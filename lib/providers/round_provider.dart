import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../database/round_dao.dart';
import '../models/book.dart';
import '../models/round.dart';
import '../services/ai_response_parser.dart';
import '../services/ai_service.dart';
import '../services/prompt_builder.dart';
import '../services/world_book_scanner.dart';
import 'ai_settings_provider.dart';
import 'world_book_provider.dart';

/// 轮次状态管理：加载、发送（组装 Prompt + 调用 AI + 解析入库）、删除、刷新、保存快照。
class RoundProvider extends ChangeNotifier {
  RoundProvider({
    RoundDao? dao,
    AiService? aiService,
    PromptBuilder? promptBuilder,
    WorldBookScanner? worldBookScanner,
    AiSettingsProvider? aiSettingsProvider,
    WorldBookProvider? worldBookProvider,
  })  : _dao = dao ?? RoundDao(),
        _aiService = aiService ?? AiService(),
        _promptBuilder = promptBuilder ?? const PromptBuilder(),
        _worldBookScanner = worldBookScanner ?? const WorldBookScanner(),
        // ignore: prefer_initializing_formals
        _aiSettingsProvider = aiSettingsProvider,
        // ignore: prefer_initializing_formals
        _worldBookProvider = worldBookProvider;

  final RoundDao _dao;
  final AiService _aiService;
  final PromptBuilder _promptBuilder;
  final WorldBookScanner _worldBookScanner;
  final AiSettingsProvider? _aiSettingsProvider;
  final WorldBookProvider? _worldBookProvider;

  List<Round> _rounds = [];
  bool _isSending = false;
  bool _isStreaming = false;
  bool _cancelRequested = false;
  String _streamingContent = '';
  String _streamingReasoning = '';
  String? _error;
  int? _bookId;

  List<Round> get rounds => List.unmodifiable(_rounds);
  bool get isSending => _isSending;
  bool get isStreaming => _isStreaming;
  String get streamingContent => _streamingContent;
  String get streamingReasoning => _streamingReasoning;
  String? get error => _error;
  Round? get latestRound => _rounds.isEmpty ? null : _rounds.last;

  /// 中断当前生成（流式会中止 HTTP 连接；非流式丢弃结果）。
  void cancelGeneration() {
    if (!_isSending) return;
    _cancelRequested = true;
    notifyListeners();
  }

  // 调试数据：仅保留最新一轮发出的完整请求 JSON、AI 原始返回与思考内容。
  int? _debugRoundId;
  String _debugRequestBody = '';
  String _debugRawResponse = '';
  String _debugRawReasoning = '';

  /// 调试数据所属轮次 id（null 表示暂无）。
  int? get debugRoundId => _debugRoundId;
  String get debugRequestBody => _debugRequestBody;
  String get debugRawResponse => _debugRawResponse;
  String get debugRawReasoning => _debugRawReasoning;

  /// 加载指定书籍的全部轮次（按 round_index 升序）。
  ///
  /// 若书籍尚无任何轮次，自动创建「第零轮」（round_index = 0），
  /// 用于在开始对话前编辑初始的世界状态与角色状态。
  Future<void> loadRounds(int bookId) async {
    if (_bookId != bookId) {
      // 切换书籍时清空调试数据。
      _debugRoundId = null;
      _debugRequestBody = '';
      _debugRawResponse = '';
      _debugRawReasoning = '';
    }
    _bookId = bookId;
    try {
      _rounds = await _dao.getRoundsByBook(bookId);
      if (_rounds.isEmpty) {
        await _dao.insertRound(
          Round(bookId: bookId, roundIndex: 0, createdAt: DateTime.now()),
        );
        _rounds = await _dao.getRoundsByBook(bookId);
      }
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  /// 发送新一轮：
  /// 1. 组装 System/User Prompt；
  /// 2. 按 AI 设置调用大模型（支持流式/思考/温度/模型）；
  /// 3. 容错解析 6 个区块；
  /// 4. 写入数据库。
  ///
  /// 返回是否成功。失败时通过 [error] 暴露原因，且不写入任何数据。
  Future<bool> sendRound({
    required String userInput,
    String tempPrePrompt = '',
    String tempPostPrompt = '',
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
    notifyListeners();
    try {
      final lastRound = latestRound;
      final recentRounds = _takeRecent(b.historyRounds);
      final worldBookEntries = _worldBookScanner.scan(
        userInput: userInput,
        historyRounds: recentRounds,
        entries: _worldBookProvider?.activeEntries ?? const [],
      );
      final prompts = _promptBuilder.build(
        book: b,
        lastRound: lastRound,
        userInput: userInput,
        tempPrePrompt: tempPrePrompt,
        tempPostPrompt: tempPostPrompt,
        worldBookEntries: worldBookEntries,
      );

      // 历史轮次按 API 要求以原生 messages 数组（user/assistant 交替）传入，
      // 而非拼入本次 Prompt 文本。
      final historyMessages = PromptBuilder.buildHistoryMessages(recentRounds);

      final useStream = settings?.streaming ?? true;
      if (useStream) {
        _isStreaming = true;
        _streamingContent = '';
        _streamingReasoning = '';
        notifyListeners();
      }

      final result = await _aiService.chat(
        apiBaseUrl: settings?.baseUrl ?? AppConfig.defaultApiBaseUrlEffective,
        apiKey: settings?.apiKey ?? AppConfig.defaultApiKeyEffective,
        systemPrompt: prompts.systemPrompt,
        userPrompt: prompts.userPrompt,
        historyMessages: historyMessages,
        model: settings?.model,
        temperature: settings?.temperature ?? 1.0,
        thinking: settings?.thinking ?? false,
        reasoningEffort: settings?.reasoningEffort ?? 'high',
        maxTokens: settings?.maxTokens,
        stream: useStream,
        onChunk: useStream
            ? (chunk) {
                if (chunk.done) return;
                if (chunk.contentDelta.isNotEmpty) {
                  _streamingContent += chunk.contentDelta;
                }
                if (chunk.reasoningDelta.isNotEmpty) {
                  _streamingReasoning += chunk.reasoningDelta;
                }
                notifyListeners();
              }
            : null,
        onRequestBody: (json) => _debugRequestBody = json,
        isCancelled: () => _cancelRequested,
      );
      // 用户主动中断：丢弃部分内容，不保存本轮，也不视为错误。
      if (_cancelRequested) {
        _isStreaming = false;
        _streamingContent = '';
        _streamingReasoning = '';
        return false;
      }
      _isStreaming = false;
      _streamingContent = '';
      _streamingReasoning = '';

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
      await _dao.insertRound(newRound);
      // 仅保留最新一轮的调试数据（完整请求 JSON、AI 原始返回与思考内容）。
      _debugRoundId = newRound.id;
      _debugRawResponse = result.content;
      _debugRawReasoning = result.reasoningContent;
      await loadRounds(b.id!);
      return true;
    } on AiCancelledException {
      // 用户主动中断（非流式场景由 _chatOnce 抛出）：不提示错误。
      _isStreaming = false;
      _streamingContent = '';
      _streamingReasoning = '';
      _error = null;
      return false;
    } catch (e) {
      _isStreaming = false;
      _streamingContent = '';
      _streamingReasoning = '';
      _error = e.toString();
      return false;
    } finally {
      _isSending = false;
      _cancelRequested = false;
      notifyListeners();
    }
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
  /// 仅允许白名单内的字段，防止误写。
  Future<void> updateRoundField(int roundId, String field, String value) async {
    const allowed = {
      'world_state',
      'character_state',
      'memory_summary',
      'current_time',
      'ai_narrative',
      'user_input',
    };
    if (!allowed.contains(field)) return;
    try {
      await _dao.updateRoundFields(roundId, {field: value});
      if (_bookId != null) {
        await loadRounds(_bookId!);
      }
    } catch (e) {
      _error = e.toString();
      notifyListeners();
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
