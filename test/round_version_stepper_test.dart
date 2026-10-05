import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/action_button.dart';
import 'package:narrchat/widgets/round_version_stepper.dart';

/// [RoundVersionStepper] 组件契约（UI-1 / UI-2）：
/// 文案与显隐口径、禁用态、以及「自身不换行 + 极窄视口不溢出」。
void main() {
  Future<void> pumpStepper(
    WidgetTester tester,
    Widget stepper, {
    Size size = const Size(320, 200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft, child: stepper))),
    );
  }

  testWidgets('UI-1 显示 x/y；current 为 null 显示「临时」', (tester) async {
    await pumpStepper(
      tester,
      RoundVersionStepper(current: 2, latest: 5, onPrev: () {}, onNext: () {}),
    );
    expect(find.text('2/5'), findsOneWidget, reason: 'y 取最新存活代号（可跳步）');

    await pumpStepper(
      tester,
      RoundVersionStepper(current: null, latest: 3, onPrev: () {}),
    );
    expect(find.text('临时'), findsOneWidget);
    expect(find.text('0/3'), findsNothing);
  });

  testWidgets('UI-1 禁用态：enabled=false 或回调为 null 时箭头不可点', (tester) async {
    await pumpStepper(
      tester,
      RoundVersionStepper(current: 1, latest: 1, enabled: false, onPrev: () {}),
    );
    final prev = tester.widget<IconButton>(
      find.byKey(RoundVersionStepper.prevKey),
    );
    expect(prev.onPressed, isNull, reason: '生成中整体置灰');

    await pumpStepper(
      tester,
      RoundVersionStepper(current: 1, latest: 2, onNext: () {}),
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(RoundVersionStepper.prevKey))
          .onPressed,
      isNull,
      reason: '没有上一代 → 左箭头禁用',
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(RoundVersionStepper.nextKey))
          .onPressed,
      isNotNull,
    );
    expect(find.byKey(RoundVersionStepper.stepperKey), findsOneWidget);
  });

  testWidgets('UI-2 极窄视口（320）下控件不溢出，且恒在 Wrap 第一行、自身不换行', (tester) async {
    final stepper = RoundVersionStepper(
      current: 12,
      latest: 34,
      onPrev: () {},
      onNext: () {},
    );
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: Wrap(
              spacing: 2,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                stepper,
                // 其余按钮允许换行到第二 / 第三行。
                for (var i = 0; i < 6; i++)
                  ActionButton(
                    icon: Icons.view_sidebar_outlined,
                    label: '很长的按钮名称 $i',
                    onPressed: () {},
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // 无溢出异常（overlap / overflow 会在测试中抛错，此处显式确认渲染完成）。
    expect(tester.takeException(), isNull);

    final stepperRect = tester.getRect(
      find.byKey(RoundVersionStepper.stepperKey),
    );
    final firstButtonRect = tester.getRect(find.byType(ActionButton).first);
    expect(
      (stepperRect.center.dy - firstButtonRect.center.dy).abs() < 0.5,
      isTrue,
      reason: '控件必须与其它按钮同一行（Wrap 首项，垂直居中对齐）',
    );
    expect(stepperRect.left, lessThanOrEqualTo(firstButtonRect.left));
    expect(stepperRect.width, lessThanOrEqualTo(132 + 0.5), reason: '整体限宽防溢出');
    expect(
      stepperRect.width,
      lessThan(320),
      reason: '限宽 + FittedBox 保证窄视口下不横向溢出',
    );
  });
}
