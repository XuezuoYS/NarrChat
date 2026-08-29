import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/settings_shell.dart';

/// 内容面板。「面板 0 / 1 / 2 …」唯一可定位，避免与标签文本重名。
Widget _buildPage(BuildContext context, int index) => Text('面板 $index');

/// [SettingsShell] 外壳行为测试。
///
/// 重点：
/// - 宽屏（≥760）：左侧竖向导航切换，无 PageView；
/// - 窄屏：顶部横向标签 + 内容区 PageView，左右滑动 / 点击标签均可切换子页面，
///   标签高亮与显示内容保持同步；宽窄布局切换时显示页与选中项一致。
void main() {
  const navItems = [
    SettingsNavItem(icon: Icons.smart_toy_outlined, label: 'API 设置'),
    SettingsNavItem(icon: Icons.palette_outlined, label: 'UI 设置'),
    SettingsNavItem(icon: Icons.extension_outlined, label: 'Mod 管理'),
    SettingsNavItem(icon: Icons.cloud_outlined, label: '云同步'),
  ];

  Widget buildShell() {
    return MaterialApp(
      theme: NarrChatTheme.light,
      home: const SettingsShell(
        title: '设置',
        icon: Icons.settings,
        navItems: navItems,
        contentBuilder: _buildPage,
      ),
    );
  }

  Future<void> pumpShell(
    WidgetTester tester, {
    Size size = const Size(500, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildShell());
    await tester.pumpAndSettle();
  }

  ChoiceChip chip(WidgetTester tester, String label) =>
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

  testWidgets('窄屏：初始显示第一个面板且对应标签选中', (tester) async {
    await pumpShell(tester);

    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('面板 0'), findsOneWidget);
    expect(chip(tester, 'API 设置').selected, isTrue);
    expect(chip(tester, 'UI 设置').selected, isFalse);
  });

  testWidgets('窄屏：内容区向左滑动切换到下一个面板，标签高亮跟随', (tester) async {
    await pumpShell(tester);

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('面板 1'), findsOneWidget);
    expect(chip(tester, 'UI 设置').selected, isTrue);
    expect(chip(tester, 'API 设置').selected, isFalse);
  });

  testWidgets('窄屏：点击标签滑动到目标面板（含跨多页动画）', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('Mod 管理'));
    await tester.pumpAndSettle();

    expect(find.text('面板 2'), findsOneWidget);
    expect(chip(tester, 'Mod 管理').selected, isTrue);
    expect(chip(tester, 'API 设置').selected, isFalse);
  });

  testWidgets('窄屏：鼠标拖拽也可翻页（Windows 桌面可用）', (tester) async {
    await pumpShell(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-500, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('面板 1'), findsOneWidget);
    expect(chip(tester, 'UI 设置').selected, isTrue);
  });

  testWidgets('宽屏：左侧导航切换面板，无 PageView', (tester) async {
    await pumpShell(tester, size: const Size(1000, 800));

    expect(find.byType(PageView), findsNothing);
    expect(find.text('面板 0'), findsOneWidget);

    await tester.tap(find.text('Mod 管理'));
    await tester.pumpAndSettle();

    expect(find.text('面板 2'), findsOneWidget);
    expect(find.text('面板 0'), findsNothing);
  });

  testWidgets('宽屏选中非首项后切到窄屏：仍显示当前选中项', (tester) async {
    await pumpShell(tester, size: const Size(1000, 800));
    await tester.tap(find.text('UI 设置'));
    await tester.pumpAndSettle();
    expect(find.text('面板 1'), findsOneWidget);

    // 窗口缩窄（切回窄屏布局）：起始页与当前选中项保持一致。
    tester.view.physicalSize = const Size(500, 800);
    await tester.pumpAndSettle();

    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('面板 1'), findsOneWidget);
    expect(chip(tester, 'UI 设置').selected, isTrue);
  });
}
