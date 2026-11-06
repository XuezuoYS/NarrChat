import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/branch_panel.dart';
import 'package:narrchat/providers/round_provider.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 对话页的分支 UI 接线：
/// - 顶栏入口显示当前分支名（默认「主线」）并能打开面板；
/// - AI 气泡「从这里分叉」真的调 `forkBranch`（错误代不给入口）；
/// - 非默认分支时链首出现分支头卡片，卡片能「回到主线」。
///
/// 面板内部行为（切换 / 改名 / 删除的交互细节）见 `branch_panel_test.dart`，
/// 本文件只测**跨层接线**。

/// 建库 → 播 2 轮 → pump 对话页（播种必须在 runAsync 里，见 chat_harness 说明）。
Future<RoundProvider> _pumpThread(
  WidgetTester tester, {
  Size size = const Size(1400, 900),
  int rounds = 2,
}) async {
  final stack = (await tester.runAsync(TestStack.create))!;
  addTearDown(() => tester.runAsync(stack.dispose));
  await tester.runAsync(() async {
    await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
    for (var i = 1; i <= rounds; i++) {
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: i,
        userInput: '第 $i 轮的用户输入',
        aiNarrative: '第 $i 轮的剧情正文。' * 20,
      );
    }
  });
  return pumpChatScreen(tester, stack: stack, seedRounds: 0, size: size);
}

void main() {
  testWidgets('顶栏分支入口显示「主线」，点开出现分支面板', (tester) async {
    final provider = await _pumpThread(tester);
    await settle(tester);

    expect(provider.workingBranchUuid, '');
    final entry = find.byKey(const ValueKey('chat-branch-entry'));
    expect(entry, findsOneWidget);
    expect(
      find.descendant(of: entry, matching: find.text('主线')),
      findsOneWidget,
      reason: '默认分支显示为「主线」',
    );

    await tester.tap(entry);
    await settle(tester);
    expect(find.byType(BranchPanel), findsOneWidget, reason: '点开应弹出分支面板');
  });

  testWidgets('AI 气泡「从这里分叉」真的建分支并切过去', (tester) async {
    final provider = await _pumpThread(tester);
    await settle(tester);

    final forkedFrom = provider.rounds.last.roundIndex;
    final fork = find.text('从这里分叉');
    expect(fork, findsWidgets, reason: '正常代应有分叉入口');
    await tester.tap(fork.first);
    await settle(tester);

    expect(provider.branches.length, 2, reason: '默认分支 + 新分叉');
    expect(provider.workingBranchUuid, isNotEmpty, reason: '分叉后应切到新分支');
    expect(provider.currentBranch?.fatherRowIndex, forkedFrom,
        reason: '从被点的那条 AI 气泡（视觉最下方 = 最新一轮）分叉');
  });

  testWidgets('错误代没有分叉入口', (tester) async {
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    await tester.runAsync(() async {
      await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        userInput: '断线那一次',
        message: '连接超时',
        messageStatus: 'error',
      );
    });
    await pumpChatScreen(tester, stack: stack, seedRounds: 0);
    await settle(tester);

    expect(find.text('从这里分叉'), findsNothing, reason: '错误代不给分叉入口');
  });

  testWidgets('非默认分支：链首出现分支头卡片，可回到主线', (tester) async {
    final provider = await _pumpThread(tester);
    await settle(tester);

    final firstRound = provider.rounds.first;
    final branchUuid = await tester.runAsync(
      () => provider.forkBranch(round: firstRound, title: '如果线'),
    );
    await tester.runAsync(() => provider.loadRounds(kHarnessBookUuid));
    await settle(tester);

    expect(branchUuid, isNotNull);
    final card = find.byKey(const ValueKey('chat-branch-header-card'));
    expect(card, findsOneWidget, reason: '非默认分支应在链首显示分支头卡片');
    expect(find.text('如果线'), findsWidgets);
    expect(find.text('从第 1 轮分叉'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-branch-header-back')));
    await settle(tester);

    expect(provider.workingBranchUuid, '');
    expect(
      find.byKey(const ValueKey('chat-branch-header-card')),
      findsNothing,
      reason: '回到主线后卡片消失',
    );
  });
}
