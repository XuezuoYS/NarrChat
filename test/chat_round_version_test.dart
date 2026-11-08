import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/round_version_stepper.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 对话页「代次控件」集成契约（UI-1 / UI-3 / UI-5）。
///
/// R3 起走**真库**：版本组由 `RoundRepository.loadChain` 的 `GenerationSet` 提供，
/// 不再有内存替身版本的 `RoundStackIndex`。切换语义 = 组内 `is_using` 换人，
/// 旧代留在库里可切回、不新增也不删除轮次。
void main() {
  /// 预置：第 1 轮两代（g1 选中、g2 闲置）。
  Future<TestStack> seedTwoVersions(WidgetTester tester, {int g2Repeat = 40}) async {
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    await tester.runAsync(() async {
      await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        uuid: 'g1',
        userInput: '第一轮输入',
        aiNarrative: '第一代正文。' * 40,
        isUsing: true,
      );
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        uuid: 'g2',
        userInput: '第一轮输入',
        aiNarrative: '第二代正文。' * g2Repeat,
        isUsing: false,
      );
    });
    return stack;
  }

  testWidgets('UI-1 ≥2 存活代显示控件：x/y 与存活代一致，单代不显示', (tester) async {
    final stack = await seedTwoVersions(tester);
    final provider = await pumpChatScreen(tester, stack: stack);

    expect(find.byKey(RoundVersionStepper.stepperKey), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget, reason: '当前代 1 / 存活代 2');
    expect(provider.versionInfoFor(1)!.aliveCount, 2);

    // 删掉闲置代 → 只剩一代，控件消失。
    await tester.runAsync(
      () => stack.repos.rounds.deleteGeneration(
        bookUuid: kHarnessBookUuid,
        generationUuid: 'g2',
      ),
    );
    await tester.runAsync(() => provider.loadRounds(kHarnessBookUuid));
    await settle(tester);

    expect(provider.versionInfoFor(1)!.aliveCount, 1);
    expect(find.byKey(RoundVersionStepper.stepperKey), findsNothing);
  });

  testWidgets('UI-3 切换：只切版本（不生成长文、不滚到底），草稿保留', (tester) async {
    final stack = await seedTwoVersions(tester);
    final provider = await pumpChatScreen(tester, stack: stack);

    // 视口内先滚动离开底部：切换不得把视图拉到底部。
    // （消息列 `reverse: true`：向下拖动 = 揭示更旧内容 = offset 增大、离开底部。）
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await settle(tester);
    final beforeOffset = tester
        .widget<Scrollable>(find.byType(Scrollable).first)
        .controller!
        .offset;

    // 草稿：切换不得清空主输入框。
    await tester.enterText(find.byType(EditableText).first, '草稿不该被清');
    await tester.pump();

    await tester.tap(find.byKey(RoundVersionStepper.nextKey));
    await settle(tester);

    expect(provider.rounds, hasLength(1), reason: '切换不新增/不删除轮次');
    expect(provider.rounds.single.uuid, 'g2', reason: '已切到第二代');
    expect(provider.versionInfoFor(1)!.aliveCount, 2, reason: '旧代仍在库里');
    expect(provider.isSending, isFalse, reason: '切换不发起生成');
    expect(find.text('草稿不该被清'), findsOneWidget, reason: '草稿保留');
    expect(
      tester
          .widget<Scrollable>(find.byType(Scrollable).first)
          .controller!
          .offset,
      closeTo(beforeOffset, 0.5),
      reason: '切换不滚动（视图停在原地）',
    );
  });

  testWidgets('UI-3b 切换后「视图停在切换控件」：正文变长也不让控件漂出视口', (tester) async {
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    await tester.runAsync(() async {
      await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
      for (var i = 1; i <= 4; i++) {
        await stack.seedRound(
          kHarnessBookUuid,
          roundIndex: i,
          uuid: 'r$i',
          userInput: '第 $i 轮的用户输入',
          aiNarrative: '第 $i 轮正文。' * 3,
        );
      }
      // 第 2 轮加一个**更长**的第二代：切过去时正文高度明显变大。
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 2,
        uuid: 'g2',
        fatherUuid: 'r1',
        userInput: '第 2 轮的用户输入',
        aiNarrative: '切换后变长很多的正文。' * 200,
        isUsing: false,
      );
    });
    final provider = await pumpChatScreen(
      tester,
      stack: stack,
      size: const Size(1400, 900),
    );

    // 向上滚到第 2 轮的代次控件可见（且不在列表底部，仍有下滚余量）。
    final stepperFinder = find.byKey(RoundVersionStepper.stepperKey);
    for (var i = 0; i < 10 && stepperFinder.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await settle(tester);
    }
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await settle(tester);
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(stepperFinder, findsOneWidget);
    final beforeTop = tester.getTopLeft(stepperFinder).dy;
    expect(beforeTop, greaterThan(50), reason: '夹具前提：控件不在视口最顶部');
    expect(
      scrollable.position.pixels - scrollable.position.minScrollExtent,
      greaterThan(50),
      reason: '夹具前提：切换前不在列表底部（否则无法向下补偿滚动）',
    );

    await tester.tap(find.byKey(RoundVersionStepper.nextKey));
    await settle(tester);

    expect(provider.rounds.firstWhere((r) => r.roundIndex == 2).uuid, 'g2');
    expect(
      provider.rounds.firstWhere((r) => r.roundIndex == 2).aiNarrative.length,
      greaterThan(1000),
      reason: '夹具：切换确实换上了更长正文',
    );
    final afterTop = tester.getTopLeft(stepperFinder).dy;
    // 这个方向（切到没有后续轮的代）下方内容变少：要让控件留在原处得把视图往上抬，
    // 抬到列表端点就抬不动了——剩余偏差是「下方内容不够」的物理上限，不是补偿丢了。
    // 这里只守「控件没被挤出视口」，精确锚定由 UI-4 的「切回去」方向守。
    expect(afterTop, greaterThan(0), reason: '控件仍在视口内（未被正文变长挤出）');
    expect(
      afterTop,
      lessThan(beforeTop + 400),
      reason: '至少不能整段漂走（前 $beforeTop → 后 $afterTop）',
    );
    expect(provider.isSending, isFalse);
  });

  testWidgets('UI-4 切回「有后续轮」的代：控件停在原处，不跳到新的最底部', (tester) async {
    // 夹具刻意做得「很长」：正文 120 次重复，一轮就快一屏。
    // - 第 1–6 轮依次挂 r1 … r6，第 4 轮补一代 g2（同父第 3 轮、没有后续轮）；
    // - 初始选中 r4：贴底时最后两轮是渲染着的，实高会进本页高度备忘；
    // - 切到 g2 后活动链只剩 4 轮（第 5/6 轮暂时消失），再切回 r4 时它们整段回来，
    //   位移远超 cacheExtent——旧的「只量控件实位」补偿会因为控件被推出构建范围而放弃，
    //   视图就留在新的最底部。本用例守的正是这条路径。
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    await tester.runAsync(() async {
      await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
      final uuids = <String>[];
      for (var i = 1; i <= 6; i++) {
        final seeded = await stack.seedRound(
          kHarnessBookUuid,
          roundIndex: i,
          userInput: '第 $i 轮的用户输入',
          aiNarrative: '第 $i 轮的剧情正文。' * 120,
        );
        uuids.add(seeded.meta.uuid);
      }
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 4,
        fatherUuid: uuids[2],
        isUsing: false,
        userInput: '第 4 轮的用户输入',
        aiNarrative: '第 4 轮的第二代正文。' * 120,
      );
    });
    final provider = await pumpChatScreen(
      tester,
      stack: stack,
      size: const Size(1400, 900),
    );

    // 向上滚到第 4 轮的代次控件（全页唯一的代次控件：只有第 4 轮有两代）。
    final stepperFinder = find.byKey(RoundVersionStepper.stepperKey);
    double? stepperTop() => stepperFinder.evaluate().isEmpty
        ? null
        : tester.getTopLeft(stepperFinder).dy;
    for (var i = 0; i < 20; i++) {
      final top = stepperTop();
      if (top != null && top > 100 && top < 600) break;
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await settle(tester);
    }
    final beforeSwitchTop = stepperTop();
    expect(beforeSwitchTop, isNotNull, reason: '夹具前提：控件已构建');
    expect(beforeSwitchTop, greaterThan(100), reason: '夹具前提：控件完整在视口内');
    expect(beforeSwitchTop, lessThan(600));

    // 切到「没有后续轮」的 g2：活动链缩短，第 5/6 轮暂时看不到。
    await tester.tap(find.byKey(RoundVersionStepper.nextKey));
    await settle(tester);
    expect(provider.rounds, hasLength(4));
    expect(provider.rounds.last.roundIndex, 4);
    expect(stepperFinder, findsOneWidget);

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final beforeTop = tester.getTopLeft(stepperFinder).dy;
    final beforePixels = scrollable.position.pixels;
    expect(beforeTop, greaterThan(0), reason: '夹具前提：控件在视口内');
    expect(
      beforePixels,
      closeTo(scrollable.position.minScrollExtent, 0.5),
      reason: '夹具前提：切换前就贴在底部（正是会「跳到最底部」的场景）',
    );

    // 切回有后续轮的 r4：第 5/6 轮整段回来（远高于一屏）→ 必须补偿，
    // 不能停在新链的最底部（那样控件会被推到构建范围之外、直接消失）。
    await tester.tap(find.byKey(RoundVersionStepper.prevKey));
    await settle(tester);

    expect(provider.rounds, hasLength(6), reason: '后续轮随父代回来');
    expect(provider.rounds.last.roundIndex, 6);
    expect(stepperFinder, findsOneWidget, reason: '控件没被后续轮推出构建范围');
    final afterTop = tester.getTopLeft(stepperFinder).dy;
    expect(
      afterTop,
      closeTo(beforeTop, 1.0),
      reason: '控件留在切换前的位置（前 $beforeTop → 后 $afterTop）',
    );
    expect(
      scrollable.position.pixels,
      greaterThan(beforePixels + 1000),
      reason: '视图被抬到控件处，而不是留在一个新的最底部',
    );
  });
}
