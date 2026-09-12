import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/narr_chat_scrollbar.dart';

/// NarrChatScrollbar（自绘通用滚动条 / 底座）隔离层测试。
///
/// 覆盖：拇指几何与拖动数学（纯计算）/ 纯叠加层（不改变被包裹视图的布局）/
/// 无溢出不渲染 / 滚动显隐与空闲淡出 / 鼠标拖动增量定位（不跳变）/
/// 全局行为接线（桌面纵向接管，触屏与横向不接管）。
///
/// 快速定位导轨（QuickScrollRail）自身的用例见 `quick_scroll_rail_test.dart`
/// 与 `sidebar_toc_test.dart`：两者共用同一底座，这里只测底座与通用皮肤。

/// 自建夹具：与业务页面无关的固定行高 ListView。
class _ScrollbarHost extends StatefulWidget {
  const _ScrollbarHost({this.itemCount = 80});

  final int itemCount;

  @override
  State<_ScrollbarHost> createState() => _ScrollbarHostState();
}

class _ScrollbarHostState extends State<_ScrollbarHost> {
  final ScrollController controller = ScrollController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NarrChatScrollbar(
      controller: controller,
      scrollable: ListView.builder(
        controller: controller,
        itemExtent: 50,
        itemCount: widget.itemCount,
        itemBuilder: (context, i) => Text('item $i'),
      ),
    );
  }
}

Future<void> pumpHost(
  WidgetTester tester, {
  int itemCount = 80,
  Size size = const Size(500, 500),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(body: _ScrollbarHost(itemCount: itemCount)),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollController hostController(WidgetTester tester) =>
    tester.state<_ScrollbarHostState>(find.byType(_ScrollbarHost)).controller;

Finder thumbFinder() => find.byType(NarrChatScrollThumb);

Finder fadeFinder() => find.descendant(
      of: find.byType(NarrChatScrollbar),
      matching: find.byType(FadeTransition),
    );

FadeTransition fadeOf(WidgetTester tester) =>
    tester.widget<FadeTransition>(fadeFinder());

void main() {
  group('ScrollThumbGeometry', () {
    test('内容不溢出：拇指 = 整条轨道（不可滚动）', () {
      expect(
        ScrollThumbGeometry.thumbHeight(
          trackExtent: 500,
          viewportDimension: 500,
          maxScrollExtent: 0,
          minHeight: 40,
        ),
        500,
      );
      // pixels 越界（瞬时越界/回弹）时位置仍被夹取在轨道内。
      expect(
        ScrollThumbGeometry.thumbTop(
          trackExtent: 500,
          thumbExtent: 250,
          pixels: -100,
          maxScrollExtent: 1000,
        ),
        0,
      );
      expect(
        ScrollThumbGeometry.thumbTop(
          trackExtent: 500,
          thumbExtent: 250,
          pixels: 99999,
          maxScrollExtent: 1000,
        ),
        250,
      );
    });

    test('拇指高度按视口比例并以 minHeight 夹取', () {
      // 视口/内容 = 500/1500 → 500 × 1/3 ≈ 166.67（> 40，不夹取）。
      expect(
        ScrollThumbGeometry.thumbHeight(
          trackExtent: 500,
          viewportDimension: 500,
          maxScrollExtent: 1000,
          minHeight: 40,
        ),
        closeTo(500 / 3, 0.001),
      );
      // 极长内容 → 比例结果过小，被 minHeight 抬起。
      expect(
        ScrollThumbGeometry.thumbHeight(
          trackExtent: 500,
          viewportDimension: 500,
          maxScrollExtent: 100000,
          minHeight: 64,
        ),
        64,
      );
      // 轨道比 minHeight 还矮 → 不超过轨道。
      expect(
        ScrollThumbGeometry.thumbHeight(
          trackExtent: 30,
          viewportDimension: 500,
          maxScrollExtent: 100000,
          minHeight: 64,
        ),
        30,
      );
    });

    test('pointerOffset：grab 保持按下位置（不跳变），center 拇指中心跟随', () {
      const pointer = Offset(10, 300);
      const grabStart = Offset(10, 200);
      // grab：位移 +100 → 偏移 +100 × (1000 / 400) = +250。
      expect(
        ScrollThumbGeometry.pointerOffset(
          pointerPosition: pointer,
          trackExtent: 500,
          thumbExtent: 100,
          viewportDimension: 500,
          maxScrollExtent: 1000,
          minScrollExtent: 0,
          dragAnchor: ScrollDragAnchor.grab,
          startOffset: 400,
          startPointerPosition: grabStart,
        ),
        closeTo(650, 0.001),
      );
      // grab：按下未移动 → 偏移不变（不会因点击滚动条而跳动）。
      expect(
        ScrollThumbGeometry.pointerOffset(
          pointerPosition: grabStart,
          trackExtent: 500,
          thumbExtent: 100,
          viewportDimension: 500,
          maxScrollExtent: 1000,
          minScrollExtent: 0,
          dragAnchor: ScrollDragAnchor.grab,
          startOffset: 400,
          startPointerPosition: grabStart,
        ),
        closeTo(400, 0.001),
      );
      // center：拇指中心对齐指针 → (300 − 50) × 2.5 = 625。
      expect(
        ScrollThumbGeometry.pointerOffset(
          pointerPosition: pointer,
          trackExtent: 500,
          thumbExtent: 100,
          viewportDimension: 500,
          maxScrollExtent: 1000,
          minScrollExtent: 0,
          dragAnchor: ScrollDragAnchor.center,
          startOffset: 0,
          startPointerPosition: Offset.zero,
        ),
        closeTo(625, 0.001),
      );
    });

    test('pointerOffset：越界钳制，轨道无法容纳拇指时返回 null', () {
      expect(
        ScrollThumbGeometry.pointerOffset(
          pointerPosition: const Offset(10, 100000),
          trackExtent: 500,
          thumbExtent: 100,
          viewportDimension: 500,
          maxScrollExtent: 1000,
          minScrollExtent: 0,
          dragAnchor: ScrollDragAnchor.center,
          startOffset: 0,
          startPointerPosition: Offset.zero,
        ),
        1000,
      );
      // 拇指占满轨道（内容不溢出）→ 无可用行程，不可定位。
      expect(
        ScrollThumbGeometry.pointerOffset(
          pointerPosition: const Offset(10, 100),
          trackExtent: 500,
          thumbExtent: 500,
          viewportDimension: 500,
          maxScrollExtent: 0,
          minScrollExtent: 0,
          dragAnchor: ScrollDragAnchor.center,
          startOffset: 0,
          startPointerPosition: Offset.zero,
        ),
        isNull,
      );
    });
  });

  group('NarrChatScrollbar', () {
    testWidgets('内容不溢出：拇指整体不渲染', (tester) async {
      await pumpHost(tester, itemCount: 3);
      expect(find.byType(NarrChatScrollbar), findsOneWidget);
      expect(thumbFinder(), findsNothing);
      expect(fadeFinder(), findsNothing);
    });

    testWidgets('滚动后拇指淡入显示，空闲 >700ms 后淡出', (tester) async {
      await pumpHost(tester);
      expect(fadeOf(tester).opacity.value, 0);

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      // 拖动事件同一帧派发：先 pump 一帧让淡入动画的 Ticker 确立起点。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(hostController(tester).offset, greaterThan(0));
      expect(fadeOf(tester).opacity.value, 1);

      // 空闲 700ms 计时结束后淡出（120ms 动画完成）。
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 200));
      expect(fadeOf(tester).opacity.value, 0);
    });

    testWidgets('鼠标按住拖动拇指：增量定位且按下瞬间不跳变', (tester) async {
      await pumpHost(tester);
      // 先把内容滚到中部，拇指远离两端（避免命中矩形被轨道边界钳制）。
      final controller = hostController(tester);
      controller.jumpTo(1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final trackH = tester.getSize(find.byType(NarrChatScrollbar)).height;
      final pos = controller.position;
      final content = pos.maxScrollExtent + pos.viewportDimension;
      final thumbH = trackH * pos.viewportDimension / content;
      final thumbTop = pos.pixels / pos.maxScrollExtent * (trackH - thumbH);
      final thumbCenter = tester.getCenter(thumbFinder());
      // 命中矩形与拇指同心（宽度外扩不影响中心）。
      expect(thumbCenter.dy, closeTo(thumbTop + thumbH / 2, 0.5));

      final startOffset = controller.offset;
      final gesture = await tester.startGesture(
        thumbCenter,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      // 按下未移动：偏移不变（grab 锚点，不跳变）。
      expect(controller.offset, startOffset);

      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      final expected = startOffset + 60 * (pos.maxScrollExtent / (trackH - thumbH));
      expect(controller.offset, closeTo(expected, 0.5));

      await gesture.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('拇指内图案：通用滚动条无图案，导轨为三角+中心圆点', (tester) async {
      await pumpHost(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 通用滚动条：无内图案（CustomPaint 仅由图案使用）。
      expect(
        find.descendant(
          of: find.byType(NarrChatScrollThumb),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );

      // 导轨皮肤：同一底座传入 arrowsWithDot → 出现图案层。
      final controller = ScrollController();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(500, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: NarrChatTheme.light,
          home: Scaffold(
            body: NarrChatScrollbar(
              controller: controller,
              thumbGlyph: ThumbGlyph.arrowsWithDot,
              thumbMinHeight: 64,
              scrollable: ListView.builder(
                controller: controller,
                itemExtent: 50,
                itemCount: 80,
                itemBuilder: (context, i) => Text('row $i'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byType(NarrChatScrollThumb),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });

    testWidgets('纯叠加层：出现滚动条前后，被包裹视图的尺寸与位置不变', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      // 「限宽 + 居中」页面形态（设置页/日志页）：外层 Align 居中，滚动视图在
      // loose 约束下收缩包裹到内容宽度。
      const windowW = 1000.0;
      Future<Rect> pumpAt(double windowH) async {
        tester.view.physicalSize = Size(windowW, windowH);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: NarrChatTheme.light,
            scrollBehavior: const NarrChatScrollBehavior(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: const SizedBox(width: 260, height: 1200),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return tester.getRect(find.byType(SingleChildScrollView));
      }

      // 内容不溢出：底座整体不渲染（叠加层为空）。
      final noOverflow = await pumpAt(1400);
      expect(find.byType(NarrChatScrollThumb), findsNothing);

      // 内容溢出：滚动条激活，但被包裹视图的宽度与水平位置必须原样不变
      // （回归：叠加层曾参与 Stack 尺寸计算，把 Stack 撑到整个可用区域，
      // 收缩包裹的滚动视图随即被按 topStart 摆到左边 → 内容「跳」到靠左）。
      final overflow = await pumpAt(600);
      expect(find.byType(NarrChatScrollThumb), findsOneWidget);
      expect(overflow.width, noOverflow.width);
      expect(overflow.center.dx, closeTo(noOverflow.center.dx, 0.5));
      expect(overflow.center.dx, closeTo(windowW / 2, 0.5));

      // 叠加层与滚动视图严格重合：拇指贴被包裹视图右缘（而非外层可用区域右缘）。
      expect(
        tester.getRect(find.byType(NarrChatScrollThumb)).right,
        closeTo(overflow.right - kScrollbarThumbEdgeGap, 0.5),
      );

      debugDefaultTargetPlatformOverride = null;
      await tester.pumpAndSettle();
    });

    testWidgets('鼠标悬停右缘命中带：拇指显示且不抛「无尺寸命中测试」异常', (tester) async {
      await pumpHost(tester);
      // 初始空闲 → 拇指透明。
      expect(fadeOf(tester).opacity.value, 0);

      // 右缘命中带内悬停（命中带自身必须有确定尺寸，否则鼠标经过会抛
      // 「Cannot hit test a render box with no size」）。
      final barRect = tester.getRect(find.byType(NarrChatScrollbar));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: Offset(barRect.right - 4, barRect.center.dy),
      );
      await mouse.moveTo(Offset(barRect.right - 4, barRect.center.dy + 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(fadeOf(tester).opacity.value, 1);

      // 离开命中带 → 空闲后淡出（悬停期间保持显示）。
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      expect(fadeOf(tester).opacity.value, 0);
      await mouse.removePointer();
    });

    testWidgets('附加浮层排在拇指之下（拖动时拇指不被浮层盖住）', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(500, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: NarrChatTheme.light,
          home: Scaffold(
            body: NarrChatScrollbar(
              controller: controller,
              thumbGlyph: ThumbGlyph.arrowsWithDot,
              thumbMinHeight: 64,
              stripKey: const Key('test_strip'),
              overlayBuilder: (context, trackExtent) =>
                  const SizedBox.expand(key: Key('test_overlay')),
              scrollable: ListView.builder(
                controller: controller,
                itemExtent: 50,
                itemCount: 80,
                itemBuilder: (context, i) => Text('row $i'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 拖动中：浮层可见，且拇指仍然存在（否则导轨拖动态会「看不见拇指」）。
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('test_overlay')), findsOneWidget);
      expect(thumbFinder(), findsOneWidget);

      // 层序：浮层必须是拇指拖动命中层**之前**的兄弟（更早 = 更下层）。
      // 同层 Stack 的子树先序遍历顺序即绘制顺序（越靠后越在上层）。
      final positionedKeys = tester
          .widgetList<Positioned>(find.byType(Positioned))
          .map((w) => w.child.key)
          .toList();
      final overlayIndex = positionedKeys.indexOf(const Key('test_overlay'));
      final stripIndex = positionedKeys.indexOf(const Key('test_strip'));
      expect(overlayIndex, isNonNegative);
      expect(stripIndex, isNonNegative);
      expect(overlayIndex, lessThan(stripIndex));
    });
  });

  group('NarrChatScrollBehavior', () {
    test('shouldShowScrollbar：仅桌面平台 + 纵向接管', () {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        expect(
          NarrChatScrollBehavior.shouldShowScrollbar(
            direction: AxisDirection.down,
            platform: platform,
          ),
          isTrue,
          reason: '$platform 纵向应由自绘滚动条接管',
        );
        expect(
          NarrChatScrollBehavior.shouldShowScrollbar(
            direction: AxisDirection.right,
            platform: platform,
          ),
          isFalse,
          reason: '$platform 横向保持默认（不加滚动条）',
        );
      }
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          NarrChatScrollBehavior.shouldShowScrollbar(
            direction: AxisDirection.down,
            platform: platform,
          ),
          isFalse,
          reason: '$platform 触屏平台保持默认（不自动加滚动条）',
        );
      }
    });

    testWidgets('桌面端纵向滚动视图自动接入自绘滚动条', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      tester.view.physicalSize = const Size(500, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: NarrChatTheme.light,
          scrollBehavior: const NarrChatScrollBehavior(),
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemExtent: 50,
              itemCount: 80,
              itemBuilder: (context, i) => Text('row $i'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NarrChatScrollbar), findsOneWidget);
      expect(find.byType(Scrollbar), findsNothing);

      // 滚动 → 自绘拇指出现（替换生效，而非仅包了一层）。
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(thumbFinder(), findsOneWidget);

      // 复位平台覆写：不能留到 testWidgets 收尾（框架会断言调试变量被改动）。
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpAndSettle();
    });

    testWidgets('触屏平台纵向滚动视图不被接管（保持默认无滚动条）', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      tester.view.physicalSize = const Size(500, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: NarrChatTheme.light,
          scrollBehavior: const NarrChatScrollBehavior(),
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemExtent: 50,
              itemCount: 80,
              itemBuilder: (context, i) => Text('row $i'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NarrChatScrollbar), findsNothing);
      expect(find.byType(Scrollbar), findsNothing);

      // 内容仍可正常滚动。
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));

      // 复位平台覆写：不能留到 testWidgets 收尾（框架会断言调试变量被改动）。
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpAndSettle();
    });
  });
}
