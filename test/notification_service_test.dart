import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/chat_route.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:narrchat/utils/uuid_utils.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 书籍身份即 uuid：通知槽 id 只是 uuid 的派生哈希，
/// 业务侧（payload / 路由参数 / 栈顶判定）一律直接使用 uuid 字符串。
///
/// R3 起书籍来自真库（`TestStack`），库操作必须经 `tester.runAsync`。
const bookAUuid = 'f3a1b7c2-1d2e-4a5b-9c8d-1e2f3a4b5c61';
const bookBUuid = 'c7d5e3f1-6a7b-4c8d-9e0f-a1b2c3d4e5f6';

/// 构造一条标记为「书 [bookUuid] 的 chat 页」的路由（路由参数 = 书籍 uuid）。
Route<void> chatRoute(String bookUuid) => MaterialPageRoute<void>(
      builder: (_) => const SizedBox(),
      settings: RouteSettings(name: chatRouteName, arguments: bookUuid),
    );

void main() {
  /// 建一套隔离存储 + 两本书 + 已初始化的服务。
  Future<({GenerationNotificationService service, TestStack stack})> makeService(
    WidgetTester tester,
    FakeNotificationBackend backend, {
    List<String> uuids = const [bookAUuid, bookBUuid],
  }) async {
    final stack = await tester.runAsync(TestStack.create);
    addTearDown(() => tester.runAsync(stack!.dispose));
    await tester.runAsync(() async {
      for (final uuid in uuids) {
        await stack!.seedBook(uuid: uuid, title: uuid == bookAUuid ? '书A' : '书B');
      }
    });
    final bookProvider = BookProvider(repository: stack!.repos.books);
    await tester.runAsync(bookProvider.loadBooks);
    final service = GenerationNotificationService(
      bookProvider: bookProvider,
      backend: backend,
      attentionBackend: FakeTaskbarAttentionBackend(),
    );
    await service.init();
    return (service: service, stack: stack);
  }

  testWidgets('前台且正在该书 chat 页时不弹通知', (tester) async {
    final backend = FakeNotificationBackend();
    final (:service, stack: _) = await makeService(tester, backend);

    // 模拟栈顶正在查看书 A 的 chat 页（生命周期默认 resumed）。
    service.routeObserver.didPush(chatRoute(bookAUuid), null);
    expect(service.topChatBookUuid, bookAUuid);

    service.onGenerationCompleted(bookAUuid, '书A');

    expect(backend.shown, isEmpty);
  });

  testWidgets('后台完成生成时弹出通知', (tester) async {
    final backend = FakeNotificationBackend();
    final (:service, stack: _) = await makeService(tester, backend);
    service.didChangeAppLifecycleState(AppLifecycleState.paused);

    service.onGenerationCompleted(bookAUuid, '书A');

    expect(backend.shown, hasLength(1));
    // 槽位 id = uuid 的派生哈希，payload 就是 uuid 本身。
    expect(backend.shown.single.id, notificationIdForUuid(bookAUuid));
    expect(backend.shown.single.payload, bookAUuid);
    expect(backend.shown.single.title, '《书A》本轮已完成');
    expect(backend.shown.single.body, '点击打开');
  });

  testWidgets('前台但在其它页面（栈顶非 chat）时弹出通知', (tester) async {
    final backend = FakeNotificationBackend();
    final (:service, stack: _) = await makeService(tester, backend);

    service.onGenerationCompleted(bookBUuid, '书B');

    expect(backend.shown, hasLength(1));
    expect(backend.shown.single.id, notificationIdForUuid(bookBUuid));
    expect(
      backend.shown.single.id,
      isNot(notificationIdForUuid(bookAUuid)),
      reason: '每本书各自派生槽位，互不覆盖',
    );
  });

  testWidgets('进入对应书 chat 页时自动删除该通知', (tester) async {
    final backend = FakeNotificationBackend();
    final (:service, stack: _) = await makeService(tester, backend);

    // 后台先弹出一条书 B 的通知。
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    service.onGenerationCompleted(bookBUuid, '书B');
    backend.cancelled.clear();

    // 前台进入书 B 的 chat 页。
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    service.routeObserver.didPush(chatRoute(bookBUuid), null);

    expect(backend.cancelled, contains(notificationIdForUuid(bookBUuid)));
  });

  testWidgets('生成任务进行中启动保活前台服务，全部结束后停止', (tester) async {
    final backend = FakeNotificationBackend();
    final (:service, stack: _) = await makeService(tester, backend);

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
    final stack = await tester.runAsync(TestStack.create);
    addTearDown(() => tester.runAsync(stack!.dispose));
    await tester.runAsync(() async {
      await stack!.seedBook(uuid: bookAUuid, title: '书A');
      await stack.seedBook(uuid: bookBUuid, title: '书B');
    });
    final bookProvider = BookProvider(repository: stack!.repos.books);
    await tester.runAsync(bookProvider.loadBooks);

    final service = GenerationNotificationService(
      bookProvider: bookProvider,
      backend: backend,
      attentionBackend: FakeTaskbarAttentionBackend(),
    );
    await service.init();
    await pumpNotificationHost(
      tester,
      service: service,
      bookProvider: bookProvider,
      stack: stack,
    );

    // 模拟点击「书 B 生成完成」通知（回调参数 = payload 里的书籍 uuid）。
    backend.tap(bookBUuid);
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget);
    // 路由以 uuid 标记栈顶 chat 页，故跳转后即视为正在查看该书。
    expect(service.topChatBookUuid, bookBUuid);
  });
}
