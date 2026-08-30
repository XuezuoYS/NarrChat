import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';

import 'helpers/chat_harness.dart';

/// 宽屏右侧栏宽度拖拽调整：拖拽实时改宽 / 松手落库 / 40% 上限 /
/// 双击复位 / 收起保持 / 窗口缩放夹取 / 窄屏不受影响。
void main() {
  const dividerKey = Key('sidebar_resize_divider');

  Finder divider() => find.byKey(dividerKey);

  double sidebarWidth(WidgetTester tester) =>
      tester.getSize(find.byType(SidebarPanel)).width;

  /// 从手柄处开始一次横向拖拽：[moves] 为逐帧位移（累积值用于夹取断言）。
  Future<TestGesture> startResizeDrag(
    WidgetTester tester,
    List<Offset> moves,
  ) async {
    final gesture = await tester.startGesture(tester.getCenter(divider()));
    for (final move in moves) {
      await gesture.moveBy(move);
      await tester.pump();
    }
    return gesture;
  }

  testWidgets('宽屏默认：侧栏 380，拖拽手柄存在', (tester) async {
    await pumpChatScreen(tester);
    expect(sidebarWidth(tester), closeTo(kChatSidebarDefaultWidth, 1));
    expect(divider(), findsOneWidget);
  });

  testWidgets('向左拖拽：实时改宽、松手才写入本地配置', (tester) async {
    final ui = UiSettingsProvider();
    await pumpChatScreen(tester, uiSettings: ui);

    final gesture = await startResizeDrag(
      tester,
      const [Offset(-60, 0), Offset(-60, 0), Offset(-60, 0)],
    );
    // 拖动中途：界面宽度已实时变宽，但尚未持久化。
    final midWidth = sidebarWidth(tester);
    expect(midWidth, greaterThan(kChatSidebarDefaultWidth));
    expect(ui.chatSidebarWidth, kChatSidebarDefaultWidth);

    await gesture.up();
    await tester.pumpAndSettle();
    // 松手后：最终宽度一次写入配置，显示宽度与持久化值一致。
    expect(ui.chatSidebarWidth, greaterThan(kChatSidebarDefaultWidth));
    expect(midWidth, lessThanOrEqualTo(ui.chatSidebarWidth));
    expect(sidebarWidth(tester), closeTo(ui.chatSidebarWidth, 1));
  });

  testWidgets('向右拖拽：宽度不会低于默认（=最小）', (tester) async {
    await pumpChatScreen(tester);
    final gesture = await startResizeDrag(
      tester,
      const [Offset(40, 0), Offset(40, 0), Offset(40, 0)],
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(sidebarWidth(tester), closeTo(kChatSidebarDefaultWidth, 1));
  });

  testWidgets('拖拽超过窗口宽 40% 时被夹取', (tester) async {
    final ui = UiSettingsProvider();
    await pumpChatScreen(tester, uiSettings: ui);

    final gesture = await startResizeDrag(
      tester,
      const [Offset(-200, 0), Offset(-200, 0), Offset(-200, 0)],
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final cap = 1400 * 0.4;
    expect(sidebarWidth(tester), closeTo(cap, 1));
    expect(ui.chatSidebarWidth, closeTo(cap, 1));
  });

  testWidgets('双击手柄：恢复默认宽度并持久化', (tester) async {
    final ui = UiSettingsProvider();
    await pumpChatScreen(tester, uiSettings: ui);
    // 先拖宽。
    final gesture = await startResizeDrag(
      tester,
      const [Offset(-40, 0), Offset(-40, 0), Offset(-40, 0)],
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ui.chatSidebarWidth, greaterThan(kChatSidebarDefaultWidth));

    // 双击复位。
    await tester.tap(divider());
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(divider());
    await tester.pumpAndSettle();

    expect(sidebarWidth(tester), closeTo(kChatSidebarDefaultWidth, 1));
    expect(ui.chatSidebarWidth, kChatSidebarDefaultWidth);
  });

  testWidgets('收起时手柄隐藏，重新展开后宽度保持', (tester) async {
    final ui = UiSettingsProvider();
    await pumpChatScreen(tester, uiSettings: ui);
    final gesture = await startResizeDrag(
      tester,
      const [Offset(-40, 0), Offset(-40, 0), Offset(-40, 0)],
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final widened = ui.chatSidebarWidth;
    expect(widened, greaterThan(kChatSidebarDefaultWidth));

    // 收起：手柄消失，出现「打开侧栏」。
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(divider(), findsNothing);
    expect(find.text('打开侧栏'), findsOneWidget);

    // 重新展开：宽度沿用（不因收起重置）。
    await tester.tap(find.text('打开侧栏'));
    await tester.pumpAndSettle();
    expect(divider(), findsOneWidget);
    expect(sidebarWidth(tester), closeTo(widened, 1));
  });

  testWidgets('窗口缩窄：有效宽度夹到下限，存储值不被改写', (tester) async {
    final ui = UiSettingsProvider();
    await pumpChatScreen(tester, uiSettings: ui);
    final gesture = await startResizeDrag(
      tester,
      const [Offset(-40, 0), Offset(-40, 0), Offset(-40, 0), Offset(-40, 0)],
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final widened = ui.chatSidebarWidth;
    expect(widened, greaterThan(kChatSidebarDefaultWidth));

    // 缩到 900：比例上限（360）低于默认值（380），min 优先 → 380。
    tester.view.physicalSize = const Size(900, 900);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(sidebarWidth(tester), closeTo(kChatSidebarDefaultWidth, 1));
    expect(ui.chatSidebarWidth, widened, reason: '显示夹取不应改写存储值');
  });

  testWidgets('窗口缩到窄屏：无手柄，抽屉恢复 88% 占比', (tester) async {
    final ui = UiSettingsProvider();
    await pumpChatScreen(tester, uiSettings: ui);
    final gesture = await startResizeDrag(
      tester,
      const [Offset(-40, 0), Offset(-40, 0), Offset(-40, 0)],
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final widened = ui.chatSidebarWidth;
    expect(widened, greaterThan(kChatSidebarDefaultWidth));

    tester.view.physicalSize = const Size(600, 900);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(divider(), findsNothing);

    // 打开抽屉：宽度按屏宽 0.88 占比（不读自定义宽度）。
    await tester.tap(find.byIcon(Icons.view_sidebar_outlined));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byType(SidebarPanel)).dx,
      closeTo(600 - 600 * 0.88, 1),
    );
  });
}
