import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/widgets/action_button.dart';
import 'package:narrchat/widgets/chat_bubble.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 生成中气泡的**落点轮号**。
///
/// 回归背景：R3 起「刷新本轮 / 修改并重新提问 / 按意见修改」不再先删投影行，
/// 而是在同轮新增一代；待定气泡若仍按「链尾 +1」摆放，刷新第 N 轮会先在末尾
/// 冒出「第 N+1 轮正在生成」，旧代与后续轮也一直挂到生成结束——停止后才并回
/// 第 N 轮。这里钉住：待定气泡就在目标轮的位置，生成期间视图按目标轮截断。
///
/// 生成期间有无限转圈动画，**不能 pumpAndSettle**；等待收尾统一用
/// [waitSendDone] / [finishStream]。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  /// 生成中页眉。
  Finder generatingHeader(int roundIndex) =>
      find.text('第 $roundIndex 轮 · 正在生成中……');

  /// 某一轮 AI 气泡底部的「刷新本轮」按钮。
  Finder refreshButtonOf(int roundIndex) => find.descendant(
        of: find.ancestor(
          of: find.text('第 $roundIndex 轮的剧情正文。'),
          matching: find.byType(ChatBubble),
        ),
        matching: find.ancestor(
          of: find.text('刷新本轮'),
          matching: find.byType(ActionButton),
        ),
      );

  /// 等生成真正开始（真库 I/O 要真实事件循环），再推一帧确认框退场。
  Future<void> pumpUntilGenerating(
    WidgetTester tester,
    RoundProvider provider,
  ) async {
    for (var i = 0; i < 30 && !provider.isSending; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(provider.isSending, isTrue, reason: '前提：生成已经开始');
    // 确认框退场 + 待定气泡首帧；不做 pumpAndSettle（转圈动画永不结束）。
    await tester.pump(const Duration(milliseconds: 320));
  }

  testWidgets('刷新链尾轮：生成中气泡就在被刷新轮，不会冒充下一轮', (tester) async {
    final ai = FakeStreamingAiService();
    final rp = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 3,
      seedBodyRepeats: 1,
    );

    // 走真实入口：气泡底部「刷新本轮」→ 二次确认 → 继续。
    await tester.tap(refreshButtonOf(3));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget, reason: '刷新仍要二次确认');
    expect(find.textContaining('将重新生成第 3 轮'), findsOneWidget);

    await tester.tap(find.text('继续'));
    await pumpUntilGenerating(tester, rp);

    expect(generatingHeader(3), findsOneWidget);
    expect(
      generatingHeader(4),
      findsNothing,
      reason: '链尾 +1 是修复前的错误落点',
    );
    expect(
      find.text('第 3 轮的剧情正文。'),
      findsNothing,
      reason: '被刷新的旧代在生成期间隐藏',
    );
    expect(
      find.text('第 3 轮的用户输入'),
      findsOneWidget,
      reason: '只保留待定用户气泡，旧代不与之并列',
    );

    ai.complete();
    await waitSendDone(tester, rp);

    expect(rp.rounds.length, 3, reason: '同轮换代，链长不变');
    expect(rp.versionInfoFor(3)!.aliveCount, 2, reason: '同轮新增一代');
    expect(find.text('第 3 轮'), findsOneWidget, reason: '完成后收敛为真实气泡页眉');
    expect(find.text('第 3 轮的剧情正文。'), findsNothing, reason: '链上已是新代');
    expect(find.textContaining('流式生成的最终正文'), findsOneWidget);
  });

  testWidgets('刷新中间轮：后续轮次在生成期间就隐藏，完成后链停在该轮', (tester) async {
    final ai = FakeStreamingAiService();
    final rp = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 3,
      seedBodyRepeats: 1,
    );

    final done = rp.refreshRound(rp.rounds[1], book: book);
    await tester.pump();
    await tester.pump();

    expect(generatingHeader(2), findsOneWidget);
    expect(
      find.text('第 3 轮的用户输入'),
      findsNothing,
      reason: '后续轮次随目标轮一起隐藏，不等生成结束才消失',
    );
    expect(find.text('第 2 轮的剧情正文。'), findsNothing, reason: '目标轮旧代隐藏');
    expect(find.text('第 1 轮的用户输入'), findsOneWidget, reason: '目标轮之前保留');

    ai.complete();
    await waitSendDone(tester, rp);
    await done;

    expect(rp.rounds.map((r) => r.roundIndex).toList(), [1, 2]);
    expect(rp.versionInfoFor(2)!.aliveCount, 2, reason: '第 2 轮同组新增一代');
  });

  testWidgets('刷新后停止：错误代落在被刷新轮，不会多出下一轮', (tester) async {
    final ai = FakeStreamingAiService();
    final rp = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 2,
      seedBodyRepeats: 1,
    );

    final done = rp.refreshRound(rp.rounds[1], book: book);
    await tester.pump();
    await tester.pump();
    expect(generatingHeader(2), findsOneWidget);

    rp.cancelGeneration();
    ai.complete();
    await waitSendDone(tester, rp);
    await done;

    expect(
      rp.rounds.map((r) => r.roundIndex).toList(),
      [1, 2],
      reason: '停止不会另起第 3 轮',
    );
    expect(rp.rounds.last.isError, isTrue, reason: '中断落一条错误代');
    expect(rp.rounds.last.message, '已中断');
    expect(generatingHeader(2), findsNothing);
    expect(find.text('第 2 轮'), findsOneWidget, reason: '错误代页眉仍是被刷新轮');
  });

  testWidgets('普通发送新一轮：生成中气泡仍落在链尾 +1（不回归）', (tester) async {
    final ai = FakeStreamingAiService();
    final rp = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 2,
      seedBodyRepeats: 1,
    );

    final done = rp.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    await tester.pump();

    expect(generatingHeader(3), findsOneWidget, reason: '新一轮 = 链尾 +1');
    expect(
      find.text('第 2 轮的用户输入'),
      findsOneWidget,
      reason: '新一轮不隐藏已有轮次（截断只针对重新生成）',
    );

    ai.complete();
    await waitSendDone(tester, rp);
    expect(await done, isTrue);
    expect(rp.rounds.map((r) => r.roundIndex).toList(), [1, 2, 3]);
  });

  testWidgets('按意见修改：生成中气泡落在被重写的轮号', (tester) async {
    final ai = FakeStreamingAiService();
    final rp = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 1,
      seedBodyRepeats: 1,
    );

    final done = rp.modifyRoundByOpinion(
      rp.rounds.single,
      '写紧凑些',
      book: book,
    );
    await tester.pump();
    await tester.pump();

    expect(generatingHeader(1), findsOneWidget);
    expect(
      find.text('第 1 轮的剧情正文。'),
      findsNothing,
      reason: '被重写轮的旧代在生成期间隐藏',
    );

    ai.complete();
    await waitSendDone(tester, rp);
    expect(await done, isTrue);
    expect(rp.versionInfoFor(1)!.aliveCount, 2, reason: '同轮新增一代');
  });
}
