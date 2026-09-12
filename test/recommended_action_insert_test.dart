import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/widgets/recommended_action_view.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 双击「推荐下一步」选项 → 写入主输入框（**不发送**）：落点三分支 + 焦点收尾。
///
/// 与 `chat_bubble_test.dart`（组件层：手势与回调）分工：本文件验证对话页把
/// 回调接到主输入框后的实际效果（文本 / 光标 / 焦点 / 未触发发送）。
void main() {
  const action = '1. 上前行礼\n2. 询问掌门\n3. 自定义行动';

  /// 预置一条带推荐行动的轮次并 pump 对话页，返回主输入框的控制器与焦点。
  Future<({TextEditingController controller, FocusNode focus, RoundProvider rounds})>
      pumpWithAction(WidgetTester tester) async {
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        userInput: '我踏入青云宗。',
        aiNarrative: '山门巍峨。',
        recommendedAction: action,
        currentTime: '第一天 午时',
        createdAt: DateTime.now(),
      ),
    );
    final rounds = await pumpChatScreen(tester, roundDao: dao, seedBodyRepeats: 1);
    // 输入框为空时 hint 可见，据此定位主输入框（侧边栏编辑框不匹配该 hint）。
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, '输入你的行动或对话…'),
    );
    return (
      controller: field.controller!,
      focus: field.focusNode!,
      rounds: rounds,
    );
  }

  /// 推荐行动区块内的选项文本（Markdown 渲染为 RichText）。
  Finder optionText(String text) => find.descendant(
        of: find.byType(RecommendedActionView),
        matching: find.text(text, findRichText: true),
      );

  /// 鼠标双击选项（同一位置两次点击，间隔在双击窗口内）。
  Future<void> doubleTap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(finder, kind: PointerDeviceKind.mouse);
    // 越过后一个双击判定窗口：让识别器计时器收敛（测试结束不得残留计时器）。
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('空输入：双击选项直接置入，光标落在末尾且聚焦（不发送）', (tester) async {
    final t = await pumpWithAction(tester);
    expect(t.controller.text, isEmpty);

    await doubleTap(tester, optionText('上前行礼'));

    expect(t.controller.text, '上前行礼');
    expect(t.controller.selection, const TextSelection.collapsed(offset: 4));
    expect(t.focus.hasFocus, isTrue, reason: '插入后焦点交回输入框');
    expect(t.rounds.isSending, isFalse, reason: '仅写入输入框，不触发发送');
    expect(t.rounds.rounds, hasLength(1), reason: '未产生新轮次');
  });

  testWidgets('有文本且无光标：追加到已输入文本末尾', (tester) async {
    final t = await pumpWithAction(tester);
    // 程序化赋值 = 无光标（选择区无效，如草稿恢复后从未聚焦）。
    t.controller.text = '我走向主殿。';
    await tester.pump();

    await doubleTap(tester, optionText('询问掌门'));

    expect(t.controller.text, '我走向主殿。询问掌门');
    expect(t.controller.selection, const TextSelection.collapsed(offset: 10));
    expect(t.rounds.isSending, isFalse);
  });

  testWidgets('有文本且有光标：在光标所在处插入（不追加到末尾）', (tester) async {
    final t = await pumpWithAction(tester);
    t.controller.value = const TextEditingValue(
      text: '我走向主殿。',
      selection: TextSelection.collapsed(offset: 2),
    );
    await tester.pump();

    await doubleTap(tester, optionText('上前行礼'));

    expect(t.controller.text, '我走上前行礼向主殿。');
    expect(t.controller.selection, const TextSelection.collapsed(offset: 6));
    expect(t.rounds.isSending, isFalse);
  });

  testWidgets('双击末条「自定义行动」：不写入文本，仅聚焦输入框', (tester) async {
    final t = await pumpWithAction(tester);
    t.controller.text = '我走向主殿。';
    await tester.pump();

    await doubleTap(tester, optionText('自定义行动'));

    expect(t.controller.text, '我走向主殿。', reason: '不写入「自定义行动」字样');
    expect(t.focus.hasFocus, isTrue, reason: '只把焦点交给输入框，由用户自行输入');
    expect(t.rounds.isSending, isFalse);
  });
}
