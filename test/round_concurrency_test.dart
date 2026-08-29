import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/notification_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/screens/home_screen.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

/// 合法 6 区块正文。
const _fullContent = '## 剧情演绎\n正文内容\n'
    '## 推荐行动\n\n'
    '## 当前时间\n第一天 午时\n'
    '## 世界状态\n\n'
    '## 角色状态\n\n'
    '## 记忆总结\n';

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
  const bookA = Book(uuid: 'b1', title: '书A');
  const bookB = Book(uuid: 'b2', title: '书B');

  group('并发与跨轮隔离', () {
    test('停止后立即重发：旧流残留不注入新一轮（令牌守卫）', () async {
      final dao = FakeRoundDao();
      final bookDao = FakeBookDao();
      final ai = _ConcurrentAiService();
      final rp = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        retryDelay: Duration.zero,
      );
      await rp.loadRounds('b1');

      // 第一轮流式开始并输出部分内容。
      final f1 = rp.sendRound(userInput: '第一轮', book: bookA);
      await _pumpUntil(() => ai.sessions.isNotEmpty);
      final s1 = ai.sessions.single;
      s1.onChunk?.call(const AiStreamChunk(contentDelta: 'AAAA'));
      expect(rp.streamingContent, 'AAAA');

      // 用户点击停止，随后第一轮调用结束（复位状态）。
      rp.cancelGeneration(bookUuid: 'b1');
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
          (r) =>
              r.bookUuid == 'b1' &&
              r.roundIndex == 1 &&
              r.userInput == '第二轮',
        ),
        hasLength(1),
      );
    });

    test('书 A 生成中切到书 B：B 不泄漏 A 的流式，且可并发生成', () async {
      final dao = FakeRoundDao();
      final bookDao = FakeBookDao();
      final ai = _ConcurrentAiService();
      final rp = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        retryDelay: Duration.zero,
      );
      await rp.loadRounds('b1');

      // 书 A 开始生成。
      final fA = rp.sendRound(userInput: 'A 的请求', book: bookA);
      await _pumpUntil(() => ai.sessions.isNotEmpty);
      final sA = ai.sessions.single;
      sA.onChunk?.call(const AiStreamChunk(contentDelta: 'AAA'));
      expect(rp.streamingContent, 'AAA');

      // 打开书 B：B 不应显示 A 的流式状态。
      await rp.loadRounds('b2');
      expect(rp.isSending, isFalse, reason: '书 B 未生成，不应显示生成中');
      expect(rp.isStreaming, isFalse);
      expect(rp.streamingContent, isEmpty);
      expect(rp.pendingUserInput, isEmpty);
      expect(rp.activeGenerationBookUuids, ['b1'], reason: '书 A 仍在生成');

      // 书 B 可并发生成（不被书 A 的 isSending 阻塞）。
      final fB = rp.sendRound(userInput: 'B 的请求', book: bookB);
      await _pumpUntil(() => ai.sessions.length >= 2);
      final sB = ai.sessions[1];
      sB.onChunk?.call(const AiStreamChunk(contentDelta: 'BBB'));
      expect(rp.streamingContent, 'BBB');
      expect(rp.activeGenerationBookUuids, containsAll(['b1', 'b2']));

      // 切回书 A：A 的流式内容仍独立保留，未受 B 影响。
      await rp.loadRounds('b1');
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
      expect(dao.rounds.where((r) => r.bookUuid == 'b1' && r.roundIndex == 1),
          hasLength(1));

      // 完成书 B：轮次落入书 B。
      await rp.loadRounds('b2');
      sB.completer.complete(
        const AiCallResult(
          content: _fullContent,
          promptTokens: 1,
          completionTokens: 1,
        ),
      );
      expect(await fB, isTrue);
      expect(dao.rounds.where((r) => r.bookUuid == 'b2' && r.roundIndex == 1),
          hasLength(1));
    });

    test('书 A 生成完成时若已切到书 B：不把当前查看书改回 A', () async {
      final dao = FakeRoundDao();
      final bookDao = FakeBookDao();
      final ai = _ConcurrentAiService();
      final rp = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        retryDelay: Duration.zero,
      );
      await rp.loadRounds('b1');

      // 书 A 开始生成。
      final fA = rp.sendRound(userInput: 'A 的请求', book: bookA);
      await _pumpUntil(() => ai.sessions.isNotEmpty);
      final sA = ai.sessions.single;

      // 切到书 B（此时书 B 仅有自动创建的第零轮）。
      await rp.loadRounds('b2');
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
      expect(dao.rounds.where((r) => r.bookUuid == 'b1' && r.roundIndex == 1),
          hasLength(1));
      expect(rp.rounds, hasLength(1), reason: '仍为书 B 的第零轮');
      expect(rp.rounds.single.roundIndex, 0);

      // 切回书 A 可见新轮次。
      await rp.loadRounds('b1');
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
            // 云同步：ChatScreen 进入书籍时触发自动同步（未配置时忽略）。
            ChangeNotifierProvider(create: (_) => CloudSyncProvider()),
          ],
          child: MaterialApp(
            theme: NarrChatTheme.light,
            home: Scaffold(body: const ChatScreen()),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('其他书生成中：顶部显示计数横幅，点击弹窗后进入该书', (tester) async {
      final bookDao = FakeBookDao(books: [bookA, bookB]);
      final dao = FakeRoundDao();
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
      await roundProvider.loadRounds('b2');
      final worldBookProvider = WorldBookProvider(dao: FakeWorldBookDao());

      await pumpChat(
        tester,
        bookProvider: bookProvider,
        roundProvider: roundProvider,
        worldBookProvider: worldBookProvider,
      );

      // 无其他书生成时：无横幅。
      expect(find.text('1本书正在生成……'), findsNothing);

      // 书 A 开始生成（保持挂起）。
      final fA = roundProvider.sendRound(userInput: '书A请求', book: bookA);
      await tester.pump();

      // 横幅出现：显示计数（当前书 B 自身不计入）。
      expect(find.text('1本书正在生成……'), findsOneWidget);

      // 点击横幅 → 弹出「正在生成的书」对话框。
      await tester.tap(find.text('1本书正在生成……'));
      await tester.pump();
      expect(find.text('正在生成的书'), findsOneWidget);
      expect(find.text('书A'), findsOneWidget);

      // 点击对话框中的书 A → 跳转到书 A 对话页。
      await tester.tap(find.text('书A'));
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

    testWidgets('多本书生成：横幅计数，弹窗列出全部并可选跳转', (tester) async {
      const bookC = Book(uuid: 'b3', title: '书C');
      final bookDao = FakeBookDao(books: [bookA, bookB, bookC]);
      final dao = FakeRoundDao();
      final ai = _ConcurrentAiService();
      final bookProvider = BookProvider(dao: bookDao);
      await bookProvider.loadBooks(); // 默认选中书A
      bookProvider.selectBook(bookB); // 当前查看书 B

      final roundProvider = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        retryDelay: Duration.zero,
      );
      await roundProvider.loadRounds('b2');
      final worldBookProvider = WorldBookProvider(dao: FakeWorldBookDao());

      await pumpChat(
        tester,
        bookProvider: bookProvider,
        roundProvider: roundProvider,
        worldBookProvider: worldBookProvider,
      );

      // 书 A 与书 C 同时生成。
      final fA = roundProvider.sendRound(userInput: '书A请求', book: bookA);
      final fC = roundProvider.sendRound(userInput: '书C请求', book: bookC);
      await tester.pump();

      // 横幅显示 2 本书（当前书 B 不计入）。
      expect(find.text('2本书正在生成……'), findsOneWidget);

      // 点击横幅 → 弹窗列出书 A 与书 C。
      await tester.tap(find.text('2本书正在生成……'));
      await tester.pump();
      expect(find.text('正在生成的书'), findsOneWidget);
      expect(find.text('书A'), findsOneWidget);
      expect(find.text('书C'), findsOneWidget);

      // 点击书 C → 跳转到书 C。
      await tester.tap(find.text('书C'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('书C'), findsWidgets);

      // 收尾：完成两本书生成。
      for (var i = 0; i < 20 && ai.sessions.length < 2; i++) {
        await tester.pump();
      }
      for (final s in ai.sessions) {
        s.completer.complete(
          const AiCallResult(
            content: _fullContent,
            promptTokens: 1,
            completionTokens: 1,
          ),
        );
      }
      await tester.pump();
      await fA;
      await fC;
    });

    testWidgets('首页（书籍列表）也展示生成横幅并可进入对应书', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final bookDao = FakeBookDao(books: [bookA, bookB]);
      final dao = FakeRoundDao();
      final ai = _ConcurrentAiService();
      final bookProvider = BookProvider(dao: bookDao);
      await bookProvider.loadBooks();
      final roundProvider = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        retryDelay: Duration.zero,
      );
      final worldBookProvider = WorldBookProvider(dao: FakeWorldBookDao());

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AiSettingsProvider()),
            ChangeNotifierProvider(create: (_) => bookProvider),
            ChangeNotifierProvider(create: (_) => worldBookProvider),
            ChangeNotifierProvider(create: (_) => roundProvider),
            ChangeNotifierProvider(
              create: (_) => NotificationSettingsProvider(
                service: GenerationNotificationService(
                  bookProvider: bookProvider,
                  attentionBackend: FakeTaskbarAttentionBackend(),
                ),
              ),
            ),
            ChangeNotifierProvider(create: (_) => SidebarProvider()),
            // 云同步（SyncStatusChip 需读取其 syncState）。
            ChangeNotifierProvider(create: (_) => CloudSyncProvider()),
          ],
          child: MaterialApp(
            theme: NarrChatTheme.light,
            home: const HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 无生成时：无横幅。
      expect(find.text('1本书正在生成……'), findsNothing);

      // 书 A 开始生成（保持挂起）。
      final fA = roundProvider.sendRound(userInput: '书A请求', book: bookA);
      await tester.pump();

      // 首页（无当前查看书）展示横幅，计数含书 A。
      expect(find.text('1本书正在生成……'), findsOneWidget);

      // 点击横幅 → 弹窗（首页书籍列表本身也有「书A」条目，需限定在弹窗内）。
      await tester.tap(find.text('1本书正在生成……'));
      await tester.pump();
      expect(find.text('正在生成的书'), findsOneWidget);
      final dialogBookA = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('书A'),
      );
      expect(dialogBookA, findsOneWidget);

      // 点击弹窗中的书 A → 进入书 A 对话页。
      await tester.tap(dialogBookA);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('书A'), findsWidgets);

      // 收尾：完成书 A 生成。
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