import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/chat_route.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/services/notification_service.dart';

import 'helpers/fakes.dart';

/// 任务栏「后台完成」闪烁提醒（Windows，同 QQ）的隔离层测试。
///
/// 被测对象是 [GenerationNotificationService] 的闪烁接线：
/// - 生成在非前台（最小化 / 未聚焦）完成 → 系统通知照常 + 任务栏开始闪烁；
/// - 前台完成 → 不闪烁（窗口可见且聚焦，任务栏无需提醒）；
/// - 前台正在查看该书 chat 页 → 不闪烁也不弹通知；
/// - 窗口回到前台（resumed）→ 停止闪烁。
///
/// Windows 真实实现（Win32TaskbarAttentionBackend 的 user32 FFI）无法在
/// 测试中验证，本文件全部注入 [FakeTaskbarAttentionBackend]。
const bookA = Book(
  uuid: 'f3a1b7c2-1d2e-4a5b-9c8d-1e2f3a4b5c61',
  title: '书A',
);

/// 构造一个已初始化、注入假通知 / 假闪烁后端的服务。
Future<
  (
    GenerationNotificationService service,
    FakeNotificationBackend backend,
    FakeTaskbarAttentionBackend attention,
  )
>
_makeService() async {
  final bookDao = FakeBookDao(books: [bookA]);
  final bookProvider = BookProvider(dao: bookDao);
  await bookProvider.loadBooks();
  final backend = FakeNotificationBackend();
  final attention = FakeTaskbarAttentionBackend();
  final service = GenerationNotificationService(
    bookProvider: bookProvider,
    backend: backend,
    attentionBackend: attention,
  );
  await service.init();
  return (service, backend, attention);
}

/// 构造一条标记为「书 [bookUuid] 的 chat 页」的路由（路由参数 = 书籍 uuid）。
Route<void> chatRoute(String bookUuid) => MaterialPageRoute<void>(
  builder: (_) => const SizedBox(),
  settings: RouteSettings(name: chatRouteName, arguments: bookUuid),
);

void main() {
  testWidgets('后台完成生成：任务栏开始闪烁，系统通知照常', (tester) async {
    final (service, backend, attention) = await _makeService();
    // 模拟最小化 / 切到后台（生命周期进入非 resumed）。
    service.didChangeAppLifecycleState(AppLifecycleState.hidden);

    service.onGenerationCompleted(bookA.uuid, '书A');

    expect(attention.startCount, 1);
    expect(attention.stopCount, 0);
    // 闪烁与系统通知是两条独立提醒通道，互不影响。
    expect(backend.shown, hasLength(1));
  });

  testWidgets('未聚焦（inactive）完成生成：任务栏开始闪烁', (tester) async {
    final (service, _, attention) = await _makeService();
    // 窗口可见但无焦点（被其它窗口遮挡 / 切到别的应用）。
    service.didChangeAppLifecycleState(AppLifecycleState.inactive);

    service.onGenerationCompleted(bookA.uuid, '书A');

    expect(attention.startCount, 1);
  });

  testWidgets('前台完成生成：不闪烁', (tester) async {
    final (service, _, attention) = await _makeService();
    // 生命周期默认 resumed（窗口可见且聚焦），任务栏无需提醒。

    service.onGenerationCompleted(bookA.uuid, '书A');

    expect(attention.startCount, 0);
  });

  testWidgets('前台正在查看该书 chat 页完成生成：不闪烁也不弹通知', (tester) async {
    final (service, backend, attention) = await _makeService();
    service.routeObserver.didPush(chatRoute(bookA.uuid), null);
    expect(service.topChatBookUuid, bookA.uuid);

    service.onGenerationCompleted(bookA.uuid, '书A');

    expect(attention.startCount, 0);
    expect(backend.shown, isEmpty);
  });

  testWidgets('窗口回到前台：停止闪烁', (tester) async {
    final (service, _, attention) = await _makeService();
    // 后台完成一次 → 开始闪烁。
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    service.onGenerationCompleted(bookA.uuid, '书A');
    expect(attention.startCount, 1);

    // 用户点任务栏 / 打开窗口恢复焦点 → 停止闪烁。
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);

    expect(attention.stopCount, 1);
  });
}
