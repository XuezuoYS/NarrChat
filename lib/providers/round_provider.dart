import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config/ai_platforms.dart';
import '../config/app_config.dart';
import '../models/agent_event.dart';
import '../models/agent_mode_level.dart';
import '../models/book.dart';
import '../models/branch.dart';
import '../models/branch_copy.dart';
import '../models/raw_exchange.dart';
import '../models/round.dart';
import '../models/round_generation.dart';
import '../models/round_send_intent.dart';
import '../models/round_stack.dart';
import '../repositories/book_repository.dart';
import '../repositories/round_repository.dart';
import '../services/app_repositories.dart';
import '../services/agent/agent_default_tools.dart';
import '../services/agent/agent_mode_profile.dart';
import '../services/agent/agent_round_runner.dart';
import '../services/agent/agent_runner.dart';
import '../services/agent/fetch_page_tool.dart';
import '../services/agent/narr_agent_tool.dart';
import '../services/agent/state/agent_state_working_copy.dart';
import '../services/agent/web_search_tool.dart';
import '../services/agent/wire_adapters.dart';
import '../services/ai_request_body_builder.dart';
import '../services/ai_response_parser.dart';
import '../services/ai_service.dart';
import '../services/branch_rules.dart';
import '../services/html_search_service.dart';
import '../services/wire_messages.dart';
import '../services/image_store.dart';
import '../services/memory_merge_planner.dart';
import '../services/non_stream_replay.dart';
import '../services/prompt_interface.dart';
import '../services/request_frame_outline.dart';
import '../services/world_book_scanner.dart';
import '../utils/uuid_utils.dart';
import 'ai_settings_provider.dart';
import 'cloud_sync_provider.dart';
import 'experimental_settings_provider.dart';
import 'mod_provider.dart';
import 'world_book_provider.dart';

/// 单本书的运行时生成状态（支持多本书并发生成互不干扰）。
///
/// 生成令牌 [token]：每次 `sendIntent` 自增。旧一轮的残留流回调（onChunk /
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
  /// 仅**生成期间**的顶部提示；结束时随本轮落库为该「代」的提示。
  final List<String> agentWarnings = [];

  /// 本书**代级提示**的变更计数（对话列表据此失效缓存的条目高度）。
  ///
  /// R3 起提示直接挂在代上（`Round.message` / `messageStatus`），不再有本地副本，
  /// 因此这里只保留一个「提示可能变了」的信号给 UI 用。
  int messagesVersion = 0;

  /// 生成期间展示的用户输入（结束 / 中断后清除）。
  String pendingUserInput = '';

  /// 本次生成应落在的轮号（null = 当前没有生成）。
  ///
  /// 与 [pendingUserInput] 同时置位 / 清空：
  /// - 普通新一轮 = 链尾 +1（见 `RoundProvider.nextRoundIndex`）；
  /// - 「重新生成 / 修改并重新提问 / 按意见修改」= **被重写的那一轮**。
  ///
  /// 界面据此把生成中气泡画在真正的位置：R2 时代刷新会先删该轮起的投影行，
  /// 「链尾 +1」恰好等于目标轮号；R3 改成同轮新增一代后若继续沿用链尾 +1，
  /// 刷新第 N 轮会先在末尾冒充「第 N+1 轮正在生成」，完成 / 停止后才跳回第 N 轮。
  int? pendingRoundIndex;
}

/// 轮次状态管理：加载、发送（组装 Prompt + 调用 AI + 解析入库）、删除、刷新、保存快照。
class RoundProvider extends ChangeNotifier {
  /// 网络类失败自动重试的最大次数（灰字提示「错误重连……（x/3）」）。
  static const int _maxAiRetries = 3;

  RoundProvider({
    RoundRepository? rounds,
    BookRepository? books,
    AiService? aiService,
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
  })  : _roundsRepo = rounds ?? AppRepositories.instance.rounds,
        _booksRepo = books ?? AppRepositories.instance.books,
        _aiService = aiService ?? AiService(),
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

  final RoundRepository _roundsRepo;
  final BookRepository _booksRepo;
  final AiService _aiService;
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

  /// 当前书的完整读取结果：活动链正文 + 全书元信息 + 分支。
  ///
  /// 元信息用来算链 / 版本组 / 进度（轻），[rounds] 只有链上的正文。
  RoundChain _chain = RoundChain.empty;

  int _versionsRevision = 0;

  /// 版本树 / 分支变更计数：任何代或分支变化都自增。
  ///
  /// 供 UI 做缓存失效（对话页的条目高度依赖「代次控件是否显示」，
  /// 控件显隐会改变条目高度 → 必须并入几何重建的失效依据）。
  int get versionsRevision => _versionsRevision;

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

  /// 各成功轮的 RAW 时间线（内存）：**按「代」uuid 归属**。
  ///
  /// R3 里"一轮"就是活动链上的某一代，代的 uuid 跨设备、跨重载都稳定，
  /// 所以直接拿它当键；只有**换书**才整体清理（避免跨书误配）。
  final Map<String, List<RawExchange>> _rawByGeneration = {};

  String? _error;

  /// 当前查看书籍的 uuid（空串 = 未加载任何书）。
  String _bookUuid = '';

  /// 获取（必要时创建）指定书的运行时生成状态。
  _BookGenState _gen(String bookUuid) =>
      _gens.putIfAbsent(bookUuid, () => _BookGenState(bookUuid));

  /// 当前是否至少有一本书正在生成（用于通知服务保活启停）。
  bool _hasActiveGeneration() => _gens.values.any((g) => g.isSending);

  /// 当前 Agent 档位（无设置注入 = 关闭；仅测试 / 降级路径）。
  AgentModeLevel get _agentLevel =>
      _experimentalSettings?.agentModeLevel ?? AgentModeLevel.off;

  /// 当前「精简思考回传」策略（无设置注入时按默认**关**；仅测试 / 降级路径）。
  bool get _reduceReasoningReplay =>
      _experimentalSettings?.reduceReasoningReplay ?? false;

  List<Round> get rounds => _roundsView;

  /// 当前活动链所属书的 uuid（空串 = 尚未加载任何书）。
  ///
  /// 对话页用它判断 `rounds` 是不是**当前这本书**的数据：换书时数据是异步来的，
  /// 首帧读到的可能还是上一本书的活动链（全局 provider 不随页面销毁），
  /// 拿它建几何 / 建窗口会把新页面的窗口带到旧书的总轮数上。
  String get loadedBookUuid => _bookUuid;

  /// 当前查看书的运行时生成状态（未加载任何书或从未生成时为 null）。
  _BookGenState? get _curGen => _gens[_bookUuid];

  bool get isSending => _curGen?.isSending ?? false;

  /// 指定书是否正在生成（支持多本书并发生成；与当前查看的是哪本书无关）。
  bool isGeneratingBook(String bookUuid) =>
      bookUuid.isNotEmpty && (_gens[bookUuid]?.isSending ?? false);

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

  /// 某轮当前应用代的提示行（库内 `round_stack.message`）。
  ///
  /// 提示挂在「代」上：切换版本即看到那一代自己的提示；删除代 / 删除轮随行消失。
  /// 空列表 = 该轮无提示（含「轮次不存在 / 尚未采纳」）。
  List<String> roundWarningsFor(int roundIndex) {
    final message = roundMessageFor(roundIndex);
    return message == null ? const [] : List.unmodifiable(message.lines);
  }

  /// 某轮当前应用代的提示（含级别）；`null` = 无提示。
  ///
  /// R3 里提示就挂在活动链那一代自己身上（`Round.message` / `messageStatus`），
  /// 不需要再去查别的表。
  RoundStackMessage? roundMessageFor(int roundIndex) {
    for (final round in _rounds) {
      if (round.roundIndex != roundIndex) continue;
      if (!round.hasMessage) return null;
      return RoundStackMessage(
        uuid: round.uuid,
        roundIndex: round.roundIndex,
        isFailure: round.isError,
        text: round.message,
        status: round.effectiveMessageStatus,
      );
    }
    return null;
  }


  /// 提示的变更计数（对话列表据此重算条目高度）。
  int get roundWarningsVersion => _curGen?.messagesVersion ?? 0;

  /// 提示变更计数（R3 里提示随代读回，加载即刷新）。
  void _bumpMessages(String bookUuid) {
    _gen(bookUuid).messagesVersion++;
  }

  /// 当前自动重试进度（灰字「错误重连……（x/3）」）；null = 无重试。
  (int, int)? get retryStatus => _curGen?.retryStatus;

  /// 指定代的 RAW 时间线（无数据返回 null）。
  ///
  /// 参数是**代 uuid**（[Round.uuid]）：R3 没有投影行 id，界面拿到的就是代身份。
  List<RawExchange>? rawExchangesFor(String roundUuid) {
    final data = _rawByGeneration[roundUuid];
    return (data == null || data.isEmpty) ? null : data;
  }


  /// 当前正在生成中、尚未落库的用户输入（用于生成期间不回藏用户消息）。
  String get pendingUserInput => _curGen?.pendingUserInput ?? '';

  /// 生成中气泡应落在的轮号（null = 当前没有生成）。
  ///
  /// 普通新一轮 = 链尾 +1；「重新生成 / 修改并重新提问 / 按意见修改」=
  /// **被重写的轮号**。界面把待定气泡画在这一轮的位置，并在生成期间暂时隐藏
  /// 该轮旧代与后续轮次（见 `ChatScreen._rebuildGeometry`）。
  int? get pendingRoundIndex => _curGen?.pendingRoundIndex;

  /// 当前正在生成中的书籍 uuid（供跨书进程提示栏展示，点击可跳转对应书籍）。
  List<String> get activeGenerationBookUuids =>
      [for (final g in _gens.values) if (g.isSending) g.bookUuid];

  /// 当前**可见**的对话页所属书籍（用户正停留在该书的对话页上；否则为 null）。
  ///
  /// 跨书生成提示必须排除它：停留在某书页面时不该提示「这本书正在生成」，
  /// 在应用内离开该页面（回首页 / 进设置 / 切到别的书）后才提示，
  /// 回到该书页面后提示再次消失——与改动前对话页内嵌横幅的行为一致
  /// （旧横幅在对话页里传 `excludeBookUuid: 当前查看书`，首页则展示全部）。
  String? get visibleChatBookUuid => _visibleChatBookUuid;
  String? _visibleChatBookUuid;

  /// 汇报「当前可见的对话页书籍」（由 `ChatScreen` 依路由可见性维护）。
  ///
  /// 只传值、不做归属校验：路由被覆盖时页面会汇报 null；切换页面时同一帧内的
  /// 帧后回调按登记顺序执行，新页面的汇报最后生效。
  void setVisibleChatBook(String? bookUuid) {
    // 已销毁（测试 teardown / 应用退出时页面被拆掉的帧后回调）直接忽略。
    if (_disposed || _visibleChatBookUuid == bookUuid) return;
    _visibleChatBookUuid = bookUuid;
    notifyListeners();
  }

  /// 清空可见对话页书籍，但**仅当它仍是 [bookUuid]**（页面销毁时的归属校验：
  /// 通知跳转用 `pushReplacement` 时新页面可能已经接管）。
  ///
  /// 路由被*弹出*时 `isCurrent` 不会先变 false 再通知，因此由 `ChatScreen.dispose`
  /// 在**帧后**调用本方法（dispose 期间整棵树锁定，直接通知会触发
  /// 「setState() or markNeedsBuild() called when widget tree was locked」）。
  void clearVisibleChatBook(String bookUuid) {
    if (_visibleChatBookUuid != bookUuid) return;
    setVisibleChatBook(null);
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  String? get error => _error;
  Round? get latestRound => _rounds.isEmpty ? null : _rounds.last;

  /// 当前书籍下一轮的轮号（新轮 `roundIndex`；新建轮失败时的错误代落点）。
  ///
  /// 链非空 = 链尾 +1；**空分支**（刚分叉还没写过轮次）= 分叉点轮号 +1。
  /// 后者必须问仓储，否则在 IF 线上会从第 1 轮开始写，把轮号撞回主线。
  ///
  /// ⚠️ 它只描述「新建轮」；刷新 / 修改轮的落点是**被重写的那一轮**，
  /// 见 [pendingRoundIndex]（两者混用曾把生成中气泡错画成「第 N+1 轮」）。
  int get nextRoundIndex => _chain.nextRoundIndex;

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

  /// 用一次仓储读取的结果整体刷新：活动链 + 全书元信息 + 分支。
  void _setChain(RoundChain chain) {
    _chain = chain;
    _setRounds(chain.rounds);
  }

  /// 加载指定书籍：活动链（含正文）+ 全书元信息 + 分支。
  ///
  /// R3 没有投影表：界面上的每一轮就是活动链上的某一代。
  /// RAW 时间线不随加载清空（按代 uuid 保存），仅换书时整体清理。
  ///
  /// **换书先清链**：上一本书的活动链必须在 await 之前就消失并通知出去。
  /// 否则新打开的对话页首帧会拿上一本书的轮次建窗口——链变短时 `delta` 为负，
  /// 那次负 delta 正是「整页空白 + 只有轨道」的根因（见 `ChatWindowController
  /// .setTotalRounds` 的不变量说明）。
  Future<void> loadRounds(String bookUuid) async {
    if (_bookUuid.isNotEmpty && _bookUuid != bookUuid) {
      _rawByGeneration.clear();
      _setChain(RoundChain.empty);
      _bumpVersions();
      notifyListeners();
    }
    _bookUuid = bookUuid;
    try {
      _setChain(await _roundsRepo.loadChain(bookUuid));
      _bumpVersions();
      _bumpMessages(bookUuid);
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  /// 版本树 / 分支变更计数自增（UI 缓存失效依据）。
  void _bumpVersions() => _versionsRevision++;

  /// 本轮的父代 = 上一轮**当前代**的 uuid。
  String? _fatherAnchorFor(int roundIndex) {
    if (roundIndex <= 0) return null;
    for (final round in _rounds) {
      if (round.roundIndex == roundIndex - 1) {
        return round.uuid.isEmpty ? null : round.uuid;
      }
    }
    return null;
  }

  /// 当前分支里、指定轮号 + 父代那组的下一序号。
  int _nextSerialFor({required int roundIndex, required String? fatherUuid}) {
    var maxSerial = 0;
    for (final meta in _chain.allMeta) {
      if (meta.roundIndex != roundIndex) continue;
      if (meta.branchUuid != _chain.workingBranch) continue;
      if ((meta.fatherUuid ?? '') != (fatherUuid ?? '')) continue;
      if (meta.roundSerialNum > maxSerial) maxSerial = meta.roundSerialNum;
    }
    return maxSerial + 1;
  }

  /// 把一轮写成当前分支的一代（成功轮次与错误轮次共用同一条写入路径）。
  ///
  /// `is_using = true`：由 store 负责把同组其它代清 0（切换语义天然成立）。
  Future<String> _appendRound(
    Round round, {
    required int serial,
    String? fatherUuid,
    String message = '',
    String messageStatus = '',
  }) async {
    final uuid = UuidUtils.generateUuidV4();
    final generation = round
        .copyWith(
          uuid: uuid,
          fatherUuid: fatherUuid,
          branchUuid: _chain.workingBranch,
          roundSerialNum: serial,
          isUsing: true,
          messageStatus: messageStatus,
          message: message,
        )
        .toGeneration();
    await _roundsRepo.appendGeneration(
      bookUuid: round.bookUuid,
      generation: generation,
    );
    return uuid;
  }

  /// 写入一条**错误代**（失败 / 中断），返回它的代 uuid（写失败返回 null）。
  ///
  /// 方案 A：失败也是链上一条真轮次（`message_status='error'` + 文案）。
  /// 它不能衍生下一轮、不能被 fork——由仓储与 UI 双向拦住。
  /// 失败尝试的 RAW 也按代 uuid 归位，用户点开红条仍能看请求 / 返回。
  Future<String?> _appendFailureRound({
    required String bookUuid,
    required int roundIndex,
    required String userInput,
    required List<String> userImages,
    required String message,
  }) async {
    final father = _fatherAnchorFor(roundIndex);
    final round = Round(
      bookUuid: bookUuid,
      roundIndex: roundIndex,
      userInput: userInput,
      userImages: userImages,
      messageStatus: RoundMessageStatus.error,
      message: message.trim().isEmpty ? '已中断' : message.trim(),
      createdAt: DateTime.now(),
    );
    try {
      final uuid = await _appendRound(
        round,
        serial: _nextSerialFor(roundIndex: roundIndex, fatherUuid: father),
        fatherUuid: father,
        message: round.message,
        messageStatus: RoundMessageStatus.error,
      );
      final raw = _gens[bookUuid]?.failedRawExchanges;
      if (raw != null && raw.isNotEmpty) {
        _rawByGeneration[uuid] = List.of(raw);
      }
      return uuid;
    } catch (e) {
      debugPrint('[round] 错误代写入失败：$e');
      return null;
    }
  }

  /// 生成写入后的统一收尾：刷新活动链（错误代也要立刻上屏）。
  Future<void> _afterGenerationWrite(String bookUuid) async {
    _bumpVersions();
    _bumpMessages(bookUuid);
    if (_bookUuid == bookUuid) {
      await loadRounds(bookUuid);
    }
  }

  /// 清除链尾的错误轮（UI「清除失败条目」入口）。
  ///
  /// 方案 A 下"失败条目"就是链尾那条 error 代，清掉它等于删除它所在的这一轮。
  ///
  /// 不能走 `deleteGeneration`：`BranchRules.planDeleteGeneration` 对"组内唯一一代"
  /// 是**拒绝**的（正常场景应改走删除本轮）。而错误代在自己的组里天然是唯一一代，
  /// 于是必然被拒 → 用户点「清除失败条目」毫无反应。错误代是链尾、没有后代，
  /// 删本轮与删它等价，且没有正文会丢。
  Future<void> clearFailedAttempt() async {
    if (_bookUuid.isEmpty) return;
    final tail = _chain.tail;
    if (tail == null || !tail.isError) return;
    try {
      await _roundsRepo.deleteRoundAndFollowing(
        bookUuid: _bookUuid,
        roundIndex: tail.roundIndex,
      );
      _rawByGeneration.remove(tail.uuid);
      await loadRounds(_bookUuid);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
    _cloudSyncProvider?.triggerSync();
  }

  /// 重新加载当前书籍的轮次（云备份还原数据后调用）。
  ///
  /// 还原后当前书籍可能已被覆盖删除：先确认书还在，避免对已删除的书做读写。
  Future<void> reloadCurrent() async {
    if (_bookUuid.isEmpty) return;
    final book = await _booksRepo.loadBook(_bookUuid);
    if (book == null) {
      _setChain(RoundChain.empty);
      notifyListeners();
      return;
    }
    await loadRounds(_bookUuid);
  }

  // ---------------------------------------------------------------------------
  // 分支
  // ---------------------------------------------------------------------------

  /// 全部可选分支（默认分支「主线」永远第一个）。
  List<Branch> get branches => _chain.allBranches;

  /// 当前激活分支的 uuid（`''` = 默认分支）。
  String get workingBranchUuid => _chain.workingBranch;

  /// 当前分支行（默认分支返回 null）。
  Branch? get currentBranch => _chain.currentBranch;

  /// [branch] 的分叉点信息（父代序号 / 父代是否还在库里）。
  ///
  /// 纯查询：只读本次 `loadRounds` 已带回的元信息，不碰库；默认分支返回 null。
  BranchForkPoint? forkPointOf(Branch branch) =>
      BranchRules.forkPointOf(branch, _chain.allMeta);

  /// 切换分支：重建活动链并刷新（不触发云备份、不动 `updated_at`）。
  Future<bool> switchBranch(String branchUuid) async {
    if (_bookUuid.isEmpty || isSending) return false;
    if (branchUuid == _chain.workingBranch) return true;
    try {
      await _roundsRepo.switchBranch(
        bookUuid: _bookUuid,
        branchUuid: branchUuid,
      );
      _bumpVersions();
      await loadRounds(_bookUuid);
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 新分支的自动名：默认分支算第 1 条，因此第一个分支叫「分支 2」。
  ///
  /// 「从此新建分支」与「从此代拷贝链至新的分支」共用同一口径，
  /// 避免两处各写一遍命名规则后漂移。
  String _nextBranchName() => '分支 ${_chain.branches.length + 2}';

  /// 从某一代分叉出一条 IF 线，成功返回新分支 uuid。
  ///
  /// 分支内此刻没有轮次；用户下一次输入会写入链首代。错误代不能分叉。
  Future<String?> forkBranch({required Round round, String? title}) async {
    if (_bookUuid.isEmpty || isSending) return null;
    if (round.uuid.isEmpty) return null;
    if (round.isError) {
      _error = '失败轮次不能分叉，请先重新生成';
      notifyListeners();
      return null;
    }
    try {
      final branch = await _roundsRepo.forkBranch(
        bookUuid: _bookUuid,
        generationUuid: round.uuid,
        branchName: (title ?? '').trim().isEmpty
            ? _nextBranchName()
            : title!.trim(),
      );
      _bumpVersions();
      await loadRounds(_bookUuid);
      // 建分支是**内容变更**（会刷新 book_meta.updated_at），必须触发同步；
      // 否则用户建了一堆分支，直到某次别的操作才会上云。
      _cloudSyncProvider?.triggerSync();
      return branch.branchUuid;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  /// 「从此代拷贝链至新的分支」：拷贝目标代及其整棵子代树。
  ///
  /// - 新分支的 father = 目标代的父代（链首时沿用源分支父级，无父级则成根）；
  /// - **不切换**当前分支：是否跳转由对话框让用户选；
  /// - 成功后刷新活动链与分支列表（源分支内容不动），并触发一次云同步；
  /// - 失败 / 被拒时写入 [error] 并返回 null，界面据此展示原因。
  ///
  /// [onProgress] 透传给仓储，用于对话框显示「已拷贝 x / y 代」。
  Future<BranchCopyResult?> copyChainToNewBranch({
    required Round round,
    void Function(int done, int total)? onProgress,
  }) async {
    if (_bookUuid.isEmpty || round.uuid.isEmpty) return null;
    if (isSending) {
      _error = '正在生成中，暂不可拷贝';
      notifyListeners();
      return null;
    }
    if (round.isError) {
      _error = '失败代不能拷贝，请先重新生成';
      notifyListeners();
      return null;
    }
    final bookUuid = _bookUuid;
    try {
      final result = await _roundsRepo.copyChainToNewBranch(
        bookUuid: bookUuid,
        fromGenerationUuid: round.uuid,
        branchName: _nextBranchName(),
        onProgress: onProgress,
      );
      _bumpVersions();
      // 新分支不激活：活动链仍是源分支，但分支列表 / 面板要立刻出现它。
      if (_bookUuid == bookUuid) {
        await loadRounds(bookUuid);
      }
      _cloudSyncProvider?.triggerSync();
      return result;
    } catch (e) {
      debugPrint('[branch] 拷贝链失败：$e');
      // 对话框直接展示这句原因：StateError 去掉 "Bad state:" 前缀，
      // 别让用户看到 Dart 的异常类名。
      _error = e is StateError ? e.message : e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<bool> renameBranch(String branchUuid, String title) async {
    if (_bookUuid.isEmpty || branchUuid.isEmpty) return false;
    final trimmed = title.trim();
    if (trimmed.isEmpty) return false;
    try {
      await _roundsRepo.renameBranch(
        bookUuid: _bookUuid,
        branchUuid: branchUuid,
        name: trimmed,
      );
      _bumpVersions();
      await loadRounds(_bookUuid);
      // 改名同样是内容变更（刷新 updated_at），与建/删分支保持一致地触发同步。
      _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 删除分支（连它全部轮次）；子分支保留，父信息靠快照兜底。
  Future<bool> deleteBranch(String branchUuid) async {
    if (_bookUuid.isEmpty || branchUuid.isEmpty || isSending) return false;
    try {
      final result = await _roundsRepo.deleteBranch(
        bookUuid: _bookUuid,
        branchUuid: branchUuid,
      );
      if (result.isRefused) {
        _error = result.refusal;
        notifyListeners();
        return false;
      }
      _bumpVersions();
      await loadRounds(_bookUuid);
      _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 修改还原（代 = 活动链上的一行）
  // ---------------------------------------------------------------------------

  /// 该轮的可切换版本信息（`null` = 不显示控件）。
  ///
  /// **同步**读本机缓存的元信息（`RoundRepository.loadChain` 一次性带回，
  /// 绝不逐轮查库 / 读正文）；缓存随 [loadRounds] 与 [versionsRevision] 失效。
  RoundVersionInfo? versionInfoFor(int roundIndex) {
    if (_bookUuid.isEmpty) return null;
    Round? current;
    for (final round in _rounds) {
      if (round.roundIndex == roundIndex) {
        current = round;
        break;
      }
    }
    if (current == null) return null;
    final set = _chain.generationSetOf(current.uuid);
    if (set.generations.isEmpty) return null;

    final group = set.generations;
    final index = group.indexWhere((g) => g.uuid == current!.uuid);
    final prev = index > 0 ? group[index - 1] : null;
    final next = index >= 0 && index < group.length - 1
        ? group[index + 1]
        : null;
    return RoundVersionInfo(
      currentSerial: index >= 0 ? group[index].roundSerialNum : null,
      latestSerial: group.last.roundSerialNum,
      aliveCount: group.length,
      currentUuid: current.uuid,
      prevUuid: prev?.uuid,
      nextUuid: next?.uuid,
      prevSerial: prev?.roundSerialNum,
      nextSerial: next?.roundSerialNum,
    );
  }

  /// 切换本轮版本：[forward] = true 取下一存活代，false 取上一存活代；
  /// 没有可切换目标 / 正在生成 → 直接返回 false。
  ///
  /// 成功后重载活动链。**不**滚动到底、**不**触发云备份（切换不改变内容权威）。
  Future<bool> switchRoundVersion(
    int roundIndex, {
    required bool forward,
  }) async {
    if (_bookUuid.isEmpty || isSending) return false;
    final info = versionInfoFor(roundIndex);
    final target = forward ? info?.nextUuid : info?.prevUuid;
    if (target == null) return false;
    final bookUuid = _bookUuid;
    try {
      await _roundsRepo.switchGeneration(
        bookUuid: bookUuid,
        generationUuid: target,
      );
      _bumpVersions();
      // RAW 不随切换清空：它按代 uuid 归属，切到哪一代就看哪一代的记录。
      await loadRounds(bookUuid);
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 兼容旧调用点：R3 不再有"采纳"这一步（没有投影表要收敛）。
  ///
  /// 联网还原 / 导入后调用它只会重载一次，语义等价且无副作用。
  Future<void> adoptRoundStack({bool force = false}) async {
    if (_bookUuid.isEmpty) return;
    await loadRounds(_bookUuid);
  }

  /// 预览「此刻若点击发送将实际发出」的请求体（不发送、**无任何副作用**）。
  ///
  /// 与 [sendIntent] 共用同一份组装（[_planSend]）与同一批执行器：预览不是
  /// 「真实发送的镜像」，不会另拼一套字段——界面所见的状态（灰条用途、历史、
  /// 档位、图片、参数）与实发完全同源。
  ///
  /// 返回 [RoundRequestPreview]：
  /// - `firstFrame` = 真正会发出的**首帧**（Agent 档位 = 该档位实际的第一步，
  ///   Lv.1 为准备帧而非正文帧）；
  /// - `subsequentFrames` = 后续**可能**发出的帧（仅增量字段，取决于模型响应）。
  ///
  /// 不落库、不发网络、不改生成状态（不新增轮次、不触发预热 / 云同步）。
  Future<RoundRequestPreview> previewRequestBody({
    required RoundSendIntent intent,
    Book? book,
  }) async {
    final b = book;
    if (b == null || b.uuid.isEmpty) {
      throw StateError('尚未选择书籍');
    }
    final invalid = validateSendIntent(intent);
    if (invalid != null) {
      throw StateError(invalid);
    }
    final plan = await _planSend(intent: intent, book: b);
    return _previewPlan(plan: plan, book: b);
  }

  /// 校验发送意图能否在当前状态下执行；返回原因（null = 可执行）。
  ///
  /// 预览与实发共用：灰条「按意见修改」指向的轮次若已被删除，两边给出同一句提示。
  ///
  /// [RoundSendKind.reaskRound] **不要求目标轮仍存在**——它只表达「从该轮号起截断
  /// 后重发」，投影里本就没有该轮时截断即为无操作（失败条目「本该产生的那一轮」
  /// 载体正是这种情况，见 [refreshRound]）；该用途指向的轮次是否还在，由界面侧
  /// 灰条守卫（`ComposerInputMode.guard`）按行身份判定。
  String? validateSendIntent(RoundSendIntent intent) {
    if (intent.kind != RoundSendKind.rewriteByOpinion) return null;
    return _targetRoundOf(intent) == null ? '该轮次已不存在，已退出修改' : null;
  }

  /// 意图指向的目标轮次（[RoundSendKind.newRound] 返回 null；不存在也返回 null）。
  Round? _targetRoundOf(RoundSendIntent intent) {
    final index = intent.targetRoundIndex;
    if (index == null) return null;
    for (final r in _rounds) {
      if (r.roundIndex == index) return r;
    }
    return null;
  }

  /// 本轮要保留的「用户输入 + 图片」（生成期间气泡 / 失败条目）。
  ///
  /// 修改轮沿用被重写轮的原输入与原图（意见不落库），其余取意图本身。
  ({String input, List<String> images}) _retainedOf(RoundSendIntent intent) {
    if (intent.kind != RoundSendKind.rewriteByOpinion) {
      return (input: intent.userInput, images: intent.images);
    }
    final target = _targetRoundOf(intent);
    return target == null
        ? (input: intent.userInput, images: intent.images)
        : (input: target.userInput, images: target.userImages);
  }

  /// 意图 → 本次请求计划（**纯组装**：不读写生成状态、不落库、不发网络）。
  ///
  /// 「先删轮再发」的用途（[RoundSendKind.reaskRound] / [RoundSendKind.rewriteByOpinion]）
  /// 在这里用**虚拟投影**表达截断语义，从而不必真的删库就能算出实发请求体；
  /// R3 的实发阶段**不删旧代**：新代直接插进同组并设为选中（见 [sendIntent]）。
  /// 界面侧的「生成期间按目标轮截断」只是展示投影，不写库。
  ///
  /// 每个用途的投影都先拼上父上文前缀（父分支到分叉点为止的上文）：空分支 /
  /// 分支上的任何一轮都不能只拿本分支的历史，否则新分支会像从零开始。
  Future<_SendPlan> _planSend({
    required RoundSendIntent intent,
    required Book book,
  }) async {
    final prefix = await _upstreamPrefixOf(book.historyRounds);
    List<Round> withPrefix(List<Round> branchRounds) =>
        [...prefix, ...branchRounds];

    switch (intent.kind) {
      case RoundSendKind.newRound:
        return _SendPlan(
          req: await _assembleRoundRequest(
            book: book,
            projection: withPrefix(_rounds),
            // 空分支没有链尾：轮号必须问仓储（父代轮号 +1），否则会从第 1 轮重开。
            targetRoundIndexOverride: nextRoundIndex,
            userInput: intent.userInput,
            userImages: intent.images,
          ),
        );
      case RoundSendKind.reaskRound:
        // 目标轮可以不在投影里（失败条目「本该产生的那一轮」载体）：截断即无操作。
        final index = intent.requiredTargetRoundIndex;
        return _SendPlan(
          req: await _assembleRoundRequest(
            book: book,
            // 与「重新生成」等价：历史只取目标轮之前的那些轮。
            projection: withPrefix(_projectionBefore(index)),
            userInput: intent.userInput,
            userImages: intent.images,
          ),
        );
      case RoundSendKind.rewriteByOpinion:
        final target = _targetRoundOf(intent)!;
        final projection = withPrefix(_projectionBefore(target.roundIndex));
        return _SendPlan(
          req: await _assembleRoundRequest(
            book: book,
            // **截断后的**投影：历史 n 轮必须是被重写轮之前最近 n 轮（与实发
            // 先删该轮起投影行的结果一致）；被重写轮自身由 `rewrite` 追加。
            projection: projection,
            userInput: target.userInput,
            userImages: target.userImages,
            // 基座 = 严格早于被重写轮的最近一轮（须在删投影行之前取）；
            // 重写分支首轮时，这个「上一轮」来自父上文（分叉点父代）。
            rewrite: RoundRewrite(
              target: target,
              base: projection.lastOrNull,
              opinion: intent.opinion,
              images: intent.images,
            ),
          ),
        );
    }
  }

  /// 本次请求要拼进投影的父上文（旧 → 新，含父代已删时的一轮快照）。
  ///
  /// 只取最近 `max(historyRounds, 1)` 条父轮次：既够 `_takeRecent` 的窗口，
  /// 也避免为一次发送把几千轮祖先正文全读出来；快照比存活父轮次都旧，放最前。
  Future<List<Round>> _upstreamPrefixOf(int historyRounds) async {
    final upstream = await _roundsRepo.loadUpstreamContext(
      bookUuid: _bookUuid,
      chain: _chain,
      limit: historyRounds < 1 ? 1 : historyRounds,
    );
    return [
      if (upstream.fallbackRound != null) upstream.fallbackRound!,
      ...upstream.rounds,
    ];
  }

  /// 计划 → 预演结果：直发 = 单帧；联网 / Agent = 对应执行器给出的帧骨架。
  ///
  /// 帧骨架由执行器自己产出（`outlineFrames`），首帧走与实发同一组装路径；
  /// Provider 不做任何二次拼合，因此不存在「预览与实发两套规则」。
  Future<RoundRequestPreview> _previewPlan({
    required _SendPlan plan,
    required Book book,
  }) async {
    final req = plan.req;
    if (req.agent) {
      final runner = _makeAgentRoundRunner(
        req: req,
        book: book,
        // 预览：不接任何过程回调，绝不改动生成状态。
        gen: null,
        call: _previewNeverCalled,
      );
      return RoundRequestPreview.fromOutline(
        runner.outlineFrames(req.agentValues!.messages),
      );
    }
    if (req.useSearch) {
      final runner = _makeSearchRunner(
        req: req,
        gen: null,
        call: _previewNeverCalled,
      );
      return RoundRequestPreview.fromOutline(
        runner.outlineFrames(_searchInitialMessages(req)),
      );
    }
    return RoundRequestPreview.single(firstFrame: req.directBody);
  }

  /// 预览专用 `call`：帧骨架只构建、不调用，因此这里永不被触发。
  static Future<AiCallResult> _previewNeverCalled(
    Map<String, dynamic> requestBody,
    bool stream,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  ) =>
      throw StateError('预览请求体不发起任何 AI 调用');

  /// 组装本轮「将要发出」的请求要素（纯组装，无副作用）：
  /// worldBook / Mod / 提示词 / 历史消息与图片 / 发送参数与请求体。
  ///
  /// 供 [sendIntent] 与「预览请求体」共用：不读写任何生成状态、不落库、不发网络。
  ///
  /// [projection] 是本次请求生效的**轮次投影**（按 `roundIndex` 升序）：普通发送
  /// = 「父上文前缀 + 当前分支链」；「先删轮再发」的用途 = 再按目标轮号截断后的
  /// 虚拟投影。所有依赖轮次的部分（末轮基座、历史 n 轮、图片）都只读它。
  ///
  /// [targetRoundIndexOverride] 覆盖「投影尾号 +1」的推导：空分支没有链尾，
  /// 新建轮必须由调用方传 `nextRoundIndex`（父代轮号 +1）；重新提问 / 修改轮
  /// 不传，保持各自原有口径。
  ///
  /// [rewrite] 非 null 时按**修改轮**组装（见 [RoundRewrite]）：
  /// - 生成基座 [PromptRequest.lastRound] = 被重写轮的上一轮（工具 / 状态快照停在那里）；
  /// - 历史 = 预设 n 轮 + **被重写轮自身**（= 该轮生成时 AI 收到的轮 + 自身，共 n+1）；
  /// - user 消息走修改轮模板，「主人的输入」= 用户填写的修改意见。
  Future<_RoundRequest> _assembleRoundRequest({
    required Book book,
    required List<Round> projection,
    required String userInput,
    List<String>? userImages,
    int? targetRoundIndexOverride,
    RoundRewrite? rewrite,
  }) async {
    final settings = _aiSettingsProvider;
    // 生成基座轮：新建轮 = 投影末轮（含父上文）；修改轮 = 被重写轮的上一轮。
    final lastRound =
        rewrite == null ? projection.lastOrNull : rewrite.base;
    final targetRoundIndex = rewrite?.target.roundIndex ??
        targetRoundIndexOverride ??
        (lastRound?.roundIndex ?? 0) + 1;
    // 档位驱动的记忆合并：本轮生成**之前**算定（输入 = 基座轮落库的记忆总结 +
    // 本书档位），随后下发给提示词 / Agent 执行器，并用于生成后判定。
    final memoryMergePlan = planMemoryMerge(
      memoryText: lastRound?.memorySummary ?? '',
      tier: book.memorySummaryRounds,
      newRoundIndex: targetRoundIndex,
    );
    // 历史轮次：新建轮 = 最近 n 轮；修改轮 = 被重写轮之前 n 轮 + **被重写轮自身**
    //（该轮生成时 AI 收到的 n 轮 + 该轮，供 AI 照着它做定向重写）。按轮号过滤是
    // 冗余保险：调用方已先删该轮起的投影行，这里只保证「自身恰好出现一次、且在最后」。
    final recentRounds = rewrite == null
        ? _takeRecent(projection, book.historyRounds)
        : [
            ..._takeRecent(projection, book.historyRounds)
                .where((r) => r.roundIndex < rewrite.target.roundIndex),
            rewrite.target,
          ];
    // 世界书 / Mod 世界书的关键词扫描输入：修改轮 = 被重写轮的原输入（原文需要的
    // 设定）+ 修改意见（新出现的词），两边该命中的都命中。
    final scanInput = rewrite == null
        ? userInput
        : '${rewrite.target.userInput}\n$userInput';
    final worldBookEntries = _worldBookScanner.scan(
      userInput: scanInput,
      historyRounds: recentRounds,
      entries: _worldBookProvider?.activeEntries ?? const [],
    );
    // 本书启用的 Mod：实时解析并置入前置词/后置词/系统提示词/世界书
    //（Mod 世界书条目与书籍世界书一致：关键词命中才注入，留空则恒定生效）。
    final modsBundle = _modProvider == null
        ? null
        : await _modProvider.resolveModsBundle(
            bookUuid: book.uuid,
            userInput: scanInput,
            historyRounds: recentRounds,
          );
    // 模式与协议**正交**（全解耦）：
    // - agentLevel：实验性档位（关 / Lv.1 / Lv.2，默认关闭）——档位档案
    //   （[AgentModeProfile]）决定提示词模式、工具栏目与历史拼合形态；
    //   无设置注入（仅测试/降级路径）保持 Chat 语义；
    // - responsesWire：平台接入协议决定的线路格式（只决定请求体形态）。
    final agentLevel =
        settings == null ? AgentModeLevel.off : _agentLevel;
    final profile = AgentModeProfile.of(agentLevel);
    final agentMode = profile.isOn;
    final responsesWire =
        settings?.selectedPlatform.apiType.isResponses ?? false;
    // 提示词取用**唯一入口**（`prompt_interface.dart`，当前绑定 v2）：
    // 本轮 system / user 文本与工具集都只经接口取用；报文与历史消息不在此列。
    final promptRequest = PromptRequest(
      book: book,
      mode: profile.promptMode,
      // 修改轮：基座 = 被重写轮的上一轮；新建轮：上一轮。
      lastRound: lastRound,
      // 修改轮：本轮 user 消息的【主人的输入】= 用户填写的修改意见。
      userInput: rewrite?.opinion ?? userInput,
      worldBookEntries: worldBookEntries,
      mods: modsBundle,
      rewrite: rewrite == null
          ? null
          : RewriteTarget(
              roundIndex: targetRoundIndex,
              roundTime: rewrite.target.currentTime,
            ),
    );
    final systemPrompt = promptInterface.system(promptRequest);

    // 历史轮次按 API 要求以原生 messages 数组（user/assistant 交替）传入，
    // 而非拼入本次 Prompt 文本（与提示词解耦：见 `wire_messages.dart`）。
    final supportsVision = settings?.supportsVision ?? false;
    // 本轮随 user 消息发出的图片：修改轮 = 意见里附带的图片（**不落库**，
    // 新版本沿用原图），新建轮 = 待发送附件。
    final currentImages = rewrite?.images ?? userImages;
    // 预读取本轮及历史用户消息所需图片为 base64 data URL（仅识图模型）。
    final imageDataUrls = supportsVision
        ? await _collectImageDataUrls(recentRounds, currentImages)
        : const <String, String>{};
    final historyMessages = buildHistoryMessages(
      recentRounds,
      imagePartsFor: supportsVision
          ? (r) => _imagePartsFor(r, imageDataUrls)
          : null,
      // 拼合形态随档位（见 [AssistantHistoryShape]）：Lv.2 每轮只带正文三小节、
      // Lv.1 最新一轮带 5 区块（历史区块由工具提供）、Chat 维持原样。
      shape: profile.historyShape,
    );
    final userText = promptInterface.user(promptRequest);
    final userContent = supportsVision
        ? _userContentWithImages(
            userText,
            currentImages,
            imageDataUrls,
          )
        : userText;

    // 搜索能力：默认关闭，用户可在 Chat 页选项下拉中手动开启（lastSearch）；
    // 无设置注入时按预设能力回退（仅测试/降级路径）。
    // Agent 档位下 思考 / 流式 / 搜索**强制开启**（只受模型配置页的能力开关
    // 限制）：组合时快照覆盖，**不改写**用户已保存的 Chat 每轮选项，
    // 关闭 Agent 后立即恢复用户原设置。
    final useSearch = settings == null
        ? AiPlatforms.defaultSupportsSearch
        : agentMode
            ? settings.supportsSearch
            : (settings.supportsSearch && settings.lastSearch);
    final useStream = agentMode
        ? (settings?.supportsStreaming ?? true)
        : (settings?.streaming ?? true);
    final model = (settings?.model.trim().isNotEmpty ?? false)
        ? settings!.model
        : AiPlatforms.defaultModelId;
    final thinking = agentMode
        ? (settings?.supportsThinking ?? AiPlatforms.defaultThinking)
        : (settings?.thinking ?? AiPlatforms.defaultThinking);
    final reasoningEffort =
        settings?.reasoningEffort ?? AppConfig.defaultReasoningEffort;
    final temperature = settings?.temperature ?? 1.0;
    final maxTokens = settings?.maxTokens;

    // AGENT 模式：分阶段执行器（Lv.1 = 准备 → 记忆 → 正文；
    // Lv.2 = 正文 → 缺口驱动的维护轮）+ 自定义状态/搜索工具。
    // 线路（responses / chat）只影响请求体形态，执行器结构完全一致：
    // - responses 线路：instructions + input items + 顶层工具 schema；
    // - chat 线路：system 消息 + role 消息 + 嵌套 function schema，
    //   执行器帧内追加的 function_call 条目在组装时转 chat 消息形态。
    if (agentMode && settings != null) {
      // AI 看到的初始 input：历史消息 + 当前用户消息（vision 图片在
      // responses 线路下转换为 input_image 内容块）；状态**不预置**，
      // 由模型主动调用各栏读取器获取（见 AgentRoundRunner 文档）。
      // 形态与执行器内部一致：Chat 线路 = Chat messages，Responses 线路 =
      // Responses 条目——两种线路随后都经 `_agentBody` / `_agentChatBody`
      // 的同一条转换路径出帧（首帧与续接帧不再各转一次）。
      // 联网工具随档位强制开启时同样**不追加任何 system 指令**：
      // 何时调用、搜索后必须打开页面等要求全部写在工具 `description` 里
      //（档位提示词只负责本档位可用的工具与调用纪律）。
      final inputItems = <Map<String, dynamic>>[
        if (!responsesWire) {'role': 'system', 'content': systemPrompt},
        ...historyMessages,
        {'role': 'user', 'content': userContent},
      ];
      // 工具 schema 超集（档位对应的状态工具 + 可选搜索工具），
      // **各阶段共用同一份**：tools 数组任何差异都会改变请求前缀，
      // 使服务商的上下文缓存整段失效。
      final schemaTools = _agentTools(
        level: agentLevel,
        workingCopy: AgentStateWorkingCopy(
          // 修改轮：工作副本 = 被重写轮（轮号 = 目标轮，基座 = 其上一轮）——
          // 工具读取 / 编辑都停在「上一轮的状态」。
          roundIndex: targetRoundIndex,
          lastRound: lastRound,
          categoryNames: [for (final c in book.roleCategories) c.name],
        ),
        useSearch: useSearch,
      );
      final agentValues = AiRequestValues(
        model: model,
        messages: inputItems,
        temperature: temperature,
        thinking: thinking,
        reasoningEffort: reasoningEffort,
        maxTokens: maxTokens,
        stream: useStream,
        tools: agentToolSchemas(schemaTools, responses: responsesWire),
        instructions: responsesWire ? systemPrompt : null,
      );
      // 预览 = 正文轮首帧的**同一条**组装路径（单一真源）。
      final firstBody = responsesWire
          ? _agentBody(
              settings: settings,
              base: agentValues,
              t: AgentTurnRequest(
                stage: AgentStage.story,
                items: inputItems,
              ),
            )
          : _agentChatBody(
              settings: settings,
              base: agentValues,
              t: AgentTurnRequest(
                stage: AgentStage.story,
                items: inputItems,
              ),
            );
      return _RoundRequest(
        systemPrompt: systemPrompt,
        historyMessages: historyMessages,
        userContent: userContent,
        model: model,
        useStream: useStream,
        useSearch: useSearch,
        directBody: firstBody,
        agent: true,
        agentLevel: agentLevel,
        responsesWire: responsesWire,
        agentValues: agentValues,
        agentChaining:
            responsesWire && settings.selectedPlatform.supportsResponseChaining,
        memoryMergePlan: memoryMergePlan,
        targetRoundIndex: targetRoundIndex,
        baseRound: lastRound,
      );
    }

    // Chat 模式（Agent 关闭）：按当前预设（规则构建器）动态组合请求体。
    // 线路规则：chat 线路 = system 消息 + 普通消息直发；responses 线路 =
    // instructions（系统提示词）+ input items（与 Chat 协议同构的消息），
    // **不引入任何 Agent 工具 / 状态机制**——协议只决定线路格式。
    if (responsesWire) {
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
        instructions: systemPrompt,
      );
      final requestBody = settings == null
          ? AiRequestBodyBuilder.buildPresetBody(
              rules: AiPlatforms.defaultRules,
              values: values,
            )
          : settings.buildRequestBody(values);
      return _RoundRequest(
        systemPrompt: systemPrompt,
        historyMessages: historyMessages,
        userContent: userContent,
        model: model,
        useStream: useStream,
        useSearch: useSearch,
        directBody: requestBody,
        responsesWire: true,
        memoryMergePlan: memoryMergePlan,
        targetRoundIndex: targetRoundIndex,
        baseRound: lastRound,
      );
    }

    final values = AiRequestValues(
      model: model,
      messages: [
        {'role': 'system', 'content': systemPrompt},
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
      systemPrompt: systemPrompt,
      historyMessages: historyMessages,
      userContent: userContent,
      model: model,
      useStream: useStream,
      useSearch: useSearch,
      directBody: requestBody,
      memoryMergePlan: memoryMergePlan,
      targetRoundIndex: targetRoundIndex,
      baseRound: lastRound,
    );
  }

  /// 发送新一轮（[RoundSendIntent.newRound] 的便捷入口；语义见 [sendIntent]）。
  ///
  /// 返回是否成功。请求失败 / 用户中断时保留用户输入到「失败条目」
  /// （AI 输出以红色提示框占位），不再以消息提示；
  /// 仅当失败条目落库也失败时通过 [error] 暴露原因。
  Future<bool> sendRound({
    required String userInput,
    Book? book,
    List<String>? userImages,
  }) =>
      sendIntent(
        intent: RoundSendIntent.newRound(
          userInput: userInput,
          images: userImages ?? const [],
        ),
        book: book,
      );

  /// 按**发送意图**实发（界面「发送 / 提交灰条用途」的唯一实发入口）。
  ///
  /// 与「预览请求体」（[previewRequestBody]）共用同一份组装（[_planSend]）与同一
  /// 批执行器：预览给出的首帧就是这里真正发出的那一帧，不存在两套拼合规则。
  ///
  /// 流程：
  /// 0. 校验意图（「按意见修改」要求目标轮仍存在）→ 清空本书「失败条目」
  ///    （失败则稍后重新写入）；
  /// 1. 组装请求计划（纯组装；「先删轮再发」的用途用虚拟投影算截断后的请求）；
  /// 2. 需要时先删该轮起的投影行（[RoundSendKind.reaskRound] /
  ///    [RoundSendKind.rewriteByOpinion]），再按计划调用大模型；
  /// 3. 容错解析 6 个区块；
  /// 4. 写入数据库。
  Future<bool> sendIntent({
    required RoundSendIntent intent,
    Book? book,
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
    // 错误代不能衍生下一轮：链尾是失败/中断时必须先重新生成或删除该轮，
    // 否则新轮会挂到一条没有内容的父代下面，整条链的上下文都是空的。
    if (_chain.tail?.isError == true &&
        intent.kind == RoundSendKind.newRound) {
      _error = '上一轮生成失败，请先「重新生成」或删除该轮';
      notifyListeners();
      return false;
    }
    final invalid = validateSendIntent(intent);
    if (invalid != null) {
      _error = invalid;
      notifyListeners();
      return false;
    }

    final settings = _aiSettingsProvider;
    // 生成令牌：本轮唯一。旧一轮的残留流回调（onChunk / isCancelled）捕获发起时
    // 的令牌，一旦与当前不一致即丢弃 / 中止，杜绝跨轮注入与双流式并存。
    gen.token++;
    final genToken = gen.token;
    // 失败占位的落点轮号：重写 = **被重写的那一轮**；新建轮 = 投影尾号 +1。
    // 先用「意图算出的待定落点」兜底（组装阶段就失败时也能落在正确轮号），
    // 请求计划算出后以计划口径覆盖；`catch` 子句取不到 try 块内的局部变量，故提前声明。
    int? failureRoundIndex;
    // 记录本次请求开始前是否已有其它生成任务（用于「首个任务开始」通知服务）。
    final wasActive = _hasActiveGeneration();
    gen.isSending = true;
    gen.cancelRequested = false;
    _error = null;
    // 记录本次用户输入：生成期间在消息列表中展示，结束/中断后清除。
    // 修改轮沿用被重写轮的原输入（意见不落库）。
    final retained = _retainedOf(intent);
    gen.pendingUserInput = retained.input;
    // 生成中气泡的落点：从意图立刻算出（界面在首次通知后就开始读它）。
    // 新建轮 = 下一轮；刷新 / 修改轮 = 被重写的轮号——不能再一律用链尾 +1。
    gen.pendingRoundIndex = intent.targetRoundIndex ?? nextRoundIndex;
    // 重置 Agent 过程时间线、重试状态、状态钳制警告与 RAW 时间线。
    gen.agentEvents.clear();
    gen.contentBoundaryIndex = -1;
    gen.agentWarnings.clear();
    gen.newReasoningBlockPending = true;
    gen.retryStatus = null;
    gen.rawExchanges.clear();
    gen.failedRawExchanges = null;
    notifyListeners();
    // 首个生成任务开始：通知服务启动 Android 后台保活前台服务。
    if (!wasActive) onGenerationActiveChanged?.call(true);
    try {
      // 组装本轮请求要素（worldBook / Mod / 提示词 / 历史消息与图片 / 参数与请求体）：
      // 与「预览请求体」共用同一逻辑，保证预览与实发完全一致。
      final plan = await _planSend(intent: intent, book: b);
      final req = plan.req;
      failureRoundIndex = req.targetRoundIndex;
      // 组装期间链可能被并发重载（云同步 / 换书）：以计划口径为准。
      gen.pendingRoundIndex = req.targetRoundIndex;
      // R3 没有投影表：旧代本来就留在库里，重写/重新生成**不需要**先删任何东西。
      // 新的一代插进同组并设为选中，后续轮次因父代改变自然从活动链上隐去。
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
      // 真实执行器：网络调用 + RAW 捕获（与预览共用同一分派，差别只在它）。
      final call = _makeRealCall(
        gen: gen,
        req: req,
        settings: settings,
      );
      // 模式与协议正交分派：
      // - Agent 模式（开关开）→ 两阶段执行器（线路由 req.responsesWire 决定）；
      // - 联网搜索 → Agent 工具循环（线路同样由 protocol 决定）；
      // - 直发 → 单轮请求（responses 线路走 /responses，chat 线路走 chat）。
      final agentOutcome = req.agent
          ? await _callWithRetry(
              () => _runAgentRound(
                req: req,
                book: b,
                gen: gen,
                call: call,
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
                req: req,
                gen: gen,
                call: call,
                onChunk: onChunk,
                isCancelled: isCancelled,
              ),
              gen: gen,
              genToken: genToken,
            )
          : await _callWithRetry(
              () => call(
                req.directBody,
                req.useStream,
                onChunk,
                null,
                isCancelled,
              ),
              gen: gen,
              genToken: genToken,
            );
      // 用户主动中断：丢弃部分内容，落一条错误代保留用户输入。
      if (gen.cancelRequested) {
        gen.isStreaming = false;
        gen.showTimeline = false;
        gen.streamingContent = '';
        gen.agentEvents.clear();
        gen.failedRawExchanges = List.of(gen.rawExchanges);
        final ok = await _appendFailureRound(
          bookUuid: b.uuid,
          roundIndex: failureRoundIndex,
          userInput: retained.input,
          userImages: retained.images,
          message: '已中断',
        );
        if (ok != null) await _afterGenerationWrite(b.uuid);
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
        // 新建轮 = 投影尾号 +1；修改轮 = **被重写的那一轮**（投影行同号替换为新代）。
        roundIndex: req.targetRoundIndex,
        userInput: retained.input,
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
        // 缓存命中输入 token（服务商未返回该字段 → null → 界面「（无）」）。
        cachedTokensIn: result.cachedTokensIn,
        // 本轮实际使用的模型名（{{model}} 解析值），随轮次持久化。
        modelName: req.model,
        // 用户消息附带的图片（相对路径），随轮次落库，供气泡展示与历史回放。
        userImages: retained.images,
        createdAt: DateTime.now(),
      );
      // 结束态：生成期间的顶部警告随本轮落库为该「代」的提示（`warning` 级）。
      // Chat 模式无回炉机会：档位要求的记忆合并没落地 → 追加一条提示
      //（Agent 模式的同类判定在 `AgentRoundRunner` 内，避免重复提示）。
      final mergePlan = req.memoryMergePlan;
      final chatMergeWarnings = <String>[
        if (agentOutcome == null &&
            mergePlan != null &&
            !isMemoryMergeApplied(parsed.memorySummary, mergePlan))
          mergePlan.uiText,
      ];
      final generationWarnings = [
        ...gen.agentWarnings,
        ...chatMergeWarnings,
      ].where((line) => line.trim().isNotEmpty).toList();
      // R3：本轮 = 当前分支里同分组的新一代（父 = 上一轮当前代）。
      // 该轮若曾被重写，旧代作为同父兄弟代留在库里（`← / →` 切回）。
      // 父代必须显式传给 `_appendRound`：它不给 `fatherUuid` 就默认 null，
      // 于是每轮都成了「链首」——三代各自成根，活动链只解析出最后一轮。
      final fatherUuid = _fatherAnchorFor(newRound.roundIndex);
      await _appendRound(
        newRound,
        serial: _nextSerialFor(
          roundIndex: newRound.roundIndex,
          fatherUuid: fatherUuid,
        ),
        fatherUuid: fatherUuid,
        message: generationWarnings.join('\n'),
        messageStatus: generationWarnings.isEmpty ? '' : 'warning',
      );
      _bumpVersions();
      // 成功轮次：RAW 时间线按**代 uuid** 归位（loadRounds 不会丢它）。
      final rawExchanges = List.of(gen.rawExchanges);
      gen.rawExchanges.clear();
      if (_bookUuid == b.uuid) {
        await loadRounds(b.uuid);
      }
      final liveRound = _bookUuid == b.uuid
          ? _rounds
              .where((r) => r.roundIndex == newRound.roundIndex)
              .firstOrNull
          : null;
      if (liveRound != null) {
        _rawByGeneration[liveRound.uuid] = rawExchanges;
      }
      // 生成成功：通知系统通知服务（若用户不在该书 chat 页则弹出系统通知）。
      onGenerationCompleted?.call(b.uuid, b.title);
      return true;
    } on AiCancelledException {
      // 用户主动中断（非流式场景由 _chatOnce 抛出）：不提示错误，落一条错误代。
      gen.isStreaming = false;
      gen.showTimeline = false;
      gen.streamingContent = '';
      gen.agentEvents.clear();
      _error = null;
      gen.failedRawExchanges = List.of(gen.rawExchanges);
      final ok = await _appendFailureRound(
        bookUuid: b.uuid,
        // 组装阶段就中断时 failureRoundIndex 仍为空：用待定落点兜底，
        // 保证错误代落在被刷新 / 修改的那一轮，而不是链尾 +1。
        roundIndex: failureRoundIndex ?? gen.pendingRoundIndex ?? nextRoundIndex,
        userInput: retained.input,
        userImages: retained.images,
        message: '已中断',
      );
      if (ok != null) await _afterGenerationWrite(b.uuid);
      return false;
    } catch (e) {
      // 请求失败：落一条错误代，文案 = 失败原因 + 本轮已产生的过程警告。
      gen.isStreaming = false;
      gen.showTimeline = false;
      gen.streamingContent = '';
      gen.agentEvents.clear();
      gen.failedRawExchanges = List.of(gen.rawExchanges);
      final failureMessage = [
        e.toString(),
        ...gen.agentWarnings,
      ].where((line) => line.trim().isNotEmpty).join('\n');
      final saved = await _appendFailureRound(
        bookUuid: b.uuid,
        // 同中断路径：组装阶段失败也要落在目标轮（见上）。
        roundIndex: failureRoundIndex ?? gen.pendingRoundIndex ?? nextRoundIndex,
        userInput: retained.input,
        userImages: retained.images,
        message: failureMessage,
      );
      if (saved != null) await _afterGenerationWrite(b.uuid);
      // 仅当错误代也落库失败时才暴露原因（UI 兜底提示并恢复输入）。
      _error = saved != null ? null : e.toString();
      return false;
    } finally {
      gen.isSending = false;
      gen.cancelRequested = false;
      gen.pendingUserInput = '';
      gen.pendingRoundIndex = null;
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
  /// 交换记录，返回后回填思考 / 搜索 / 正文三块；调用**失败**时把原因写进
  /// [RawExchange.error]（RAW 里显示「请求失败：…」而不是含糊的「无返回」——
  /// 例如协议兼容降级前的探测帧被服务商拒绝，随后同一帧会重发）。
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
    final AiCallResult result;
    try {
      result = await _aiService.chat(
        apiBaseUrl: apiBaseUrl,
        apiKey: apiKey,
        requestBody: requestBody,
        stream: stream,
        onChunk: onChunk,
        isCancelled: isCancelled,
      );
    } catch (e) {
      exchange.error = '$e';
      rethrow;
    }
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

  /// 本轮工具集（**唯一入口 = `promptInterface.tools`**）：档位决定状态工具栏目，
  /// [useSearch] 决定是否叠加联网工具（搜索 → 打开页）。
  ///
  /// [gen] 为 null 时仅用于「预览请求体」读取工具定义：过程回调全部置空
  /// （工具只读 name/description/parameters，绝不执行 run，无副作用）。
  /// 测试 / 调用方可注入的工具替身在 `promptInterface` 内优先使用。
  List<NarrAgentTool> _agentTools({
    required AgentModeLevel level,
    AgentStateWorkingCopy? workingCopy,
    bool useSearch = false,
    _BookGenState? gen,
  }) =>
      promptInterface.tools(AgentToolsRequest(
        level: level,
        workingCopy: workingCopy,
        useSearch: useSearch,
        search: _searchService,
        webSearch: _webSearchTool,
        fetchPage: _fetchPageTool,
        handlers: gen == null
            ? null
            : AgentToolEventHandlers(
                onResults: (r) => _handleSearchResults(r, gen),
                onSearchFail: () => _handleSearchFail(gen),
                onFetchDone: () => _handleFetchDone(gen),
                onFetchFail: () => _handleFetchFail(gen),
                onFetchRefused: () => _handleFetchFail(gen, refused: true),
                onFetchHop: (h) => _handleFetchHop(h, gen),
              ),
      ));

  /// 联网工具循环执行（本轮开启联网搜索时）。
  ///
  /// 首轮带 `narrchat_webSearch` 工具调用模型；若模型请求搜索则执行并把结果
  /// 回传，直至模型返回最终内容（6 区块）或达到最大迭代次数。
  ///
  /// [call] 由调用方注入：实发 = 网络 + RAW 捕获（见 [_makeRealCall]）；预览不调用
  /// 本方法，只取 [AgentRunner.outlineFrames] 给出的帧骨架。
  Future<AiCallResult> _runAgent({
    required _RoundRequest req,
    required _AiCall call,
    required _BookGenState? gen,
    required void Function(AiStreamChunk chunk)? onChunk,
    required bool Function() isCancelled,
  }) async {
    final runner = _makeSearchRunner(req: req, gen: gen, call: call);
    return runner.run(
      initialMessages: _searchInitialMessages(req),
      stream: req.useStream,
      onChunk: onChunk,
      isCancelled: isCancelled,
      onActivity: gen == null ? null : (a) => _handleAgentActivity(a, gen),
    );
  }

  /// 联网工具循环的初始 messages（system + 历史 + 当前输入）。
  static List<Map<String, dynamic>> _searchInitialMessages(_RoundRequest req) => [
        {'role': 'system', 'content': req.systemPrompt},
        ...req.historyMessages,
        {'role': 'user', 'content': req.userContent},
      ];

  /// 工具循环执行器（**实发与预览共用同一构造**：同一帧体构建器与工具集）。
  ///
  /// [gen] 为 null = 预览：工具过程回调全部置空（工具只读 name/description/
  /// parameters，绝不执行 run，也不改生成状态）。
  AgentRunner _makeSearchRunner({
    required _RoundRequest req,
    required _BookGenState? gen,
    required _AiCall call,
  }) {
    final tools = _agentTools(
      level: AgentModeLevel.off,
      useSearch: true,
      gen: gen,
    );
    return AgentRunner(
      // 规则构建器 / 自定义模板与线路（chat / responses）都按当前设置决定。
      buildBody: _makeBodyBuilder(
        _aiSettingsProvider,
        req.useStream,
        responsesWire: req.responsesWire,
      ),
      call: call,
      // 每个 Agent 运行使用绑定到本书生成状态的工具实例：多本书并发生成时，
      // 搜索 / 抓取过程事件（UI 展示）互不串书；测试注入的工具优先。
      tools: tools,
      toolSchemas: agentToolSchemas(tools, responses: req.responsesWire),
      reduceReasoningReplay: _reduceReasoningReplay,
    );
  }

  /// AGENT 单轮执行（分阶段 + 状态自取；线路由 req.responsesWire 决定）。
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
    required Book book,
    required _AiCall call,
    required _BookGenState gen,
    required void Function(AiStreamChunk chunk)? onChunk,
    required bool Function() isCancelled,
  }) async {
    final runner = _makeAgentRoundRunner(
      req: req,
      book: book,
      gen: gen,
      call: call,
    );
    final workingCopy = runner.workingCopy;
    final values = req.agentValues!;

    final roundResult = await runner.run(
      initialInputItems: values.messages,
      stream: req.useStream,
      onChunk: onChunk,
      isCancelled: isCancelled,
    );
    if (roundResult.content.trim().isEmpty) {
      // 整轮没有任何正文（纯工具轮 / 服务端只回工具调用 / 首帧即被截断）：
      // 本轮判失败，走既有的「失败条目保留用户输入」路径，不写入半截轮次；
      // 同时留下一条后果说明（由失败路径合并进该轮失败占位代的提示：
      // 状态改动随工作副本一起作废）。
      final truncated = roundResult.incomplete;
      gen.agentWarnings
        ..clear()
        ..add(
          truncated
              ? '本轮未产出正文（模型输出在上限处被截断），本轮的状态改动已作废。'
                    '请在设置中调高「最大 token」后重试。'
              : '本轮未产出正文（模型只返回了工具调用），本轮的状态改动已作废。',
        );
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
        cachedTokensIn: roundResult.cachedTokensIn,
        responseId: roundResult.responseId,
      ),
      snapshot: _mergedSnapshot(
        AgentModeProfile.of(req.agentLevel),
        workingCopy,
        roundResult.content,
      ),
      agent: roundResult,
    );
  }

  /// AGENT 执行器（**实发与预览共用同一构造**：档位档案、工具超集、状态工作副本、
  /// 帧体构建器完全一致）。
  ///
  /// [gen] 为 null = 预览：不接任何过程回调（工具只读定义、不执行，也不改生成状态）。
  AgentRoundRunner _makeAgentRoundRunner({
    required _RoundRequest req,
    required Book book,
    required _BookGenState? gen,
    required _AiCall call,
  }) {
    final workingCopy = AgentStateWorkingCopy(
      // 修改轮：轮号 = 被重写轮，基座 = 其上一轮（工具查询 / 编辑停在上一轮）。
      roundIndex: req.targetRoundIndex,
      lastRound: req.baseRound,
      categoryNames: [for (final c in book.roleCategories) c.name],
    );
    // 工具超集：档位对应的状态工具 + （可选）搜索工具，**各阶段共用同一份**
    // schema，保证 instructions / tools 前缀在准备 / 记忆 / 正文 / 维护之间完全一致。
    final tools = _agentTools(
      level: req.agentLevel,
      workingCopy: workingCopy,
      useSearch: req.useSearch,
      gen: gen,
    );
    final values = req.agentValues!;
    return AgentRoundRunner(
      // 线路决定请求体形态（responses / chat），执行器结构与帧语义不变。
      buildBody: (t) => req.responsesWire
          ? _agentBody(settings: _aiSettingsProvider, base: values, t: t)
          : _agentChatBody(settings: _aiSettingsProvider, base: values, t: t),
      call: call,
      tools: tools,
      workingCopy: workingCopy,
      // 档位档案：提示词模式、工具栏目、正文契约的唯一映射。
      profile: AgentModeProfile.of(req.agentLevel),
      memoryMergePlan: req.memoryMergePlan,
      chaining: req.agentChaining,
      reduceReasoningReplay: _reduceReasoningReplay,
      // AGENT 单轮路径：搜索 / 打开页面事件由工具事件（流式预览 / 开始 /
      // 完成）**统一承载**——同一工具调用只产生一个事件框；活动回调仅用于
      // 新一轮思考块管理（否则会出现「联网搜索框 + Tool 框」双框）。
      onActivity: gen == null
          ? null
          : (a) {
              if (a.type == AgentActivityType.turn) {
                _handleAgentActivity(a, gen);
              }
            },
      onToolStarted: gen == null ? null : (o) => _handleToolStarted(o, gen),
      onToolFinished: gen == null ? null : (o) => _handleToolFinished(o, gen),
    );
  }

  /// 实发执行器：真实网络调用 + RAW 捕获（[call] 的唯一注入点，见 [sendIntent]）。
  ///
  /// 与预览的差别**只有这一个函数**：预览路径根本不构造它（帧骨架只构建、不调用）。
  _AiCall _makeRealCall({
    required _BookGenState gen,
    required _RoundRequest req,
    required AiSettingsProvider? settings,
  }) {
    final apiBaseUrl = settings?.baseUrl ?? AppConfig.defaultApiBaseUrlEffective;
    final apiKey = settings?.apiKey ?? AppConfig.defaultApiKeyEffective;
    return (body, stream, onChunk, onRequestBody, isCancelled) =>
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
              );
  }

  /// 投影里严格早于 [roundIndex] 的全部轮次（虚拟投影：与「先删该轮起投影行」
  /// 的结果一致，供预览 / 实发在**不落库**的前提下算出截断后的请求）。
  List<Round> _projectionBefore(int roundIndex) => [
        for (final r in _rounds)
          if (r.roundIndex < roundIndex) r,
      ];

  /// 本轮落库快照（档位差异的唯一处理点）：
  /// - **Lv.2**：状态三栏全部来自工作副本（正文不含状态区块）；
  /// - **Lv.1**：世界状态 / 角色状态 / 当前时间由**正文文本**携带（属正文契约），
  ///   历史（记忆总结）由工具维护 → 从正文解析补齐前三项、记忆取工作副本；
  ///   正文解析不到时该项为空（与 Chat 的缺失语义一致，不做兜底猜测）。
  static RoundSnapshot _mergedSnapshot(
    AgentModeProfile profile,
    AgentStateWorkingCopy workingCopy,
    String story,
  ) {
    final copySnapshot = workingCopy.mergedSnapshot();
    if (profile.toolSections.contains(AgentStateSection.worldState)) {
      return copySnapshot;
    }
    final parsed = AiResponseParser.parse(story);
    return RoundSnapshot(
      worldState: parsed.worldState,
      characterState: parsed.characterState,
      memorySummary: copySnapshot.memorySummary,
      currentTime: parsed.currentTime.isNotEmpty
          ? parsed.currentTime
          : copySnapshot.currentTime,
    );
  }

  /// AGENT 模式单帧请求体（Responses 线路；预览与实发共用同一路径）。
  ///
  /// 帧间差异只有这几处，其余前缀逐字节一致（服务商上下文缓存依赖此）：
  /// - [AgentTurnRequest.items]：本轮累积 input（各阶段追加 assistant / 工具
  ///   条目与阶段指令，维护轮再追加缺口清单）；
  /// - [AgentTurnRequest.previousResponseId]：有状态续接帧不重发
  ///   instructions / tools。
  ///
  /// **思考强度 / 思考开关 / `max_output_tokens` 一律沿用用户设置**：
  /// 程序不为任何帧覆盖它们（触顶时由执行器下发「拆短调用」指令 +
  /// 黄框提示用户自行调高上限）。
  static Map<String, dynamic> _agentBody({
    required AiSettingsProvider? settings,
    required AiRequestValues base,
    required AgentTurnRequest t,
  }) {
    final previousResponseId = t.previousResponseId;
    final chained =
        previousResponseId != null && previousResponseId.isNotEmpty;
    // 执行器累积的 items 已是「Responses 形状」→ 按条目类型还原 input
    //（**不能**再走 `responsesItemsFromChatMessages`：思考条目会被当成无 role
    // 的普通消息，产出坏条目）。首帧与后续帧因此共用同一条转换路径。
    final values = _frameValues(
      base,
      t,
      chained: chained,
      items: responsesItemsFromAgentItems(t.items),
    );
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
  /// 续接，每帧全量重发）。
  static Map<String, dynamic> _agentChatBody({
    required AiSettingsProvider? settings,
    required AiRequestValues base,
    required AgentTurnRequest t,
  }) {
    final values = _chatFrameValues(base, t, chatItemsFromAgentItems(t.items));
    return settings == null
        ? AiRequestBodyBuilder.buildPresetBody(
            rules: AiPlatforms.defaultRules,
            values: values,
          )
        : settings.buildRequestBody(values);
  }

  /// 各阶段帧的公共取值（协议无关部分）：**思考开关与强度全帧沿用用户设置**
  /// （执行器不为任何阶段覆盖；见 [AgentTurnRequest]），温度 / 上限 / 流式同样
  /// 沿用户设置；有状态续接（[chained]）时省略 tools / instructions
  /// （responses 专用）。
  static AiRequestValues _frameValues(
    AiRequestValues base,
    AgentTurnRequest t, {
    bool chained = false,
    List<Map<String, dynamic>>? items,
  }) {
    return AiRequestValues(
      model: base.model,
      messages: items ?? t.items,
      temperature: base.temperature,
      thinking: base.thinking,
      reasoningEffort: base.reasoningEffort,
      maxTokens: base.maxTokens,
      stream: base.stream,
      tools: chained ? null : base.tools,
      instructions: chained ? null : base.instructions,
    );
  }

  /// [_frameValues] 的 Chat 线路变体：messages 换成 Chat 形态，
  /// `instructions` 置 null（Chat 协议没有该字段，系统提示词已是首帧第一条
  /// system 消息）。
  static AiRequestValues _chatFrameValues(
    AiRequestValues base,
    AgentTurnRequest t,
    List<Map<String, dynamic>> messages,
  ) {
    final frame = _frameValues(base, t, chained: false, items: messages);
    return AiRequestValues(
      model: frame.model,
      messages: frame.messages,
      temperature: frame.temperature,
      thinking: frame.thinking,
      reasoningEffort: frame.reasoningEffort,
      maxTokens: frame.maxTokens,
      stream: frame.stream,
      tools: frame.tools,
      instructions: null,
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
    final AiCallResult result;
    try {
      result = await _aiService.responses(
        apiBaseUrl: apiBaseUrl,
        apiKey: apiKey,
        requestBody: requestBody,
        stream: stream,
        onChunk: onChunk,
        isCancelled: isCancelled,
      );
    } catch (e) {
      // 失败原因留在 RAW 里：协议兼容降级前的探测帧（如 `previous_response_id`
      // 有状态续接）被服务商拒绝时，RAW 会显示「请求失败：<报错原文>」
      // 而不是含糊的「无返回」。
      exchange.error = '$e';
      rethrow;
    }
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
  /// R3 没有"投影行"，一轮就是活动链上的一代，所以两个入口的语义是：
  /// - [deleteFollowing] = true：删除本轮**及之后**全部轮次（本分支的全部代）；
  /// - [deleteFollowing] = false：只删**当前这一代**（等同于「删除此代」）。
  ///
  /// 与「重新生成」的区别：重新生成是**新增**一代并切过去（旧代留着可切回），
  /// 删除是物理删行。
  Future<void> deleteRound(Round round, {required bool deleteFollowing}) async {
    if (deleteFollowing) {
      await _deleteRoundAndFollowing(round);
      return;
    }
    // 「仅删除本轮」= 删除这一代。中间轮只有一代时无法安全删除（会把链断开），
    // 但**链尾**没有后继，删这一代和删这一轮完全等价——直接按"删到末尾"处理，
    // 避免用户点删除却毫无反应。
    final deleted = await deleteCurrentGeneration(round);
    if (!deleted && _chain.tail?.uuid == round.uuid) {
      _error = null;
      await _deleteRoundAndFollowing(round);
    }
  }

  Future<void> _deleteRoundAndFollowing(Round round) async {
    try {
      final result = await _roundsRepo.deleteRoundAndFollowing(
        bookUuid: round.bookUuid,
        roundIndex: round.roundIndex,
      );
      if (result.deleted > 0) {
        _bumpVersions();
        // 提示随代一起消失（删除是物理删行）。
        for (final key in _rawByGeneration.keys.toList()) {
          final live = _rounds.any((r) => r.uuid == key);
          if (!live) _rawByGeneration.remove(key);
        }
      }
      if (_bookUuid.isNotEmpty) {
        await loadRounds(_bookUuid);
      }
      _cloudSyncProvider?.triggerSync();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  /// 删除某轮**当前这一代**（用户端单代删除）：
  /// 1. 物理删除该代**及其后代子树**（父代已删的子代不可达）；
  /// 2. 该轮当前代自动回落到相邻存活代（**前一代优先**；第一代被删则回落后面一代）；
  /// 3. 后续轮次随父代回来 / 随分支消失。
  ///
  /// 唯一一代没有回落目标 → 返回 `false` 且**不改动任何数据**（提示由调用方给出）。
  Future<bool> deleteCurrentGeneration(Round round) async {
    if (_bookUuid.isEmpty || isSending) return false;
    if (round.uuid.isEmpty) return false;
    try {
      final result = await _roundsRepo.deleteGeneration(
        bookUuid: round.bookUuid,
        generationUuid: round.uuid,
      );
      if (result.isRefused) {
        _error = result.refusal;
        notifyListeners();
        return false;
      }
      _bumpVersions();
      // RAW 按代 uuid 归属：被删代的记录随代消失（其余代不受影响）。
      _rawByGeneration.remove(round.uuid);
      if (_bookUuid.isNotEmpty) {
        await loadRounds(_bookUuid);
      }
      _cloudSyncProvider?.triggerSync();
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 当前已加载书的「删除未启用的代」计划；未加载该书 / uuid 为空时返回 null。
  ///
  /// 同步读本机缓存的元信息，不碰数据库（供书籍设置面板展示计数）。
  DeleteUnusedGenerationsPlan? unusedGenerationsPlanFor(String bookUuid) {
    if (bookUuid.isEmpty || _bookUuid != bookUuid) return null;
    return BranchRules.planDeleteUnusedGenerations(all: _chain.allMeta);
  }

  /// 删除指定书**未启用**的代（每组保留当前选中代）。
  ///
  /// - 正在生成中 / uuid 为空 → 返回带 `refusal` 的结果，不写库；
  /// - 成功删除 > 0 时重载当前书的活动链、清掉已删代的 RAW 记录，并触发云备份；
  /// - 异常收进 [error] 并以 `refusal` 返回，供界面直接提示。
  Future<RoundMutation> deleteUnusedGenerations(String bookUuid) async {
    if (bookUuid.isEmpty) {
      return const RoundMutation(refusal: '书籍信息缺失');
    }
    if (isGeneratingBook(bookUuid)) {
      return const RoundMutation(refusal: '正在生成中，暂不可删除未启用的代');
    }
    try {
      final result = await _roundsRepo.deleteUnusedGenerations(
        bookUuid: bookUuid,
      );
      if (result.deleted <= 0) return result;

      _bumpVersions();
      if (_bookUuid == bookUuid) {
        await loadRounds(bookUuid);
        // RAW 按代 uuid 归属：被删代的记录随代消失，其余代不受影响。
        final alive = {for (final meta in _chain.allMeta) meta.uuid};
        _rawByGeneration.removeWhere((uuid, _) => !alive.contains(uuid));
        notifyListeners();
      }
      _cloudSyncProvider?.triggerSync();
      return result;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return RoundMutation(refusal: _error);
    }
  }

  /// 「重新生成」——**唯一入口**（气泡底部按钮 / 气泡菜单 / 错误代按钮与菜单共用）：
  /// 以该轮的用户输入 / 图片重新请求 AI（新增一代并切到它，旧代留着可切回）。
  ///
  /// [round] 只作**载体**：真正被读的是 [Round.roundIndex] / [Round.userInput] /
  /// [Round.userImages]。错误代场景由界面直接把那条错误轮传进来——它与正常刷新
  /// 是同一条路径，差别只是输入来自哪里。
  ///
  /// 走 [RoundSendIntent.reaskRound]：**预览请求体**用同一意图即可给出这条路径真正
  /// 会发出的请求体（截断语义由虚拟投影表达）。
  Future<void> refreshRound(Round round, {Book? book}) async {
    final b = book;
    if (b == null || b.uuid.isEmpty || _gen(b.uuid).isSending) return;
    await sendIntent(
      intent: RoundSendIntent.reaskRound(
        targetRoundIndex: round.roundIndex,
        userInput: round.userInput,
        images: round.userImages,
      ),
      book: b,
    );
  }

  /// 修改并重新提问：
  /// 1. 原地修改该轮当前代（用户输入）；
  /// 2. 删除该轮起的投影行（旧代保留）；
  /// 3. 以修改后的输入重新请求 AI（替换为新的一代）。
  Future<void> editAndReAsk(
    Round round,
    String editedInput, {
    Book? book,
    List<String>? images,
  }) async {
    final b = book;
    if (b == null || b.uuid.isEmpty || _gen(b.uuid).isSending) return;
    await _applyEdit(round.uuid, (r) => r.copyWith(userInput: editedInput));
    await sendIntent(
      intent: RoundSendIntent.reaskRound(
        targetRoundIndex: round.roundIndex,
        userInput: editedInput,
        images: images ?? const [],
      ),
      book: b,
    );
  }

  /// 按意见修改：以用户填写的修改意见**重写某一轮**（AI 气泡的「按意见修改」）。
  ///
  /// 与 [refreshRound] / [editAndReAsk] 同一套「重写」骨架，差别只在请求：
  /// 1. 取被重写轮 [round] 与其**上一轮**的快照（内容来自内存投影）；
  /// 2. 删除该轮起的投影行（旧代保留在版本树，`← / →` 可切回；后续轮次随旧代
  ///    一起从视图隐藏——分支模型既定语义，与「重新生成」一致）；
  /// 3. 以「修改轮」提示词重新请求 AI（见 [sendIntent]）：
  ///    - 历史 = 该轮生成时收到的 n 轮 + 该轮自身（n+1）；
  ///    - 状态 / 记忆等工具读取到的信息全部停在**上一轮**；
  ///    - 用户输入与图片沿用该轮原值（新版本与修改前一致），意见只进请求。
  ///
  /// [images] 是随意见附带的图片（仅本次请求，不落库）。
  /// 返回是否成功；失败按既有「重新生成」规则写入失败条目（见 [sendIntent]）。
  Future<bool> modifyRoundByOpinion(
    Round round,
    String opinion, {
    Book? book,
    List<String>? images,
  }) async {
    final b = book;
    if (b == null || b.uuid.isEmpty || _gen(b.uuid).isSending) return false;
    final text = opinion.trim();
    if (text.isEmpty) return false;
    return sendIntent(
      intent: RoundSendIntent.rewriteByOpinion(
        targetRoundIndex: round.roundIndex,
        opinion: text,
        images: images ?? const [],
      ),
      book: b,
    );
  }

  /// 原地修改某一代（不新增代）：写正文列并刷新 `updated_at`。
  ///
  /// 供编辑 AI 正文 / 用户输入 / 侧边栏白名单字段共用。
  Future<bool> _applyEdit(
    String roundUuid,
    Round Function(Round) change,
  ) async {
    final round = _rounds.where((r) => r.uuid == roundUuid).firstOrNull;
    if (round == null) return false;
    final edited = change(round);
    try {
      await _roundsRepo.updateContent(
        bookUuid: round.bookUuid,
        generationUuid: round.uuid,
        fields: {
          'user_input': edited.userInput,
          'ai_narrative': edited.aiNarrative,
          'world_state': edited.worldState,
          'character_state': edited.characterState,
          'memory_summary': edited.memorySummary,
          'current_time': edited.currentTime,
          'recommended_action': edited.recommendedAction,
        },
      );
      _bumpVersions();
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

  /// 编辑 AI 正文（长按/右键 → 编辑正文）。
  Future<void> updateNarrative(String roundUuid, String narrative) async {
    await _applyEdit(roundUuid, (r) => r.copyWith(aiNarrative: narrative));
  }

  /// 编辑用户输入（长按/右键 → 编辑输入）：同样走原地修改。
  Future<void> updateUserInput(String roundUuid, String input) async {
    await _applyEdit(roundUuid, (r) => r.copyWith(userInput: input));
  }

  /// 侧边栏显式保存：将单个字段（数据库列名）原地写回当前代并重新加载。
  ///
  /// 仅允许白名单内的字段，防止误写；返回是否保存成功。
  Future<bool> updateRoundField(
    String roundUuid,
    String field,
    String value,
  ) async {
    if (!RoundField.editable.contains(field)) return false;
    return _applyEdit(roundUuid, (r) => r.withField(field, value));
  }

  static List<Round> _takeRecent(List<Round> rounds, int n) {
    final chatRounds = rounds.where((r) => r.roundIndex > 0).toList();
    if (n <= 0) return [];
    if (chatRounds.length > n) {
      return chatRounds.sublist(chatRounds.length - n);
    }
    return chatRounds;
  }
}

/// 「按意见修改」（修改轮）的一次请求上下文。
///
/// 由 [RoundProvider.modifyRoundByOpinion] 构造：目标轮与其上一轮的快照都取自
/// **内存投影**（此时该轮起的投影行已被删除），因此这里必须自带全部内容。
class RoundRewrite {
  const RoundRewrite({
    required this.target,
    required this.base,
    required this.opinion,
    this.images = const [],
  });

  /// 被重写的那一轮（内容 = 修改前的当前代）。
  final Round target;

  /// 生成基座 = 被重写轮的上一轮（历史 / 状态工作副本都停在它上面）。
  final Round? base;

  /// 用户填写的修改意见（本轮 user 消息的【主人的输入】）。
  final String opinion;

  /// 随意见附带的图片：仅用于本次请求（**不落库**，新版本沿用该轮原图）。
  final List<String> images;
}

/// 一次 AI 调用的执行器：实发 = 网络请求 + RAW 捕获（[_RoundProvider._makeRealCall]）；
/// 预览路径只取执行器给出的帧骨架，从不构造本执行器。
typedef _AiCall = Future<AiCallResult> Function(
  Map<String, dynamic> requestBody,
  bool stream,
  void Function(AiStreamChunk chunk)? onChunk,
  void Function(String requestBody)? onRequestBody,
  bool Function()? isCancelled,
);

/// 一次发送的内部计划。
///
/// 组装（[_RoundProvider._planSend]）是纯函数：R3 没有投影表，重新生成只是往
/// 同组再插一代，所以这里不需要「发送前先删什么」的指令。
class _SendPlan {
  const _SendPlan({required this.req});

  /// 本轮请求组装结果。
  final _RoundRequest req;
}

/// 一轮请求的组装结果（供 `sendIntent` 与「预览请求体」共用）。
///
/// 全部字段在组装时确定，不携带任何运行时生成状态。
/// [agent]（实验性档位）与 [responsesWire]（线路协议）**正交**：
/// - [agent] 为 true：Agent 分阶段执行器启用（自定义工具 + 状态工作副本），
///   [agentLevel] / [agentValues] 等字段随之生效；
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

  /// 是否 AGENT 模式（实验性档位 Lv.1 / Lv.2；与协议正交）。
  final bool agent;

  /// Agent 档位（[agent] 为 true 时有效）：Lv.1 走 5 区块正文 + 历史工具，
  /// Lv.2 走 3 小节正文 + 六工具。
  final AgentModeLevel agentLevel;

  /// 是否 Response API 线路（/responses；协议只决定请求体形态）。
  final bool responsesWire;

  /// AGENT 模式请求取值模板（model / 初始 input items / instructions /
  /// 工具 schema 超集 / 思考与温度 / max tokens）；每帧在此基础上替换
  /// `messages`（累积 input），见 [_agentBody]。
  final AiRequestValues? agentValues;

  /// 平台是否支持有状态链式续接（previous_response_id）。默认关：
  /// 许多 OpenAI 兼容实现无此字段，关闭时全量重发（前缀不变仍可命中缓存）；
  /// Chat 线路不支持续接，恒为 false。
  final bool agentChaining;

  /// 本轮应执行的「记忆总结轮次合并」动作（档位 0 / 无动作时为 null）。
  ///
  /// 组装时一次算定（`memory_merge_planner.dart`）：Chat 经用户消息注入指令、
  /// Agent 交执行器；两者都在生成后用它判定是否落地（未落地 → 常驻警告）。
  final MemoryMergePlan? memoryMergePlan;

  /// 本轮落库的轮号：新建轮 = 投影尾号 +1；修改轮 = **被重写的那一轮**。
  final int targetRoundIndex;

  /// 本轮的状态基座轮（修改轮 = 被重写轮的上一轮）。
  ///
  /// Agent 工作副本以它铺设（工具读取 / 编辑都停在上一轮）。
  final Round? baseRound;

  const _RoundRequest({
    required this.systemPrompt,
    required this.historyMessages,
    required this.userContent,
    required this.model,
    required this.useStream,
    required this.useSearch,
    required this.directBody,
    this.agent = false,
    this.agentLevel = AgentModeLevel.off,
    this.responsesWire = false,
    this.agentValues,
    this.agentChaining = false,
    this.memoryMergePlan,
    required this.targetRoundIndex,
    this.baseRound,
  });
}
