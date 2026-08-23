import 'dart:async';

import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/world_book_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/failed_attempt.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/image_import_service.dart';
import 'package:narrchat/services/notification_service.dart';

/// 公共测试替身（Fakes）。
///
/// 用途：多个测试文件此前各自复制一份 `_MockBookDao` / `_MockRoundDao` 等
/// 替身类（累计约 1000 行），且实现细节互相漂移。统一收口到本文件后：
/// - 所有 `getAllBooks` 均已覆写，彻底切断真实 DatabaseHelper / path_provider
///   初始化链（此前部分文件漏覆写，会“碰巧通过”）；
/// - 新增测试直接复用，不再复制。
///
/// 约定：本文件不包含任何 widget 脚手架（见 chat_harness.dart），
/// 仅包含“数据/服务层”替身。

/// 内存版 [BookDao]：可注入书籍列表与最近对话时间，记录失败条目。
class FakeBookDao extends BookDao {
  FakeBookDao({this.books = const [], this.times = const {}});

  final List<Book> books;
  final Map<int, DateTime> times;
  FailedAttempt failed = const FailedAttempt();

  @override
  Future<List<Book>> getAllBooks() async => books;

  @override
  Future<Map<int, DateTime>> getLastRoundTimes() async => times;

  @override
  Future<FailedAttempt> getFailedAttempt(int bookId) async => failed;

  @override
  Future<void> setFailedAttempt(int bookId, FailedAttempt attempt) async {
    failed = attempt;
  }
}

/// 内存版 [RoundDao]：轮次按 bookId 过滤、insert 分配递增 id、
/// delete 支持“仅本轮 / 后续全部”两种语义（与真实实现一致）。
class FakeRoundDao extends RoundDao {
  final List<Round> rounds = [];
  int _nextId = 1;

  @override
  Future<List<Round>> getRoundsByBook(int bookId) async =>
      List.of(rounds.where((r) => r.bookId == bookId));

  @override
  Future<int> insertRound(Round round) async {
    final created = Round(
      id: _nextId++,
      bookId: round.bookId,
      roundIndex: round.roundIndex,
      userInput: round.userInput,
      aiNarrative: round.aiNarrative,
      worldState: round.worldState,
      characterState: round.characterState,
      memorySummary: round.memorySummary,
      currentTime: round.currentTime,
      recommendedAction: round.recommendedAction,
      tokensIn: round.tokensIn,
      tokensOut: round.tokensOut,
      modelName: round.modelName,
      createdAt: round.createdAt,
      userImages: List.of(round.userImages),
      aiImages: List.of(round.aiImages),
    );
    rounds.add(created);
    return created.id!;
  }

  @override
  Future<int> updateRoundFields(
    int roundId,
    Map<String, Object?> fields,
  ) async {
    final index = rounds.indexWhere((r) => r.id == roundId);
    if (index < 0) return 0;
    final updated = Round(
      id: roundId,
      bookId: rounds[index].bookId,
      roundIndex: rounds[index].roundIndex,
      userInput: (fields['user_input'] as String?) ?? rounds[index].userInput,
      aiNarrative: (fields['ai_narrative'] as String?) ??
          rounds[index].aiNarrative,
      worldState: (fields['world_state'] as String?) ??
          rounds[index].worldState,
      characterState: (fields['character_state'] as String?) ??
          rounds[index].characterState,
      memorySummary: (fields['memory_summary'] as String?) ??
          rounds[index].memorySummary,
      currentTime: (fields['current_time'] as String?) ??
          rounds[index].currentTime,
      recommendedAction: rounds[index].recommendedAction,
      tokensIn: rounds[index].tokensIn,
      tokensOut: rounds[index].tokensOut,
      modelName: rounds[index].modelName,
      createdAt: rounds[index].createdAt,
      userImages: rounds[index].userImages,
      aiImages: rounds[index].aiImages,
    );
    rounds[index] = updated;
    return 1;
  }

  @override
  Future<void> deleteRound(int roundId, {bool deleteFollowing = false}) async {
    Round? target;
    for (final r in rounds) {
      if (r.id == roundId) {
        target = r;
        break;
      }
    }
    if (target == null) return;
    if (deleteFollowing) {
      rounds.removeWhere(
        (r) => r.bookId == target!.bookId && r.roundIndex >= target.roundIndex,
      );
    } else {
      rounds.removeWhere((r) => r.id == roundId);
    }
  }
}

/// 内存版 [WorldBookDao]：默认返回空条目。
class FakeWorldBookDao extends WorldBookDao {
  @override
  Future<List<WorldBookEntry>> getEntriesByBook(int bookId) async => [];
}

/// 可控流式 AI：测试驱动 [emit] / [emitReasoning] / [complete]，
/// 模拟逐 chunk 输出与生成结束；complete 后若已取消则抛
/// [AiCancelledException]（对应真实流式路径）。
class FakeStreamingAiService extends AiService {
  final Completer<void> _done = Completer<void>();
  void Function(AiStreamChunk chunk)? _onChunk;

  /// 向流式回调推送一个正文增量。
  void emit(String delta) => _onChunk?.call(AiStreamChunk(contentDelta: delta));

  /// 向流式回调推送一个思考增量。
  void emitReasoning(String delta) =>
      _onChunk?.call(AiStreamChunk(reasoningDelta: delta));

  /// 结束流式并返回完整结果。
  void complete() => _done.complete();

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    _onChunk = onChunk;
    onRequestBody?.call('{"model":"test","messages":[]}');
    await _done.future;
    if (isCancelled?.call() ?? false) {
      throw const AiCancelledException();
    }
    _onChunk?.call(const AiStreamChunk(done: true));
    return const AiCallResult(
      content: '## 剧情演绎\n流式生成的最终正文\n'
          '## 推荐行动\n\n'
          '## 当前时间\n第一天 午时\n'
          '## 世界状态\n\n'
          '## 角色状态\n\n'
          '## 记忆总结\n',
      promptTokens: 10,
      completionTokens: 20,
    );
  }
}

/// 可立即返回的 AI（成功 / 可切换失败），用于不依赖流式时序的用例。
class ToggleAiService extends AiService {
  bool fail = false;

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    onRequestBody?.call('{"model":"test","messages":[]}');
    if (fail) throw const AiException('模拟失败');
    return const AiCallResult(
      content: '## 剧情演绎\n成功正文\n'
          '## 推荐行动\n\n'
          '## 当前时间\n第一天 午时\n'
          '## 世界状态\n\n'
          '## 角色状态\n\n'
          '## 记忆总结\n',
      promptTokens: 1,
      completionTokens: 1,
    );
  }
}

/// 记录调用并可由测试手动触发点击的假通知后端。
class FakeNotificationBackend implements NotificationBackend {
  FakeNotificationBackend({this.notificationsEnabled, this.launchPayload});

  final List<({int id, String title, String body, String payload})> shown = [];
  final List<int> cancelled = [];
  final List<int> startedForeground = [];
  int stopForegroundCount = 0;
  void Function(int bookId)? onTap;

  /// 是否允许通知（null = 非 Android / 未知）。
  bool? notificationsEnabled;

  /// 冷启动点通知的 bookId（null = 非冷启动）。
  int? launchPayload;

  @override
  Future<void> init({required void Function(int bookId) onTap}) async {
    this.onTap = onTap;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    shown.add((id: id, title: title, body: body, payload: payload));
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);

  @override
  Future<int?> launchNotificationPayload() async => launchPayload;

  @override
  Future<bool?> areNotificationsEnabled() async => notificationsEnabled;

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Future<void> startForeground({
    required int id,
    required String title,
    required String body,
  }) async {
    startedForeground.add(id);
  }

  @override
  Future<void> stopForeground() async {
    stopForegroundCount++;
  }

  /// 模拟用户点击通知。
  void tap(int bookId) => onTap?.call(bookId);
}

/// 可控图片导入替身：按 [results] 顺序返回结果，并记录调用次数与参数。
class FakeImageImportService implements ImageImportService {
  FakeImageImportService({this.results = const []});

  /// 每次调用返回的结果（按序读取；耗尽后返回空结果）。不做突变，兼容只读列表。
  List<ImageImportResult> results;
  int calls = 0;
  int? lastSizeLimitMb;
  int _next = 0;

  @override
  Future<ImageImportResult> importImages({
    required int sizeLimitMb,
    void Function(int done, int total)? onProgress,
  }) async {
    calls++;
    lastSizeLimitMb = sizeLimitMb;
    if (_next >= results.length) return const ImageImportResult();
    return results[_next++];
  }
}
