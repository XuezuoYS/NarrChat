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

/// 合法 6 区块正文。
const _fullContent = '## 剧情演绎\n正文内容\n'
    '## 推荐行动\n\n'
    '## 当前时间\n第一天 午时\n'
    '## 世界状态\n\n'
    '## 角色状态\n\n'
    '## 记忆总结\n';

class _MockBookDao extends BookDao {
  _MockBookDao([this.books = const []]);
  final List<Book> books;
  FailedAttempt failed = const FailedAttempt();

  @override
  Future<List<Book>> getAllBooks() async => books;

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
  Future<int> updateRoundFields(int roundId, Map<String, Object?> fields) async =>
      1;

  @override
  Future<void> deleteRound(int roundId, {bool deleteFollowing = false}) async {}
}

class _MockWorldBookDao extends WorldBookDao {
  @override
  Future<List<WorldBookEntry>> getEntriesByBook(int bookId) async => [];
}

/// 单次流式会话：保存 onChunk / isCancelled，供测试逐块驱动与完成。
class _StreamSession {
  void Function(AiStreamChunk chunk)? onChunk;
  bool Function()? isCancelled;
  final Completer<AiCallResult> completer = Completer<AiCallResult>();
}

/// 可控流式 AI：每次 [chat] 生成一个独立会话，支持多本书并发生成各自驱动。
class _ConcurrentAiService extends AiService {
  final List<_StreamSession> sessions = [];

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) {
    final s = _StreamSession()
      ..onChunk = onChunk
      ..isCancelled = isCancelled;
    sessions.add(s);
    onRequestBody?.call('{"model":"test","messages":[]}');
    return s.completer.future;
  }
}

/// 轮询等待条件成立（纯异步测试，非 widget 测试）。
Future<void> _pumpUntil(bool Function() cond) async {
  for (var i = 0; i < 100 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  const bookA = Book(id: 1, title: '书A');
  const bookB = Book(id: 2, title: '书B');

  group('并发与跨轮隔离', () {
    test('停止后立即重发：旧流残留不注入新一轮（令牌守卫）', () async {
      final dao = _MockRoundDao();
      final bookDao = _MockBookDao();
      final ai = _ConcurrentAiService();
      final rp = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        retryDelay: Duration.zero,
      );
      await rp.loadRounds(1);

      // 第一轮流式开始并输出部分内容。
      final f1 = rp.sendRound(userInput: '第一轮', book: bookA);
      await _pumpUntil(() => ai.sessions.isNotEmpty);
      final s1 = ai.sessions.single;
      s1.onChunk?.call(const AiStreamChunk(contentDelta: 'AAAA'));
      expect(rp.streamingContent, 'AAAA');

      // 用户点击停止，随后第一轮调用结束（复位状态）。
      rp.cancelGeneration(bookId: 1);
      s1.completer.complete(
        const AiCallResult(
          content: _fullContent,
          promptTokens: 1,
          completionTokens: 1,
        ),
      );
      expect(await f1, isFalse);

      // 立刻重发第二轮。
      final f2 = rp.sendRound(userInput: '第二轮', book: bookA);
      await _pumpUntil(() => ai.sessions.length >= 2);
      final s2 = ai.sessions[1];
      s2.onChunk?.call(const AiStreamChunk(contentDelta: 'BBBB'));
      expect(rp.streamingContent, 'BBBB');

      // 旧流残留（第一轮的 onChunk 回调再次被触发）——令牌守卫应丢弃。
      s1.onChunk?.call(const AiStreamChunk(contentDelta: 'ZOMBIE'));
      s1.onChunk?.call(const AiStreamChunk(done: true));
      expect(
        rp.streamingContent,
        'BBBB',
        reason: '旧流残留不得注入新一轮',
      );
      // 旧流的取消闭包此时应为 true（令牌已过期）。
      expect(s1.isCancelled?.call(), isTrue);

      // 完成第二轮：成功落库。
      s2.completer.complete(
        const AiCallResult(
          content: _fullContent,
          promptTokens: 1,
          completionTokens: 1,
        ),
      );
      expect(await f2, isTrue);
      // 第一轮被取消未落库；第二轮以 roundIndex 1 落库（书 A 第零轮之后）。
      expect(
        dao.rounds.where(
          (r) => r.bookId == 1 && r.roundIndex == 1 && r.userInput == '第二轮',
        ),
        hasLength(1),
      );
    });

    test('书 A 生成中切到书 B：B 不泄漏 A 的流式，且可并发生成', () async {
      final dao = _MockRoundDao();
      final bookDao = _MockBookDao();
      final ai = _ConcurrentAiService();
      final rp = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        retryDelay: Duration.zero,
      );
      await rp.loadRounds(1);

      // 书 A 开始生成。
      final fA = rp.sendRound(userInput: 'A 的请求', book: bookA);
      await _pumpUntil(() => ai.sessions.isNotEmpty);
      final sA = ai.sessions.single;
      sA.onChunk?.call(const AiStreamChunk(contentDelta: 'AAA'));
      expect(rp.streamingContent, 'AAA');

      // 打开书 B：B 不应显示 A 的流式状态。
      await rp.loadRounds(2);
      expect(rp.isSending, isFalse, reason: '书 B 未生成，不应显示生成中');
      expect(rp.isStreaming, isFalse);
      expect(rp.streamingContent, isEmpty);
      expect(rp.pendingUserInput, isEmpty);
      expect(rp.activeGenerationBookIds, [1], reason: '书 A 仍在生成');

      // 书 B 可并发生成（不被书 A 的 isSending 阻塞）。
      final fB = rp.sendRound(userInput: 'B 的请求', book: bookB);
      await _pumpUntil(() => ai.sessions.length >= 2);
      final sB = ai.sessions[1];
      sB.onChunk?.call(const AiStreamChunk(contentDelta: 'BBB'));
      expect(rp.streamingContent, 'BBB');
      expect(rp.activeGenerationBookIds, containsAll([1, 2]));

      // 切回书 A：A 的流式内容仍独立保留，未受 B 影响。
      await rp.loadRounds(1);
      expect(rp.streamingContent, 'AAA');

      // 完成书 A：轮次落入书 A。
      sA.completer.complete(
        const AiCallResult(
          content: _fullContent,
          promptTokens: 1,
          completionTokens: 1,
        ),
      );
      expect(await fA, isTrue);
      expect(dao.rounds.where((r) => r.bookId == 1 && r.roundIndex == 1),
          hasLength(1));

      // 完成书 B：轮次落入书 B。
      await rp.loadRounds(2);
      sB.completer.complete(
        const AiCallResult(
          content: _fullContent,
          promptTokens: 1,
          completionTokens: 1,
        ),
      );
      expect(await fB, isTrue);
      expect(dao.rounds.where((r) => r.bookId == 2 && r.roundIndex == 1),
          hasLength(1));
    });

    test('书 A 生成完成时若已切到书 B：不把当前查看书改回 A', () async {
      final dao = _MockRoundDao();
      final bookDao = _MockBookDao();
      final ai = _ConcurrentAiService();
      final rp = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        retryDelay: Duration.zero,
      );
      await rp.loadRounds(1);

      // 书 A 开始生成。
      final fA = rp.sendRound(userInput: 'A 的请求', book: bookA);
      await _pumpUntil(() => ai.sessions.isNotEmpty);
      final sA = ai.sessions.single;

      // 切到书 B（此时书 B 仅有自动创建的第零轮）。
      await rp.loadRounds(2);
      expect(rp.rounds.where((r) => r.roundIndex == 0), hasLength(1));

      // 书 A 完成。
      sA.completer.complete(
        const AiCallResult(
          content: _fullContent,
          promptTokens: 1,
          completionTokens: 1,
        ),
      );
      expect(await fA, isTrue);

      // 书 A 的轮次已落库（第零轮 + 本轮）；但当前查看仍是书 B（未被 A 覆盖）。
      expect(dao.rounds.where((r) => r.bookId == 1 && r.roundIndex == 1),
          hasLength(1));
      expect(rp.rounds, hasLength(1), reason: '仍为书 B 的第零轮');
      expect(rp.rounds.single.roundIndex, 0);

      // 切回书 A 可见新轮次。
      await rp.loadRounds(1);
      expect(rp.rounds.where((r) => r.roundIndex == 1), hasLength(1));
    });
  });

  group('跨书进程提示栏', () {
    Future<void> pumpChat(
      WidgetTester tester, {
      required BookProvider bookProvider,
      required RoundProvider roundProvider,
      required WorldBookProvider worldBookProvider,
    }) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AiSettingsProvider()),
            ChangeNotifierProvider(create: (_) => bookProvider),
            ChangeNotifierProvider(create: (_) => worldBookProvider),
            ChangeNotifierProvider(create: (_) => roundProvider),
            ChangeNotifierProvider(create: (_) => SidebarProvider()),
          ],
          child: MaterialApp(
            theme: NarrChatTheme.light,
            home: Scaffold(body: const ChatScreen()),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('其他书生成中：顶部横幅显示，点击跳转到该书', (tester) async {
      final bookDao = _MockBookDao([bookA, bookB]);
      final dao = _MockRoundDao();
      final ai = _ConcurrentAiService();
      final bookProvider = BookProvider(dao: bookDao);
      await bookProvider.loadBooks(); // 默认选中第一本（书A）
      bookProvider.selectBook(bookB); // 当前查看书 B

      final roundProvider = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        retryDelay: Duration.zero,
      );
      await roundProvider.loadRounds(2);
      final worldBookProvider = WorldBookProvider(dao: _MockWorldBookDao());

      await pumpChat(
        tester,
        bookProvider: bookProvider,
        roundProvider: roundProvider,
        worldBookProvider: worldBookProvider,
      );

      // 无其他书生成时：无横幅。
      expect(find.text('《书A》正在生成中'), findsNothing);

      // 书 A 开始生成（保持挂起）。
      final fA = roundProvider.sendRound(userInput: '书A请求', book: bookA);
      await tester.pump();

      // 横幅出现：显示书 A 生成中，当前书 B 自身不显示。
      expect(find.text('《书A》正在生成中'), findsOneWidget);
      expect(find.text('《书B》正在生成中'), findsNothing);

      // 点击横幅 → 跳转到书 A 对话页。
      await tester.tap(find.text('《书A》正在生成中'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 新页面 AppBar 标题为书 A。
      expect(find.text('书A'), findsWidgets);

      // 收尾：完成书 A 生成，避免悬空。
      for (var i = 0; i < 20 && ai.sessions.isEmpty; i++) {
        await tester.pump();
      }
      ai.sessions.first.completer.complete(
        const AiCallResult(
          content: _fullContent,
          promptTokens: 1,
          completionTokens: 1,
        ),
      );
      await tester.pump();
      await fA;
    });
  });
}
