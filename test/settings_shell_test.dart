import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/narr_chat_scrollbar.dart';
import 'package:narrchat/widgets/settings_shell.dart';

/// 内容面板。「面板 0 / 1 / 2 …」唯一可定位，避免与标签文本重名。
Widget _buildPage(BuildContext context, int index) => Text('面板 $index');

/// [SettingsShell] 外壳行为测试。
///
/// 重点：
/// - 宽屏（≥760）：左侧竖向导航切换，无 PageView；内容区**靠左**（限宽 860）
///   且滚动视图铺满内容区（滚动条贴内容区右缘）；
/// - 宽屏内容溢出（出现滚动条）前后内容位置一致，不发生时靠左/时居中的跳变；
/// - 窄屏：顶部横向标签 + 内容区 PageView，左右滑动 / 点击标签均可切换子页面，
///   标签高亮与显示内容保持同步；宽窄布局切换时显示页与选中项一致。
void main() {
  const navItems = [
    SettingsNavItem(icon: Icons.smart_toy_outlined, label: 'API 设置'),
    SettingsNavItem(icon: Icons.palette_outlined, label: 'UI 设置'),
    SettingsNavItem(icon: Icons.extension_outlined, label: 'Mod 管理'),
    SettingsNavItem(icon: Icons.cloud_outlined, label: '云同步'),
  ];

  Widget buildShell({Widget Function(BuildContext context, int index)? page}) {
    return MaterialApp(
      theme: NarrChatTheme.light,
      // 桌面平台由自绘滚动条接管纵向滚动视图（内容溢出即出现滚动条）。
      scrollBehavior: const NarrChatScrollBehavior(),
      home: SettingsShell(
        title: '设置',
        icon: Icons.settings,
        navItems: navItems,
        contentBuilder: page ?? _buildPage,
      ),
    );
  }

  Future<void> pumpShell(
    WidgetTester tester, {
    Size size = const Size(500, 800),
    Widget Function(BuildContext context, int index)? page,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildShell(page: page));
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

  testWidgets('宽屏：内容靠左（限宽 860），滚动视图铺满内容区', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpShell(tester, size: const Size(1400, 800));

    // 左侧导航 220 + 1px 分隔线 = 内容区左边界。
    const regionLeft = 221.0;
    final scroll = tester.getRect(find.byType(SingleChildScrollView));
    expect(scroll.left, closeTo(regionLeft, 0.5));
    // 滚动视图铺满内容区 → 滚动条贴内容区右缘（而非内容列右缘）。
    expect(scroll.right, closeTo(1400, 0.5));
    // 内容列靠左（与左侧导航同属左对齐骨架），左边界 = 内容区 + 24 内边距。
    expect(
      tester.getTopLeft(find.text('面板 0')).dx,
      closeTo(regionLeft + 24, 0.5),
    );

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpAndSettle();
  });

  testWidgets('宽屏：内容溢出出现滚动条前后，内容左边界不变（不再跳变）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    Future<double> leftOfPage({required double pageHeight}) async {
      await pumpShell(
        tester,
        size: const Size(1400, 800),
        page: (context, i) =>
            SizedBox(height: pageHeight, child: Text('面板 $i')),
      );
      return tester.getTopLeft(find.text('面板 0')).dx;
    }

    // 不溢出：无滚动条。
    final short = await leftOfPage(pageHeight: 200);
    expect(find.byType(NarrChatScrollThumb), findsNothing);

    // 溢出：滚动条激活，内容仍在同一左边界（回归：曾在此跳成「靠左」而
    // 不溢出时保持居中，同一页面随内容长短左右横跳）。
    final tall = await leftOfPage(pageHeight: 2000);
    expect(find.byType(NarrChatScrollThumb), findsOneWidget);
    expect(tall, closeTo(short, 0.5));

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpAndSettle();
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
