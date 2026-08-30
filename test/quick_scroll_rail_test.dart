import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/quick_scroll_rail.dart';

/// QuickScrollRail 隔离层测试（自建 ListView 夹具，不触碰业务页面）。
///
/// 覆盖：无溢出隐藏 / 滚动显隐与空闲淡出 / 鼠标拖动线性定位 / 鼠标拖动浮层
/// 与当前标题对齐 / 松手浮层立即消失 / 单行长标题省略 / 暗色渐变底色 /
/// null 偏移条目跳过 / 标签行数上限。
class _RailHost extends StatefulWidget {
  const _RailHost({
    required this.entries,
    this.itemCount = 80,
    this.itemHeight = 50,
    this.panelColor,
    this.dark = false,
  });

  final List<QuickScrollEntry> entries;
  final int itemCount;
  final double itemHeight;
  final Color? panelColor;
  final bool dark;

  @override
  State<_RailHost> createState() => _RailHostState();
}

class _RailHostState extends State<_RailHost> {
  final ScrollController controller = ScrollController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return QuickScrollRail(
      controller: controller,
      panelColor: widget.panelColor,
      entries: widget.entries,
      scrollable: ListView.builder(
        controller: controller,
        itemExtent: widget.itemHeight,
        itemCount: widget.itemCount,
        itemBuilder: (context, i) => Text('item $i'),
      ),
    );
  }
}

/// 生成 [count] 个固定间距（[gap] px，对齐偏移 = i × gap）的目录条目。
List<QuickScrollEntry> buildEntries(
  int count, {
  double gap = 400,
  List<double?>? resolverOverrides,
}) {
  return [
    for (var i = 0; i < count; i++)
      QuickScrollEntry(
        id: 'e$i',
        label: 'E$i',
        offsetResolver: () => resolverOverrides == null || i >= resolverOverrides.length
            ? i * gap
            : resolverOverrides[i],
      ),
  ];
}

Future<void> pumpHost(
  WidgetTester tester, {
  required List<QuickScrollEntry> entries,
  int itemCount = 80,
  double itemHeight = 50,
  Color? panelColor,
  bool dark = false,
  Size size = const Size(600, 600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? NarrChatTheme.dark : NarrChatTheme.light,
      home: Scaffold(
        body: _RailHost(
          entries: entries,
          itemCount: itemCount,
          itemHeight: itemHeight,
          panelColor: panelColor,
          dark: dark,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FadeTransition thumbFade(WidgetTester tester) => tester.widget<FadeTransition>(
      find.byKey(const Key('quick_scroll_rail_thumb_fade')),
    );

/// 拖动中浮层（FadeTransition）；松手后应立即移出树。
Finder overlayFinder() => find.byKey(const Key('quick_scroll_rail_overlay'));

void main() {
  testWidgets('内容不溢出（maxScrollExtent <= 0）时导轨整体不渲染', (tester) async {
    await pumpHost(tester, entries: buildEntries(3), itemCount: 5);
    expect(find.byKey(const Key('quick_scroll_rail_strip')), findsNothing);
    expect(find.byKey(const Key('quick_scroll_rail_thumb')), findsNothing);
    expect(find.byKey(const Key('quick_scroll_rail_overlay')), findsNothing);
  });

  testWidgets('滚动后拇指淡入显示，空闲 >700ms 后淡出', (tester) async {
    await pumpHost(tester, entries: buildEntries(6));
    expect(thumbFade(tester).opacity.value, 0);

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    // 拖动事件同一帧派发：先 pump 一帧让淡入动画的 Ticker 确立起点。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_offsetOf(tester), greaterThan(0)); // 滚动生效
    expect(thumbFade(tester).opacity.value, 1);

    // 空闲 700ms 计时结束后淡出（120ms 动画完成）。
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 200));
    expect(thumbFade(tester).opacity.value, 0);
  });

  testWidgets('鼠标按住拖动：线性映射定位，当前条目贴近拇指中心', (tester) async {
    final entries = buildEntries(6, gap: 400);
    await pumpHost(tester, entries: entries);

    final strip = find.byKey(const Key('quick_scroll_rail_strip'));
    final stripSize = tester.getSize(strip);
    final stripTopLeft = tester.getTopLeft(strip);
    final maxExtent = _maxExtentOf(tester);
    final viewport = 600.0;
    final frac = viewport / (maxExtent + viewport);
    final thumbH = (stripSize.height * frac).clamp(64.0, stripSize.height);

    // 鼠标按下（不移动不跳转），随后拖到 50% 位置。
    final gesture = await tester.startGesture(
      stripTopLeft + Offset(stripSize.width / 2, 100),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(_offsetOf(tester), 0); // 未移动 → 内容不动（纯单击不做定位）
    // 地图模式：即使停在顶部，目录沿全高分布（最后一节也应可见）。
    expect(find.text('E5'), findsOneWidget);

    await gesture.moveTo(stripTopLeft + Offset(stripSize.width / 2, thumbH / 2 + (stripSize.height - thumbH) * 0.5));
    await tester.pump();
    // 推进动画时钟：展开动画（180ms）完成，浮层全量可见。
    await tester.pump(const Duration(milliseconds: 200));
    expect(_offsetOf(tester), closeTo(maxExtent * 0.5, 1));

    // 当前标题（E4，offset 1600 ≤ 1700）行中心贴近拇指中心；强调随拖动
    // 位置连续变化：iCont = 4.25 → E4 权重 0.75 → 字号 = 19.2 + 2.4*0.75。
    final currentLabel = find.text('E4');
    expect(currentLabel, findsOneWidget);
    expect(
      tester.widget<Text>(currentLabel).style?.fontSize,
      closeTo(QuickScrollRail.labelFontSize +
          QuickScrollRail.labelFontSizeBoost * 0.75, 0.1),
    );
    final rowCenterY = tester.getCenter(currentLabel).dy;
    final thumbCenterY =
        stripTopLeft.dy + thumbH / 2 + (stripSize.height - thumbH) * 0.5;
    expect(
      rowCenterY,
      closeTo(thumbCenterY, QuickScrollRail.labelRowHeight / 2 + 1),
    );

    await gesture.up();
    await tester.pump();
    // 松手：收起动画播放中（右滑出+淡出），浮层仍在树中。
    expect(overlayFinder(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50));
    final collapsing = tester.widget<Opacity>(
      find
          .descendant(of: overlayFinder(), matching: find.byType(Opacity))
          .first,
    );
    expect(collapsing.opacity, lessThan(1.0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(overlayFinder(), findsNothing);
  });

  testWidgets('拖到轨道底 → 滚动到 maxScrollExtent，当前条目为最后一个', (tester) async {
    await pumpHost(tester, entries: buildEntries(6, gap: 400));
    final strip = find.byKey(const Key('quick_scroll_rail_strip'));
    final size = tester.getSize(strip);
    final topLeft = tester.getTopLeft(strip);
    final maxExtent = _maxExtentOf(tester);

    final gesture = await tester.startGesture(
      topLeft + Offset(size.width / 2, 100),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(topLeft + Offset(size.width / 2, size.height - 1));
    await tester.pump();
    expect(_offsetOf(tester), closeTo(maxExtent, 1));
    // 最后一个条目当前态（位置驱动强调：恰好位于拇指 → 满载字号）。
    final last = tester.widget<Text>(find.text('E5'));
    expect(
      last.style?.fontSize,
      closeTo(QuickScrollRail.labelFontSize +
          QuickScrollRail.labelFontSizeBoost, 0.1),
    );
    await gesture.up();
  });

  testWidgets('长标题单行省略并受限宽（默认屏宽 70%）约束', (tester) async {
    final long = '很长的目录标题' * 30;
    await pumpHost(
      tester,
      entries: [
        QuickScrollEntry(
          id: 'long',
          label: long,
          offsetResolver: () => 0,
        ),
        ...buildEntries(3, gap: 400),
      ],
    );
    final strip = find.byKey(const Key('quick_scroll_rail_strip'));
    final size = tester.getSize(strip);
    final topLeft = tester.getTopLeft(strip);
    final gesture = await tester.startGesture(
      topLeft + Offset(size.width / 2, 120),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(topLeft + Offset(size.width / 2, 300));
    await tester.pump();

    final text = tester.widget<Text>(find.text(long));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    // 宽度不超过 70% 屏宽（600 × 0.7 = 420）。
    expect(tester.getSize(find.text(long)).width, lessThanOrEqualTo(420));
    await gesture.up();
  });

  testWidgets('暗色主题：渐变底色 = 暗色 surface（panelColor 缺省）', (tester) async {
    await pumpHost(tester, entries: buildEntries(3), dark: true);
    final strip = find.byKey(const Key('quick_scroll_rail_strip'));
    final size = tester.getSize(strip);
    final topLeft = tester.getTopLeft(strip);
    final gesture = await tester.startGesture(
      topLeft + Offset(size.width / 2, 100),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(topLeft + Offset(size.width / 2, 300));
    await tester.pump();

    final gradient = tester
        .widget<DecoratedBox>(
          find.byKey(const Key('quick_scroll_rail_gradient')),
        )
        .decoration as BoxDecoration;
    final colors = (gradient.gradient as LinearGradient).colors;
    expect(colors.first.a, 0);
    expect(colors.last, NarrChatTheme.dark.colorScheme.surface);
    await gesture.up();
  });

  testWidgets('目录溢出屏幕：超出上下边缘的行不可见（由边缘淡出处理）', (tester) async {
    await pumpHost(tester, entries: buildEntries(60, gap: 400));
    final strip = find.byKey(const Key('quick_scroll_rail_strip'));
    final size = tester.getSize(strip);
    final topLeft = tester.getTopLeft(strip);
    final gesture = await tester.startGesture(
      topLeft + Offset(size.width / 2, 100),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    // 顶部位置：当前 = E0，行从拇指中心向下以行高（30）排开；
    // 超出可见带（trackH + rowH）的行不在树中（供上下边缘渐变淡出）。
    // E19 @ y=45+19*30=615（≤ 652 可见）；E21 @ y=675（> 652 不可见）。
    expect(find.text('E19'), findsOneWidget);
    expect(find.text('E21'), findsNothing);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('边缘淡出蒙版用 dstIn（仅调制透明度，不把文字染成白色）', (tester) async {
    await pumpHost(tester, entries: buildEntries(4));
    final strip = find.byKey(const Key('quick_scroll_rail_strip'));
    final size = tester.getSize(strip);
    final topLeft = tester.getTopLeft(strip);
    final gesture = await tester.startGesture(
      topLeft + Offset(size.width / 2, 100),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final mask = tester.widget<ShaderMask>(
      find.descendant(
        of: find.byKey(const Key('quick_scroll_rail_overlay')),
        matching: find.byType(ShaderMask),
      ),
    );
    // srcIn 会把子内容着色成蒙版颜色（纯白）→ 亮色面板上完全不可见。
    expect(mask.blendMode, BlendMode.dstIn);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('offsetResolver 返回 null 的条目被跳过，不参与布局与当前判定', (tester) async {
    await pumpHost(
      tester,
      entries: buildEntries(3, gap: 400, resolverOverrides: const [null, 0, 400]),
    );
    final strip = find.byKey(const Key('quick_scroll_rail_strip'));
    final size = tester.getSize(strip);
    final topLeft = tester.getTopLeft(strip);
    final gesture = await tester.startGesture(
      topLeft + Offset(size.width / 2, 100),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(topLeft + Offset(size.width / 2, 300));
    await tester.pump();
    // E0 被跳过：条目按 [0, 400] 参与，当前条目 = E2（400，满载字号）。
    final current = tester.widget<Text>(find.text('E2'));
    expect(
      current.style?.fontSize,
      closeTo(QuickScrollRail.labelFontSize +
          QuickScrollRail.labelFontSizeBoost, 0.1),
    );
    await gesture.up();
  });
}

double _offsetOf(WidgetTester tester) {
  final list = tester.widget<ListView>(find.byType(ListView));
  return list.controller!.offset;
}

double _maxExtentOf(WidgetTester tester) {
  final list = tester.widget<ListView>(find.byType(ListView));
  return list.controller!.position.maxScrollExtent;
}
