import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config/ai_platforms.dart';
import '../config/app_config.dart';
import '../database/book_dao.dart';
import '../database/round_dao.dart';
import '../models/agent_event.dart';
import '../models/book.dart';
import '../models/failed_attempt.dart';
import '../models/raw_exchange.dart';
import '../models/round.dart';
import '../services/agent/agent_round_runner.dart';
import '../services/agent/agent_runner.dart';
import '../services/agent/fetch_page_tool.dart';
import '../services/agent/narr_agent_tool.dart';
import '../services/agent/state/agent_state_working_copy.dart';
import '../services/agent/state/state_tools.dart';
import '../services/agent/web_search_tool.dart';
import '../services/agent/wire_adapters.dart';
import '../services/ai_request_body_builder.dart';
import '../services/ai_response_parser.dart';
import '../services/ai_service.dart';
import '../services/html_search_service.dart';
import '../services/image_store.dart';
import '../services/non_stream_replay.dart';
import '../services/prompt_builder.dart';
import '../services/prompt_formats.dart';
import '../services/world_book_scanner.dart';
import 'ai_settings_provider.dart';
import 'cloud_sync_provider.dart';
import 'experimental_settings_provider.dart';
import 'mod_provider.dart';
import 'world_book_provider.dart';

/// 单本书的运行时生成状态（支持多本书并发生成互不干扰）。
///
/// 生成令牌 [token]：每次 `sendRound` 自增。旧一轮的残留流回调（onChunk /
/// isCancelled）捕获发起时的令牌，一旦与当前 [token] 不一致即丢弃 / 中止，
/// 从根源上杜绝「上一轮流式输出注入本轮」与双流式并存。
class _BookGenState {
  _BookGenState(this.bookUuid);

  /// 所属书籍 uuid（并发生成的分组键）。
  final String bookUuid;

  /// 生成令牌：新请求使旧残留回调失效。
  int token = 0;

  bool isSending = false;
  bool isStreaming = false;
  bool cancelRequested = false;
  String streamingContent = '';

  /// 是否处于「块时间线」展示模式：流式传输，或非流式 + 多轮
  /// （AGENT / 联网搜索）时的非流式回放——两者都渲染思考 / 工具 / 正文块。
  bool showTimeline = false;

  /// Agent 过程时间线：思考 / 搜索事件按真实顺序交错排列
  ///（思考1 → 搜索1 → 思考2 → 搜索2 …）。
  final List<AgentEvent> agentEvents = [];

  /// 正文起点边界：`contentBoundaryIndex` = 首个正文增量到达时的事件数
  ///（-1 = 正文尚未开始）。正文是「块外」的特殊块：渲染时插入到该下标，
  /// 此前的块在其上方、之后的块在其下方（严格按 AI 返回顺序）。
  int contentBoundaryIndex = -1;

  /// 正文采纳与帧级分类**不在这里**：全部在 `AgentRoundRunner` 的门控内完成，
  /// 本状态只消费「已门控」的正文增量（见 `_buildStreamingOnChunk`）。
  ///
  /// 工具流式预览：call_id → 事件下标；call_id → 已累积的原始参数文本。
  final Map<String, int> toolEventIdxByCallId = {};
  final Map<String, String> toolArgsRawByCallId = {};

  /// 下一段思考增量到达时是否新建思考事件（agent 每轮开始时置位）。
  bool newReasoningBlockPending = true;

  /// 当前自动重试进度：(已重试次数, 总次数)；null = 无重试。
  (int, int)? retryStatus;

  /// 当前尝试的 RAW 时间线（请求体 → AI返回 交错；重试时清空）。
  final List<RawExchange> rawExchanges = [];

  /// 失败条目的 RAW 时间线（最近一次失败 / 中断尝试）。
  List<RawExchange>? failedRawExchanges;

  /// AGENT 模式的状态钳制警告（修复 2 次后仍失败、已跳过应用的修改项）。
  /// 仅**生成期间**的顶部提示；结束后转存到 [roundWarnings]。
  final List<String> agentWarnings = [];

  /// 轮次级**常驻**警告：roundIndex → 提示行。
  ///
  /// 只存内存：不入库、不进云同步（属于本机生成过程的诊断信息，不该污染
  /// 用户数据或同步到其它设备）。手动关闭、重生成该轮、改提问、删除该轮
  /// 都会随轮次一起清除；换书保留（各书独立），杀进程即清空。
  final Map<int, List<String>> roundWarnings = {};

  /// [roundWarnings] 的变更计数：对话列表据此失效缓存的条目高度。
  int warningsVersion = 0;

  /// 生成期间展示的用户输入（结束 / 中断后清除）。
  String pendingUserInput = '';

  /// 本书的「失败条目」（最近一次未完成的生成尝试；空 = 无）。
  FailedAttempt failedAttempt = const FailedAttempt();
}

/// 轮次状态管理：加载、发送（组装 Prompt + 调用 AI + 解析入库）、删除、刷新、保存快照。
class RoundProvider extends ChangeNotifier {
  /// Agent 路径注入的搜索指令：引导模型在用户要求搜索或需要核实时主动调用工具
  /// （非思考模式下模型容易把「搜索」当成剧情动作，需显式声明）；
  /// 搜索后必须主动打开结果页面阅读正文，确保细节准确。
  static const String _searchInstruction =
      '【联网搜索】本工具已由用户显式开启，你应主动利用它获取真实世界信息'
      '（如核实地名、历史、设定、专有名词等，或用户要求搜索/查询/查找资料时），'
      '不必等用户逐条点名，但也不要无关紧要地频繁调用。必须按以下流程执行：\n'
      '1. 先调用 narrchat_webSearch 工具搜索，获取结果标题、链接与摘要；\n'
      '2. 必须随后用 narrchat_webFetchPage 打开最相关的 1~3 个结果页面并阅读正文，'
      '禁止只依赖摘要就动笔，务必确保细节准确；\n'
      '3. 若页面拒绝访问（HTTP 4xx/5xx）或打开失败，'
      '请换用其它结果页面继续获取信息，不要反复搜索而不打开页面；\n'
      '4. 从打开的页面正文中提炼背景、设定、人物等细节后再继续创作；\n'
      '5. 禁止在未打开任何页面的情况下直接结束联网环节开始创作。';

  /// 网络类失败自动重试的最大次数（灰字提示「错误重连……（x/3）」）。
  static const int _maxAiRetries = 3;

  RoundProvider({
    RoundDao? dao,
    BookDao? bookDao,
    AiService? aiService,
    PromptBuilder? promptBuilder,
    WorldBookScanner? worldBookScanner,
    AiSettingsProvider? aiSettingsProvider,
    /// 实验性功能设置（Agent 模式开关；null = 视为关闭，仅测试/降级路径）。
    ExperimentalSettingsProvider? experimentalSettings,
    WorldBookProvider? worldBookProvider,
    ModProvider? modProvider,
    CloudSyncProvider? cloudSyncProvider,
    /// 生成成功回调（书籍 uuid, 书名）：由 main 接入系统通知服务；
    /// 仅生成成功时触发，取消 / 失败不触发。
    this.onGenerationCompleted,
    /// 生成任务活动状态回调（active=true 首个任务开始 / false 全部结束）：
    /// 由 main 接入通知服务，用于启动 / 停止 Android 后台保活前台服务。
    this.onGenerationActiveChanged,
    WebSearchTool? webSearchTool,
    FetchPageTool? fetchPageTool,
    /// 默认搜索工具共用的搜索服务（测试可注入 mock）。
    HtmlSearchService? searchService,
    /// 非流式响应的展示回放器（测试可注入零间隔 / 大粒度以加速）。
    NonStreamReplayer? nonStreamReplayer,
    /// 网络类失败重试间隔（测试可注入零时长）。
    Duration retryDelay = const Duration(milliseconds: 800),
  })  : _dao = dao ?? RoundDao(),
        _bookDao = bookDao ?? BookDao(),
        _aiService = aiService ?? AiService(),
        _promptBuilder = promptBuilder ?? const PromptBuilder(),
        _worldBookScanner = worldBookScanner ?? const WorldBookScanner(),
        // ignore: prefer_initializing_formals
        _aiSettingsProvider = aiSettingsProvider,
        // ignore: prefer_initializing_formals
        _experimentalSettings = experimentalSettings,
        // ignore: prefer_initializing_formals
        _worldBookProvider = worldBookProvider,
        // ignore: prefer_initializing_formals
        _modProvider = modProvider,
        // ignore: prefer_initializing_formals
        _cloudSyncProvider = cloudSyncProvider,
        // ignore: prefer_initializing_formals
        _retryDelay = retryDelay {
    // 共享搜索服务实例（默认 Agent 工具按书复用，避免重复创建 http client）。
    _searchService = searchService ?? HtmlSearchService();
    _nonStreamReplayer = nonStreamReplayer ?? const NonStreamReplayer();
    // 测试 / 调用方可注入工具（非 null 时 Agent 运行优先使用）。
    _webSearchTool = webSearchTool;
    _fetchPageTool = fetchPageTool;
  }

  final RoundDao _dao;
  final BookDao _bookDao;
  final AiService _aiService;
  final PromptBuilder _promptBuilder;
  final WorldBookScanner _worldBookScanner;
  final AiSettingsProvider? _aiSettingsProvider;
  final ExperimentalSettingsProvider? _experimentalSettings;
  final WorldBookProvider? _worldBookProvider;
  final ModProvider? _modProvider;
  final CloudSyncProvider? _cloudSyncProvider;
  /// 共享搜索服务（默认 Agent 工具按书复用同一实例，避免重复创建 http client）。
  late final HtmlSearchService _searchService;

  /// 非流式响应的展示回放器（驱动与流式相同的块时间线展示）。
  late final NonStreamReplayer _nonStreamReplayer;

  /// 测试 / 调用方可注入的工具（非 null 时 Agent 运行优先使用）。
  WebSearchTool? _webSearchTool;
  FetchPageTool? _fetchPageTool;

  /// 网络类失败重试间隔。
  final Duration _retryDelay;

  /// 生成成功回调（书籍 uuid, 书名）。
  final void Function(String bookUuid, String bookTitle)? onGenerationCompleted;

  /// 生成任务活动状态回调（首个任务开始 / 全部任务结束）。
  final void Function(bool active)? onGenerationActiveChanged;

  List<Round> _rounds = [];

  /// 缓存的不可变轮次视图：仅当 [_rounds] 重新赋值时更新。
  /// UI 用 `context.select` 按引用比较该视图，避免流式输出时
  /// 轮次未变化却随每次 chunk 触发侧栏等无关组件重建。
  List<Round> _roundsView = const [];

  /// 各书运行时生成状态（key = 书籍 uuid；支持多本书并发生成互不干扰）。
  final Map<String, _BookGenState> _gens = {};

  /// 各成功轮次的 RAW 时间线（内存，key = roundId；切换书籍时清理）。
  final Map<int, List<RawExchange>> _rawDataByRound = {};

  String? _error;

  /// 当前查看书籍的 uuid（空串 = 未加载任何书）。
  String _bookUuid = '';

  /// 获取（必要时创建）指定书的运行时生成状态。
  _BookGenState _gen(String bookUuid) =>
      _gens.putIfAbsent(bookUuid, () => _BookGenState(bookUuid));

  /// 当前是否至少有一本书正在生成（用于通知服务保活启停）。
  bool _hasActiveGeneration() => _gens.values.any((g) => g.isSending);

  List<Round> get rounds => _roundsView;

  /// 当前查看书的运行时生成状态（未加载任何书或从未生成时为 null）。
  _BookGenState? get _curGen => _gens[_bookUuid];

  bool get isSending => _curGen?.isSending ?? false;
  bool get isStreaming => _curGen?.isStreaming ?? false;
  String get streamingContent => _curGen?.streamingContent ?? '';

  /// 当前是否处于「块时间线」展示模式（流式传输或非流式回放）——
  /// 决定生成中气泡渲染时间线（思考 / 工具 / 正文块）还是等待转圈提示。
  bool get showTimeline => _curGen?.showTimeline ?? false;

  /// Agent 过程时间线（思考 / 搜索交错，供流式气泡渲染）。
  List<AgentEvent> get agentEvents =>
      _curGen == null ? const [] : List.unmodifiable(_curGen!.agentEvents);

  /// 正文起点边界（-1 = 正文尚未开始；正文块插入事件序列的该下标处）。
  int get contentBoundaryIndex => _curGen?.contentBoundaryIndex ?? -1;

  /// AGENT 模式状态钳制警告（修复 2 次后仍跳过应用的修改项）。
  List<String> get agentWarnings =>
      _curGen == null ? const [] : List.unmodifiable(_curGen!.agentWarnings);

  /// 某轮的常驻警告（仅内存；生成结束时由 AGENT 写入，可手动关闭）。
  List<String> roundWarningsFor(int roundIndex) {
    final lines = _curGen?.roundWarnings[roundIndex];
    return (lines == null || lines.isEmpty) ? const [] : List.unmodifiable(lines);
  }

  /// 常驻警告的变更计数（对话列表据此重算条目高度）。
  int get roundWarningsVersion => _curGen?.warningsVersion ?? 0;

  /// 手动关闭某轮的常驻警告。
  void dismissRoundWarnings(int roundIndex) {
    final gen = _curGen;
    if (gen == null || gen.roundWarnings.remove(roundIndex) == null) return;
    gen.warningsVersion++;
    notifyListeners();
  }

  /// 写入 / 清除某轮常驻警告（[lines] 为空即清除）。不通知：由调用方收尾。
  void _setRoundWarnings(
    _BookGenState gen,
    int roundIndex,
    List<String> lines,
  ) {
    final had = gen.roundWarnings.containsKey(roundIndex);
    if (lines.isEmpty) {
      if (had) {
        gen.roundWarnings.remove(roundIndex);
        gen.warningsVersion++;
      }
      return;
    }
    if (had && listEquals(gen.roundWarnings[roundIndex]!, lines)) return;
    gen.roundWarnings[roundIndex] = List.of(lines);
    gen.warningsVersion++;
  }

  /// 清除 [fromIndex] 及之后的警告（这些轮即将被重生成 / 删除）。
  void _dropRoundWarningsFrom(_BookGenState gen, int fromIndex) {
    final before = gen.roundWarnings.length;
    gen.roundWarnings.removeWhere((index, _) => index >= fromIndex);
    if (gen.roundWarnings.length != before) gen.warningsVersion++;
  }

  /// 当前自动重试进度（灰字「错误重连……（x/3）」）；null = 无重试。
  (int, int)? get retryStatus => _curGen?.retryStatus;

  /// 指定轮次的 RAW 时间线（无数据返回 null）。
  List<RawExchange>? rawExchangesFor(int roundId) {
    final data = _rawDataByRound[roundId];
    return (data == null || data.isEmpty) ? null : data;
  }

  /// 失败条目的 RAW 时间线（无数据返回 null）。
  List<RawExchange>? get failedRawExchanges {
    final data = _curGen?.failedRawExchanges;
    return (data == null || data.isEmpty) ? null : data;
  }

  /// 当前正在生成中、尚未落库的用户输入（用于生成期间不回藏用户消息）。
  String get pendingUserInput => _curGen?.pendingUserInput ?? '';

  /// 当前查看书「失败条目」：请求失败 / 用户中断的未完成尝试（空 = 无）。
  FailedAttempt get failedAttempt =>
      _curGen?.failedAttempt ?? const FailedAttempt();

  /// 是否存在失败条目。
  bool get hasFailureEntry => !failedAttempt.isEmpty;

  /// 失败条目的用户输入（空串 = 无）。
  String get failedUserInput => failedAttempt.userInput;

  /// 失败条目附带的用户消息图片（相对路径；为空 = 无图片）。
  List<String> get failedUserImages => failedAttempt.userImages;

  /// 失败条目的错误信息（空串 = 用户中断「已截断」）。
  String get failedErrorMessage => failedAttempt.errorMessage;

  /// 当前正在生成中的书籍 uuid（供跨书进程提示栏展示，点击可跳转对应书籍）。
  List<String> get activeGenerationBookUuids =>
      [for (final g in _gens.values) if (g.isSending) g.bookUuid];

  String? get error => _error;
  Round? get latestRound => _rounds.isEmpty ? null : _rounds.last;

  /// 当前书籍下一轮的轮号（新轮 `roundIndex`；也是失败条目「本该产生的那一轮」）。
  int get nextRoundIndex => (latestRound?.roundIndex ?? 0) + 1;

  /// 中断指定书（默认当前查看书）的生成（流式会中止 HTTP 连接；非流式丢弃结果）。
  void cancelGeneration({String? bookUuid}) {
    final target = (bookUuid ?? _bookUuid);
    if (target.isEmpty) return;
    final gen = _gens[target];
    if (gen == null || !gen.isSending) return;
    gen.cancelRequested = true;
    notifyListeners();
  }

  /// 更新轮次列表并刷新缓存的不可变视图。
  void _setRounds(List<Round> rounds) {
    _rounds = rounds;
    _roundsView = List.unmodifiable(rounds);
  }

  /// 加载指定书籍的全部轮次（按 round_index 升序）。
  ///
  /// 若书籍尚无任何轮次，自动创建「第零轮」（round_index = 0），
  /// 用于在开始对话前编辑初始的世界状态与角色状态。
  Future<void> loadRounds(String bookUuid) async {
    // 切换书籍：清理旧书的内存 RAW 数据，避免跨书误配。
    if (_bookUuid.isNotEmpty && _bookUuid != bookUuid) {
      _rawDataByRound.clear();
    }
    _bookUuid = bookUuid;
    try {
      _setRounds(await _dao.getRoundsByBook(bookUuid));
      if (_rounds.isEmpty) {
        await _dao.insertRound(
          Round(bookUuid: bookUuid, roundIndex: 0, createdAt: DateTime.now()),
        );
        _setRounds(await _dao.getRoundsByBook(bookUuid));
      }
    } catch (e) {
      _error = e.toString();
    }
    // 加载本书「失败条目」（best-effort：读取失败不影响轮次加载）。
    await _loadFailedAttempt(bookUuid);
    notifyListeners();
  }

  /// 加载本书「失败条目」；读取失败时置空（不打扰用户）。
  Future<void> _loadFailedAttempt(String bookUuid) async {
    try {
      _gen(bookUuid).failedAttempt = await _bookDao.getFailedAttempt(bookUuid);
    } catch (_) {
      _gen(bookUuid).failedAttempt = const FailedAttempt();
    }
  }

  /// 写入本书「失败条目」（内存 + 数据库）；空条目即清空。返回是否成功落库。
  Future<bool> _setFailedAttempt(String bookUuid, FailedAttempt attempt) async {
    _gen(bookUuid).failedAttempt = attempt;
    notifyListeners();
    try {
      await _bookDao.setFailedAttempt(bookUuid, attempt);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清除本书「失败条目」（UI「清除失败条目」入口）。
  Future<void> clearFailedAttempt() async {
    if (_bookUuid.isEmpty) return;
    final gen = _gen(_bookUuid);
    gen.failedRawExchanges = null;
    // 挂在「本该产生的那一轮」上的常驻警告一并清除。
    _dropRoundWarningsFrom(gen, nextRoundIndex);
    await _setFailedAttempt(_bookUuid, const FailedAttempt());
    notifyListeners();
  }

  /// 重新加载当前书籍的轮次（云同步恢复数据后调用）。
  ///
  /// 云同步「删除并恢复」后，当前书籍可能已被覆盖删除：
  /// 先确认书籍仍存在，避免对已删除书籍误建「第零轮」触发外键错误。
  Future<void> reloadCurrent() async {
    if (_bookUuid.isEmpty) return;
    final exists = await _bookDao.getBookByUuid(_bookUuid) != null;
    if (!exists) {
      _setRounds([]);
      notifyListeners();
      return;
    }
    await loadRounds(_bookUuid);
  }

  /// 预览「此刻若发送将实际发出」的请求体 JSON（pretty 格式化，不发送）。
  ///
  /// 与 [sendRound] 共用同一组装逻辑，保证与实发完全一致：
  /// - AGENT 模式（实验性开关）：返回正文轮首帧（线路形态由协议决定）；
  /// - 联网搜索开启：返回工具循环首帧（system 追加【联网搜索】指令 + 工具 schema）；
  /// - 联网搜索关闭：返回直发请求体（无工具）。
  ///
  /// 无任何副作用（不落库 / 不发网络 / 不改生成状态）。
  Future<String> previewRequestBody({
    required String userInput,
    Book? book,
    List<String>? userImages,
  }) async {
    final b = book;
    if (b == null || b.uuid.isEmpty) {
      throw StateError('尚未选择书籍');
    }
    final req = await _assembleRoundRequest(
      book: b,
      userInput: userInput,
      userImages: userImages,
    );
    final Map<String, dynamic> firstBody;
    if (req.agent) {
      // AGENT 模式：预览正文轮首帧（与实发同一条组装路径）。
      firstBody = req.directBody;
    } else if (req.useSearch) {
      // 联网搜索工具循环：与实发共用同一线段（线路 / schema 形状一致）。
      final searchTools = _makeAgentTools(null);
      final runner = AgentRunner(
        buildBody: _makeBodyBuilder(
          _aiSettingsProvider,
          req.useStream,
          responsesWire: req.responsesWire,
        ),
        // 预览只构建首帧，不发起任何 AI 调用（call 永不被触发）。
        call: (_, _, _, _, _) => throw UnsupportedError('预览不发起 AI 调用'),
        // 仅用于读取工具 schema（name/description/parameters），绝不执行 run。
        tools: searchTools,
        toolSchemas: agentToolSchemas(searchTools, responses: req.responsesWire),
      );
      firstBody = runner.previewFirstBody([
        {
          'role': 'system',
          'content': '${req.systemPrompt}\n\n$_searchInstruction',
        },
        ...req.historyMessages,
        {'role': 'user', 'content': req.userContent},
      ]);
    } else {
      firstBody = req.directBody;
    }
    return const JsonEncoder.withIndent('  ').convert(firstBody);
  }

  /// 组装本轮「将要发出」的请求要素（纯组装，无副作用）：
  /// worldBook / Mod / 提示词 / 历史消息与图片 / 发送参数与请求体。
  ///
  /// 供 [sendRound] 与「预览请求体」共用：不读写任何生成状态、不落库、不发网络。
  Future<_RoundRequest> _assembleRoundRequest({
    required Book book,
    required String userInput,
    List<String>? userImages,
  }) async {
    final settings = _aiSettingsProvider;
    final lastRound = latestRound;
    final recentRounds = _takeRecent(book.historyRounds);
    final worldBookEntries = _worldBookScanner.scan(
      userInput: userInput,
      historyRounds: recentRounds,
      entries: _worldBookProvider?.activeEntries ?? const [],
    );
    // 本书启用的 Mod：实时解析并置入前置词/后置词/系统提示词/世界书
    //（Mod 世界书条目与书籍世界书一致：关键词命中才注入，留空则恒定生效）。
    final modsBundle = _modProvider == null
        ? null
        : await _modProvider.resolveModsBundle(
            bookUuid: book.uuid,
            userInput: userInput,
            historyRounds: recentRounds,
          );
    // 模式与协议**正交**（全解耦）：
    // - agentMode：实验性开关（默认关闭）——两阶段生成 + 自定义工具；
    //   无设置注入（仅测试/降级路径）保持 Chat 语义；
    // - responsesWire：平台接入协议决定的线路格式（只决定请求体形态）。
    final agentMode =
        settings != null && (_experimentalSettings?.agentModeEnabled ?? false);
    final responsesWire =
        settings?.selectedPlatform.apiType.isResponses ?? false;
    // 按模式组装本轮提示词：Chat / AGENT 共享同一构建流程，仅格式要求不同
    //（AGENT 模式下 systemPrompt 即 Response API 的 instructions 字段）。
    final prompts = _promptBuilder.build(
      book: book,
      lastRound: lastRound,
      userInput: userInput,
      worldBookEntries: worldBookEntries,
      mods: modsBundle,
      mode: agentMode ? PromptMode.agent : PromptMode.chat,
    );

    // 历史轮次按 API 要求以原生 messages 数组（user/assistant 交替）传入，
    // 而非拼入本次 Prompt 文本。
    final supportsVision = settings?.supportsVision ?? false;
    // 预读取本轮及历史用户消息所需图片为 base64 data URL（仅识图模型）。
    final imageDataUrls = supportsVision
        ? await _collectImageDataUrls(recentRounds, userImages)
        : const <String, String>{};
    final historyMessages = PromptBuilder.buildHistoryMessages(
      recentRounds,
      imagePartsFor: supportsVision
          ? (r) => _imagePartsFor(r, imageDataUrls)
          : null,
      // AGENT：assistant 历史只携带三个正文小节（剧情/行动/时间；世界/角色/
      // 记忆的唯一来源是 `narrchat_readState` 工具结果）——历史里的 6 区块
      // 是模型照抄 Chat 格式的直接原因。
      storyOnly: agentMode,
    );
    final userText = prompts.userPrompt;
    final userContent = supportsVision
        ? _userContentWithImages(
            userText,
            userImages,
            imageDataUrls,
          )
        : userText;

    // 搜索能力：默认关闭，用户可在 Chat 页选项下拉中手动开启（lastSearch）；
    // 无设置注入时按预设能力回退（仅测试/降级路径）。
    final useSearch = settings == null
        ? AiPlatforms.defaultSupportsSearch
        : (settings.supportsSearch && settings.lastSearch);
    final useStream = settings?.streaming ?? true;
    final model = (settings?.model.trim().isNotEmpty ?? false)
        ? settings!.model
        : AiPlatforms.defaultModelId;
    final thinking = settings?.thinking ?? AiPlatforms.defaultThinking;
    final reasoningEffort =
        settings?.reasoningEffort ?? AppConfig.defaultReasoningEffort;
    final temperature = settings?.temperature ?? 1.0;
    final maxTokens = settings?.maxTokens;

    // AGENT 模式：两阶段执行器（正文轮 → 状态轮）+ 自定义状态/搜索工具。
    // 线路（responses / chat）只影响请求体形态，执行器结构完全一致：
    // - responses 线路：instructions + input items + 顶层工具 schema；
    // - chat 线路：system 消息 + role 消息 + 嵌套 function schema，
    //   执行器帧内追加的 function_call 条目在组装时转 chat 消息形态。
    if (agentMode) {
      final instructions = useSearch
          ? '${prompts.systemPrompt}\n\n$_searchInstruction'
          : prompts.systemPrompt;
      // AI 看到的初始 input：历史消息 + 当前用户消息（vision 图片在
      // responses 线路下转换为 input_image 内容块）；状态快照**不预置**，
      // 由模型主动调用 narrchat_readState 获取（见 AgentRoundRunner 文档）。
      final inputItems = responsesWire
          ? responsesItemsFromChatMessages([
              ...historyMessages,
              {'role': 'user', 'content': userContent},
            ])
          : [
              {'role': 'system', 'content': instructions},
              ...historyMessages,
              {'role': 'user', 'content': userContent},
            ];
      // 工具 schema 超集（状态工具 + 可选搜索工具），**两阶段共用同一份**：
      // tools 数组任何差异都会改变请求前缀，使服务商的上下文缓存整段失效。
      final schemaTools = [
        ...buildStateTools(
          AgentStateWorkingCopy(
            roundIndex: (lastRound?.roundIndex ?? 0) + 1,
            lastRound: lastRound,
            categoryNames: [for (final c in book.roleCategories) c.name],
          ),
        ),
        if (useSearch) ..._makeAgentTools(null),
      ];
      final agentValues = AiRequestValues(
        model: model,
        messages: inputItems,
        temperature: temperature,
        thinking: thinking,
        reasoningEffort: reasoningEffort,
        maxTokens: maxTokens,
        stream: useStream,
        tools: agentToolSchemas(schemaTools, responses: responsesWire),
        instructions: responsesWire ? instructions : null,
      );
      // 预览 = 正文轮首帧的**同一条**组装路径（单一真源）。
      final firstBody = responsesWire
          ? _agentBody(
              settings: settings,
              base: agentValues,
              t: AgentTurnRequest(
                stage: AgentStage.story,
                items: inputItems,
                toolChoice: settings.selectedPlatform.apiType.supportsToolChoice
                    ? 'auto'
                    : null,
              ),
            )
          : _agentChatBody(
              settings: settings,
              base: agentValues,
              t: AgentTurnRequest(
                stage: AgentStage.story,
                items: inputItems,
                toolChoice: settings.selectedPlatform.apiType.supportsToolChoice
                    ? 'auto'
                    : null,
              ),
            );
      return _RoundRequest(
        systemPrompt: prompts.systemPrompt,
        historyMessages: historyMessages,
        userContent: userContent,
        model: model,
        useStream: useStream,
        useSearch: useSearch,
        directBody: firstBody,
        agent: true,
        responsesWire: responsesWire,
        agentValues: agentValues,
        agentChaining:
            responsesWire && settings.selectedPlatform.supportsResponseChaining,
        agentToolChoice: settings.selectedPlatform.apiType.supportsToolChoice,
      );
    }

    // Chat 模式（Agent 关闭）：按当前预设（规则构建器）动态组合请求体。
    // 线路规则：chat 线路 = system 消息 + 普通消息直发；responses 线路 =
    // instructions（系统提示词）+ input items（与 Chat 协议同构的消息），
    // **不引入任何 Agent 工具 / 状态机制**——协议只决定线路格式。
    if (responsesWire) {
      final instructions = useSearch
          ? '${prompts.systemPrompt}\n\n$_searchInstruction'
          : prompts.systemPrompt;
      final values = AiRequestValues(
        model: model,
        messages: responsesItemsFromChatMessages([
          ...historyMessages,
          {'role': 'user', 'content': userContent},
        ]),
        temperature: temperature,
        thinking: thinking,
        reasoningEffort: reasoningEffort,
        maxTokens: maxTokens,
        stream: useStream,
        tools: null,
        instructions: instructions,
      );
      final requestBody = settings == null
          ? AiRequestBodyBuilder.buildPresetBody(
              rules: AiPlatforms.defaultRules,
              values: values,
            )
          : settings.buildRequestBody(values);
      return _RoundRequest(
        systemPrompt: prompts.systemPrompt,
        historyMessages: historyMessages,
        userContent: userContent,
        model: model,
        useStream: useStream,
        useSearch: useSearch,
        directBody: requestBody,
        responsesWire: true,
      );
    }

    final values = AiRequestValues(
      model: model,
      messages: [
        {'role': 'system', 'content': prompts.systemPrompt},
        ...historyMessages,
        {'role': 'user', 'content': userContent},
      ],
      temperature: temperature,
      thinking: thinking,
      reasoningEffort: reasoningEffort,
      maxTokens: maxTokens,
      stream: useStream,
      tools: null,
    );
    final requestBody = settings == null
        ? AiRequestBodyBuilder.buildPresetBody(
            rules: AiPlatforms.defaultRules,
            values: values,
          )
        : settings.buildRequestBody(values);
    return _RoundRequest(
      systemPrompt: prompts.systemPrompt,
      historyMessages: historyMessages,
      userContent: userContent,
      model: model,
      useStream: useStream,
      useSearch: useSearch,
      directBody: requestBody,
    );
  }

  /// 发送新一轮：
  /// 0. 清空本书「失败条目」（成功则保持为空，失败则重新写入）；
  /// 1. 组装 System/User Prompt；
  /// 2. 按 AI 设置调用大模型（支持流式/思考/温度/模型）；
  /// 3. 容错解析 6 个区块；
  /// 4. 写入数据库。
  ///
  /// 返回是否成功。请求失败 / 用户中断时保留用户输入到「失败条目」
  /// （AI 输出以红色提示框占位），不再以消息提示；
  /// 仅当失败条目落库也失败时通过 [error] 暴露原因。
  Future<bool> sendRound({
    required String userInput,
    Book? book,
    List<String>? userImages,
  }) async {
    final b = book;
    if (b == null || b.uuid.isEmpty) {
      _error = '尚未选择书籍';
      notifyListeners();
      return false;
    }
    final gen = _gen(b.uuid);
    if (gen.isSending) {
      _error = '正在请求中，请稍候';
      return false;
    }

    final settings = _aiSettingsProvider;
    // 生成令牌：本轮唯一。旧一轮的残留流回调（onChunk / isCancelled）捕获发起时
    // 的令牌，一旦与当前不一致即丢弃 / 中止，杜绝跨轮注入与双流式并存。
    gen.token++;
    final genToken = gen.token;
    // 记录本次请求开始前是否已有其它生成任务（用于「首个任务开始」通知服务）。
    final wasActive = _hasActiveGeneration();
    gen.isSending = true;
    gen.cancelRequested = false;
    _error = null;
    // 记录本次用户输入：生成期间在消息列表中展示，结束/中断后清除。
    gen.pendingUserInput = userInput;
    // 重置 Agent 过程时间线、重试状态、状态钳制警告与 RAW 时间线。
    gen.agentEvents.clear();
    gen.contentBoundaryIndex = -1;
    gen.agentWarnings.clear();
    // 本轮（含上一次失败尝试留下的）常驻警告随重生成清除。
    _dropRoundWarningsFrom(gen, nextRoundIndex);
    gen.newReasoningBlockPending = true;
    gen.retryStatus = null;
    gen.rawExchanges.clear();
    gen.failedRawExchanges = null;
    notifyListeners();
    // 首个生成任务开始：通知服务启动 Android 后台保活前台服务。
    if (!wasActive) onGenerationActiveChanged?.call(true);
    try {
      // 开始新请求：清空本书「失败条目」（失败则稍后重新写入）。
      await _setFailedAttempt(b.uuid, const FailedAttempt());
      // 组装本轮请求要素（worldBook / Mod / 提示词 / 历史消息与图片 / 参数与请求体）：
      // 与「预览请求体」共用同一逻辑，保证预览与实发完全一致。
      final req = await _assembleRoundRequest(
        book: b,
        userInput: userInput,
        userImages: userImages,
      );
      // 非流式 + 多轮（AGENT / 联网搜索）：启用「展示回放」——一次性响应
      // 切成合成流式块，按 AI 轮次展示每个块（思考 / 工具过程 → 结果 / 正文）。
      final displayReplay = !req.useStream && (req.agent || req.useSearch);
      gen.showTimeline = req.useStream || displayReplay;
      gen.streamingContent = '';
      if (req.useStream) {
        gen.isStreaming = true;
      }
      notifyListeners();

      final onChunk = _buildStreamingOnChunk(
        gen,
        genToken,
        enabled: req.useStream || displayReplay,
      );
      // 取消闭包：用户显式中断，或本轮令牌已过期（新一轮已发起）都视为取消，
      // 使上一轮残留流自行中止，绝不继续向本轮注入内容。
      bool isCancelled() => gen.cancelRequested || genToken != gen.token;
      // 模式与协议正交分派：
      // - Agent 模式（开关开）→ 两阶段执行器（线路由 req.responsesWire 决定）；
      // - 联网搜索 → Agent 工具循环（线路同样由 protocol 决定）；
      // - 直发 → 单轮请求（responses 线路走 /responses，chat 线路走 chat）。
      final agentOutcome = req.agent
          ? await _callWithRetry(
              () => _runAgentRound(
                req: req,
                settings: settings,
                book: b,
                gen: gen,
                apiBaseUrl:
                    settings?.baseUrl ?? AppConfig.defaultApiBaseUrlEffective,
                apiKey: settings?.apiKey ?? AppConfig.defaultApiKeyEffective,
                onChunk: onChunk,
                isCancelled: isCancelled,
              ),
              gen: gen,
              genToken: genToken,
            )
          : null;
      final result = req.agent
          ? agentOutcome!.result
          : req.useSearch
          ? await _callWithRetry(
              () => _runAgent(
                settings: settings,
                apiBaseUrl:
                    settings?.baseUrl ?? AppConfig.defaultApiBaseUrlEffective,
                apiKey: settings?.apiKey ?? AppConfig.defaultApiKeyEffective,
                initialMessages: [
                  {
                    'role': 'system',
                    'content': '${req.systemPrompt}\n\n$_searchInstruction',
                  },
                  ...req.historyMessages,
                  {'role': 'user', 'content': req.userContent},
                ],
                useStream: req.useStream,
                onChunk: onChunk,
                gen: gen,
                isCancelled: isCancelled,
                responsesWire: req.responsesWire,
              ),
              gen: gen,
              genToken: genToken,
            )
          : await _callWithRetry(
              () => req.responsesWire
                  ? _responsesCapturing(
                      gen: gen,
                      requestBody: req.directBody,
                      apiBaseUrl:
                          settings?.baseUrl ??
                          AppConfig.defaultApiBaseUrlEffective,
                      apiKey: settings?.apiKey ??
                          AppConfig.defaultApiKeyEffective,
                      stream: req.useStream,
                      onChunk: onChunk,
                      isCancelled: isCancelled,
                    )
                  : _chatCapturing(
                      gen: gen,
                      requestBody: req.directBody,
                      apiBaseUrl:
                          settings?.baseUrl ??
                          AppConfig.defaultApiBaseUrlEffective,
                      apiKey: settings?.apiKey ??
                          AppConfig.defaultApiKeyEffective,
                      stream: req.useStream,
                      onChunk: onChunk,
                      isCancelled: isCancelled,
                    ),
              gen: gen,
              genToken: genToken,
            );
      // 用户主动中断：丢弃部分内容，以「已截断」失败条目保留用户输入。
      if (gen.cancelRequested) {
        gen.isStreaming = false;
        gen.showTimeline = false;
        gen.streamingContent = '';
        gen.agentEvents.clear();
        gen.failedRawExchanges = List.of(gen.rawExchanges);
        await _setFailedAttempt(
          b.uuid,
          FailedAttempt(
            userInput: userInput,
            userImages: userImages ?? const [],
          ),
        );
        return false;
      }
      gen.isStreaming = false;
      gen.showTimeline = false;
      gen.streamingContent = '';
      gen.agentEvents.clear();

      final parsed = AiResponseParser.parse(result.content);
      // AGENT 模式：状态**只**来自本轮工作副本的合并结果（模型不再以文本
      // 区块输出状态，正文里也没有状态区块可解析）；未落地的缺项由
      // `AgentRoundResult.warnings` 常驻提示。Chat 模式仍解析文本区块。
      final agentSnapshot = agentOutcome?.snapshot;

      final newRound = Round(
        bookUuid: b.uuid,
        roundIndex: nextRoundIndex,
        userInput: userInput,
        aiNarrative: parsed.aiNarrative,
        worldState: agentSnapshot?.worldState ?? parsed.worldState,
        characterState:
            agentSnapshot?.characterState ?? parsed.characterState,
        memorySummary:
            agentSnapshot?.memorySummary ?? parsed.memorySummary,
        currentTime: agentSnapshot?.currentTime ?? parsed.currentTime,
        recommendedAction: parsed.recommendedAction,
        tokensIn: result.promptTokens,
        tokensOut: result.completionTokens,
        // 本轮实际使用的模型名（{{model}} 解析值），随轮次持久化。
        modelName: req.model,
        // 用户消息附带的图片（相对路径），随轮次落库，供气泡展示与历史回放。
        userImages: userImages ?? const [],
        createdAt: DateTime.now(),
      );
      final newRoundId = await _dao.insertRound(newRound);
      // 结束态：生成期间的顶部警告转存为该轮的常驻警告（空即清除上一轮失败
      // 尝试留下的同下标提示）；只存内存，不入库、不云同步。
      _setRoundWarnings(gen, newRound.roundIndex, gen.agentWarnings);
      // 成功轮次：RAW 时间线归属到本轮（随后清理当前缓冲）。
      _rawDataByRound[newRoundId] = List.of(gen.rawExchanges);
      gen.rawExchanges.clear();
      // 自动云同步：所有生成结束路径（成功 / 失败 / 中断）统一在 finally 触发，
      // 不阻塞本轮返回；上传失败也不影响本轮结果。
      if (_bookUuid == b.uuid) {
        await loadRounds(b.uuid);
      }
      // 生成成功：通知系统通知服务（若用户不在该书 chat 页则弹出系统通知）。
      onGenerationCompleted?.call(b.uuid, b.title);
      return true;
    } on AiCancelledException {
      // 用户主动中断（非流式场景由 _chatOnce 抛出）：不提示错误，
      // 以「已截断」失败条目保留用户输入。
      gen.isStreaming = false;
      gen.showTimeline = false;
      gen.streamingContent = '';
      gen.agentEvents.clear();
      _error = null;
      gen.failedRawExchanges = List.of(gen.rawExchanges);
      await _setFailedAttempt(
        b.uuid,
        FailedAttempt(
          userInput: userInput,
          userImages: userImages ?? const [],
        ),
      );
      return false;
    } catch (e) {
      // 请求失败：以「生成失败 + 原因」失败条目保留用户输入（不再弹消息提示）。
      gen.isStreaming = false;
      gen.showTimeline = false;
      gen.streamingContent = '';
      gen.agentEvents.clear();
      gen.failedRawExchanges = List.of(gen.rawExchanges);
      final saved = await _setFailedAttempt(
        b.uuid,
        FailedAttempt(
          userInput: userInput,
          errorMessage: e.toString(),
          userImages: userImages ?? const [],
        ),
      );
      // 仅当失败条目落库也失败时才暴露原因（UI 兜底提示并恢复输入）。
      _error = saved ? null : e.toString();
      return false;
    } finally {
      gen.isSending = false;
      gen.cancelRequested = false;
      gen.pendingUserInput = '';
      gen.retryStatus = null;
      gen.rawExchanges.clear();
      // 全部生成任务结束：通知服务停止 Android 后台保活前台服务。
      if (!_hasActiveGeneration()) {
        onGenerationActiveChanged?.call(false);
      }
      notifyListeners();
      // 自动云同步：生成结束（成功落库 / 失败条目 / 用户中断均会改动本地数据），
      // 全自动模式下异步触发一次同步；不在队内重复触发（provider 内部排队）。
      _cloudSyncProvider?.triggerSync();
    }
  }

  /// 包裹一次 AI 调用并捕获 RAW 交换记录（请求体 + 返回三块）。
  ///
  /// 直发路径与 Agent 工具循环（逐迭代）共用：调用前入列一条携带请求体的
  /// 交换记录，返回后回填思考 / 搜索 / 正文三块。
  Future<AiCallResult> _chatCapturing({
    required _BookGenState gen,
    required Map<String, dynamic> requestBody,
    required String apiBaseUrl,
    required String apiKey,
    required bool stream,
    required void Function(AiStreamChunk chunk)? onChunk,
    required bool Function() isCancelled,
  }) async {
    final exchange = RawExchange(
      requestBody: const JsonEncoder.withIndent('  ').convert(requestBody),
    );
    gen.rawExchanges.add(exchange);
    final result = await _aiService.chat(
      apiBaseUrl: apiBaseUrl,
      apiKey: apiKey,
      requestBody: requestBody,
      stream: stream,
      onChunk: onChunk,
      isCancelled: isCancelled,
    );
    // 非流式 + 展示回放（onChunk 仅在流式或回放模式非空）：把一次性响应
    // 切成合成块驱动块时间线。工具预览由活动回调创建（Chat 搜索循环），
    // 此处不开启，避免「联网搜索框 + Tool 框」双框。
    if (!stream && onChunk != null) {
      await _nonStreamReplayer.replay(
        result,
        emit: onChunk,
        isStopped: isCancelled,
      );
    }
    exchange
      ..thinking = result.reasoningContent
      ..toolCalls = _formatToolCalls(result.toolCalls)
      ..content = result.content;
    return result;
  }

  /// 把工具调用格式化为 RAW 展示用的 JSON 文本（空 = 无搜索块）。
  static String _formatToolCalls(List<AiToolCall> calls) {
    if (calls.isEmpty) return '';
    return const JsonEncoder.withIndent('  ').convert([
      for (final c in calls)
        {'id': c.id, 'name': c.name, 'arguments': c.arguments},
    ]);
  }

  /// 带自动重试的 AI 调用。
  ///
  /// - 网络 / 连接 / 超时类失败（[AiExceptionKind.network]）：显示灰字
  ///   「错误重连……（x/3）」，重置流式内容与 Agent 时间线后自动重试，
  ///   最多 [_maxAiRetries] 次；
  /// - API 业务类失败（[AiExceptionKind.api]）与用户中断：不重试，直接抛出。
  Future<T> _callWithRetry<T>(
    Future<T> Function() action, {
    required _BookGenState gen,
    required int genToken,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final result = await action();
        gen.retryStatus = null;
        return result;
      } on AiCancelledException {
        rethrow;
      } catch (e) {
        if (attempt >= _maxAiRetries ||
            classifyAiErrorKind(e) != AiExceptionKind.network ||
            gen.cancelRequested) {
          rethrow;
        }
        // 重置流式内容与 Agent 时间线，展示重试提示并稍候重试。
        gen.streamingContent = '';
        gen.agentEvents.clear();
        gen.contentBoundaryIndex = -1;
        gen.agentWarnings.clear();
        gen.newReasoningBlockPending = true;
        gen.rawExchanges.clear();
        gen.retryStatus = (attempt + 1, _maxAiRetries);
        notifyListeners();
        if (_retryDelay > Duration.zero) {
          await Future<void>.delayed(_retryDelay);
        }
        if (gen.cancelRequested) {
          throw const AiCancelledException();
        }
      }
    }
  }

  /// Agent 工具循环执行（本轮开启联网搜索时）。
  ///
  /// 首轮带 `narrchat_webSearch` 工具调用模型；若模型请求搜索则执行并把结果
  /// 回传，直至模型返回最终内容（6 区块）或达到最大迭代次数。
  // ---------------------------------------------------------------------------
  // 图片 → OpenAI 兼容 vision content（base64 data URL）
  // ---------------------------------------------------------------------------

  /// 收集本轮及历史轮次用户消息所需图片的 data URL（按相对路径缓存）。
  ///
  /// 仅被识图模型调用；缺失文件跳过（不阻断发送，UI 侧以占位图提示）。
  Future<Map<String, String>> _collectImageDataUrls(
    List<Round> historyRounds,
    List<String>? currentImages,
  ) async {
    final paths = <String>{
      ...?currentImages,
      for (final r in historyRounds) ...r.userImages,
    };
    final result = <String, String>{};
    for (final path in paths) {
      try {
        result[path] = await _imageDataUrl(path);
      } catch (_) {
        // 文件缺失 / 读取失败：跳过，避免整请求失败。
      }
    }
    return result;
  }

  /// 单个图片 → data URL（`data:image/<ext>;base64,<…>`）。
  Future<String> _imageDataUrl(String relPath) async {
    final bytes = await ImageStore.readBytes(relPath);
    final ext = ImageStore.normalizeExt(relPath);
    return 'data:image/$ext;base64,${base64Encode(bytes)}';
  }

  /// 为某历史轮次用户消息构造图片 parts（无可用图片则返回空）。
  List<Map<String, dynamic>> _imagePartsFor(
    Round round,
    Map<String, String> dataUrls,
  ) {
    return [
      for (final path in round.userImages)
        if (dataUrls.containsKey(path))
          {
            'type': 'image_url',
            'image_url': {'url': dataUrls[path]!, 'detail': 'high'},
          },
    ];
  }

  /// 组装当前用户消息 `content`：有图片为数组，否则为纯文本字符串。
  Object _userContentWithImages(
    String text,
    List<String>? userImages,
    Map<String, String> dataUrls,
  ) {
    final parts = <Map<String, dynamic>>[];
    for (final path in (userImages ?? const [])) {
      if (dataUrls.containsKey(path)) {
        parts.add({
          'type': 'image_url',
          'image_url': {'url': dataUrls[path]!, 'detail': 'high'},
        });
      }
    }
    if (parts.isEmpty) return text;
    return [
      {'type': 'text', 'text': text},
      ...parts,
    ];
  }

  /// 按当前 AI 设置动态构建「工具循环」请求体（规则构建器 / 自定义模板）。
  ///
  /// 供 `_runAgent` 与「预览请求体」共用：同一构建器保证首帧请求与预览
  /// 完全一致。[responsesWire] 为 true 时按 Responses 线路组装——system 消息
  /// 抽出为 `instructions`，其余消息转 input items（含 tool_calls 展开为
  /// function_call）；Chat 线路原样传入 `messages`。
  Map<String, dynamic> Function(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
  ) _makeBodyBuilder(
    AiSettingsProvider? settings,
    bool useStream, {
    required bool responsesWire,
  }) {
    return (messages, tools) {
      final parts = responsesWire
          ? responsesPartsFromChatMessages(messages)
          : (instructions: null, items: messages);
      final values = AiRequestValues(
        model: (settings?.model.trim().isNotEmpty ?? false)
            ? settings!.model
            : AiPlatforms.defaultModelId,
        messages: parts.items,
        temperature: settings?.temperature ?? 1.0,
        thinking: settings?.thinking ?? AiPlatforms.defaultThinking,
        reasoningEffort:
            settings?.reasoningEffort ?? AppConfig.defaultReasoningEffort,
        maxTokens: settings?.maxTokens,
        stream: useStream,
        tools: tools,
        instructions: parts.instructions,
      );
      return settings == null
          ? AiRequestBodyBuilder.buildPresetBody(
              rules: AiPlatforms.defaultRules,
              values: values,
            )
          : settings.buildRequestBody(values);
    };
  }

  /// 默认 Agent 工具列表（搜索 + 抓取）。
  ///
  /// [gen] 为 null 时仅用于「预览请求体」读取工具 schema：全部过程回调置空
  ///（工具只读 name/description/parameters，绝不执行 run，无副作用）。
  /// 测试 / 调用方可注入工具（非 null 时 Agent 运行优先使用）。
  List<NarrAgentTool> _makeAgentTools(_BookGenState? gen) {
    return [
      _webSearchTool ??
          WebSearchTool(
            search: _searchService,
            onResults: gen == null
                ? null
                : (r) => _handleSearchResults(r, gen),
            onFail: gen == null ? null : () => _handleSearchFail(gen),
          ),
      _fetchPageTool ??
          FetchPageTool(
            search: _searchService,
            onDone: gen == null ? null : () => _handleFetchDone(gen),
            onFail: gen == null ? null : () => _handleFetchFail(gen),
            onRefused: gen == null
                ? null
                : () => _handleFetchFail(gen, refused: true),
            onHop: gen == null ? null : (h) => _handleFetchHop(h, gen),
          ),
    ];
  }

  Future<AiCallResult> _runAgent({
    required AiSettingsProvider? settings,
    required String apiBaseUrl,
    required String apiKey,
    required List<Map<String, dynamic>> initialMessages,
    required bool useStream,
    required void Function(AiStreamChunk chunk)? onChunk,
    required _BookGenState gen,
    required bool Function() isCancelled,
    required bool responsesWire,
  }) async {
    final tools = _makeAgentTools(gen);
    final runner = AgentRunner(
      // 与「预览请求体」共用同一构建器：规则构建器 / 自定义模板一致；
      // 线路（chat / responses）与工具 schema 形状都由协议选择决定。
      buildBody: _makeBodyBuilder(
        settings,
        useStream,
        responsesWire: responsesWire,
      ),
      call: (requestBody, stream, onChunk, onRequestBody, isCancelled) =>
          responsesWire
              ? _responsesCapturing(
                  gen: gen,
                  requestBody: requestBody,
                  apiBaseUrl: apiBaseUrl,
                  apiKey: apiKey,
                  stream: stream,
                  onChunk: onChunk,
                  isCancelled: isCancelled ?? () => false,
                )
              : _chatCapturing(
                  gen: gen,
                  requestBody: requestBody,
                  apiBaseUrl: apiBaseUrl,
                  apiKey: apiKey,
                  stream: stream,
                  onChunk: onChunk,
                  isCancelled: isCancelled ?? () => false,
                ),
      // 每个 Agent 运行使用绑定到本书生成状态的工具实例：多本书并发生成时，
      // 搜索 / 抓取过程事件（UI 展示）互不串书；测试注入的工具优先。
      tools: tools,
      toolSchemas: agentToolSchemas(tools, responses: responsesWire),
    );

    return runner.run(
      initialMessages: initialMessages,
      stream: useStream,
      onChunk: onChunk,
      isCancelled: isCancelled,
      onActivity: (a) => _handleAgentActivity(a, gen),
    );
  }

  /// AGENT 单轮执行（两阶段 + 状态自取；线路由 req.responsesWire 决定）。
  ///
  /// 返回聚合结果（正文 = 最后一个标题帧）、工作副本合并快照与执行器结果。
  /// 状态**只**来自工作副本：模型不再以文本区块输出状态，故无文本兜底。
  Future<
      ({
        AiCallResult result,
        RoundSnapshot snapshot,
        AgentRoundResult agent,
      })> _runAgentRound({
    required _RoundRequest req,
    required AiSettingsProvider? settings,
    required Book book,
    required _BookGenState gen,
    required String apiBaseUrl,
    required String apiKey,
    required void Function(AiStreamChunk chunk)? onChunk,
    required bool Function() isCancelled,
  }) async {
    final workingCopy = AgentStateWorkingCopy(
      roundIndex: (latestRound?.roundIndex ?? 0) + 1,
      lastRound: latestRound,
      categoryNames: [for (final c in book.roleCategories) c.name],
    );
    // 工具超集：状态工具 + （可选）搜索工具，两阶段共用同一份 schema，
    // 保证 instructions / tools 前缀在正文轮与状态轮之间完全一致。
    final tools = <NarrAgentTool>[
      ...buildStateTools(workingCopy),
      if (req.useSearch) ..._makeAgentTools(gen),
    ];
    final values = req.agentValues!;
    final runner = AgentRoundRunner(
      // 线路决定请求体形态（responses / chat），执行器结构与帧语义不变。
      buildBody: (t) => req.responsesWire
          ? _agentBody(settings: settings, base: values, t: t)
          : _agentChatBody(settings: settings, base: values, t: t),
      call: (body, stream, onChunk, onRequestBody, isCancelled) =>
          req.responsesWire
              ? _responsesCapturing(
                  gen: gen,
                  requestBody: body,
                  apiBaseUrl: apiBaseUrl,
                  apiKey: apiKey,
                  stream: stream,
                  onChunk: onChunk,
                  isCancelled: isCancelled ?? () => false,
                )
              : _chatCapturing(
                  gen: gen,
                  requestBody: body,
                  apiBaseUrl: apiBaseUrl,
                  apiKey: apiKey,
                  stream: stream,
                  onChunk: onChunk,
                  isCancelled: isCancelled ?? () => false,
                ),
      tools: tools,
      workingCopy: workingCopy,
      chaining: req.agentChaining,
      supportsToolChoice: req.agentToolChoice,
      // AGENT 单轮路径：搜索 / 打开页面事件由工具事件（流式预览 / 开始 /
      // 完成）**统一承载**——同一工具调用只产生一个事件框；活动回调仅用于
      // 新一轮思考块管理（否则会出现「联网搜索框 + Tool 框」双框）。
      onActivity: (a) {
        if (a.type == AgentActivityType.turn) {
          _handleAgentActivity(a, gen);
        }
      },
      onToolStarted: (o) => _handleToolStarted(o, gen),
      onToolFinished: (o) => _handleToolFinished(o, gen),
    );

    final roundResult = await runner.run(
      initialInputItems: values.messages,
      stream: req.useStream,
      onChunk: onChunk,
      isCancelled: isCancelled,
    );
    if (roundResult.content.trim().isEmpty) {
      // 整轮没有任何正文（纯工具轮 / 服务端只回工具调用 / 首帧即被截断）：
      // 本轮判失败，走既有的「失败条目保留用户输入」路径，不写入半截轮次；
      // 同时留下常驻黄框说明后果（状态改动随工作副本一起作废，仅内存提示）。
      final truncated = roundResult.incomplete;
      _setRoundWarnings(gen, workingCopy.roundIndex, [
        truncated
            ? '本轮未产出正文（模型输出在上限处被截断），本轮的状态改动已作废。'
                  '请在设置中调高「最大 token」后重试。'
            : '本轮未产出正文（模型只返回了工具调用），本轮的状态改动已作废。',
      ]);
      throw AiException(
        truncated
            ? 'AGENT 本轮正文被输出上限截断（${roundResult.incompleteReason}）。'
            : 'AGENT 本轮未产出正文（模型只返回了工具调用）。',
      );
    }
    gen.agentWarnings
      ..clear()
      ..addAll(roundResult.warnings);
    return (
      result: AiCallResult(
        content: roundResult.content,
        reasoningContent: roundResult.reasoningContent,
        promptTokens: roundResult.promptTokens,
        completionTokens: roundResult.completionTokens,
        responseId: roundResult.responseId,
      ),
      snapshot: workingCopy.mergedSnapshot(),
      agent: roundResult,
    );
  }

  /// AGENT 模式单帧请求体（Responses 线路；预览与实发共用同一路径）。
  ///
  /// 帧间差异只有这几处，其余前缀逐字节一致（服务商上下文缓存依赖此）：
  /// - [AgentTurnRequest.items]：本轮累积 input（正文轮追加了 assistant / 工具
  ///   条目，状态轮再追加最新状态快照块与指令）；
  /// - [AgentTurnRequest.toolChoice]：正文轮 `auto`、状态轮 `required`；
  ///   平台不支持时 null；
  /// - [AgentTurnRequest.previousResponseId]：有状态续接帧不重发
  ///   instructions / tools；
  /// - [AgentTurnRequest.stateThinkingEffort]：状态帧把思考强度降为 `low`——
  ///   不硬关（状态维护需要理解正文与快照），只在用户开启思考模式时生效；
  ///   服务商不接受时由执行器回落用户设置。
  ///
  /// `max_output_tokens` **一律沿用用户设置**：程序不为状态帧擅自抬高上限，
  /// 触顶时由执行器下发「拆短调用」指令 + 黄框提示用户自行调高。
  static Map<String, dynamic> _agentBody({
    required AiSettingsProvider? settings,
    required AiRequestValues base,
    required AgentTurnRequest t,
  }) {
    final previousResponseId = t.previousResponseId;
    final chained =
        previousResponseId != null && previousResponseId.isNotEmpty;
    final values = _frameValues(base, t, chained: chained);
    final body = settings == null
        ? AiRequestBodyBuilder.buildPresetBody(
            rules: AiPlatforms.defaultRules,
            values: values,
          )
        : settings.buildRequestBody(values);
    if (chained) body['previous_response_id'] = previousResponseId;
    return body;
  }

  /// AGENT 模式单帧请求体（Chat 线路）。
  ///
  /// 执行器内部的「Responses 形状」items 经 [chatItemsFromAgentItems] 转换
  /// 为合法的 Chat messages：assistant 携带 `tool_calls`、工具结果以
  /// `role: tool` 回传；无 `previous_response_id`（Chat 协议没有有状态
  /// 续接，每帧全量重发）。`tool_choice` 由 Chat 规则注入（值为 null 时
  /// 整键省略），被服务商拒绝时执行器就地降级重发同一帧。
  static Map<String, dynamic> _agentChatBody({
    required AiSettingsProvider? settings,
    required AiRequestValues base,
    required AgentTurnRequest t,
  }) {
    final frame = _frameValues(base, t, chained: false);
    final values = AiRequestValues(
      model: frame.model,
      messages: chatItemsFromAgentItems(t.items),
      temperature: frame.temperature,
      thinking: frame.thinking,
      reasoningEffort: frame.reasoningEffort,
      maxTokens: frame.maxTokens,
      stream: frame.stream,
      tools: frame.tools,
      // Chat 线路无 instructions 字段：系统提示词已是首帧第一条 system 消息。
      instructions: null,
      toolChoice: frame.toolChoice,
    );
    return settings == null
        ? AiRequestBodyBuilder.buildPresetBody(
            rules: AiPlatforms.defaultRules,
            values: values,
          )
        : settings.buildRequestBody(values);
  }

  /// 两阶段帧的公共取值（协议无关部分）：状态帧思考覆盖（[kAgentStateThinkingEffort]
  /// = `low`，仅用户开启思考时生效）、温度 / 强度 / 上限 / 流式沿用户设置，
  /// 有状态续接（[chained]）时省略 tools / instructions（responses 专用）。
  static AiRequestValues _frameValues(
    AiRequestValues base,
    AgentTurnRequest t, {
    bool chained = false,
  }) {
    final stateEffort = (t.stateThinkingEffort != null && base.thinking)
        ? t.stateThinkingEffort!
        : null;
    return AiRequestValues(
      model: base.model,
      messages: t.items,
      temperature: base.temperature,
      thinking: stateEffort != null ? true : base.thinking,
      reasoningEffort: stateEffort ?? base.reasoningEffort,
      maxTokens: base.maxTokens,
      stream: base.stream,
      tools: chained ? null : base.tools,
      instructions: chained ? null : base.instructions,
      toolChoice: t.toolChoice,
    );
  }

  /// Response API 通道的 RAW 捕获（与 [_chatCapturing] 对称）。
  Future<AiCallResult> _responsesCapturing({
    required _BookGenState gen,
    required Map<String, dynamic> requestBody,
    required String apiBaseUrl,
    required String apiKey,
    required bool stream,
    required void Function(AiStreamChunk chunk)? onChunk,
    required bool Function() isCancelled,
  }) async {
    final exchange = RawExchange(
      requestBody: const JsonEncoder.withIndent('  ').convert(requestBody),
    );
    gen.rawExchanges.add(exchange);
    final result = await _aiService.responses(
      apiBaseUrl: apiBaseUrl,
      apiKey: apiKey,
      requestBody: requestBody,
      stream: stream,
      onChunk: onChunk,
      isCancelled: isCancelled,
    );
    // 非流式 + 展示回放：一次性响应切成合成块驱动块时间线。AGENT 模式的
    // 工具事件统一由「流式预览 / 开始 / 完成」承载，故开启工具预览块
    //（同一工具调用只产生一个事件框）。
    if (!stream && onChunk != null) {
      await _nonStreamReplayer.replay(
        result,
        emit: onChunk,
        isStopped: isCancelled,
        emitToolPreviews: true,
      );
    }
    exchange
      ..thinking = result.reasoningContent
      ..toolCalls = _formatToolCalls(result.toolCalls)
      ..content = result.content;
    return result;
  }

  /// 工具名 → 事件类型（同一工具调用只产生一个事件框；类型决定图标/标题）。
  static AgentEventType _toolEventType(String name) => switch (name) {
        'narrchat_webSearch' => AgentEventType.search,
        'narrchat_webFetchPage' => AgentEventType.fetch,
        _ => AgentEventType.tool,
      };

  /// 工具**流式预览**回调：`output_item.added` / 参数增量到达即创建 / 更新
  /// 工具卡片（与思考块同语义：先流式出现，执行完成后展示结果）。
  ///
  /// 与 [onToolStarted] 共享**同一个**事件（按 callId 匹配）：每次工具调用
  /// 只产生一个事件框，杜绝「联网搜索框 + Tool 框」并存的双框现象。
  void _handleToolPreview(AiStreamChunk chunk, _BookGenState gen) {
    final id = chunk.toolCallId!;
    var idx = gen.toolEventIdxByCallId[id];
    if (idx == null) {
      idx = gen.agentEvents.length;
      gen.toolEventIdxByCallId[id] = idx;
      final name = chunk.toolName ?? '';
      gen.agentEvents.add(
        AgentEvent(
          type: _toolEventType(name),
          toolName: name,
          callId: id,
          content: name.isEmpty ? '工具调用' : name,
          searching: true,
        ),
      );
    }
    if (chunk.toolArgsDelta != null) {
      gen.toolArgsRawByCallId[id] =
          (gen.toolArgsRawByCallId[id] ?? '') + chunk.toolArgsDelta!;
      final name = gen.agentEvents[idx].toolName;
      final raw = gen.toolArgsRawByCallId[id]!;
      gen.agentEvents[idx] = gen.agentEvents[idx].copyWith(
        content: '$name（${_clipToolArgs(raw)}）',
      );
    }
    notifyListeners();
  }

  static String _clipToolArgs(String raw) {
    final t = raw.trim();
    return t.length <= 40 ? t : '${t.substring(0, 40)}…';
  }

  /// 工具开始回调：优先复用流式预览事件（按 callId 匹配），否则新建——
  /// 保证同一工具调用只有一个事件框。事件主体（subject）取语义化内容
  /// （搜索 query / 打开页面 url），未提供时回退参数摘要。
  void _handleToolStarted(AgentToolOutcome outcome, _BookGenState gen) {
    _finishCurrentThinking(gen);
    final callId = outcome.callId;
    final subject = outcome.subject.trim().isEmpty
        ? outcome.argsSummary
        : outcome.subject;
    final existing =
        callId.isEmpty ? null : gen.toolEventIdxByCallId[callId];
    if (existing != null) {
      gen.agentEvents[existing] = gen.agentEvents[existing].copyWith(
        toolName: outcome.name,
        content: subject,
        searching: true,
      );
    } else {
      gen.agentEvents.add(
        AgentEvent(
          type: _toolEventType(outcome.name),
          content: subject,
          toolName: outcome.name,
          callId: callId,
          searching: true,
        ),
      );
      if (callId.isNotEmpty) {
        gen.toolEventIdxByCallId[callId] = gen.agentEvents.length - 1;
      }
    }
    notifyListeners();
  }

  /// 工具完成回调：按 callId（回退名称/摘要匹配）标记完成 / 失败（含结果说明）。
  void _handleToolFinished(AgentToolOutcome outcome, _BookGenState gen) {
    var target = -1;
    final callId = outcome.callId;
    if (callId.isNotEmpty && gen.toolEventIdxByCallId.containsKey(callId)) {
      target = gen.toolEventIdxByCallId[callId]!;
      gen.toolEventIdxByCallId.remove(callId);
      gen.toolArgsRawByCallId.remove(callId);
    } else {
      final subject = outcome.subject.trim().isEmpty
          ? outcome.argsSummary
          : outcome.subject;
      for (var i = gen.agentEvents.length - 1; i >= 0; i--) {
        final e = gen.agentEvents[i];
        if (e.searching &&
            (e.toolName == outcome.name ||
                e.content == outcome.argsSummary ||
                e.content == subject)) {
          target = i;
          break;
        }
      }
    }
    if (target >= 0) {
      gen.agentEvents[target] = gen.agentEvents[target].copyWith(
        searching: false,
        done: true,
        failed: !outcome.applied,
        toolDetail: outcome.message,
      );
    }
    notifyListeners();
  }

  /// 流式增量回调：累积正文，思考按块累积（agent 每轮一个新思考块），
  /// 并驱动 UI 更新（非流式返回 null）。
  ///
  /// 【无镜像门控】AGENT 模式的帧级正文分类（开场白不外露、标题帧胜出、
  /// 状态轮文本丢弃）**全部**在 `AgentRoundRunner` 的门控里完成，这里收到的
  /// 正文增量已经是「可上屏的正文」：
  /// - [AiStreamChunk.narrativeReset] 为 true → 正文块重置（后到的完整标题帧
  ///   覆盖前一个写到一半的帧），清空已展示正文，但**保持**首次固定的正文
  ///   起点边界（时间线块顺序不变）；
  /// - 首个正文增量固定 `contentBoundaryIndex` 并结束当前思考块。
  ///
  /// Chat 模式（AGENT 门控不介入）语义不变：正文增量即时上屏。
  /// [enabled] 为 true（流式传输或非流式回放）时构建块处理管道，
  /// 否则返回 null（展示无关的直发路径）。
  void Function(AiStreamChunk chunk)? _buildStreamingOnChunk(
    _BookGenState gen,
    int genToken, {
    required bool enabled,
  }) {
    if (!enabled) return null;
    return (chunk) {
      // 旧一轮的残留 chunk（令牌不一致）：直接丢弃，绝不注入本轮。
      if (genToken != gen.token) return;
      if (chunk.done) return;
      // 新一次尝试开始产出内容：清除重试提示（灰字消失）。
      gen.retryStatus = null;
      if (chunk.narrativeReset) {
        // 正文块重置（AGENT「最后一个标题帧胜出」覆盖前一帧）。
        gen.streamingContent = '';
        notifyListeners();
        return;
      }
      if (chunk.toolCallId != null) {
        _handleToolPreview(chunk, gen);
      }
      if (chunk.contentDelta.isNotEmpty) {
        // 进入正文阶段：当前轮的思考已完成；首个正文增量固定「正文起点边界」
        //（正文块插入在该下标：此前的块在正文上方、之后的块在正文下方）。
        if (gen.contentBoundaryIndex < 0) {
          gen.contentBoundaryIndex = gen.agentEvents.length;
        }
        _finishCurrentThinking(gen);
        gen.streamingContent += chunk.contentDelta;
      }
      if (chunk.reasoningDelta.isNotEmpty) {
        // 需要新建思考事件（首段思考或 agent 新一轮开始）时先开新事件。
        if (gen.newReasoningBlockPending) {
          gen.newReasoningBlockPending = false;
          gen.agentEvents.add(const AgentEvent(type: AgentEventType.thinking));
        }
        final last = gen.agentEvents.length - 1;
        gen.agentEvents[last] = gen.agentEvents[last].copyWith(
          content: gen.agentEvents[last].content + chunk.reasoningDelta,
        );
      }
      notifyListeners();
    };
  }

  /// 将最近的未完成思考事件标记为完成（思考结束 / 开始搜索 / 进入正文时）。
  void _finishCurrentThinking(_BookGenState gen) {
    for (var i = gen.agentEvents.length - 1; i >= 0; i--) {
      final e = gen.agentEvents[i];
      if (e.type == AgentEventType.thinking && !e.done) {
        gen.agentEvents[i] = e.copyWith(done: true);
        break;
      }
    }
  }

  /// Agent 活动回调：
  /// - `turn`：新一轮 LLM 调用开始，上一轮思考完成，后续思考进入新事件；
  /// - `searching`：开始搜索，本轮思考完成并新增搜索事件；
  /// - `fetching`：开始打开网页，本轮思考完成并新增 fetch 事件。
  void _handleAgentActivity(AgentActivity activity, _BookGenState gen) {
    if (activity.type == AgentActivityType.turn) {
      _finishCurrentThinking(gen);
      gen.newReasoningBlockPending = true;
      notifyListeners();
    } else if (activity.type == AgentActivityType.searching) {
      _finishCurrentThinking(gen);
      gen.agentEvents.add(
        AgentEvent(
          type: AgentEventType.search,
          content: activity.query,
          searching: true,
        ),
      );
      notifyListeners();
    } else if (activity.type == AgentActivityType.fetching) {
      _finishCurrentThinking(gen);
      gen.agentEvents.add(
        AgentEvent(
          type: AgentEventType.fetch,
          content: activity.query,
          searching: true,
        ),
      );
      notifyListeners();
    }
  }

  /// 搜索完成回调：更新指定书最近一个进行中的搜索事件（结果 + 完成）。
  void _handleSearchResults(List<SearchResult> results, _BookGenState gen) {
    for (var i = gen.agentEvents.length - 1; i >= 0; i--) {
      final e = gen.agentEvents[i];
      if (e.type == AgentEventType.search && e.searching) {
        gen.agentEvents[i] = e.copyWith(
          searching: false,
          results: results,
          done: true,
        );
        break;
      }
    }
    notifyListeners();
  }

  /// 搜索失败 / 无结果回调：把指定书搜索事件标记为失败（UI 显示 ✕，不报错截断）。
  void _handleSearchFail(_BookGenState gen) {
    for (var i = gen.agentEvents.length - 1; i >= 0; i--) {
      final e = gen.agentEvents[i];
      if (e.type == AgentEventType.search && e.searching) {
        gen.agentEvents[i] = e.copyWith(
          searching: false,
          done: true,
          failed: true,
        );
        break;
      }
    }
    notifyListeners();
  }

  /// 打开页面成功回调：把指定书最近的进行中 fetch 事件标记完成（✓）。
  void _handleFetchDone(_BookGenState gen) {
    _markFetchEvent(gen, failed: false);
  }

  /// 打开页面失败回调：把指定书 fetch 事件标记为失败（✕）。
  /// [refused] 为 true 表示页面拒绝访问（HTTP 4xx/5xx），非工具故障，
  /// UI 显示黄色 ✕ 且不计入工具连续失败次数。
  void _handleFetchFail(_BookGenState gen, {bool refused = false}) {
    _markFetchEvent(gen, failed: true, refused: refused);
  }

  /// 更新指定书最近一个进行中的 fetch 事件（完成 / 失败 / 拒绝访问）。
  void _markFetchEvent(
    _BookGenState gen, {
    required bool failed,
    bool refused = false,
  }) {
    for (var i = gen.agentEvents.length - 1; i >= 0; i--) {
      final e = gen.agentEvents[i];
      if (e.type == AgentEventType.fetch && e.searching) {
        gen.agentEvents[i] = e.copyWith(
          searching: false,
          done: true,
          failed: failed,
          refused: refused,
        );
        break;
      }
    }
    notifyListeners();
  }

  /// 抓取跳转回调：把每一跳追加到指定书最近的 fetch 事件（UI 流式展示跳转链）。
  void _handleFetchHop(FetchHop hop, _BookGenState gen) {
    for (var i = gen.agentEvents.length - 1; i >= 0; i--) {
      final e = gen.agentEvents[i];
      if (e.type == AgentEventType.fetch) {
        gen.agentEvents[i] = e.copyWith(hops: [...e.hops, hop]);
        break;
      }
    }
    notifyListeners();
  }

  /// 删除轮次。
  ///
  /// - [deleteFollowing] 为 false：仅删除本轮；
  /// - [deleteFollowing] 为 true：删除本轮及后续所有轮次。
  Future<void> deleteRound(Round round, {required bool deleteFollowing}) async {
    try {
      await _dao.deleteRound(round.id!, deleteFollowing: deleteFollowing);
      // 常驻警告随轮次一起消失（重生成此轮 / 修改提问都先删轮，故一并覆盖）。
      final gen = _gens[round.bookUuid];
      if (gen != null) {
        if (deleteFollowing) {
          _dropRoundWarningsFrom(gen, round.roundIndex);
        } else {
          _setRoundWarnings(gen, round.roundIndex, const []);
        }
      }
      if (_bookUuid.isNotEmpty) {
        await loadRounds(_bookUuid);
      }
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  /// 刷新本轮：
  /// 1. 删除本轮及后续所有轮次；
  /// 2. 以当前轮次的用户输入重新请求 AI（本轮被新结果替换）。
  Future<void> refreshRound(Round round, {Book? book}) async {
    final b = book;
    if (b == null || b.uuid.isEmpty || _gen(b.uuid).isSending) return;
    await deleteRound(round, deleteFollowing: true);
    await sendRound(
      userInput: round.userInput,
      book: b,
      userImages: round.userImages,
    );
  }

  /// 修改并重新提问：
  /// 1. 更新该轮的用户输入；
  /// 2. 删除本轮及后续所有轮次；
  /// 3. 以修改后的输入重新请求 AI（替换原轮次及后续，而非追加新轮次）。
  Future<void> editAndReAsk(
    Round round,
    String editedInput, {
    Book? book,
    List<String>? images,
  }) async {
    final b = book;
    if (b == null || b.uuid.isEmpty || _gen(b.uuid).isSending) return;
    await updateUserInput(round.id!, editedInput);
    await deleteRound(round, deleteFollowing: true);
    await sendRound(userInput: editedInput, book: b, userImages: images);
  }

  /// 编辑 AI 正文（长按/右键 → 编辑正文）。
  ///
  /// 保存成功后刷新本轮 `updated_at`（见 [RoundDao.updateRoundFields]）
  /// 并触发一次自动云同步，保证编辑结果可被推送。
  Future<void> updateNarrative(int roundId, String narrative) async {
    try {
      await _dao.updateRoundFields(roundId, {'ai_narrative': narrative});
      if (_bookUuid.isNotEmpty) {
        await loadRounds(_bookUuid);
      }
      _cloudSyncProvider?.triggerSync();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  /// 编辑用户输入（长按/右键 → 编辑输入）。
  ///
  /// 保存成功后刷新本轮 `updated_at` 并触发一次自动云同步。
  Future<void> updateUserInput(int roundId, String input) async {
    try {
      await _dao.updateRoundFields(roundId, {'user_input': input});
      if (_bookUuid.isNotEmpty) {
        await loadRounds(_bookUuid);
      }
      _cloudSyncProvider?.triggerSync();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  /// 侧边栏显式保存：将单个字段（数据库列名）写回并重新加载。
  ///
  /// 仅允许白名单内的字段，防止误写；返回是否保存成功。
  /// 保存成功后刷新本轮 `updated_at` 并触发一次自动云同步
  /// （写库失败 / 被拒时不同步，避免推送未落库的编辑）。
  Future<bool> updateRoundField(int roundId, String field, String value) async {
    const allowed = {
      RoundField.worldState,
      RoundField.characterState,
      RoundField.memorySummary,
      RoundField.currentTime,
      RoundField.aiNarrative,
      RoundField.userInput,
    };
    if (!allowed.contains(field)) return false;
    try {
      await _dao.updateRoundFields(roundId, {field: value});
      if (_bookUuid.isNotEmpty) {
        await loadRounds(_bookUuid);
      }
      _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 取最近 N 轮作为历史上下文（排除第零轮，其无实际对话内容）。
  List<Round> _takeRecent(int n) {
    final chatRounds = _rounds.where((r) => r.roundIndex > 0).toList();
    if (n <= 0) return [];
    if (chatRounds.length > n) {
      return chatRounds.sublist(chatRounds.length - n);
    }
    return chatRounds;
  }
}

/// 一轮请求的组装结果（供 `sendRound` 与「预览请求体」共用）。
///
/// 全部字段在组装时确定，不携带任何运行时生成状态。
/// [agent]（实验性开关）与 [responsesWire]（线路协议）**正交**：
/// - [agent] 为 true：Agent 两阶段执行器启用（自定义工具 + 状态工作副本），
///   [agentValues] 等 Agent 字段随之生效；
/// - [responsesWire] 为 true：请求体走 Response API 线路（/responses）。
class _RoundRequest {
  /// 组装后的系统提示词（最终文本；AGENT / responses 线路为 instructions）。
  final String systemPrompt;

  /// 历史 messages（user/assistant 交替；识图模型下已含图片 parts）。
  final List<Map<String, dynamic>> historyMessages;

  /// 当前用户消息 content：纯文本字符串或 vision parts 数组。
  final Object userContent;

  /// 实际使用的模型名（{{model}} 解析值，随轮次持久化）。
  final String model;

  /// 是否流式输出。
  final bool useStream;

  /// 是否启用联网搜索（Agent 工具循环）。
  final bool useSearch;

  /// 直发（非搜索）路径的请求体；AGENT 模式为**正文轮首帧**体（与实发同源）。
  final Map<String, dynamic> directBody;

  /// 是否 AGENT 模式（实验性开关；与协议正交）。
  final bool agent;

  /// 是否 Response API 线路（/responses；协议只决定请求体形态）。
  final bool responsesWire;

  /// AGENT 模式请求取值模板（model / 初始 input items / instructions /
  /// 工具 schema 超集 / 思考与温度 / max tokens）；每帧在此基础上替换
  /// `messages`（累积 input）与 `toolChoice`，见 [_agentBody]。
  final AiRequestValues? agentValues;

  /// 平台是否支持有状态链式续接（previous_response_id）。默认关：
  /// 许多 OpenAI 兼容实现无此字段，关闭时全量重发（前缀不变仍可命中缓存）；
  /// Chat 线路不支持续接，恒为 false。
  final bool agentChaining;

  /// 协议是否支持 `tool_choice`（能力初值；运行中被拒时执行器自动降级）。
  final bool agentToolChoice;

  const _RoundRequest({
    required this.systemPrompt,
    required this.historyMessages,
    required this.userContent,
    required this.model,
    required this.useStream,
    required this.useSearch,
    required this.directBody,
    this.agent = false,
    this.responsesWire = false,
    this.agentValues,
    this.agentChaining = false,
    this.agentToolChoice = true,
  });
}