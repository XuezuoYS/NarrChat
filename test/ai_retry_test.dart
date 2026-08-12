import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/world_book_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/failed_attempt.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// 内存版 BookDao，避免测试依赖 sqflite。
class _MockBookDao extends BookDao {
  FailedAttempt failed = const FailedAttempt();

  @override
  Future<Map<int, DateTime>> getLastRoundTimes() async => {};

  @override
  Future<FailedAttempt> getFailedAttempt(int bookId) async => failed;

  @override
  Future<void> setFailedAttempt(int bookId, FailedAttempt attempt) async {
    failed = attempt;
  }
}

class _MockRoundDao extends RoundDao {
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
      createdAt: round.createdAt,
    );
    rounds.add(created);
    return created.id!;
  }

  @override
  Future<int> updateRoundFields(
    int roundId,
    Map<String, Object?> fields,
  ) async => 1;

  @override
  Future<void> deleteRound(
    int roundId, {
    bool deleteFollowing = false,
  }) async {}
}

class _MockWorldBookDao extends WorldBookDao {
  @override
  Future<List<WorldBookEntry>> getEntriesByBook(int bookId) async => [];
}

/// 可控失败次数的 AI：前 [failTimes] 次抛 [failKind] 类异常，之后成功。
/// [gate] 非空时，成功那次调用前等待（便于观察中间重试状态）。
class _RetryAiService extends AiService {
  _RetryAiService({
    required this.failTimes,
    this.failKind = AiExceptionKind.network,
    this.gate,
  });

  final int failTimes;
  final AiExceptionKind failKind;
  final Completer<void>? gate;
  int calls = 0;

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
    calls++;
    if (calls <= failTimes) {
      throw AiException('模拟失败：${failKind.name}', kind: failKind);
    }
    if (gate != null) await gate!.future;
    onChunk?.call(const AiStreamChunk(done: true));
    return const AiCallResult(
      content: '## 剧情演绎\n重试成功正文\n'
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

/// 首次调用先输出部分内容再抛网络异常，之后成功（模拟流式中途断连）。
class _StreamFailThenOkAiService extends AiService {
  int calls = 0;

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
    calls++;
    if (calls == 1) {
      // 第 1 次：先输出部分内容再断连。
      onChunk?.call(const AiStreamChunk(contentDelta: '半截正文'));
      throw const AiException(
        '网络请求失败：模拟断连',
        kind: AiExceptionKind.network,
      );
    }
    onChunk?.call(const AiStreamChunk(done: true));
    return const AiCallResult(
      content: '## 剧情演绎\n完整正文\n'
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

void main() {
  const book = Book(id: 1, title: '测试书');

  Future<RoundProvider> pumpChat(
    WidgetTester tester,
    AiService ai,
    _MockBookDao bookDao,
    _MockRoundDao dao, {
    Duration retryDelay = const Duration(milliseconds: 100),
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final roundProvider = RoundProvider(
      dao: dao,
      aiService: ai,
      bookDao: bookDao,
      retryDelay: retryDelay,
    );
    await roundProvider.loadRounds(1);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AiSettingsProvider()),
          ChangeNotifierProvider(
            create: (_) => BookProvider(dao: bookDao)..loadBooks(),
          ),
          ChangeNotifierProvider(
            create: (_) => WorldBookProvider(dao: _MockWorldBookDao()),
          ),
          ChangeNotifierProvider(create: (_) => roundProvider),
          ChangeNotifierProvider(create: (_) => SidebarProvider()),
        ],
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: Scaffold(body: const ChatScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return roundProvider;
  }

  /// 等待 sendRound 结束（isSending 期间发送按钮有无限转圈动画，
  /// 不能用 pumpAndSettle，须等 isSending 变 false 后再 settle）。
  Future<void> waitSendDone(
    WidgetTester tester,
    RoundProvider provider,
  ) async {
    for (var i = 0; i < 20 && provider.isSending; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('网络类失败自动重试：灰字「错误重连（x/3）」并最终成功', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final gate = Completer<void>();
    final ai = _RetryAiService(failTimes: 2, gate: gate);
    final roundProvider = await pumpChat(tester, ai, bookDao, dao);

    final sendFuture = roundProvider.sendRound(userInput: '触发重试', book: book);
    await tester.pump();
    // 第 1 次调用失败 → 进入 1/3 重试（灰字显示在流式气泡内）。
    expect(roundProvider.retryStatus, (1, 3));
    expect(find.text('错误重连……（1/3）'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    // 第 2 次调用失败 → 2/3。
    expect(roundProvider.retryStatus, (2, 3));
    expect(find.text('错误重连……（2/3）'), findsOneWidget);
    expect(find.text('错误重连……（1/3）'), findsNothing);

    await tester.pump(const Duration(milliseconds: 100));
    // 第 3 次调用成功但被 gate 挂起：仍显示 2/3（尚未产出内容）。
    expect(ai.calls, 3);
    expect(roundProvider.retryStatus, (2, 3));

    gate.complete();
    await waitSendDone(tester, roundProvider);

    // 成功：重试提示消失、正文入库、无失败条目。
    expect(await sendFuture, isTrue);
    expect(roundProvider.retryStatus, isNull);
    expect(find.textContaining('错误重连'), findsNothing);
    expect(find.textContaining('重试成功正文'), findsOneWidget);
    expect(bookDao.failed.isEmpty, isTrue);
    expect(ai.calls, 3);
  });

  testWidgets('网络类失败重试 3 次后仍失败：进入「生成失败」红框', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final ai = _RetryAiService(failTimes: 999); // 永远失败
    final roundProvider = await pumpChat(
      tester,
      ai,
      bookDao,
      dao,
      retryDelay: Duration.zero,
    );

    final sendFuture = roundProvider.sendRound(userInput: '触发失败', book: book);
    await waitSendDone(tester, roundProvider);

    expect(await sendFuture, isFalse);
    // 初始 1 次 + 重试 3 次 = 4 次调用。
    expect(ai.calls, 4);
    expect(roundProvider.retryStatus, isNull);
    // 失败条目保留用户输入与原因。
    expect(bookDao.failed.userInput, '触发失败');
    expect(bookDao.failed.errorMessage, contains('模拟失败'));
    // UI：红框 + 无灰字重试文本残留。
    expect(find.text('生成失败'), findsOneWidget);
    expect(find.textContaining('错误重连'), findsNothing);
  });

  testWidgets('API 业务类失败不自动重试', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final ai = _RetryAiService(
      failTimes: 999,
      failKind: AiExceptionKind.api,
    );
    final roundProvider = await pumpChat(
      tester,
      ai,
      bookDao,
      dao,
      retryDelay: Duration.zero,
    );

    final sendFuture = roundProvider.sendRound(userInput: '触发失败', book: book);
    await waitSendDone(tester, roundProvider);

    expect(await sendFuture, isFalse);
    // 仅 1 次调用，不重试。
    expect(ai.calls, 1);
    expect(roundProvider.retryStatus, isNull);
    expect(find.text('生成失败'), findsOneWidget);
  });

  testWidgets('流式中途断连：重置半截正文并重试成功', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final ai = _StreamFailThenOkAiService();
    final roundProvider = await pumpChat(tester, ai, bookDao, dao);

    final sendFuture = roundProvider.sendRound(userInput: '触发断连', book: book);
    await tester.pump();
    // 第 1 次调用输出半截正文后断连：半截内容已被重置，进入 1/3 重试。
    expect(roundProvider.streamingContent, isEmpty);
    expect(roundProvider.retryStatus, (1, 3));
    expect(find.text('错误重连……（1/3）'), findsOneWidget);
    expect(find.textContaining('半截正文'), findsNothing);

    await tester.pump(const Duration(milliseconds: 100));
    // 第 2 次调用成功：重试提示消失、正文入库。
    await waitSendDone(tester, roundProvider);
    expect(await sendFuture, isTrue);
    expect(roundProvider.retryStatus, isNull);
    expect(find.textContaining('错误重连'), findsNothing);
    expect(find.textContaining('完整正文'), findsOneWidget);
    expect(ai.calls, 2);
  });
}
