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
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/debug_prompt_dialog.dart';
import 'package:provider/provider.dart';

/// 内存版 DAO，避免测试依赖 sqflite。
class _MockBookDao extends BookDao {
  FailedAttempt failed = const FailedAttempt();

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
  Future<int> updateRoundFields(int roundId, Map<String, Object?> fields) async => 1;

  @override
  Future<void> deleteRound(int roundId, {bool deleteFollowing = false}) async {}
}

class _MockWorldBookDao extends WorldBookDao {
  @override
  Future<List<WorldBookEntry>> getEntriesByBook(int bookId) async => [];
}

/// 可控流式 AI：complete 后若已取消则抛 [AiCancelledException]
/// （对应真实流式路径：流循环检测到中断后抛出异常）。
class _FakeStreamingAiService extends AiService {
  final Completer<void> _done = Completer<void>();
  void Function(AiStreamChunk chunk)? _onChunk;

  void emit(String delta) => _onChunk?.call(AiStreamChunk(contentDelta: delta));
  void emitReasoning(String delta) =>
      _onChunk?.call(AiStreamChunk(reasoningDelta: delta));
  void complete() => _done.complete();

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required String systemPrompt,
    required String userPrompt,
    List<Map<String, String>> historyMessages = const [],
    String? model,
    double temperature = 1.0,
    bool thinking = false,
    String reasoningEffort = 'high',
    int? maxTokens,
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
class _ToggleAiService extends AiService {
  bool fail = false;

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required String systemPrompt,
    required String userPrompt,
    List<Map<String, String>> historyMessages = const [],
    String? model,
    double temperature = 1.0,
    bool thinking = false,
    String reasoningEffort = 'high',
    int? maxTokens,
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

void main() {
  const book = Book(id: 1, title: '测试书');

  Future<RoundProvider> pumpChat(
    WidgetTester tester,
    AiService ai,
    _MockBookDao bookDao,
    _MockRoundDao dao,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final roundProvider = RoundProvider(
      dao: dao,
      aiService: ai,
      bookDao: bookDao,
    );
    await roundProvider.loadRounds(1);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
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

  testWidgets('请求失败：保留用户输入并显示红色「生成失败」气泡（无消息提示）', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final roundProvider =
        await pumpChat(tester, _ToggleAiService()..fail = true, bookDao, dao);

    final sendFuture = roundProvider.sendRound(userInput: '触发失败', book: book);
    await waitSendDone(tester, roundProvider);

    expect(await sendFuture, isFalse);
    // 失败条目落库：用户输入 + 失败原因；rounds 表无新增轮次。
    expect(bookDao.failed.userInput, '触发失败');
    expect(bookDao.failed.errorMessage, contains('模拟失败'));
    expect(bookDao.failed.isTruncated, isFalse);
    expect(dao.rounds.where((r) => r.roundIndex > 0), isEmpty);
    // UI：用户输入气泡 + 红框标题 + 失败原因。
    expect(find.text('触发失败'), findsOneWidget);
    expect(find.text('生成失败'), findsOneWidget);
    expect(find.text('模拟失败'), findsOneWidget);
    // 无 SnackBar 消息提示。
    expect(find.textContaining('请求失败：'), findsNothing);
  });

  testWidgets('停止生成：保留用户输入并显示红色「已截断」', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final ai = _FakeStreamingAiService();
    final roundProvider = await pumpChat(tester, ai, bookDao, dao);

    final sendFuture = roundProvider.sendRound(userInput: '请继续剧情', book: book);
    await tester.pump();
    ai.emit('部分剧情内容');
    await tester.pump();

    roundProvider.cancelGeneration();
    ai.complete();
    await waitSendDone(tester, roundProvider);

    expect(await sendFuture, isFalse);
    // 失败条目：用户输入 + 空错误信息（=已截断）。
    expect(bookDao.failed.userInput, '请继续剧情');
    expect(bookDao.failed.errorMessage, isEmpty);
    expect(bookDao.failed.isTruncated, isTrue);
    // UI：用户输入气泡 + 「已截断」红框（无「生成失败」）。
    expect(find.text('请继续剧情'), findsOneWidget);
    expect(find.text('已截断'), findsOneWidget);
    expect(find.text('生成失败'), findsNothing);
  });

  testWidgets('失败后发送新消息：清空失败条目并正常生成', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final ai = _ToggleAiService();
    final roundProvider = await pumpChat(tester, ai, bookDao, dao);

    // 第一次请求失败。
    ai.fail = true;
    var f = roundProvider.sendRound(userInput: '失败的输入', book: book);
    await waitSendDone(tester, roundProvider);
    expect(await f, isFalse);
    expect(find.text('生成失败'), findsOneWidget);

    // 发送新消息（不再失败）。
    ai.fail = false;
    f = roundProvider.sendRound(userInput: '新的输入', book: book);
    await waitSendDone(tester, roundProvider);
    expect(await f, isTrue);

    // 失败条目已清空，红框消失；新轮正常落库（编号 1）。
    expect(bookDao.failed.isEmpty, isTrue);
    expect(find.text('生成失败'), findsNothing);
    expect(find.text('新的输入'), findsOneWidget);
    expect(find.textContaining('成功正文'), findsOneWidget);
    final chat = dao.rounds.where((r) => r.roundIndex > 0).toList();
    expect(chat, hasLength(1));
    expect(chat.single.roundIndex, 1);
    expect(chat.single.aiNarrative, contains('成功正文'));
  });

  testWidgets('正常完成生成：无失败条目、无红框', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final roundProvider =
        await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    final sendFuture = roundProvider.sendRound(userInput: '正常剧情', book: book);
    await waitSendDone(tester, roundProvider);

    expect(await sendFuture, isTrue);
    expect(bookDao.failed.isEmpty, isTrue);
    expect(find.text('已截断'), findsNothing);
    expect(find.text('生成失败'), findsNothing);
  });

  testWidgets('成功轮次：最新 AI 气泡可打开调试对话框', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final roundProvider =
        await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    final sendFuture = roundProvider.sendRound(userInput: '正常剧情', book: book);
    await waitSendDone(tester, roundProvider);
    expect(await sendFuture, isTrue);

    // 最新 AI 气泡提供「调试」入口并展示本轮请求。
    expect(find.text('调试'), findsOneWidget);
    await tester.tap(find.text('调试'));
    await tester.pumpAndSettle();
    expect(find.byType(DebugPromptDialog), findsOneWidget);
    expect(find.textContaining('model'), findsWidgets);
  });

  testWidgets('失败条目：提供调试入口并展示实际发出的请求', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final roundProvider =
        await pumpChat(tester, _ToggleAiService()..fail = true, bookDao, dao);

    final sendFuture = roundProvider.sendRound(userInput: '触发失败', book: book);
    await waitSendDone(tester, roundProvider);
    expect(await sendFuture, isFalse);
    expect(bookDao.failed.errorMessage, isNotEmpty);

    // 失败条目底部提供「调试」入口，打开后展示实际发出的请求。
    expect(find.text('调试'), findsOneWidget);
    await tester.tap(find.text('调试'));
    await tester.pumpAndSettle();
    expect(find.byType(DebugPromptDialog), findsOneWidget);
    expect(find.textContaining('model'), findsWidgets);
  });

  testWidgets('流式截断：调试中保留截断前的部分输出与思考', (tester) async {
    final bookDao = _MockBookDao();
    final dao = _MockRoundDao();
    final ai = _FakeStreamingAiService();
    final roundProvider = await pumpChat(tester, ai, bookDao, dao);

    final sendFuture = roundProvider.sendRound(userInput: '请继续剧情', book: book);
    await tester.pump();
    // 先累积部分思考与正文，再停止生成。
    ai.emitReasoning('思考片段内容');
    ai.emit('部分剧情内容');
    await tester.pump();
    roundProvider.cancelGeneration();
    ai.complete();
    await waitSendDone(tester, roundProvider);
    expect(await sendFuture, isFalse);
    expect(bookDao.failed.isTruncated, isTrue);

    // 失败条目调试入口：截断前的部分内容被临时保存可供查看。
    expect(find.text('调试'), findsOneWidget);
    await tester.tap(find.text('调试'));
    await tester.pumpAndSettle();
    expect(find.byType(DebugPromptDialog), findsOneWidget);

    // 「AI 原始返回」Tab 展示截断前的部分正文。
    await tester.tap(find.text('AI 原始返回'));
    await tester.pumpAndSettle();
    expect(find.textContaining('部分剧情内容'), findsOneWidget);

    // 「思考内容」Tab 展示截断前的部分思考。
    await tester.tap(find.text('思考内容'));
    await tester.pumpAndSettle();
    expect(find.textContaining('思考片段内容'), findsOneWidget);
  });
}
