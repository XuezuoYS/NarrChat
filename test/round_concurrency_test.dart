import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/notification_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/screens/home_screen.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/island_bar.dart';
import 'package:narrchat/widgets/narr_chat_app_bar.dart';
import 'package:narrchat/widgets/pinned_notice_island.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

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

  group('跨书进程驻场岛', () {
    /// 展开驻场岛并等形变完成（岛上常驻转圈动画，不能用 pumpAndSettle）。
    ///
    /// 先等胶囊「宽度展开动画」走完（200ms，起点宽度为 0、期间右侧箭头被
    /// 裁剪掉不可点），再点箭头展开面板。
    Future<void> expandIsland(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
    }

    Future<void> pumpChat(
      WidgetTester tester, {
      required BookProvider bookProvider,
      required RoundProvider roundProvider,
      required WorldBookProvider worldBookProvider,
      void Function(String bookUuid)? onOpenBook,
      Size size = const Size(1400, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AiSettingsProvider()),
            ChangeNotifierProvider(
              create: (_) => ExperimentalSettingsProvider(),
            ),
            ChangeNotifierProvider(create: (_) => UiSettingsProvider()),
            ChangeNotifierProvider(create: (_) => bookProvider),
            ChangeNotifierProvider(create: (_) => worldBookProvider),
            ChangeNotifierProvider(create: (_) => roundProvider),
            ChangeNotifierProvider(create: (_) => SidebarProvider()),
            // 云同步：ChatScreen 进入书籍时触发自动同步（未配置时忽略）。
            ChangeNotifierProvider(create: (_) => CloudSyncProvider()),
          ],
          child: MaterialApp(
            theme: NarrChatTheme.light,
            builder: noticeHostBuilder(onOpenBook: onOpenBook),
            home: Scaffold(body: const ChatScreen()),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('其他书生成中：驻场岛显示计数，展开后点该书跳转', (tester) async {
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
      final opened = <String>[];

      await pumpChat(
        tester,
        bookProvider: bookProvider,
        roundProvider: roundProvider,
        worldBookProvider: worldBookProvider,
        onOpenBook: opened.add,
      );

      // 无其他书生成时：驻场岛不占位。
      expect(find.text('1本书正在生成……'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);

      // 书 A 开始生成（保持挂起）。
      final fA = roundProvider.sendRound(userInput: '书A请求', book: bookA);
      await tester.pump();

      // 驻场岛出现：显示计数。
      expect(find.text('1本书正在生成……'), findsOneWidget);

      // 点击胶囊展开 → 列出正在生成的书。
      await expandIsland(tester);
      final islandBookA = find.descendant(
        of: find.byType(PinnedNoticeIsland),
        matching: find.text('书A'),
      );
      expect(islandBookA, findsOneWidget);

      // 点击该书 → 回调跳转（真实导航由 main.dart 接到通知服务）。
      await tester.tap(islandBookA);
      await tester.pump();
      expect(opened, ['b1']);

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

    testWidgets('窄屏对话页：岛嵌在顶栏附加行里，而不是掉到悬浮位', (tester) async {
      final bookDao = FakeBookDao(books: [bookA, bookB]);
      final dao = FakeRoundDao();
      final ai = _ConcurrentAiService();
      final bookProvider = BookProvider(dao: bookDao);
      await bookProvider.loadBooks();
      bookProvider.selectBook(bookB);

      final roundProvider = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        retryDelay: Duration.zero,
      );
      await roundProvider.loadRounds('b2');
      final worldBookProvider = WorldBookProvider(dao: FakeWorldBookDao());

      // 与真机截图一致的窄窗口（< 760 走「顶栏向下多一行」）。
      await pumpChat(
        tester,
        bookProvider: bookProvider,
        roundProvider: roundProvider,
        worldBookProvider: worldBookProvider,
        size: const Size(378, 793),
      );

      final fA = roundProvider.sendRound(userInput: '书A请求', book: bookA);
      await tester.pump();
      // 出现在出现动画 / 附加行高度动画都结束之后。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      final bar = tester.getRect(find.byType(NarrChatAppBar));
      expect(bar.height, closeTo(kToolbarHeight + kIslandRowHeight, 1),
          reason: '窄屏顶栏向下多一行');
      final card = tester.getRect(
        find
            .descendant(
              of: find.byType(PinnedNoticeIsland),
              matching: find.byType(Material),
            )
            .first,
      );
      // 悬浮位在顶栏下方（top ≈ kToolbarHeight + 8）；嵌在附加行时岛向上借
      // kIslandRowOverlap 的工具栏空白区，下方留 kIslandRowPadding 的顶栏背景留白。
      final rowBottom = bar.bottom - 1; // 顶栏底部 1px 边线
      final rowTop = rowBottom - kIslandRowHeight;
      expect(rowTop - card.top, closeTo(kIslandRowOverlap, 0.5),
          reason: '岛应嵌在附加行里（不是悬浮位）');
      expect(rowBottom - card.bottom, closeTo(kIslandRowPadding, 0.5),
          reason: '岛下方保留顶栏背景留白');

      // 收尾：完成生成，避免悬空。
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

    testWidgets('多本书生成：驻场岛计数，展开列出全部并可选跳转', (tester) async {
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
      final opened = <String>[];

      await pumpChat(
        tester,
        bookProvider: bookProvider,
        roundProvider: roundProvider,
        worldBookProvider: worldBookProvider,
        onOpenBook: opened.add,
      );

      // 书 A 与书 C 同时生成。
      final fA = roundProvider.sendRound(userInput: '书A请求', book: bookA);
      final fC = roundProvider.sendRound(userInput: '书C请求', book: bookC);
      await tester.pump();

      // 驻场岛显示 2 本书。
      expect(find.text('2本书正在生成……'), findsOneWidget);

      // 展开 → 列出书 A 与书 C，点击跳转。
      await expandIsland(tester);
      final island = find.byType(PinnedNoticeIsland);
      expect(
        find.descendant(of: island, matching: find.text('书A')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: island, matching: find.text('书C')),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(of: island, matching: find.text('书C')),
      );
      await tester.pump();
      expect(opened, ['b3']);

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

    testWidgets('首页（书籍列表）也展示驻场岛并可进入对应书', (tester) async {
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
      final opened = <String>[];

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AiSettingsProvider()),
            ChangeNotifierProvider(
              create: (_) => ExperimentalSettingsProvider(),
            ),
            ChangeNotifierProvider(create: (_) => UiSettingsProvider()),
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
            builder: noticeHostBuilder(onOpenBook: opened.add),
            home: const HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 无生成时：驻场岛不占位。
      expect(find.text('1本书正在生成……'), findsNothing);

      // 书 A 开始生成（保持挂起）。
      final fA = roundProvider.sendRound(userInput: '书A请求', book: bookA);
      await tester.pump();

      // 首页同样展示驻场岛（不依赖当前查看书）。
      expect(find.text('1本书正在生成……'), findsOneWidget);

      // 展开 → 首页书籍列表本身也有「书A」条目，需限定在驻场岛内点击。
      await expandIsland(tester);
      final islandBookA = find.descendant(
        of: find.byType(PinnedNoticeIsland),
        matching: find.text('书A'),
      );
      expect(islandBookA, findsOneWidget);

      await tester.tap(islandBookA);
      await tester.pump();
      expect(opened, ['b1']);

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