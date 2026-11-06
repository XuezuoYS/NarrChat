import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/widgets/round_version_stepper.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

/// 对话页「删除此代」契约：扩展菜单入口 → 二次确认 → 自动回落相邻代。
///
/// R3 起走**真库**：删除语义由 `RoundRepository.deleteGeneration` +
/// `BranchRules` 承担（删该代及后代子树、回落前一代、唯一一代拒绝）。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  Finder menuItem(String value) => find.byWidgetPredicate(
        (w) => w is PopupMenuItem<String> && w.value == value,
      );

  /// 点击气泡扩展菜单里的某一项。
  Future<void> tapMenuItem(
    WidgetTester tester,
    String value,
    String label,
  ) async {
    await tester.tap(
      find.descendant(of: menuItem(value), matching: find.text(label)),
    );
    await settle(tester);
  }

  /// 代次控件的箭头状态（false = 置灰不可点）。
  ({bool prev, bool next}) arrowState(WidgetTester tester) => (
        prev: tester
                .widget<IconButton>(find.byKey(RoundVersionStepper.prevKey))
                .onPressed !=
            null,
        next: tester
                .widget<IconButton>(find.byKey(RoundVersionStepper.nextKey))
                .onPressed !=
            null,
      );

  /// 预置：第 1 轮三代（g1/g2/g3，当前 = g2「第 2 代正文」）。
  Future<TestStack> seedThreeGens(WidgetTester tester) async {
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    await tester.runAsync(() async {
      await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        uuid: 'g1',
        userInput: '第一轮输入',
        aiNarrative: '第 1 代正文',
        isUsing: false,
      );
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        uuid: 'g2',
        userInput: '第一轮输入',
        aiNarrative: '第 2 代正文',
        isUsing: true,
      );
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        uuid: 'g3',
        userInput: '第一轮输入',
        aiNarrative: '第 3 代正文',
        isUsing: false,
      );
    });
    return stack;
  }

  /// 收窄到唯一一代（保留当前代 g2）。
  Future<void> shrinkToOne(
    WidgetTester tester,
    TestStack stack,
    RoundProvider provider,
  ) async {
    await tester.runAsync(() async {
      await stack.repos.rounds.deleteGeneration(
        bookUuid: kHarnessBookUuid,
        generationUuid: 'g1',
      );
      await stack.repos.rounds.deleteGeneration(
        bookUuid: kHarnessBookUuid,
        generationUuid: 'g3',
      );
    });
    await tester.runAsync(() => provider.loadRounds(kHarnessBookUuid));
    await settle(tester);
  }

  testWidgets('入口显隐：≥2 存活代时菜单含「删除此代」，唯一一代不显示', (tester) async {
    final stack = await seedThreeGens(tester);
    final provider = await pumpChatScreen(tester, stack: stack);

    await tester.longPress(find.text('第 2 代正文'));
    await settle(tester);
    expect(menuItem('deleteGen'), findsOneWidget);
    expect(
      find.descendant(of: menuItem('deleteGen'), matching: find.text('删除此代')),
      findsOneWidget,
    );
    expect(menuItem('delete'), findsOneWidget, reason: '既有「删除本轮」不受影响');

    // 关掉菜单，把该轮收窄到唯一一代（当前代仍在）再看。
    await tester.tapAt(const Offset(4, 4));
    await settle(tester);
    await shrinkToOne(tester, stack, provider);
    expect(provider.versionInfoFor(1)!.aliveCount, 1);

    await tester.longPress(find.text('第 2 代正文'));
    await settle(tester);
    expect(
      menuItem('deleteGen'),
      findsNothing,
      reason: '唯一一代没有可回落的相邻代 → 不显示入口',
    );
    expect(menuItem('delete'), findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await settle(tester);
  });

  testWidgets('确认框：给出落点与剩余代；取消则不删除、不切换', (tester) async {
    final stack = await seedThreeGens(tester);
    final provider = await pumpChatScreen(tester, stack: stack);
    expect(find.text('2/3'), findsOneWidget, reason: '夹具：当前第 2 代 / 最新第 3 代');

    await tester.longPress(find.text('第 2 代正文'));
    await settle(tester);
    await tapMenuItem(tester, 'deleteGen', '删除此代');

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('第 1 轮的第 2 代'), findsOneWidget);
    expect(find.textContaining('自动切换到第 1 代'), findsOneWidget);
    expect(find.textContaining('本轮剩余 2 代'), findsOneWidget);
    expect(find.textContaining('无法恢复'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settle(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(provider.versionInfoFor(1)!.aliveCount, 3, reason: '取消不删除');
    expect(find.text('2/3'), findsOneWidget, reason: '代次与正文原样不动');
    expect(find.text('第 2 代正文'), findsOneWidget);
  });

  testWidgets('确认删除：删当前代 → 回落前一代，最大数不变、左右箭头按剩余代置灰',
      (tester) async {
    final stack = await seedThreeGens(tester);
    final provider = await pumpChatScreen(tester, stack: stack);
    expect(arrowState(tester), (prev: true, next: true));

    await tester.longPress(find.text('第 2 代正文'));
    await settle(tester);
    await tapMenuItem(tester, 'deleteGen', '删除此代');
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await settle(tester);

    // R3：删代即真实写库，当前代回落到前一代 g1。
    expect(provider.versionInfoFor(1)!.aliveCount, 2);
    expect(provider.rounds.single.uuid, 'g1', reason: '回落到前一代');
    expect(find.text('第 1 代正文'), findsOneWidget, reason: '正文随回落代');
    expect(
      find.text('1/3'),
      findsOneWidget,
      reason: '删的不是最大号 → 「最新第 3 代」不变，序号不重排',
    );
    final arrows = arrowState(tester);
    expect(arrows.prev, isFalse, reason: '已在前一代 → 左箭头置灰');
    expect(arrows.next, isTrue, reason: '右侧仍有第 3 代可切');
    expect(provider.isSending, isFalse, reason: '删除不发起生成');
  });

  testWidgets('守卫：菜单已开出后缩到唯一一代 → 悬浮提示「请删除此轮」且不删除',
      (tester) async {
    final stack = await seedThreeGens(tester);
    final provider = await pumpChatScreen(tester, stack: stack);

    await tester.longPress(find.text('第 2 代正文'));
    await settle(tester);
    expect(menuItem('deleteGen'), findsOneWidget);

    // 菜单开着的期间版本树变化（模拟特殊手段触发 / 竞态）。
    await tester.runAsync(() async {
      await stack.repos.rounds.deleteGeneration(
        bookUuid: kHarnessBookUuid,
        generationUuid: 'g1',
      );
      await stack.repos.rounds.deleteGeneration(
        bookUuid: kHarnessBookUuid,
        generationUuid: 'g3',
      );
    });
    await tester.runAsync(() => provider.loadRounds(kHarnessBookUuid));
    await tester.pump();

    await tapMenuItem(tester, 'deleteGen', '删除此代');
    await settleNoticeEnter(tester);
    expect(find.textContaining('唯一代不可删除，请删除此轮。'), findsOneWidget);
    expect(provider.versionInfoFor(1)!.aliveCount, 1, reason: '守卫拦截：不做任何删除');
    expect(find.byType(AlertDialog), findsNothing, reason: '不进入确认框');
    await flushNotices(tester);
  });

  testWidgets('守卫：正在生成中点击「删除此代」→ 提示暂不可删除', (tester) async {
    final stack = await seedThreeGens(tester);
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, stack: stack, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    expect(provider.isSending, isTrue);

    await tester.longPress(find.text('第 2 代正文'));
    // 生成中不能用 settle（转圈动画永不结束），手动推一帧让菜单弹出。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.descendant(
        of: menuItem('deleteGen'),
        matching: find.text('删除此代'),
      ),
    );
    await settleNoticeEnter(tester);

    expect(find.textContaining('正在生成中，暂不可删除此代。'), findsOneWidget);
    expect(
      provider.rounds.firstWhere((r) => r.roundIndex == 1).uuid,
      'g2',
      reason: '守卫拦截：代次不动',
    );
    await flushNotices(tester);
    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });
}
