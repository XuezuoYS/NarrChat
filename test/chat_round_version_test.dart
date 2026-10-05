import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/round_stack.dart';
import 'package:narrchat/widgets/failed_attempt_bubble.dart';
import 'package:narrchat/widgets/round_version_stepper.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 对话页「代次控件」集成契约（UI-1 / UI-3 / UI-5）。
///
/// 版本树服务用内存替身：控件显隐 / 切换编排 / 草稿与滚动行为都可在不落库的
/// 前提下断言；真实版本树语义由 `round_stack_service_test.dart`（真库）覆盖。
void main() {
  /// 预置：第 0 轮 + 第 1 轮（当前代 g1，另有闲置代 g2）。
  Future<({FakeRoundDao dao, FakeRoundStackService stack})> seedTwoVersions() async {
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(bookUuid: kHarnessBookUuid, roundIndex: 0, createdAt: DateTime.now()),
    );
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        userInput: '第一轮输入',
        aiNarrative: '第一代正文。' * 40,
        createdAt: DateTime.now(),
        useStackUuid: 'g1',
      ),
    );
    final stack = FakeRoundStackService(roundDao: dao)
      ..metas = [
        const RoundStackMeta(
          uuid: 'g1',
          bookUuid: kHarnessBookUuid,
          roundIndex: 1,
          roundSerialNum: 1,
          roundState: 'use',
        ),
        const RoundStackMeta(
          uuid: 'g2',
          bookUuid: kHarnessBookUuid,
          roundIndex: 1,
          roundSerialNum: 2,
        ),
      ];
    return (dao: dao, stack: stack);
  }

  testWidgets('UI-1 ≥2 存活代显示控件：x/y 与存活代一致，单代不显示', (tester) async {
    final seed = await seedTwoVersions();
    final provider = await pumpChatScreen(
      tester,
      roundDao: seed.dao,
      roundStackService: seed.stack,
    );

    expect(find.byKey(RoundVersionStepper.stepperKey), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget, reason: '当前代 1 / 最新存活代 2');

    // 只剩一代（清掉 metas）→ 控件消失。
    seed.stack.metas = [
      const RoundStackMeta(
        uuid: 'g1',
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        roundSerialNum: 1,
        roundState: 'use',
      ),
    ];
    await provider.loadRounds(kHarnessBookUuid);
    await tester.pumpAndSettle();

    expect(find.byKey(RoundVersionStepper.stepperKey), findsNothing);
  });
  testWidgets('UI-3 切换：只切版本（不生成长文、不滚到底），草稿保留并给出提示', (tester) async {
    final seed = await seedTwoVersions();
    final provider = await pumpChatScreen(
      tester,
      roundDao: seed.dao,
      roundStackService: seed.stack,
      seedBodyRepeats: 40,
    );
    // 视口内先滚动到中间位置：切换不得把视图拉到底部。
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    final beforeOffset = tester
        .widget<Scrollable>(find.byType(Scrollable).first)
        .controller!
        .offset;
    final roundsBefore = seed.dao.rounds.length;

    // 草稿：切换不得清空主输入框。
    await tester.enterText(find.byType(EditableText).first, '草稿不该被清');
    await tester.pump();

    await tester.tap(find.byKey(RoundVersionStepper.nextKey));
    await tester.pumpAndSettle();

    expect(seed.stack.switches, hasLength(1));
    expect(seed.stack.switches.single.targetUuid, 'g2');
    expect(seed.stack.switches.single.roundIndex, 1);
    expect(
      seed.dao.rounds.length,
      roundsBefore,
      reason: '切换不新增/不删除轮次（投影重建由服务负责）',
    );
    expect(provider.isSending, isFalse, reason: '切换不发起生成');
    expect(find.text('草稿不该被清'), findsOneWidget, reason: '草稿保留');
    expect(
      find.textContaining('已切换到第'),
      findsNothing,
      reason: '切换直接生效，不弹提示',
    );
    expect(
      tester
          .widget<Scrollable>(find.byType(Scrollable).first)
          .controller!
          .offset,
      closeTo(beforeOffset, 0.5),
      reason: '切换不滚动（视图停在父）',
    );
  });

  testWidgets('UI-3b 切换后「视图停在切换控件」：正文变长也不让控件漂出视口', (tester) async {
    // 5 轮：切换目标在第 2 轮，其下仍有轮次 → 有下滚余量（列表底部除外）。
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(bookUuid: kHarnessBookUuid, roundIndex: 0, createdAt: DateTime.now()),
    );
    for (var i = 1; i <= 4; i++) {
      await dao.insertRound(
        Round(
          bookUuid: kHarnessBookUuid,
          roundIndex: i,
          userInput: '第 $i 轮的用户输入',
          aiNarrative: '第 $i 轮正文。' * 40,
          createdAt: DateTime.now(),
          useStackUuid: i == 2 ? 'g1' : '',
        ),
      );
    }
    final stack = FakeRoundStackService(roundDao: dao)
      ..metas = [
        const RoundStackMeta(
          uuid: 'g1',
          bookUuid: kHarnessBookUuid,
          roundIndex: 2,
          roundSerialNum: 1,
          roundState: 'use',
        ),
        const RoundStackMeta(
          uuid: 'g2',
          bookUuid: kHarnessBookUuid,
          roundIndex: 2,
          roundSerialNum: 2,
        ),
      ];
    final provider = await pumpChatScreen(
      tester,
      roundDao: dao,
      roundStackService: stack,
      size: const Size(1400, 900),
    );

    // 向上滚到第 2 轮的代次控件可见（且不在列表底部，仍有下滚余量）。
    final stepperFinder = find.byKey(RoundVersionStepper.stepperKey);
    for (var i = 0; i < 10 && stepperFinder.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();
    }
    // 再把控件往下带一点，避免贴视口顶、并留出上下余量。
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();
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
      scrollable.position.maxScrollExtent - scrollable.position.pixels,
      greaterThan(50),
      reason: '夹具前提：切换前不在列表底部（否则无法向下补偿滚动）',
    );

    // 切换「落地」为超长正文（模拟真实投影重建后的高度变化）。
    stack.onSwitch = (bookUuid, roundIndex, targetUuid) {
      final index = dao.rounds.indexWhere(
        (r) => r.bookUuid == bookUuid && r.roundIndex == roundIndex,
      );
      dao.rounds[index] = dao.rounds[index].copyWith(
        aiNarrative: '切换后变长很多的正文。' * 200,
        useStackUuid: targetUuid,
      );
    };

    await tester.tap(find.byKey(RoundVersionStepper.nextKey));
    await tester.pumpAndSettle();

    expect(
      dao.rounds.firstWhere((r) => r.roundIndex == 2).aiNarrative.length,
      greaterThan(1000),
      reason: '夹具：切换确实换上了更长正文',
    );
    final afterTop = tester.getTopLeft(
      find.byKey(RoundVersionStepper.stepperKey),
    ).dy;    expect(
      (afterTop - beforeTop).abs(),
      lessThan(2),
      reason: '按控件锚点补偿滚动：控件应停在切换前的位置（前 $beforeTop → 后 $afterTop）',
    );
    expect(
      afterTop,
      greaterThan(0),
      reason: '控件仍在视口内（未被正文长度变化挤出）',
    );
    expect(provider.isSending, isFalse);
  });

  testWidgets('UI-5 失败气泡：只给「← 还原上一代」，右箭头禁用；还原后红条消失', (tester) async {
    final seed = await seedTwoVersions();
    final ai = ToggleAiService();
    final provider = await pumpChatScreen(
      tester,
      roundDao: seed.dao,
      roundStackService: seed.stack,
      ai: ai,
    );
    expect(find.byKey(RoundVersionStepper.stepperKey), findsOneWidget);

    // 「刷新本轮」失败：投影被删（旧代仍在版本树）→ 红条 + 可还原。
    ai.fail = true;
    await provider.refreshRound(provider.rounds.last, book: provider.rounds.isEmpty ? null : const Book(uuid: kHarnessBookUuid, title: '测试书'));
    await tester.pumpAndSettle();

    expect(provider.hasFailureEntry, isTrue);
    expect(find.byType(FailedAttemptBubble), findsOneWidget);
    expect(find.text('临时'), findsOneWidget, reason: '失败态是临时代');
    final prev = tester.widget<IconButton>(
      find.byKey(RoundVersionStepper.prevKey),
    );
    final next = tester.widget<IconButton>(
      find.byKey(RoundVersionStepper.nextKey),
    );
    expect(prev.onPressed, isNotNull, reason: '可还原上一代');
    expect(next.onPressed, isNull, reason: '失败态没有「下一代」');

    await tester.tap(find.byKey(RoundVersionStepper.prevKey));
    await tester.pumpAndSettle();

    expect(seed.stack.switches.single.targetUuid, 'g1');
    expect(provider.hasFailureEntry, isFalse, reason: '还原即清除失败态');
    expect(find.byType(FailedAttemptBubble), findsNothing, reason: '红条消失');
  });
}
