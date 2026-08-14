import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/widgets/markdown_field.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';

import 'helpers/chat_harness.dart';

/// 侧边栏开合 / 抽屉手势测试（宽屏常驻侧栏 + 窄屏抽屉）。
void main() {
  Future<void> pumpWideChat(WidgetTester tester) async {
    // 测试环境中 ChatScreen 的 post-frame 回调执行时书籍可能尚未就绪，
    // 导致 loadRounds 未触发、侧边栏为空态；pumpChatScreen 在 pump 前显式
    // loadRounds（第零轮）以保证有内容。
    await pumpChatScreen(tester);
    await tester.pumpAndSettle();
  }

  Future<void> pumpNarrowChat(WidgetTester tester) async {
    await pumpChatScreen(tester, size: const Size(600, 900));
  }

  testWidgets('宽屏：右侧栏默认展开，无「打开侧栏」按钮', (tester) async {
    await pumpWideChat(tester);
    expect(find.text('打开侧栏'), findsNothing);
    // 顶栏存在收起按钮。
    expect(find.byIcon(Icons.close), findsWidgets);
  });

  testWidgets('宽屏：点击×收起后出现「打开侧栏」，点击后展开', (tester) async {
    await pumpWideChat(tester);
    // 收起：点击侧栏顶栏的 ×。
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();
    // 动画中途：× 可能已消失，但「打开侧栏」要等 value<0.5 才出现。
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('打开侧栏'), findsOneWidget);
    // 展开：点击「打开侧栏」。
    await tester.tap(find.text('打开侧栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('打开侧栏'), findsNothing);
  });

  testWidgets('窄屏：方形按钮呼出抽屉（按钮常驻）', (tester) async {
    await pumpNarrowChat(tester);

    // 初始：输入面板方形按钮存在（抽屉关闭）。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
    // 打开抽屉。
    await tester.tap(find.byIcon(Icons.view_sidebar_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // 动画中途采样
    final midLeft = tester.getTopLeft(find.byType(SidebarPanel)).dx;
    final drawerWidth = 600 * 0.88;
    // 中途：侧栏应处于半途（左侧 x 在 [600-drawerWidth, 600] 区间内），证明是平滑滑动而非跳变。
    expect(midLeft, greaterThan(600 - drawerWidth));
    expect(midLeft, lessThan(600));
    await tester.pump(const Duration(milliseconds: 400));
    // 抽屉打开后侧栏已完全滑入（左侧 x = 600 - drawerWidth），按钮常驻。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(SidebarPanel)).dx,
      closeTo(600 - drawerWidth, 1),
    );
  });

  testWidgets('窄屏：聊天区左滑打开右侧抽屉', (tester) async {
    await pumpNarrowChat(tester);

    // 初始：抽屉关闭，方形按钮存在。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);

    // 聊天区任意位置左滑（从右向左）。
    await tester.fling(find.byType(ChatScreen), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();

    // 抽屉打开：按钮常驻，侧栏完全滑入。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
    final drawerWidth = 600 * 0.88;
    expect(
      tester.getTopLeft(find.byType(SidebarPanel)).dx,
      closeTo(600 - drawerWidth, 1),
    );
  });

  testWidgets('窄屏：聊天区慢速长距离左拖也可打开抽屉', (tester) async {
    await pumpNarrowChat(tester);

    // 慢速拖动（速度低，但位移超过距离阈值）。
    await tester.drag(find.byType(ChatScreen), const Offset(-150, 0));
    await tester.pumpAndSettle();

    // 抽屉打开：按钮常驻。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
  });

  testWidgets('窄屏：聊天区右滑不打开右侧抽屉', (tester) async {
    await pumpNarrowChat(tester);

    // 聊天区右滑（从左向右）。
    await tester.fling(find.byType(ChatScreen), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();

    // 抽屉保持关闭：悬浮按钮仍在。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
  });

  testWidgets('窄屏：抽屉内右滑关闭右侧抽屉', (tester) async {
    await pumpNarrowChat(tester);

    // 先通过方形按钮打开抽屉。
    await tester.tap(find.byIcon(Icons.view_sidebar_outlined));
    await tester.pumpAndSettle();
    // 按钮常驻（抽屉打开时仍可见）。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);

    // 抽屉内右滑（从左向右）。
    await tester.fling(find.byType(SidebarPanel), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();

    // 抽屉关闭：按钮仍在。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
  });

  testWidgets('窄屏：鼠标横向拖动不触发滑动开合', (tester) async {
    await pumpNarrowChat(tester);

    // 鼠标横向左拖：不应打开抽屉。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(300, 450));
    await gesture.down(const Offset(300, 450));
    await gesture.moveBy(const Offset(-300, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
  });

  testWidgets('点击子模块标题栏可折叠/展开（世界状态）', (tester) async {
    await pumpWideChat(tester);
    // 「世界状态」标题栏位于视口顶部附近，无需滚动即可见。
    expect(find.text('世界状态'), findsOneWidget);
    expect(find.byType(MarkdownField), findsOneWidget);
    // 折叠：点击标题栏。
    await tester.tap(find.text('世界状态'));
    await tester.pumpAndSettle();
    // 折叠后：编辑器消失，标题栏出现「已折叠」提示。
    expect(find.byType(MarkdownField), findsNothing);
    expect(find.text('已折叠'), findsOneWidget);
    // 再次点击展开。
    await tester.tap(find.text('世界状态'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownField), findsOneWidget);
    expect(find.text('已折叠'), findsNothing);
  });
}
