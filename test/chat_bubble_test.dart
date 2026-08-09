import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/chat_bubble.dart';

void main() {
  Widget buildBubble({required VoidCallback onMenu}) {
    return MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(
        body: Center(
          child: ChatBubble(
            isUser: false,
            text: '测试消息内容',
            onContextMenu: (_) => onMenu(),
          ),
        ),
      ),
    );
  }

  testWidgets('触屏长按（不移动）触发上下文菜单', (tester) async {
    var menuCount = 0;
    await tester.pumpWidget(buildBubble(onMenu: () => menuCount++));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('测试消息内容')),
      kind: PointerDeviceKind.touch,
    );
    // 超过 500ms 长按阈值。
    await tester.pump(const Duration(milliseconds: 600));
    expect(menuCount, 1);
    await gesture.up();
    await tester.pump();
    expect(menuCount, 1);
  });

  testWidgets('触屏上下滑动（手指不抬起）不触发上下文菜单', (tester) async {
    var menuCount = 0;
    await tester.pumpWidget(buildBubble(onMenu: () => menuCount++));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('测试消息内容')),
      kind: PointerDeviceKind.touch,
    );
    // 上下滑动：移动距离超过 18px 阈值，长按应被取消。
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 600));
    expect(menuCount, 0);
    await gesture.up();
    await tester.pump();
    expect(menuCount, 0);
  });

  testWidgets('触屏轻微抖动（小于阈值）仍可触发长按', (tester) async {
    var menuCount = 0;
    await tester.pumpWidget(buildBubble(onMenu: () => menuCount++));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('测试消息内容')),
      kind: PointerDeviceKind.touch,
    );
    // 小于 18px 的轻微移动不应取消长按。
    await gesture.moveBy(const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 600));
    expect(menuCount, 1);
    await gesture.up();
    await tester.pump();
    expect(menuCount, 1);
  });
}
