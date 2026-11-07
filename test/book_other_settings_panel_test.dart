import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/app_notice_center.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/book_other_settings_panel.dart';
import 'package:provider/provider.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

/// 书籍设置「其它设置 → 删除未启用的代」面板（真库 + RoundProvider）。
///
/// 夹具固定为 4 代：
/// - 第 1 轮：g1（选中）、g1-old（未启用）；
/// - 第 2 轮：g2（g1 的后续，选中）、g-ghost（只能从 g1-old 到达，选中）。
///
/// 因此期望：未启用 1 个、级联 1 个；删完只剩 g1 / g2，活动链不变。
void main() {
  const bookUuid = 'b1';
  const book = Book(uuid: bookUuid, title: '测试书');

  late TestStack stack;

  setUp(() async {
    stack = await TestStack.create(prefix: 'book_cleanup_');
    await stack.seedBook(uuid: bookUuid, title: '测试书');
  });

  tearDown(() async {
    await stack.dispose();
  });

  Future<void> seedMixed() async {
    await stack.seedRound(
      bookUuid,
      roundIndex: 1,
      uuid: 'g1',
      isUsing: true,
      aiNarrative: '第 1 轮当前代',
    );
    await stack.seedRound(
      bookUuid,
      roundIndex: 1,
      uuid: 'g1-old',
      isUsing: false,
      aiNarrative: '第 1 轮旧代',
    );
    await stack.seedRound(
      bookUuid,
      roundIndex: 2,
      uuid: 'g2',
      fatherUuid: 'g1',
      isUsing: true,
      aiNarrative: '第 2 轮当前代',
    );
    await stack.seedRound(
      bookUuid,
      roundIndex: 2,
      uuid: 'g-ghost',
      fatherUuid: 'g1-old',
      isUsing: true,
      aiNarrative: '旧线后续',
    );
  }

  /// Pump「其它设置」面板，返回 Provider / 云同步替身 / 通知中心。
  Future<({
    RoundProvider provider,
    FakeCloudSyncProvider cloud,
    AppNoticeCenter center,
  })> pumpPanel(
    WidgetTester tester, {
    bool preload = true,
    AiService? ai,
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final cloud = FakeCloudSyncProvider();
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai ?? ToggleAiService(),
      cloudSyncProvider: cloud,
      retryDelay: Duration.zero,
    );
    if (preload) {
      await tester.runAsync(() => provider.loadRounds(bookUuid));
    }
    final center = AppNoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<RoundProvider>(
        create: (_) => provider,
        child: MaterialApp(
          theme: NarrChatTheme.light,
          builder: floatingNoticeBuilder(center: center),
          home: Scaffold(
            body: SingleChildScrollView(
              child: BookOtherSettingsPanel(bookUuid: bookUuid),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return (provider: provider, cloud: cloud, center: center);
  }

  Finder deleteButton() => find.widgetWithText(OutlinedButton, '删除未启用的代');

  testWidgets('统计：全书总数 / 未启用 / 级联后续', (tester) async {
    await tester.runAsync(seedMixed);
    await pumpPanel(tester);

    expect(find.textContaining('全书共 4 代'), findsOneWidget);
    expect(find.textContaining('其中 1 个未启用'), findsOneWidget);
    expect(find.textContaining('另有 1 个只能从这些代到达'), findsOneWidget);
  });

  testWidgets('确认框：取消不删除、不触发同步', (tester) async {
    await tester.runAsync(seedMixed);
    final p = await pumpPanel(tester);

    await tester.tap(deleteButton());
    await settle(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('将删除本书 1 个未启用的代'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('另有 1 个')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('无法恢复')),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settle(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(p.provider.versionInfoFor(1)!.aliveCount, 2, reason: '取消不删除');
    final chain = (await tester.runAsync(
      () => stack.repos.rounds.loadChain(bookUuid),
    ))!;
    expect(chain.allMeta.length, 4);
    expect(p.cloud.triggers, 0);
  });

  testWidgets('确认删除：物理删库、活动链不变、触发一次同步', (tester) async {
    await tester.runAsync(seedMixed);
    final p = await pumpPanel(tester);

    await tester.tap(deleteButton());
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await settle(tester);

    expect(p.provider.rounds.map((r) => r.uuid), [
      'g1',
      'g2',
    ], reason: '活动链原样保留');
    expect(p.provider.versionInfoFor(1)!.aliveCount, 1, reason: '组内只剩当前选中代');
    final chain = (await tester.runAsync(
      () => stack.repos.rounds.loadChain(bookUuid),
    ))!;
    expect(chain.allMeta.map((m) => m.uuid).toSet(), {'g1', 'g2'});
    expect(find.text('没有可删除的未启用的代。'), findsOneWidget);
    expect(p.cloud.triggers, 1, reason: '实际删除属内容变更');
    expect(p.center.current?.message, contains('已删除 2 个代'));

    await flushNotices(tester);
  });

  testWidgets('没有可删项：按钮禁用 + 空态文案', (tester) async {
    await tester.runAsync(() async {
      await stack.seedRound(
        bookUuid,
        roundIndex: 1,
        uuid: 'only',
        isUsing: true,
        aiNarrative: '唯一代',
      );
    });
    await pumpPanel(tester);

    expect(find.text('没有可删除的未启用的代。'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(deleteButton()).onPressed,
      isNull,
      reason: '没有可删项时按钮禁用',
    );
  });

  testWidgets('生成中：按钮禁用，Provider 守卫拒绝删除', (tester) async {
    await tester.runAsync(seedMixed);
    final ai = FakeStreamingAiService();
    final p = await pumpPanel(tester, ai: ai);

    final sendFuture = p.provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    expect(p.provider.isSending, isTrue);

    expect(find.text('本书正在生成中，生成结束后才能清理。'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(deleteButton()).onPressed, isNull);

    final result = await p.provider.deleteUnusedGenerations(bookUuid);
    expect(result.isRefused, isTrue);
    expect(result.refusal, contains('正在生成中'));
    final chain = (await tester.runAsync(
      () => stack.repos.rounds.loadChain(bookUuid),
    ))!;
    expect(chain.allMeta.length, 4, reason: '守卫拦截：没删旧代；生成中的新代此时尚未落库');

    ai.complete();
    await waitSendDone(tester, p.provider);
    expect(await sendFuture, isTrue);
  });

  testWidgets('未预加载：面板自动加载本书并显示统计', (tester) async {
    await tester.runAsync(seedMixed);
    final p = await pumpPanel(tester, preload: false);

    expect(p.provider.loadedBookUuid, bookUuid, reason: '面板会补一次加载');
    expect(find.textContaining('全书共 4 代'), findsOneWidget);
  });

  testWidgets('窄屏（手机宽度）不溢出', (tester) async {
    await tester.runAsync(seedMixed);
    await pumpPanel(tester, size: const Size(360, 720));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('全书共 4 代'), findsOneWidget);
  });
}
