import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:narrchat/utils/uuid_utils.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 通知链路的 uuid 身份验收（v16：书籍身份只有 uuid）。
///
/// 与 `notification_service_test.dart`（隔离层：槽位派生、栈顶判定、启停前台
/// 服务）分工不同：本文件走「新建书籍 → 生成一轮 → 通知 → 跳转」的端到端链路，
/// 断言链路上流动的始终是同一串 uuid —— 通知 payload、路由参数、选中书籍、
/// 派生槽位 id，全程不出现任何本地 int 主键。
void main() {
  const bookA = Book(uuid: '7c1f2a34-56b7-4c8d-9e0f-a1b2c3d4e501', title: '书A');
  const bookB = Book(uuid: '2d3e4f50-6172-4839-a0b1-c2d3e4f50602', title: '书B');

  Future<(
    BookProvider provider,
    FakeNotificationBackend backend,
    GenerationNotificationService service,
  )> host(
    WidgetTester tester, {
    List<Book> books = const [],
    String? launchUuid,
  }) async {
    final dao = FakeBookDao(books: books);
    final provider = BookProvider(dao: dao);
    await provider.loadBooks();
    final backend = FakeNotificationBackend()..launchPayload = launchUuid;
    final service = GenerationNotificationService(
      bookProvider: provider,
      backend: backend,
    );
    await service.init();
    await pumpNotificationHost(
      tester,
      service: service,
      bookProvider: provider,
      bookDao: dao,
    );
    return (provider, backend, service);
  }

  testWidgets('新建书籍 → 生成完成：通知带的是新书 uuid，槽位由其派生', (
    tester,
  ) async {
    final dao = FakeBookDao();
    final provider = BookProvider(dao: dao);
    await provider.loadBooks();
    final backend = FakeNotificationBackend();
    final service = GenerationNotificationService(
      bookProvider: provider,
      backend: backend,
    );
    await service.init();
    final ctx = await pumpNotificationHost(
      tester,
      service: service,
      bookProvider: provider,
      bookDao: dao,
    );

    // 新建书籍：uuid 由 DAO 分配，此后链路上再无 int 主键。
    expect(await provider.createBook(const Book(title: '新书推荐')), isTrue);
    final created = provider.currentBook!;
    expect(created.uuid, isNotEmpty);

    // 切后台（不在该书 chat 页）→ 生成一轮。
    service.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await ctx.rounds.loadRounds(created.uuid);
    final sent = ctx.rounds.sendRound(userInput: '开场', book: created);
    await tester.pumpAndSettle();
    expect(await sent, isTrue);

    final shown = backend.shown.single;
    expect(shown.payload, created.uuid, reason: 'payload 即书籍主键 uuid');
    expect(shown.id, notificationIdForUuid(created.uuid));
    expect(shown.title, '《新书推荐》本轮已完成');
  });

  testWidgets('冷启动点通知：按 payload 的 uuid 打开对应书籍', (tester) async {
    final (provider, _, service) = await host(
      tester,
      books: const [bookA, bookB],
      launchUuid: bookB.uuid,
    );

    await service.handleLaunchNotificationIfAny();
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(provider.currentBook?.uuid, bookB.uuid);
    expect(service.topChatBookUuid, bookB.uuid);

    // 一次启动只按启动 payload 跳转一次：重复处理不再叠第二层对话页。
    await service.handleLaunchNotificationIfAny();
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('运行中点通知：替换栈顶 chat 页并切到 uuid 指向的书', (
    tester,
  ) async {
    final (provider, backend, service) = await host(
      tester,
      books: const [bookA, bookB],
    );
    // 前台正在看 A 的对话页（生成横幅按 uuid 排除当前书）。
    await service.openChatBook(bookA.uuid);
    await tester.pumpAndSettle();
    expect(service.topChatBookUuid, bookA.uuid);

    // 此时 B 生成完成：应弹通知（不是当前查看的书）。
    service.onGenerationCompleted(bookB.uuid, bookB.title);
    await tester.pump();
    expect(backend.shown.single.payload, bookB.uuid);

    // 点通知 → 栈顶替换为 B，A 不残留在栈上。
    backend.tap(bookB.uuid);
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(service.topChatBookUuid, bookB.uuid);
    expect(provider.currentBook?.uuid, bookB.uuid);
    expect(
      backend.cancelled,
      contains(notificationIdForUuid(bookB.uuid)),
      reason: '进入该书对话页即清除其派生槽位的通知',
    );
  });

  testWidgets('payload 指向已删除的书 → 不跳转、不误选其它书', (tester) async {
    final (provider, _, service) = await host(
      tester,
      books: const [bookA],
      launchUuid: '00000000-dead-beef-0000-000000000000',
    );

    final selectedBefore = provider.currentBook?.uuid;
    await service.handleLaunchNotificationIfAny();
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsNothing);
    expect(service.topChatBookUuid, isNull);
    // 选中书籍保持原样（既没跳也没被无效 uuid 改成别的书）。
    expect(provider.currentBook?.uuid, selectedBefore);
  });

}