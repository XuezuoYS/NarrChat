import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/chat_rail.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 对话页轮次定位回归：长书里跳到**未构建**的轮次时，落点必须由真实列表
/// 边界决定，不能把目标之后几十个估算行累计进偏移。
///
/// 修复前总是“围绕目标两侧建窗”，落点公式包含目标到窗口最新端之间的大量
/// 未实测行；懒加载没建到目标时，帧末复核也没有可用的真实高度，于是稳定在
/// 错的位置——越早的轮次偏得越多。

const int _roundCount = 80;

/// 播种长书并 pump 对话页。
///
/// [shortTailRound] 非空时把该轮正文改短，用于检查“跳到最新短轮时仍保留
/// 上方历史内容”（最新轮不能套用目标首行窗口）。
Future<void> _pumpLongThread(
  WidgetTester tester, {
  int count = _roundCount,
  int bodyRepeats = 40,
  int? shortTailRound,
}) async {
  final stack = (await tester.runAsync(TestStack.create))!;
  addTearDown(() => tester.runAsync(stack.dispose));
  await tester.runAsync(() async {
    await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
    for (var i = 1; i <= count; i++) {
      final repeats = i == shortTailRound ? 1 : bodyRepeats;
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: i,
        userInput: '第 $i 轮的用户输入',
        aiNarrative: '第 $i 轮的剧情正文。' * repeats,
      );
    }
  });
  await pumpChatScreen(tester, stack: stack, seedRounds: 0);
  await settle(tester);
}

/// 通过定位轨胶囊输入轮号并提交。
Future<void> _jumpToRoundByCapsule(
  WidgetTester tester, {
  required int roundIndex,
  required int maxRound,
}) async {
  if (find.byTooltip('顶部').evaluate().isEmpty) {
    await tester.tap(find.byKey(ChatRail.trackKey));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.textContaining('/ $maxRound', findRichText: true));
  await tester.pump();
  final field = find.descendant(
    of: find.byType(ChatRail),
    matching: find.byType(TextField),
  );
  expect(field, findsOneWidget, reason: '点胶囊页码进入内联输入');
  await tester.enterText(field, '$roundIndex');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await settle(tester);
}

/// 目标轮用户气泡顶边应贴住消息列表视口顶（允许气泡内边距的十几像素）。
void _expectRoundAtTop(WidgetTester tester, int roundIndex) {
  final target = find.text('第 $roundIndex 轮的用户输入');
  expect(target, findsOneWidget, reason: '跳转后目标轮必须真的被构建并可见');
  final roundTop = tester.getTopLeft(target).dy;
  final listTop = tester.getTopLeft(find.byType(ListView)).dy;
  expect(roundTop, greaterThanOrEqualTo(listTop - 1));
  expect(
    roundTop,
    lessThanOrEqualTo(listTop + 15),
    reason: '第 $roundIndex 轮应贴视口顶（实际偏差 ${roundTop - listTop}px）',
  );
}

void main() {
  // 参数化三个目标：
  // - 1：带 24dp 顶部留白的链首；
  // - 5：远在初始窗口之外的早期轮；
  // - 65：旧实现不会重建窗口（目标仍在初始 51..80 内）的未实测轮。
  for (final target in [1, 5, 65]) {
    testWidgets('长书跳第 $target 轮：目标贴合视口顶且页码同步', (tester) async {
      await _pumpLongThread(tester);

      await _jumpToRoundByCapsule(
        tester,
        roundIndex: target,
        maxRound: _roundCount,
      );

      _expectRoundAtTop(tester, target);
      expect(
        find.textContaining('$target / $_roundCount', findRichText: true),
        findsOneWidget,
        reason: '胶囊页码必须和实际落点同源',
      );
    });
  }

  testWidgets('先跳早期再跳最新短轮：最新轮贴尾，上方历史不被清空', (tester) async {
    await _pumpLongThread(tester, count: 50, shortTailRound: 50);

    await _jumpToRoundByCapsule(tester, roundIndex: 1, maxRound: 50);
    _expectRoundAtTop(tester, 1);

    await _jumpToRoundByCapsule(tester, roundIndex: 50, maxRound: 50);

    expect(find.text('第 50 轮的用户输入'), findsOneWidget, reason: '最新轮必须可见');
    expect(
      find.text('第 49 轮的用户输入'),
      findsOneWidget,
      reason: '最新轮较短时应保留贴尾窗口，上方历史不能被目标首行窗口裁掉',
    );
  });
}
