import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/widgets/action_button.dart';
import 'package:narrchat/widgets/ai_bubble_actions.dart';
import 'package:narrchat/widgets/composer_input_mode.dart';
import 'package:narrchat/widgets/round_version_stepper.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// AI 气泡「按意见修改」的 UI 入口测试（灰条复用 + 落库口径）。
///
/// 形态与「刷新本轮 / 修改并重新提问」一致：灰条亮起 → 填写意见 → 二次确认 →
/// 同轮新增一代（旧代留在版本树，代次控件可切回）。
void main() {
  /// 主输入框（按占位文案定位，与 chat_composer_test 一致）。
  Finder composerField() => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == '输入你的行动或对话…',
  );

  Finder modeBar() => find.byKey(ComposerInputModeBar.barKey);
  Finder sendButton() => find.ancestor(
    of: find.byIcon(Icons.arrow_upward),
    matching: find.byType(IconButton),
  );

  Finder modifyButton() =>
      find.ancestor(of: find.text('按意见修改'), matching: find.byType(ActionButton));

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(composerField()).controller!.text;

  /// 走完一次「按意见修改」：填意见 → 发送 → 确认 → 等生成收尾。
  Future<void> submitOpinion(
    WidgetTester tester,
    RoundProvider provider,
    String opinion,
  ) async {
    await tester.enterText(composerField(), opinion);
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pumpAndSettle();
    expect(find.textContaining('将删除本轮及之后的所有轮次'), findsOneWidget);
    await tester.tap(find.text('继续'));
    await tester.pump();
    await waitSendDone(tester, provider);
  }

  testWidgets('底部按钮：按意见修改紧邻「刷新本轮」右侧一位', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    final labels = tester
        .widgetList<ActionButton>(
          find.descendant(
            of: find.byType(AiBubbleActions),
            matching: find.byType(ActionButton),
          ),
        )
        .map((b) => b.label)
        .toList();

    expect(labels, contains('刷新本轮'));
    expect(labels, contains('按意见修改'));
    // 位置口径：就在「刷新本轮」右侧一位（删除本轮仍在最后）。
    expect(labels.indexOf('按意见修改'), labels.indexOf('刷新本轮') + 1);
    expect(labels.indexOf('删除本轮'), greaterThan(labels.indexOf('按意见修改')));

    // 几何口径：同一行、在「刷新本轮」右侧。
    final refresh = tester.getCenter(find.text('刷新本轮'));
    final modify = tester.getCenter(find.text('按意见修改'));
    expect(modify.dy, closeTo(refresh.dy, 0.5), reason: '同一行');
    expect(modify.dx, greaterThan(refresh.dx), reason: '在刷新本轮右侧');
  });

  testWidgets('底部按钮入口：灰条亮起、输入框留空（只填意见）', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    await tester.tap(modifyButton());
    await tester.pumpAndSettle();

    expect(modeBar(), findsOneWidget);
    expect(find.text('按意见修改（第 1 轮）'), findsOneWidget);
    expect(fieldText(tester), '');
  });

  testWidgets('气泡右键菜单含「按意见修改」，点击后灰条亮起', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    await tester.longPress(find.text('第 1 轮的剧情正文。'));
    await tester.pumpAndSettle();

    // 菜单项口径：AI 气泡菜单里确有 value='modify' 的那一项。
    final modifyItem = find.byWidgetPredicate(
      (w) => w is PopupMenuItem<String> && w.value == 'modify',
    );
    expect(modifyItem, findsOneWidget);

    await tester.tap(
      find.descendant(of: modifyItem, matching: find.text('按意见修改')),
    );
    await tester.pumpAndSettle();

    expect(find.text('按意见修改（第 1 轮）'), findsOneWidget);
    expect(fieldText(tester), '');
  });

  testWidgets('提交：二次确认后同轮新增一代；原输入 / 原图沿用，意见只进请求', (tester) async {
    final rp = await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    await tester.tap(modifyButton());
    await tester.pumpAndSettle();
    await tester.enterText(composerField(), '把这段写紧凑些');
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pumpAndSettle();
    expect(find.textContaining('将删除本轮及之后的所有轮次'), findsOneWidget);
    await tester.tap(find.text('继续'));
    await tester.pump();
    await waitSendDone(tester, rp);

    // 同轮号新增一代：第 1 轮仍是第 1 轮，正文换成新生成的内容。
    final updated = rp.rounds.last;
    expect(updated.roundIndex, 1);
    expect(updated.aiNarrative, contains('成功正文'));
    // 内容与修改前一致：原输入沿用（意见不落库）。
    expect(updated.userInput, '第 1 轮的用户输入');
    // 实发报文 = 修改轮注入：重写第 1 轮 + 意见。
    final raw = rp.rawExchangesFor(updated.id!)!.single.requestBody;
    expect(raw, contains('重写第 1 轮：'));
    expect(raw, contains('把这段写紧凑些'));
    // 用途已消费：灰条收起、输入框清空。
    expect(modeBar(), findsNothing);
    expect(fieldText(tester), '');
  });

  testWidgets('确认框取消：不发请求，灰条与已填意见保留', (tester) async {
    final rp = await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    await tester.tap(modifyButton());
    await tester.pumpAndSettle();
    await tester.enterText(composerField(), '把这段写紧凑些');
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(rp.rounds.last.aiNarrative, contains('第 1 轮的剧情正文'));
    expect(modeBar(), findsOneWidget);
    expect(fieldText(tester), '把这段写紧凑些');
  });

  testWidgets('意见为空：发送键置灰、不弹确认框', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    await tester.tap(modifyButton());
    await tester.pumpAndSettle();

    expect(tester.widget<IconButton>(sendButton()).onPressed, isNull);

    await tester.tap(sendButton(), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.textContaining('将删除本轮及之后的所有轮次'), findsNothing);
    expect(modeBar(), findsOneWidget);
  });

  testWidgets('多次修改后出现代次控件（与刷新本轮同一套 ← / → 口径）', (tester) async {
    final dao = FakeRoundDao();
    final stack = FakeRoundStackService(roundDao: dao);
    final rp = await pumpChatScreen(
      tester,
      roundDao: dao,
      roundStackService: stack,
      seedRounds: 1,
      seedBodyRepeats: 1,
    );

    // 第一次修改：只有单代 → 不显示控件。
    await tester.tap(modifyButton());
    await tester.pumpAndSettle();
    await submitOpinion(tester, rp, '第一版意见');
    expect(find.byKey(RoundVersionStepper.stepperKey), findsNothing);

    // 第二次修改：同分组新增一代 → 出现控件，当前 = 最新（2/2）。
    await tester.tap(modifyButton());
    await tester.pumpAndSettle();
    await submitOpinion(tester, rp, '第二版意见');

    expect(find.byKey(RoundVersionStepper.stepperKey), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);

    // ← 走真实切换入口（投影重建由 RoundStackService 负责，其语义另有真库用例覆盖）。
    await tester.tap(find.byKey(RoundVersionStepper.prevKey));
    await tester.pumpAndSettle();
    expect(stack.switches, hasLength(1));
    expect(stack.switches.single.roundIndex, 1);
    expect(rp.rounds.last.roundIndex, 1);
  });
}
