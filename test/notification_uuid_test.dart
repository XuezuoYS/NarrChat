import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:narrchat/utils/uuid_utils.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 通知链路的 uuid 身份验收（书籍身份只有 uuid，R3 不变）。
///
/// 与 `notification_service_test.dart`（隔离层：槽位派生、栈顶判定、启停前台
/// 服务）分工不同：本文件走「新建书籍 → 生成一轮 → 通知 → 跳转」的端到端链路，
/// 断言链路上流动的始终是同一串 uuid —— 通知 payload、路由参数、选中书籍、
/// 派生槽位 id，全程不出现任何本地 int 主键。
///
/// R3 起书籍来自真库（`TestStack`），所有库操作必须经 `tester.runAsync`：
/// `testWidgets` 的测试体在 fake-async 区域里，真实文件/ sqlite 回调不推进。
const bookAUuid = '7c1f2a34-56b7-4c8d-9e0f-a1b2c3d4e501';
const bookBUuid = '2d3e4f50-6172-4839-a0b1-c2d3e4f50602';

void main() {
  /// 建一套隔离存储并按 [uuids] 播种书籍（真库 I/O 走 runAsync）。
  Future<TestStack> makeStack(
    WidgetTester tester, {
    List<String> uuids = const [],
  }) async {
    final stack = await tester.runAsync(TestStack.create);
    addTearDown(() => tester.runAsync(stack!.dispose));
    if (uuids.isNotEmpty) {
      await tester.runAsync(() async {
        for (final uuid in uuids) {
          await stack!.seedBook(uuid: uuid, title: '书${uuid[0]}');
        }
      });
    }
    return stack!;
  }

  Future<BookProvider> makeBookProvider(
    WidgetTester tester,
    TestStack stack,
  ) async {
    final provider = BookProvider(repository: stack.repos.books);
    await tester.runAsync(provider.loadBooks);
    return provider;
  }

  Future<
    ({
      BookProvider provider,
      FakeNotificationBackend backend,
      GenerationNotificationService service,
      RoundProvider rounds,
    })
  >
  host(
    WidgetTester tester, {
    List<String> uuids = const [],
    String? launchUuid,
  }) async {
    final stack = await makeStack(tester, uuids: uuids);
    final provider = await makeBookProvider(tester, stack);
    final backend = FakeNotificationBackend()..launchPayload = launchUuid;
    final service = GenerationNotificationService(
      bookProvider: provider,
      backend: backend,
      attentionBackend: FakeTaskbarAttentionBackend(),
    );
    await service.init();
    final ctx = await pumpNotificationHost(
      tester,
      service: service,
      bookProvider: provider,
      stack: stack,
    );
    return (
      provider: provider,
      backend: backend,
      service: service,
      rounds: ctx.rounds,
    );
  }

  testWidgets('新建书籍 → 生成完成：通知带的是新书 uuid，槽位由其派生', (
    tester,
  ) async {
    final stack = await makeStack(tester);
    final provider = await makeBookProvider(tester, stack);
    final backend = FakeNotificationBackend();
    final service = GenerationNotificationService(
      bookProvider: provider,
      backend: backend,
      attentionBackend: FakeTaskbarAttentionBackend(),
    );
    await service.init();
    final ctx = await pumpNotificationHost(
      tester,
      service: service,
      bookProvider: provider,
      stack: stack,
    );

    // 新建书籍：uuid 由仓储分配，此后链路上再无 int 主键。
    final created = await tester.runAsync(() async {
      expect(await provider.createBook(const Book(title: '新书推荐')), isTrue);
      return provider.currentBook!;
    });
    expect(created!.uuid, isNotEmpty);

    // 切后台（不在该书 chat 页）→ 生成一轮。
    service.didChangeAppLifecycleState(AppLifecycleState.hidden);
    final sent = await tester.runAsync(() async {
      await ctx.rounds.loadRounds(created.uuid);
      return ctx.rounds.sendRound(userInput: '开场', book: created);
    });
    await tester.pumpAndSettle();
    expect(sent, isTrue);

    final shown = backend.shown.single;
    expect(shown.payload, created.uuid, reason: 'payload 即书籍主键 uuid');
    expect(shown.id, notificationIdForUuid(created.uuid));
    expect(shown.title, '《新书推荐》本轮已完成');
  });

  testWidgets('冷启动点通知：按 payload 的 uuid 打开对应书籍', (tester) async {
    final ctx = await host(
      tester,
      uuids: const [bookAUuid, bookBUuid],
      launchUuid: bookBUuid,
    );

    await ctx.service.handleLaunchNotificationIfAny();
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(ctx.provider.currentBook?.uuid, bookBUuid);
    expect(ctx.service.topChatBookUuid, bookBUuid);

    // 一次启动只按启动 payload 跳转一次：重复处理不再叠第二层对话页。
    await ctx.service.handleLaunchNotificationIfAny();
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('运行中点通知：替换栈顶 chat 页并切到 uuid 指向的书', (
    tester,
  ) async {
    final ctx = await host(tester, uuids: const [bookAUuid, bookBUuid]);

    // 前台正在看 A 的对话页（生成横幅按 uuid 排除当前书）。
    await ctx.service.openChatBook(bookAUuid);
    await tester.pumpAndSettle();
    expect(ctx.service.topChatBookUuid, bookAUuid);

    // 此时 B 生成完成：应弹通知（不是当前查看的书）。
    ctx.service.onGenerationCompleted(bookBUuid, '书B');
    await tester.pump();
    expect(ctx.backend.shown.single.payload, bookBUuid);

    // 点通知 → 栈顶替换为 B，A 不残留在栈上。
    ctx.backend.tap(bookBUuid);
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(ctx.service.topChatBookUuid, bookBUuid);
    expect(ctx.provider.currentBook?.uuid, bookBUuid);
    expect(
      ctx.backend.cancelled,
      contains(notificationIdForUuid(bookBUuid)),
      reason: '进入该书对话页即清除其派生槽位的通知',
    );
  });

  testWidgets('payload 指向已删除的书 → 不跳转、不误选其它书', (tester) async {
    final ctx = await host(
      tester,
      uuids: const [bookAUuid],
      launchUuid: '00000000-dead-beef-0000-000000000000',
    );

    final selectedBefore = ctx.provider.currentBook?.uuid;
    await ctx.service.handleLaunchNotificationIfAny();
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsNothing);
    expect(ctx.service.topChatBookUuid, isNull);
    // 选中书籍保持原样（既没跳也没被无效 uuid 改成别的书）。
    expect(ctx.provider.currentBook?.uuid, selectedBefore);
  });
}
