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
import '../services/agent/agent_runner.dart';
import '../services/agent/fetch_page_tool.dart';
import '../services/agent/web_search_tool.dart';
import '../services/ai_request_body_builder.dart';
import '../services/ai_response_parser.dart';
import '../services/ai_service.dart';
import '../services/html_search_service.dart';
import '../services/image_store.dart';
import '../services/prompt_builder.dart';
import '../services/world_book_scanner.dart';
import 'ai_settings_provider.dart';
import 'cloud_sync_provider.dart';
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

  /// Agent 过程时间线：思考 / 搜索事件按真实顺序交错排列
  ///（思考1 → 搜索1 → 思考2 → 搜索2 …）。
  final List<AgentEvent> agentEvents = [];

  /// 下一段思考增量到达时是否新建思考事件（agent 每轮开始时置位）。
  bool newReasoningBlockPending = true;

  /// 当前自动重试进度：(已重试次数, 总次数)；null = 无重试。
  (int, int)? retryStatus;

  /// 当前尝试的 RAW 时间线（请求体 → AI返回 交错；重试时清空）。
  final List<RawExchange> rawExchanges = [];

  /// 失败条目的 RAW 时间线（最近一次失败 / 中断尝试）。
  List<RawExchange>? failedRawExchanges;

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
      '1. 先调用 web_search 工具搜索，获取结果标题、链接与摘要；\n'
      '2. 必须随后用 fetch_page 打开最相关的 1~3 个结果页面并阅读正文，'
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
        _worldBookProvider = worldBookProvider,
        // ignore: prefer_initializing_formals
        _modProvider = modProvider,
        // ignore: prefer_initializing_formals
        _cloudSyncProvider = cloudSyncProvider,
        // ignore: prefer_initializing_formals
        _retryDelay = retryDelay {
    // 共享搜索服务实例（默认 Agent 工具按书复用，避免重复创建 http client）。
    _searchService = searchService ?? HtmlSearchService();
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
  final WorldBookProvider? _worldBookProvider;
  final ModProvider? _modProvider;
  final CloudSyncProvider? _cloudSyncProvider;
  /// 共享搜索服务（默认 Agent 工具按书复用同一实例，避免重复创建 http client）。
  late final HtmlSearchService _searchService;

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

  /// Agent 过程时间线（思考 / 搜索交错，供流式气泡渲染）。
  List<AgentEvent> get agentEvents =>
      _curGen == null ? const [] : List.unmodifiable(_curGen!.agentEvents);

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
    _gen(_bookUuid).failedRawExchanges = null;
    await _setFailedAttempt(_bookUuid, const FailedAttempt());
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
    // 重置 Agent 过程时间线、重试状态与 RAW 时间线。
    gen.agentEvents.clear();
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
      final lastRound = latestRound;
      final recentRounds = _takeRecent(b.historyRounds);
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
              bookUuid: b.uuid,
              userInput: userInput,
              historyRounds: recentRounds,
            );
      final prompts = _promptBuilder.build(
        book: b,
        lastRound: lastRound,
        userInput: userInput,
        worldBookEntries: worldBookEntries,
        mods: modsBundle,
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
      );
      final userContent = supportsVision
          ? _userContentWithImages(
              prompts.userPrompt,
              userImages,
              imageDataUrls,
            )
          : prompts.userPrompt;

      final useStream = settings?.streaming ?? true;
      // 搜索能力：默认关闭，用户可在 Chat 页选项下拉中手动开启（lastSearch）；
      // 无设置注入时按预设能力回退（仅测试/降级路径）。
      final useSearch = settings == null
          ? AiPlatforms.defaultSupportsSearch
          : (settings.supportsSearch && settings.lastSearch);
      if (useStream) {
        gen.isStreaming = true;
        gen.streamingContent = '';
        notifyListeners();
      }

      // 按当前预设（规则构建器 / 自定义模板）动态组合请求体：
      // 不同模式（思考 / 联网搜索 / 流式）下发送的参数由预设规则决定。
      final values = AiRequestValues(
        model: (settings?.model.trim().isNotEmpty ?? false)
            ? settings!.model
            : AiPlatforms.defaultModelId,
        messages: [
          {'role': 'system', 'content': prompts.systemPrompt},
          ...historyMessages,
          {'role': 'user', 'content': userContent},
        ],
        temperature: settings?.temperature ?? 1.0,
        thinking:
            settings?.thinking ?? AiPlatforms.defaultThinking,
        reasoningEffort:
            settings?.reasoningEffort ?? AppConfig.defaultReasoningEffort,
        maxTokens: settings?.maxTokens,
        stream: useStream,
        tools: null,
      );
      final requestBody = settings == null
          ? AiRequestBodyBuilder.buildPresetBody(
              rules: AiPlatforms.defaultRules,
              values: values,
            )
          : settings.buildRequestBody(values);

      final onChunk = _buildStreamingOnChunk(useStream, gen, genToken);
      // 取消闭包：用户显式中断，或本轮令牌已过期（新一轮已发起）都视为取消，
      // 使上一轮残留流自行中止，绝不继续向本轮注入内容。
      bool isCancelled() => gen.cancelRequested || genToken != gen.token;
      // 本轮开启联网搜索 → Agent 工具循环（首轮带工具，搜索后生成）；
      // 否则走单轮直发路径。
      final result = useSearch
          ? await _callWithRetry(
              () => _runAgent(
                settings: settings,
                apiBaseUrl:
                    settings?.baseUrl ?? AppConfig.defaultApiBaseUrlEffective,
                apiKey: settings?.apiKey ?? AppConfig.defaultApiKeyEffective,
                initialMessages: [
                  {
                    'role': 'system',
                    'content': '${prompts.systemPrompt}\n\n$_searchInstruction',
                  },
                  ...historyMessages,
                  {'role': 'user', 'content': userContent},
                ],
                useStream: useStream,
                onChunk: onChunk,
                gen: gen,
                isCancelled: isCancelled,
              ),
              gen: gen,
              genToken: genToken,
            )
          : await _callWithRetry(
              () => _chatCapturing(
                gen: gen,
                requestBody: requestBody,
                apiBaseUrl:
                    settings?.baseUrl ?? AppConfig.defaultApiBaseUrlEffective,
                apiKey: settings?.apiKey ?? AppConfig.defaultApiKeyEffective,
                stream: useStream,
                onChunk: onChunk,
                isCancelled: isCancelled,
              ),
              gen: gen,
              genToken: genToken,
            );
      // 用户主动中断：丢弃部分内容，以「已截断」失败条目保留用户输入。
      if (gen.cancelRequested) {
        gen.isStreaming = false;
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
      gen.streamingContent = '';
      gen.agentEvents.clear();

      final parsed = AiResponseParser.parse(result.content);

      final newRound = Round(
        bookUuid: b.uuid,
        roundIndex: (lastRound?.roundIndex ?? 0) + 1,
        userInput: userInput,
        aiNarrative: parsed.aiNarrative,
        worldState: parsed.worldState,
        characterState: parsed.characterState,
        memorySummary: parsed.memorySummary,
        currentTime: parsed.currentTime,
        recommendedAction: parsed.recommendedAction,
        tokensIn: result.promptTokens,
        tokensOut: result.completionTokens,
        // 本轮实际使用的模型名（{{model}} 解析值），随轮次持久化。
        modelName: values.model,
        // 用户消息附带的图片（相对路径），随轮次落库，供气泡展示与历史回放。
        userImages: userImages ?? const [],
        createdAt: DateTime.now(),
      );
      final newRoundId = await _dao.insertRound(newRound);
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
    exchange
      ..thinking = result.reasoningContent
      ..search = _formatToolCalls(result.toolCalls)
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
  Future<AiCallResult> _callWithRetry(
    Future<AiCallResult> Function() action, {
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
  /// 首轮带 `web_search` 工具调用模型；若模型请求搜索则执行并把结果
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

  Future<AiCallResult> _runAgent({
    required AiSettingsProvider? settings,
    required String apiBaseUrl,
    required String apiKey,
    required List<Map<String, dynamic>> initialMessages,
    required bool useStream,
    required void Function(AiStreamChunk chunk)? onChunk,
    required _BookGenState gen,
    required bool Function() isCancelled,
  }) async {
    final runner = AgentRunner(
      buildBody: (messages, tools) {
        final values = AiRequestValues(
          model: (settings?.model.trim().isNotEmpty ?? false)
              ? settings!.model
              : AiPlatforms.defaultModelId,
          messages: messages,
          temperature: settings?.temperature ?? 1.0,
          thinking:
              settings?.thinking ?? AiPlatforms.defaultThinking,
          reasoningEffort:
              settings?.reasoningEffort ?? AppConfig.defaultReasoningEffort,
          maxTokens: settings?.maxTokens,
          stream: useStream,
          tools: tools,
        );
        return settings == null
            ? AiRequestBodyBuilder.buildPresetBody(
                rules: AiPlatforms.defaultRules,
                values: values,
              )
            : settings.buildRequestBody(values);
      },
      call: (requestBody, stream, onChunk, onRequestBody, isCancelled) =>
          _chatCapturing(
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
      tools: [
        _webSearchTool ??
            WebSearchTool(
              search: _searchService,
              onResults: (r) => _handleSearchResults(r, gen),
              onFail: () => _handleSearchFail(gen),
            ),
        _fetchPageTool ??
            FetchPageTool(
              search: _searchService,
              onDone: () => _handleFetchDone(gen),
              onFail: () => _handleFetchFail(gen),
              onRefused: () => _handleFetchFail(gen, refused: true),
              onHop: (h) => _handleFetchHop(h, gen),
            ),
      ],
    );

    return runner.run(
      initialMessages: initialMessages,
      stream: useStream,
      onChunk: onChunk,
      isCancelled: isCancelled,
      onActivity: (a) => _handleAgentActivity(a, gen),
    );
  }

  /// 流式增量回调：累积正文，思考按块累积（agent 每轮一个新思考块），
  /// 并驱动 UI 更新（非流式返回 null）。
  void Function(AiStreamChunk chunk)? _buildStreamingOnChunk(
    bool useStream,
    _BookGenState gen,
    int genToken,
  ) {
    if (!useStream) return null;
    return (chunk) {
      // 旧一轮的残留 chunk（令牌不一致）：直接丢弃，绝不注入本轮。
      if (genToken != gen.token) return;
      if (chunk.done) return;
      // 新一次尝试开始产出内容：清除重试提示（灰字消失）。
      gen.retryStatus = null;
      if (chunk.contentDelta.isNotEmpty) {
        // 进入正文阶段：当前轮的思考已完成。
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
      if (_bookUuid.isNotEmpty) {
        await loadRounds(_bookUuid);
      }
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