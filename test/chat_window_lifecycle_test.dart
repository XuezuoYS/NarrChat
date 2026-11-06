import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 对话页「链换了以后不能空白」的回归用例。
///
/// 历史 bug：窗口没有按书 / 分支重置。链变短时 `ChatWindowController
/// .setTotalRounds` 算出负 delta，只把 `lastRoundIndex` 夹回新总数、
/// `firstRoundIndex` 不动 → 窗口倒置（如 `(91..10)`）→ 窗口内一层轮次都查不到 →
/// 整页空白，而几何总高 0 又让右侧轨道显形（主人看到的「突然一本书只有轨道」）。
///
/// 两条真实触发路径各覆盖一条：
/// 1. 换书：全局 provider 里还留着上一本书的长链，新页面首帧先用它建窗；
/// 2. 切分支：主链 60 轮，切到早期分叉且只有 1 轮的分支。
void main() {
  const longBook = 'book-long';
  const shortBook = 'book-short';

  testWidgets('换书：上一本书的长链还在 provider 里，新书首帧不能空白', (tester) async {
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    late String shortUuid;
    await tester.runAsync(() async {
      await stack.seedBook(uuid: longBook, title: '长书');
      await stack.seedRounds(longBook, count: 120, bodyRepeats: 1);
      shortUuid = await stack.seedBook(uuid: shortBook, title: '短书');
      await stack.seedRounds(shortUuid, count: 3, bodyRepeats: 2);
    });

    await pumpChatScreen(
      tester,
      stack: stack,
      preloadRounds: false,
      beforePump: (rounds, books) async {
        // 真实路径（书列表点击进入 / 通知跳转）：全局 provider 里留着上一本书的
        // 活动链（长书 120 轮），而新页面的 currentBook 已经是短书。
        await rounds.loadRounds(longBook);
        books.selectBook(books.books.firstWhere((b) => b.uuid == shortUuid));
      },
    );
    await settle(tester);

    expect(
      find.text('第 3 轮的用户输入'),
      findsOneWidget,
      reason: '短书的最新一轮必须上屏（整页空白 = 窗口倒置的旧 bug）',
    );
    expect(find.textContaining('创作，从这里开始'), findsNothing);
    expect(
      find.textContaining('第 120 轮的剧情正文'),
      findsNothing,
      reason: '不能把上一本书的正文渲染出来',
    );
  });

  testWidgets('切到早期短分支：分支正文可见，不是只剩一张分支头卡片', (tester) async {
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    final provider = await pumpChatScreen(
      tester,
      stack: stack,
      seedRounds: 60,
      seedBodyRepeats: 2,
    );
    await settle(tester);

    final forkPoint = provider.rounds[2];
    final branchUuid = await tester.runAsync(
      () => provider.forkBranch(round: forkPoint, title: '如果线'),
    );
    expect(branchUuid, isNotNull);
    await tester.runAsync(() async {
      // 分支上补一轮：主链 60 轮 → 分支只有 1 轮，正是负 delta 的场景。
      // 分支首轮是**链首**（father_uuid 为空，靠分支行的 father_snapshot 兜上下文），
      // 所以这里不传 fatherUuid。
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: forkPoint.roundIndex + 1,
        branchUuid: branchUuid!,
        userInput: '分支的用户输入',
        aiNarrative: '分支的剧情正文。',
      );
      await provider.loadRounds(kHarnessBookUuid);
    });
    await settle(tester);

    expect(provider.workingBranchUuid, branchUuid);
    expect(
      find.text('分支的用户输入'),
      findsOneWidget,
      reason: '主链 60 轮 → 分支 1 轮时窗口必须按新链重建，不能倒置',
    );
    expect(
      find.byKey(const ValueKey('chat-branch-header-card')),
      findsOneWidget,
      reason: '非默认分支的链首卡片照旧',
    );
  });
}
