import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../config/model_presets.dart';
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
import '../services/prompt_builder.dart';
import '../services/world_book_scanner.dart';
import 'ai_settings_provider.dart';
import 'cloud_sync_provider.dart';
import 'mod_provider.dart';
import 'world_book_provider.dart';

/// 轮次状态管理：加载、发送（组装 Prompt + 调用 AI + 解析入库）、删除、刷新、保存快照。
class RoundProvider extends ChangeNotifier {
  /// Agent 路径注入的搜索指令：引导模型在用户明确要求搜索时先调用工具
  ///（非思考模式下模型容易把「搜索」当成剧情动作，需显式声明）；
  /// 搜索后应主动打开结果页面阅读，确保细节准确。
  static const String _searchInstruction =
      '【联网搜索】若用户明确要求搜索、查询或查找资料'
      '（如「搜索/查一下/查找/查资料」），请先调用 web_search 工具'
      '获取信息；然后从结果中主动选择最相关的 1~2 个页面，'
      '用 fetch_page 打开并阅读正文，确保细节准确；'
      '再基于获取的信息继续创作。未明确要求时不要调用搜索工具。';

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
    // 默认使用共享的搜索服务实例（避免重复创建 http client）。
    final search = searchService ?? HtmlSearchService();
    // 联网搜索工具：成功回调更新结果明细；失败回调标记搜索框失败（✕）。
    _webSearchTool =
        webSearchTool ??
        WebSearchTool(
          search: search,
          onResults: _handleSearchResults,
          onFail: _handleSearchFail,
        );
    // 打开网页工具：成功/失败回调更新 fetch 事件状态（✓ / ✕）。
    _fetchPageTool =
        fetchPageTool ??
        FetchPageTool(
          search: search,
          onDone: _handleFetchDone,
          onFail: _handleFetchFail,
        );
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
  late final WebSearchTool _webSearchTool;
  late final FetchPageTool _fetchPageTool;

  /// 网络类失败重试间隔。
  final Duration _retryDelay;

  List<Round> _rounds = [];

  /// 缓存的不可变轮次视图：仅当 [_rounds] 重新赋值时更新。
  /// UI 用 `context.select` 按引用比较该视图，避免流式输出时
  /// 轮次未变化却随每次 chunk 触发侧栏等无关组件重建。
  List<Round> _roundsView = const [];

  bool _isSending = false;
  bool _isStreaming = false;
  bool _cancelRequested = false;
  String _streamingContent = '';

  /// Agent 过程时间线：思考 / 搜索事件按真实顺序交错排列
  ///（思考1 → 搜索1 → 思考2 → 搜索2 …）。
  List<AgentEvent> _agentEvents = [];

  /// 下一段思考增量到达时是否新建思考事件（agent 每轮开始时置位）。
  bool _newReasoningBlockPending = true;

  /// 当前自动重试进度：(已重试次数, 总次数)；null = 无重试。
  (int, int)? _retryStatus;

  /// 当前尝试的 RAW 时间线（请求体 → AI返回 交错；重试时清空）。
  final List<RawExchange> _rawExchanges = [];

  /// 各成功轮次的 RAW 时间线（内存，key = roundId；切换书籍时清理）。
  final Map<int, List<RawExchange>> _rawDataByRound = {};

  /// 失败条目的 RAW 时间线（最近一次失败 / 中断尝试）。
  List<RawExchange>? _failedRawExchanges;
  String _pendingUserInput = '';
  String? _error;
  int? _bookId;

  /// 本书的「失败条目」（最近一次未完成的生成尝试；空 = 无）。
  FailedAttempt _failedAttempt = const FailedAttempt();

  List<Round> get rounds => _roundsView;
  bool get isSending => _isSending;
  bool get isStreaming => _isStreaming;
  String get streamingContent => _streamingContent;

  /// Agent 过程时间线（思考 / 搜索交错，供流式气泡渲染）。
  List<AgentEvent> get agentEvents => List.unmodifiable(_agentEvents);

  /// 当前自动重试进度（灰字「错误重连……（x/3）」）；null = 无重试。
  (int, int)? get retryStatus => _retryStatus;

  /// 指定轮次的 RAW 时间线（无数据返回 null）。
  List<RawExchange>? rawExchangesFor(int roundId) {
    final data = _rawDataByRound[roundId];
    return (data == null || data.isEmpty) ? null : data;
  }

  /// 失败条目的 RAW 时间线（无数据返回 null）。
  List<RawExchange>? get failedRawExchanges {
    final data = _failedRawExchanges;
    return (data == null || data.isEmpty) ? null : data;
  }

  /// 当前正在生成中、尚未落库的用户输入（用于生成期间不回藏用户消息）。
  String get pendingUserInput => _pendingUserInput;

  /// 本书「失败条目」：请求失败 / 用户中断的未完成尝试（空 = 无）。
  FailedAttempt get failedAttempt => _failedAttempt;

  /// 是否存在失败条目。
  bool get hasFailureEntry => !_failedAttempt.isEmpty;

  /// 失败条目的用户输入（空串 = 无）。
  String get failedUserInput => _failedAttempt.userInput;

  /// 失败条目的错误信息（空串 = 用户中断「已截断」）。
  String get failedErrorMessage => _failedAttempt.errorMessage;

  String? get error => _error;
  Round? get latestRound => _rounds.isEmpty ? null : _rounds.last;

  /// 中断当前生成（流式会中止 HTTP 连接；非流式丢弃结果）。
  void cancelGeneration() {
    if (!_isSending) return;
    _cancelRequested = true;
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
  Future<void> loadRounds(int bookId) async {
    // 切换书籍：清理旧书的内存 RAW 数据，避免跨书误配。
    if (_bookId != null && _bookId != bookId) {
      _rawDataByRound.clear();
      _failedRawExchanges = null;
    }
    _bookId = bookId;
    try {
      _setRounds(await _dao.getRoundsByBook(bookId));
      if (_rounds.isEmpty) {
        await _dao.insertRound(
          Round(bookId: bookId, roundIndex: 0, createdAt: DateTime.now()),
        );
        _setRounds(await _dao.getRoundsByBook(bookId));
      }
    } catch (e) {
      _error = e.toString();
    }
    // 加载本书「失败条目」（best-effort：读取失败不影响轮次加载）。
    await _loadFailedAttempt(bookId);
    notifyListeners();
  }

  /// 加载本书「失败条目」；读取失败时置空（不打扰用户）。
  Future<void> _loadFailedAttempt(int bookId) async {
    try {
      _failedAttempt = await _bookDao.getFailedAttempt(bookId);
    } catch (_) {
      _failedAttempt = const FailedAttempt();
    }
  }

  /// 写入本书「失败条目」（内存 + 数据库）；空条目即清空。返回是否成功落库。
  Future<bool> _setFailedAttempt(int bookId, FailedAttempt attempt) async {
    _failedAttempt = attempt;
    notifyListeners();
    try {
      await _bookDao.setFailedAttempt(bookId, attempt);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清除本书「失败条目」（UI「清除失败条目」入口）。
  Future<void> clearFailedAttempt() async {
    final id = _bookId;
    if (id == null) return;
    _failedRawExchanges = null;
    await _setFailedAttempt(id, const FailedAttempt());
  }

  /// 重新加载当前书籍的轮次（云同步恢复数据后调用）。
  ///
  /// 云同步「删除并恢复」后，当前书籍可能已被覆盖删除：
  /// 先确认书籍仍存在，避免对已删除书籍误建「第零轮」触发外键错误。
  Future<void> reloadCurrent() async {
    final id = _bookId;
    if (id == null) return;
    final exists = await _bookDao.getBookById(id) != null;
    if (!exists) {
      _setRounds([]);
      notifyListeners();
      return;
    }
    await loadRounds(id);
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
  }) async {
    final b = book;
    if (b == null || b.id == null) {
      _error = '尚未选择书籍';
      notifyListeners();
      return false;
    }
    if (_isSending) {
      _error = '正在请求中，请稍候';
      return false;
    }

    final settings = _aiSettingsProvider;
    _isSending = true;
    _cancelRequested = false;
    _error = null;
    // 记录本次用户输入：生成期间在消息列表中展示，结束/中断后清除。
    _pendingUserInput = userInput;
    // 重置 Agent 过程时间线、重试状态与 RAW 时间线。
    _agentEvents = [];
    _newReasoningBlockPending = true;
    _retryStatus = null;
    _rawExchanges.clear();
    _failedRawExchanges = null;
    notifyListeners();
    try {
      // 开始新请求：清空本书「失败条目」（失败则稍后重新写入）。
      await _setFailedAttempt(b.id!, const FailedAttempt());
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
              bookId: b.id!,
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
      final historyMessages = PromptBuilder.buildHistoryMessages(recentRounds);

      final useStream = settings?.streaming ?? true;
      // 搜索能力：默认关闭，用户可在 Chat 页选项下拉中手动开启（lastSearch）；
      // 无设置注入时按预设能力回退（仅测试/降级路径）。
      final useSearch = settings == null
          ? ModelPresets.defaultPreset.supportsSearch
          : (settings.selectedPreset.supportsSearch && settings.lastSearch);
      if (useStream) {
        _isStreaming = true;
        _streamingContent = '';
        notifyListeners();
      }

      // 按当前预设（规则构建器 / 自定义模板）动态组合请求体：
      // 不同模式（思考 / 联网搜索 / 流式）下发送的参数由预设规则决定。
      final values = AiRequestValues(
        model: (settings?.model.trim().isNotEmpty ?? false)
            ? settings!.model
            : ModelPresets.defaultPreset.modelId,
        messages: [
          {'role': 'system', 'content': prompts.systemPrompt},
          ...historyMessages,
          {'role': 'user', 'content': prompts.userPrompt},
        ],
        temperature: settings?.temperature ?? 1.0,
        thinking:
            settings?.thinking ?? ModelPresets.defaultPreset.defaultThinking,
        reasoningEffort:
            settings?.reasoningEffort ?? AppConfig.defaultReasoningEffort,
        maxTokens: settings?.maxTokens,
        stream: useStream,
        tools: null,
      );
      final requestBody = settings == null
          ? AiRequestBodyBuilder.buildPresetBody(
              rules: ModelPresets.defaultPreset.requestRules,
              values: values,
            )
          : settings.buildRequestBody(values);

      final onChunk = _buildStreamingOnChunk(useStream);
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
                  {'role': 'user', 'content': prompts.userPrompt},
                ],
                useStream: useStream,
                onChunk: onChunk,
              ),
            )
          : await _callWithRetry(
              () => _chatCapturing(
                requestBody: requestBody,
                apiBaseUrl:
                    settings?.baseUrl ?? AppConfig.defaultApiBaseUrlEffective,
                apiKey: settings?.apiKey ?? AppConfig.defaultApiKeyEffective,
                stream: useStream,
                onChunk: onChunk,
                isCancelled: () => _cancelRequested,
              ),
            );
      // 用户主动中断：丢弃部分内容，以「已截断」失败条目保留用户输入。
      if (_cancelRequested) {
        _isStreaming = false;
        _streamingContent = '';
        _agentEvents = [];
        _failedRawExchanges = List.of(_rawExchanges);
        await _setFailedAttempt(
          b.id!,
          FailedAttempt(userInput: userInput),
        );
        return false;
      }
      _isStreaming = false;
      _streamingContent = '';
      _agentEvents = [];

      final parsed = AiResponseParser.parse(result.content);

      final newRound = Round(
        bookId: b.id!,
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
        createdAt: DateTime.now(),
      );
      final newRoundId = await _dao.insertRound(newRound);
      // 成功轮次：RAW 时间线归属到本轮（随后清理当前缓冲）。
      _rawDataByRound[newRoundId] = List.of(_rawExchanges);
      _rawExchanges.clear();
      await loadRounds(b.id!);
      // 自动云同步：开启「每轮生成结束后自动上传」时，本轮落库后异步上传，
      // 不阻塞本轮返回；上传失败也不影响本轮结果。
      final cloud = _cloudSyncProvider;
      if (cloud != null && cloud.autoUpload && cloud.isConfigured) {
        unawaited(cloud.upload(auto: true));
      }
      return true;
    } on AiCancelledException {
      // 用户主动中断（非流式场景由 _chatOnce 抛出）：不提示错误，
      // 以「已截断」失败条目保留用户输入。
      _isStreaming = false;
      _streamingContent = '';
      _agentEvents = [];
      _error = null;
      _failedRawExchanges = List.of(_rawExchanges);
      await _setFailedAttempt(
        b.id!,
        FailedAttempt(userInput: userInput),
      );
      return false;
    } catch (e) {
      // 请求失败：以「生成失败 + 原因」失败条目保留用户输入（不再弹消息提示）。
      _isStreaming = false;
      _streamingContent = '';
      _agentEvents = [];
      _failedRawExchanges = List.of(_rawExchanges);
      final saved = await _setFailedAttempt(
        b.id!,
        FailedAttempt(userInput: userInput, errorMessage: e.toString()),
      );
      // 仅当失败条目落库也失败时才暴露原因（UI 兜底提示并恢复输入）。
      _error = saved ? null : e.toString();
      return false;
    } finally {
      _isSending = false;
      _cancelRequested = false;
      _pendingUserInput = '';
      _retryStatus = null;
      _rawExchanges.clear();
      notifyListeners();
    }
  }

  /// 包裹一次 AI 调用并捕获 RAW 交换记录（请求体 + 返回三块）。
  ///
  /// 直发路径与 Agent 工具循环（逐迭代）共用：调用前入列一条携带请求体的
  /// 交换记录，返回后回填思考 / 搜索 / 正文三块。
  Future<AiCallResult> _chatCapturing({
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
    _rawExchanges.add(exchange);
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
    Future<AiCallResult> Function() action,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final result = await action();
        _retryStatus = null;
        return result;
      } on AiCancelledException {
        rethrow;
      } catch (e) {
        if (attempt >= _maxAiRetries ||
            classifyAiErrorKind(e) != AiExceptionKind.network ||
            _cancelRequested) {
          rethrow;
        }
        // 重置流式内容与 Agent 时间线，展示重试提示并稍候重试。
        _streamingContent = '';
        _agentEvents = [];
        _newReasoningBlockPending = true;
        _rawExchanges.clear();
        _retryStatus = (attempt + 1, _maxAiRetries);
        notifyListeners();
        if (_retryDelay > Duration.zero) {
          await Future<void>.delayed(_retryDelay);
        }
        if (_cancelRequested) {
          throw const AiCancelledException();
        }
      }
    }
  }

  /// Agent 工具循环执行（本轮开启联网搜索时）。
  ///
  /// 首轮带 `web_search` 工具调用模型；若模型请求搜索则执行并把结果
  /// 回传，直至模型返回最终内容（6 区块）或达到最大迭代次数。
  Future<AiCallResult> _runAgent({
    required AiSettingsProvider? settings,
    required String apiBaseUrl,
    required String apiKey,
    required List<Map<String, dynamic>> initialMessages,
    required bool useStream,
    required void Function(AiStreamChunk chunk)? onChunk,
  }) async {
    final runner = AgentRunner(
      buildBody: (messages, tools) {
        final values = AiRequestValues(
          model: (settings?.model.trim().isNotEmpty ?? false)
              ? settings!.model
              : ModelPresets.defaultPreset.modelId,
          messages: messages,
          temperature: settings?.temperature ?? 1.0,
          thinking:
              settings?.thinking ?? ModelPresets.defaultPreset.defaultThinking,
          reasoningEffort:
              settings?.reasoningEffort ?? AppConfig.defaultReasoningEffort,
          maxTokens: settings?.maxTokens,
          stream: useStream,
          tools: tools,
        );
        return settings == null
            ? AiRequestBodyBuilder.buildPresetBody(
                rules: ModelPresets.defaultPreset.requestRules,
                values: values,
              )
            : settings.buildRequestBody(values);
      },
      call: (requestBody, stream, onChunk, onRequestBody, isCancelled) =>
          _chatCapturing(
            requestBody: requestBody,
            apiBaseUrl: apiBaseUrl,
            apiKey: apiKey,
            stream: stream,
            onChunk: onChunk,
            isCancelled: isCancelled ?? () => false,
          ),
      tools: [_webSearchTool, _fetchPageTool],
    );

    return runner.run(
      initialMessages: initialMessages,
      stream: useStream,
      onChunk: onChunk,
      isCancelled: () => _cancelRequested,
      onActivity: _handleAgentActivity,
    );
  }

  /// 流式增量回调：累积正文，思考按块累积（agent 每轮一个新思考块），
  /// 并驱动 UI 更新（非流式返回 null）。
  void Function(AiStreamChunk chunk)? _buildStreamingOnChunk(bool useStream) {
    if (!useStream) return null;
    return (chunk) {
      if (chunk.done) return;
      // 新一次尝试开始产出内容：清除重试提示（灰字消失）。
      _retryStatus = null;
      if (chunk.contentDelta.isNotEmpty) {
        // 进入正文阶段：当前轮的思考已完成。
        _finishCurrentThinking();
        _streamingContent += chunk.contentDelta;
      }
      if (chunk.reasoningDelta.isNotEmpty) {
        // 需要新建思考事件（首段思考或 agent 新一轮开始）时先开新事件。
        if (_newReasoningBlockPending) {
          _newReasoningBlockPending = false;
          _agentEvents.add(const AgentEvent(type: AgentEventType.thinking));
        }
        final last = _agentEvents.length - 1;
        _agentEvents[last] = _agentEvents[last].copyWith(
          content: _agentEvents[last].content + chunk.reasoningDelta,
        );
      }
      notifyListeners();
    };
  }

  /// 将最近的未完成思考事件标记为完成（思考结束 / 开始搜索 / 进入正文时）。
  void _finishCurrentThinking() {
    for (var i = _agentEvents.length - 1; i >= 0; i--) {
      final e = _agentEvents[i];
      if (e.type == AgentEventType.thinking && !e.done) {
        _agentEvents[i] = e.copyWith(done: true);
        break;
      }
    }
  }

  /// Agent 活动回调：
  /// - `turn`：新一轮 LLM 调用开始，上一轮思考完成，后续思考进入新事件；
  /// - `searching`：开始搜索，本轮思考完成并新增搜索事件；
  /// - `fetching`：开始打开网页，本轮思考完成并新增 fetch 事件。
  void _handleAgentActivity(AgentActivity activity) {
    if (activity.type == AgentActivityType.turn) {
      _finishCurrentThinking();
      _newReasoningBlockPending = true;
      notifyListeners();
    } else if (activity.type == AgentActivityType.searching) {
      _finishCurrentThinking();
      _agentEvents.add(
        AgentEvent(
          type: AgentEventType.search,
          content: activity.query,
          searching: true,
        ),
      );
      notifyListeners();
    } else if (activity.type == AgentActivityType.fetching) {
      _finishCurrentThinking();
      _agentEvents.add(
        AgentEvent(
          type: AgentEventType.fetch,
          content: activity.query,
          searching: true,
        ),
      );
      notifyListeners();
    }
  }

  /// 搜索完成回调：更新最近一个进行中的搜索事件（结果 + 完成）。
  void _handleSearchResults(List<SearchResult> results) {
    for (var i = _agentEvents.length - 1; i >= 0; i--) {
      final e = _agentEvents[i];
      if (e.type == AgentEventType.search && e.searching) {
        _agentEvents[i] = e.copyWith(
          searching: false,
          results: results,
          done: true,
        );
        break;
      }
    }
    notifyListeners();
  }

  /// 搜索失败 / 无结果回调：把搜索事件标记为失败（UI 显示 ✕，不报错截断）。
  void _handleSearchFail() {
    for (var i = _agentEvents.length - 1; i >= 0; i--) {
      final e = _agentEvents[i];
      if (e.type == AgentEventType.search && e.searching) {
        _agentEvents[i] = e.copyWith(
          searching: false,
          done: true,
          failed: true,
        );
        break;
      }
    }
    notifyListeners();
  }

  /// 打开页面成功回调：把最近的进行中 fetch 事件标记完成（✓）。
  void _handleFetchDone() {
    _markFetchEvent(failed: false);
  }

  /// 打开页面失败回调：标记为失败（✕）。
  void _handleFetchFail() {
    _markFetchEvent(failed: true);
  }

  /// 更新最近一个进行中的 fetch 事件（完成 / 失败）。
  void _markFetchEvent({required bool failed}) {
    for (var i = _agentEvents.length - 1; i >= 0; i--) {
      final e = _agentEvents[i];
      if (e.type == AgentEventType.fetch && e.searching) {
        _agentEvents[i] = e.copyWith(
          searching: false,
          done: true,
          failed: failed,
        );
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
      if (_bookId != null) {
        await loadRounds(_bookId!);
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
    if (b == null || b.id == null || _isSending) return;
    await deleteRound(round, deleteFollowing: true);
    await sendRound(userInput: round.userInput, book: b);
  }

  /// 修改并重新提问：
  /// 1. 更新该轮的用户输入；
  /// 2. 删除本轮及后续所有轮次；
  /// 3. 以修改后的输入重新请求 AI（替换原轮次及后续，而非追加新轮次）。
  Future<void> editAndReAsk(Round round, String editedInput, {Book? book}) async {
    final b = book;
    if (b == null || b.id == null || _isSending) return;
    await updateUserInput(round.id!, editedInput);
    await deleteRound(round, deleteFollowing: true);
    await sendRound(userInput: editedInput, book: b);
  }

  /// 编辑 AI 正文（长按/右键 → 编辑正文）。
  Future<void> updateNarrative(int roundId, String narrative) async {
    try {
      await _dao.updateRoundFields(roundId, {'ai_narrative': narrative});
      if (_bookId != null) {
        await loadRounds(_bookId!);
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  /// 编辑用户输入（长按/右键 → 编辑输入）。
  Future<void> updateUserInput(int roundId, String input) async {
    try {
      await _dao.updateRoundFields(roundId, {'user_input': input});
      if (_bookId != null) {
        await loadRounds(_bookId!);
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  /// 侧边栏实时保存：将单个字段（数据库列名）写回并重新加载。
  ///
  /// 仅允许白名单内的字段，防止误写；返回是否保存成功。
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
      if (_bookId != null) {
        await loadRounds(_bookId!);
      }
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
