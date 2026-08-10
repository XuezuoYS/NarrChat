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
import 'package:provider/provider.dart';

/// 内存版 DAO，避免测试依赖 sqflite。
class _MockBookDao extends BookDao {
  final List<Book> books;
  _MockBookDao(this.books);
  @override
  Future<List<Book>> getAllBooks() async => books;
  FailedAttempt _failed = const FailedAttempt();
  @override
  Future<FailedAttempt> getFailedAttempt(int bookId) async => _failed;
  @override
  Future<void> setFailedAttempt(int bookId, FailedAttempt attempt) async {
    _failed = attempt;
  }
}

class _MockRoundDao extends RoundDao {
  final List<Round> _rounds = [];
  int _nextId = 1;
  @override
  Future<List<Round>> getRoundsByBook(int bookId) async =>
      List.of(_rounds.where((r) => r.bookId == bookId));
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
    _rounds.add(created);
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

/// 可控流式 AI：测试驱动 [emit]/[complete]，模拟逐 chunk 输出。
class _FakeStreamingAiService extends AiService {
  final Completer<void> _done = Completer<void>();
  void Function(AiStreamChunk chunk)? _onChunk;

  /// 向流式回调推送一个内容增量。
  void emit(String delta) => _onChunk?.call(AiStreamChunk(contentDelta: delta));

  /// 结束流式并返回完整结果。
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
    await _done.future;
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

void main() {
  const book = Book(id: 1, title: '测试书');

  /// 对话消息列表最外层（ListView 自带）的滚动状态。
  ScrollableState chatScrollable(WidgetTester tester) {
    return tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }

  /// 对话消息列表的滚动偏移。
  double chatOffset(WidgetTester tester) => chatScrollable(tester).position.pixels;

  /// 对话消息列表的最大滚动偏移。
  double chatMax(WidgetTester tester) =>
      chatScrollable(tester).position.maxScrollExtent;

  /// 预置足够多轮次，使对话列表可滚动（内容远超视口高度）。
  Future<void> seedRounds(_MockRoundDao dao) async {
    for (var i = 1; i <= 6; i++) {
      await dao.insertRound(
        Round(
          bookId: 1,
          roundIndex: i,
          userInput: '第 $i 轮的用户输入',
          aiNarrative: '第 $i 轮的剧情正文。' * 40,
          currentTime: '第一天 午时',
          createdAt: DateTime.now(),
        ),
      );
    }
  }

  Future<RoundProvider> pumpChat(
    WidgetTester tester,
    _FakeStreamingAiService ai,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dao = _MockRoundDao();
    await seedRounds(dao);
    final bookDao = _MockBookDao([book]);
    final roundProvider = RoundProvider(dao: dao, aiService: ai, bookDao: bookDao);
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

  /// 用慢速手势把对话列表滚动到底部（无惯性甩动，便于确定性断言）。
  Future<void> scrollChatToBottom(WidgetTester tester) async {
    final start = tester.getCenter(find.byType(ListView));
    final gesture = await tester.startGesture(start);
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, -300));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 结束流式并等待 sendRound 完成（期间 isSending 为 true 时发送按钮
  /// 有无限转圈动画，不能用 pumpAndSettle，须等 isSending 变 false）。
  Future<void> finishStream(
    WidgetTester tester,
    _FakeStreamingAiService ai,
    RoundProvider provider,
    Future<bool> sendFuture,
  ) async {
    ai.complete();
    for (var i = 0; i < 20 && provider.isSending; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(await sendFuture, isTrue);
  }

  testWidgets('流式输出时触屏按住上滑，不会被自动滚动拉回底部', (tester) async {
    final ai = _FakeStreamingAiService();
    final roundProvider = await pumpChat(tester, ai);

    // 滚动到底部。
    await scrollChatToBottom(tester);
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    // 开始流式生成并推送首个增量（自动跟随已接管）。
    final sendFuture =
        roundProvider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emit('第一段内容');
    await tester.pump();
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    // 用户触屏按住并向上滑动（内容向下移动、offset 减小），手指不松开。
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    final posAfterDrag = chatOffset(tester);
    // 已离开底部（但仍在 80px 阈值内——旧实现正是此处被拉回）。
    expect(posAfterDrag, lessThan(chatMax(tester)));

    // 流式继续输出新内容（触发 rebuild）：手指按住期间不得被拉回底部。
    ai.emit('第二段内容');
    await tester.pump();
    expect(chatOffset(tester), closeTo(posAfterDrag, 1));

    // 松手，结束流式。
    await gesture.up();
    await tester.pump();
    await finishStream(tester, ai, roundProvider, sendFuture);
  });

  testWidgets('上翻暂停自动跟随，回到底部后恢复跟随', (tester) async {
    final ai = _FakeStreamingAiService();
    final roundProvider = await pumpChat(tester, ai);

    await scrollChatToBottom(tester);
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    final sendFuture =
        roundProvider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emit('第一段内容');
    await tester.pump();

    // 用户上翻一段距离后松手：之后流式内容不得再把它拉回底部。
    final up = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await up.moveBy(const Offset(0, 150));
    await tester.pump();
    await up.moveBy(const Offset(0, 300));
    await tester.pump();
    await up.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final posAway = chatOffset(tester);
    expect(posAway, lessThan(chatMax(tester) - 100));

    ai.emit('上翻后的内容');
    await tester.pump();
    expect(chatOffset(tester), closeTo(posAway, 1));

    // 用户拖回到底部并松手 → 自动跟随恢复。
    await scrollChatToBottom(tester);
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    ai.emit('回到底部后的内容');
    await tester.pump();
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    await finishStream(tester, ai, roundProvider, sendFuture);
  });
}
