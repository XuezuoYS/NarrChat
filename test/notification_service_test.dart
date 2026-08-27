import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/chat_route.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

const bookA = Book(id: 1, title: '书A');
const bookB = Book(id: 2, title: '书B');

/// 构造一个已初始化、注入假后端的服务。
Future<GenerationNotificationService> _makeService(
  FakeNotificationBackend backend,
) async {
  final bookDao = FakeBookDao(books: [bookA, bookB]);
  final bookProvider = BookProvider(dao: bookDao);
  await bookProvider.loadBooks();
  final service = GenerationNotificationService(
    bookProvider: bookProvider,
    backend: backend,
  );
  await service.init();
  return service;
}

/// 构造一条标记为「书 [bookId] 的 chat 页」的路由。
Route<void> chatRoute(int bookId) => MaterialPageRoute<void>(
      builder: (_) => const SizedBox(),
      settings: RouteSettings(name: chatRouteName, arguments: bookId),
    );

void main() {
  testWidgets('前台且正在该书 chat 页时不弹通知', (tester) async {
    final backend = FakeNotificationBackend();
    final service = await _makeService(backend);

    // 模拟栈顶正在查看书 1 的 chat 页（生命周期默认 resumed）。
    service.routeObserver.didPush(chatRoute(1), null);
    expect(service.topChatBookId, 1);

    service.onGenerationCompleted(1, '书A');

    expect(backend.shown, isEmpty);
  });

  testWidgets('后台完成生成时弹出通知', (tester) async {
    final backend = FakeNotificationBackend();
    final service = await _makeService(backend);
    service.didChangeAppLifecycleState(AppLifecycleState.paused);

    service.onGenerationCompleted(1, '书A');

    expect(backend.shown, hasLength(1));
    expect(backend.shown.single.id, 1);
    expect(backend.shown.single.payload, '1');
    expect(backend.shown.single.title, '《书A》本轮已完成');
    expect(backend.shown.single.body, '点击打开');
  });

  testWidgets('前台但在其它页面（栈顶非 chat）时弹出通知', (tester) async {
    final backend = FakeNotificationBackend();
    final service = await _makeService(backend);

    service.onGenerationCompleted(2, '书B');

    expect(backend.shown, hasLength(1));
    expect(backend.shown.single.id, 2);
  });

  testWidgets('进入对应书 chat 页时自动删除该通知', (tester) async {
    final backend = FakeNotificationBackend();
    final service = await _makeService(backend);

    // 后台先弹出一条书 2 的通知。
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    service.onGenerationCompleted(2, '书B');
    backend.cancelled.clear();

    // 前台进入书 2 的 chat 页。
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    service.routeObserver.didPush(chatRoute(2), null);

    expect(backend.cancelled, contains(2));
  });

  testWidgets('生成任务进行中启动保活前台服务，全部结束后停止', (tester) async {
    final backend = FakeNotificationBackend();
    final service = await _makeService(backend);

    // 首个生成任务开始 → 启动前台服务。
    service.onGenerationActiveChanged(true);
    await tester.pump();
    expect(backend.startedForeground, hasLength(1));

    // 全部结束 → 停止前台服务。
    service.onGenerationActiveChanged(false);
    await tester.pump();
    expect(backend.stopForegroundCount, 1);

    // 重复上报同状态不重复启停。
    service.onGenerationActiveChanged(false);
    await tester.pump();
    expect(backend.stopForegroundCount, 1);
  });

  testWidgets('点通知跳转到对应书 chat 页', (tester) async {
    final backend = FakeNotificationBackend();
    final bookDao = FakeBookDao(books: [bookA, bookB]);
    final bookProvider = BookProvider(dao: bookDao);
    await bookProvider.loadBooks();
    final roundProvider = RoundProvider(dao: FakeRoundDao(), bookDao: bookDao);
    final service = GenerationNotificationService(
      bookProvider: bookProvider,
      backend: backend,
    );
    await service.init();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AiSettingsProvider>(
            create: (_) => AiSettingsProvider(),
          ),
          ChangeNotifierProvider<BookProvider>.value(value: bookProvider),
          ChangeNotifierProvider<WorldBookProvider>(
            create: (_) => WorldBookProvider(dao: FakeWorldBookDao()),
          ),
          ChangeNotifierProvider<RoundProvider>.value(value: roundProvider),
          ChangeNotifierProvider(create: (_) => SidebarProvider()),
          // 云同步：ChatScreen 进入书籍时触发自动同步（未配置时忽略）。
          ChangeNotifierProvider(
            create: (_) => CloudSyncProvider(),
          ),
        ],
        child: MaterialApp(
          navigatorKey: service.navigatorKey,
          navigatorObservers: [service.routeObserver],
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 模拟点击「书 B 生成完成」通知。
    backend.tap(bookB.id!);
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(bookProvider.currentBook?.id, bookB.id);
  });
}
