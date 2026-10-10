/// 探针（非回归测试；属 `.agents/` 度量设施）：`reverse: true` 底部锚定语义。
///
/// 落地 P0-③（对话页消息列改 `reverse: true`）**之前**，在合成宿主上测清框架的
/// 真实行为，避免拿假设改生产代码。合成宿主刻意复刻改造后的结构：
/// `reverse: true` + 逻辑序号反转 + 条目稳定 key + `findChildIndexCallback`。
///
/// 覆盖：
/// - **D1** 贴底（`pixels == 0`）时追加条目：`pixels` 是否被框架自动保持、
///   是否存在越界帧（对照现状 M2 的 45/80 越界帧）；
/// - **D2/D3** 用户离底阅读时内容长高（追加 / 长高）：可视内容是否被推走（漂移）；
/// - **D4** `findChildIndexCallback` 缺失时元素/State 的复用代价
///   （reverse 列表在底部追加会让所有已有条目的**视图下标 +1**）；
/// - **D5** `reverse` 下 `ListView.padding` 的前导/后置语义（底部留白是否仍成立）；
/// - **D6** 生产实现（`ReadingAnchorItem` + `ReadingAnchorScrollPhysics`）：
///   离底长高不再推走可视内容、贴底仍保持「新内容顶上去」、易主时的取舍；
/// - **D7** 视口**上方**条目长高：不影响可视内容、也不误补偿；
/// - **D8** 手势方向：reverse 列表里向下/向上拖动各把 `pixels` 带向哪边
///   （决定测试脚手架里「滚到底部」该往哪个方向拖）。
///
/// 运行：`flutter test .agents/perf/reverse_anchor_probe_test.dart`
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/reading_anchor.dart';

/// 普通条目高度。
const double _kItemH = 120;

/// 视口高度（测试面版默认 800×600）。
const double _kViewportH = 600;

/// 合成列表配置（通过 [ValueNotifier] 驱动，避免重建 `MaterialApp` 造成
/// 主题依赖子树整体重建而干扰测量）。
class _Cfg {
  const _Cfg({
    this.count = 20,
    this.extraLogical,
    this.extraHeight = 0,
    this.reverse = true,
    this.withKeys = true,
    this.withCallback = true,
    this.withStateProbe = false,
    this.padding = const EdgeInsets.fromLTRB(20, 24, 20, 200),
  });

  final int count;

  /// 额外长高的逻辑条目下标（null = 无）。
  final int? extraLogical;
  final double extraHeight;

  final bool reverse;
  final bool withKeys;
  final bool withCallback;
  final bool withStateProbe;
  final EdgeInsets padding;

  double heightOf(int logical) =>
      _kItemH + (logical == extraLogical ? extraHeight : 0);

  _Cfg copyWith({int? count, int? extraLogical, double? extraHeight}) => _Cfg(
    count: count ?? this.count,
    extraLogical: extraLogical ?? this.extraLogical,
    extraHeight: extraHeight ?? this.extraHeight,
    reverse: reverse,
    withKeys: withKeys,
    withCallback: withCallback,
    withStateProbe: withStateProbe,
    padding: padding,
  );
}

/// D4 用：统计 State 生命周期事件。
class _StateStats {
  static int inits = 0;
  static int idMismatches = 0;
  static void reset() {
    inits = 0;
    idMismatches = 0;
  }
}

class _StateProbe extends StatefulWidget {
  const _StateProbe({required this.logical});

  final int logical;

  @override
  State<_StateProbe> createState() => _StateProbeState();
}

class _StateProbeState extends State<_StateProbe> {
  late int _boundLogical;

  @override
  void initState() {
    super.initState();
    _boundLogical = widget.logical;
    _StateStats.inits++;
  }

  @override
  void didUpdateWidget(covariant _StateProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一个 State 被复用给了**另一个**逻辑条目 = 元素按下标误复用。
    if (widget.logical != _boundLogical) {
      _StateStats.idMismatches++;
      _boundLogical = widget.logical;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _ProbeList extends StatelessWidget {
  const _ProbeList({required this.cfg, required this.controller, this.anchor});

  final ValueNotifier<_Cfg> cfg;
  final ScrollController controller;

  /// 非 null 时套用**生产**的阅读位置锚定（[ReadingAnchorItem] +
  /// [ReadingAnchorScrollPhysics]），用于在合成宿主里复测 D6/D7。
  final ReadingAnchor? anchor;

  int? _viewIndexOf(_Cfg c, Key key) {
    final value = (key as ValueKey<String>).value;
    final logical = int.parse(value.substring(1));
    final index = c.reverse ? c.count - 1 - logical : logical;
    if (index < 0 || index >= c.count) return null;
    return index;
  }

  @override
  Widget build(BuildContext context) {
    final anchor = this.anchor;
    return MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<_Cfg>(
          valueListenable: cfg,
          builder: (context, c, _) => ListView.builder(
            controller: controller,
            physics: anchor == null
                ? null
                : ReadingAnchorScrollPhysics(anchor: anchor),
            reverse: c.reverse,
            padding: c.padding,
            itemCount: c.count,
            findChildIndexCallback: c.withCallback
                ? (key) => _viewIndexOf(c, key)
                : null,
            itemBuilder: (context, index) {
              // reverse 下视图下标 0 在视觉底部 → 逻辑序号反转。
              final logical = c.reverse ? c.count - 1 - index : index;
              final child = Container(
                height: c.heightOf(logical),
                alignment: Alignment.topLeft,
                color: logical.isEven ? Colors.blue.shade50 : Colors.red.shade50,
                child: Text('item $logical'),
              );
              // ⚠️ 稳定 key 必须落在 delegate 的**直接子项**上：否则框架
              // 无法按 key 把元素搬回新下标（D4）。
              final item = Column(
                key: c.withKeys ? ValueKey('k$logical') : null,
                mainAxisSize: MainAxisSize.min,
                children: [
                  child,
                  if (c.withStateProbe) _StateProbe(logical: logical),
                ],
              );
              if (anchor == null) return item;
              // 生产接线：只让「逻辑末尾」（reverse 下视觉底部）那一条参与测量。
              return ReadingAnchorItem(
                anchor: anchor,
                active: logical == c.count - 1,
                child: item,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 视口（`ListView` 本体）的全局几何。
Rect _listRect(WidgetTester tester) =>
    tester.getRect(find.byType(ListView).first);

ScrollPosition _pos(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

double _topOf(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

Future<void> _mount(
  WidgetTester tester,
  ValueNotifier<_Cfg> cfg,
  ScrollController controller, {
  ReadingAnchor? anchor,
}) => tester.pumpWidget(
  _ProbeList(cfg: cfg, controller: controller, anchor: anchor),
);

void main() {
  testWidgets('D1 贴底追加条目：pixels 由框架保持，无越界帧', (tester) async {
    final cfg = ValueNotifier<_Cfg>(const _Cfg(count: 20));
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, cfg, controller);
    expect(_pos(tester).pixels, 0, reason: 'reverse：初始即位于底部（pixels == 0）');
    expect(_pos(tester).maxScrollExtent, greaterThan(0), reason: '内容必须溢出');

    cfg.value = cfg.value.copyWith(count: 21);
    final frames = <double>[];
    for (var i = 0; i < 12; i++) {
      frames.add(_pos(tester).pixels);
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(milliseconds: 16));
    }
    final pinned = _pos(tester).pixels;
    final bottomGap =
        _listRect(tester).bottom -
        tester.getBottomLeft(find.byKey(const ValueKey('k20'))).dy;

    // ignore: avoid_print
    print(
      '--- D1 贴底追加 ---\n'
      '  帧内 pixels 采样=$frames\n'
      '  追加后 pixels=$pinned（期望 0，无需任何脚本 jumpTo）\n'
      '  新条目底边距视口底=$bottomGap（前导 padding=200）',
    );

    expect(pinned, 0, reason: 'reverse 列表在 index 0 插入新子项不改变 pixels');
    expect(frames.every((p) => p >= -0.5), isTrue, reason: '不得出现负向越界帧');
    final maxNow = _pos(tester).maxScrollExtent;
    expect(
      frames.every((p) => p <= maxNow + 0.5),
      isTrue,
      reason: '不得出现正向越界帧（现状 M2：最大越界 390.7px）',
    );
    expect(bottomGap, closeTo(200, 1), reason: '底部留白（padding.bottom）语义不变');
  });

  testWidgets('D2/D3 离底后内容增长：可视内容被推走（漂移）', (tester) async {
    final cfg = ValueNotifier<_Cfg>(const _Cfg(count: 20));
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, cfg, controller);
    controller.jumpTo(300);
    await tester.pump();
    expect(_pos(tester).pixels, closeTo(300, 0.5));

    const reference = 'item 17';
    final topBefore = _topOf(tester, reference);
    final pxBefore = _pos(tester).pixels;

    // (a) 追加一条 120px 新条目。
    cfg.value = cfg.value.copyWith(count: 21);
    await tester.pump();
    await tester.pump();
    final appendDrift = _topOf(tester, reference) - topBefore;
    final appendPixels = _pos(tester).pixels;

    // (b) 底部条目长高 60px。
    cfg.value = cfg.value.copyWith(extraLogical: 20, extraHeight: 60);
    await tester.pump();
    await tester.pump();
    final growDrift = _topOf(tester, reference) - topBefore;
    final growPixels = _pos(tester).pixels;

    // ignore: avoid_print
    print(
      '--- D2/D3 离底内容增长（无补偿）---\n'
      '  追加 120px：参考项位移 ${appendDrift.toStringAsFixed(1)}px，'
      'pixels $pxBefore → $appendPixels\n'
      '  再长高 60px：参考项累计位移 ${growDrift.toStringAsFixed(1)}px，'
      'pixels → $growPixels',
    );

    expect(appendDrift, lessThan(-100), reason: '预期复现：追加的条目把可视内容整段推上去');
    expect(growDrift, lessThan(-150), reason: '预期复现：底部条目长高继续推走可视内容');
  });

  testWidgets('D4 findChildIndexCallback 缺失时的元素复用代价', (tester) async {
    Future<({int inits, int mismatches})> run({
      required bool withKeys,
      required bool withCallback,
    }) async {
      final cfg = ValueNotifier<_Cfg>(
        _Cfg(
          count: 20,
          withKeys: withKeys,
          withCallback: withCallback,
          withStateProbe: true,
        ),
      );
      final controller = ScrollController();
      await _mount(tester, cfg, controller);
      await tester.pump();
      await tester.pump();
      _StateStats.reset(); // 首帧/懒构建不计入
      cfg.value = cfg.value.copyWith(count: 21);
      await tester.pump();
      await tester.pump();
      final stats = (
        inits: _StateStats.inits,
        mismatches: _StateStats.idMismatches,
      );
      controller.dispose();
      cfg.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      return stats;
    }

    final keyed = await run(withKeys: true, withCallback: true);
    final keyedNoCallback = await run(withKeys: true, withCallback: false);
    final bare = await run(withKeys: false, withCallback: false);

    // ignore: avoid_print
    print(
      '--- D4 元素/State 复用（追加 1 条后：新建 State 数 / 错绑条目数）---\n'
      '  key + findChildIndexCallback：initState=${keyed.inits} 错绑=${keyed.mismatches}\n'
      '  key（无回调）：initState=${keyedNoCallback.inits} 错绑=${keyedNoCallback.mismatches}\n'
      '  无 key（无回调）：initState=${bare.inits} 错绑=${bare.mismatches}',
    );

    expect(keyed.inits, lessThanOrEqualTo(1), reason: '有回调 → 只有新追加的那一条新建 State');
    expect(keyed.mismatches, 0, reason: '有回调 → State 绑定关系不被破坏');
    expect(
      keyedNoCallback.inits + keyedNoCallback.mismatches,
      greaterThan(0),
      reason: '缺回调 → 元素按下标误复用或整段重建（丢 State）',
    );
  });

  testWidgets('D5 reverse 下 padding 前导/后置语义', (tester) async {
    final cfg = ValueNotifier<_Cfg>(const _Cfg(count: 20));
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, cfg, controller);
    final pos = _pos(tester);
    final rect = _listRect(tester);

    // 内容 = 20×120 = 2400；前导（底部留白）= 200、后置（顶部）= 24。
    final expectedMax = 2400 + 200 + 24 - rect.height;
    final bottomGap =
        rect.bottom - tester.getBottomLeft(find.byKey(const ValueKey('k19'))).dy;
    // ignore: avoid_print
    print(
      '--- D5 padding 语义 ---\n'
      '  初始 pixels=${pos.pixels}（0 = 底部）\n'
      '  maxScrollExtent=${pos.maxScrollExtent}（期望 ${expectedMax.toStringAsFixed(1)}）\n'
      '  末条底边距视口底=$bottomGap（期望 = padding.bottom = 200）',
    );

    expect(rect.height, closeTo(_kViewportH, 0.5), reason: '视口高度前提');
    expect(pos.pixels, 0);
    expect(
      pos.maxScrollExtent,
      closeTo(expectedMax, 1),
      reason: 'reverse 下 padding.bottom 是**前导**（贴底一侧）、padding.top 是后置',
    );
    expect(bottomGap, closeTo(200, 1), reason: '底部留白 = padding.bottom');
  });

  testWidgets('D6 生产实现（ReadingAnchorItem + ReadingAnchorScrollPhysics）：补偿效果', (
    tester,
  ) async {
    Future<({double drift, double pixels})> run({
      required int count,
      int? newCount,
      int? extraLogical,
      double extraHeight = 0,
      double startOffset = 300,
      required String reference,
    }) async {
      final anchor = ReadingAnchor();
      final cfg = ValueNotifier<_Cfg>(_Cfg(count: count));
      final controller = ScrollController();
      await _mount(tester, cfg, controller, anchor: anchor);
      controller.jumpTo(startOffset);
      await tester.pump();
      final topBefore = _topOf(tester, reference);
      cfg.value = cfg.value.copyWith(
        count: newCount ?? count,
        extraLogical: extraLogical,
        extraHeight: extraHeight,
      );
      await tester.pump();
      await tester.pump();
      final result = (
        drift: _topOf(tester, reference) - topBefore,
        pixels: _pos(tester).pixels,
      );
      controller.dispose();
      cfg.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      return result;
    }

    // (a) 离底 + 末尾条目**长高** → 补偿（pixels 后移同样的量）。
    final grew = await run(
      count: 20,
      extraLogical: 19,
      extraHeight: 60,
      reference: 'item 17',
    );
    // ignore: avoid_print
    print(
      '--- D6a 离底 + 末尾长高 60px（生产实现）--- 参考项位移=${grew.drift.toStringAsFixed(1)}px，'
      'pixels=300 → ${grew.pixels}（期望 360）',
    );
    expect(grew.drift.abs(), lessThan(1), reason: '视口下方长高不得推动阅读位置');
    expect(grew.pixels, closeTo(360, 1), reason: '补偿量 = 长高量');

    // (b) 离底 + **追加新条目**：末尾条目易主 → 重新对基（不补偿）。
    //     这是刻意的保守取舍：易主既可能是「同一个位置换了高度」（对基会漏补），
    //     也可能是「新条目根本没被构建过」（按高度差补会凭空跳一段）。
    final appended = await run(count: 20, newCount: 21, reference: 'item 17');
    // ignore: avoid_print
    print(
      '--- D6b 离底 + 追加条目（生产实现）--- 参考项位移=${appended.drift.toStringAsFixed(1)}px、'
      'pixels=300 → ${appended.pixels}（易主 → 不补偿，已知取舍）',
    );
    expect(appended.pixels, closeTo(300, 1), reason: '条目易主时不对基补偿');

    // (c) 贴底 + 末尾长高 → 不补偿（新内容把旧内容顶上去）。
    final atBottomGrow = await run(
      count: 20,
      extraLogical: 19,
      extraHeight: 120,
      startOffset: 0,
      reference: 'item 17',
    );
    // ignore: avoid_print
    print(
      '--- D6c 贴底 + 末尾长高 120px（生产实现）--- pixels=${atBottomGrow.pixels}（期望仍为 0）',
    );
    expect(atBottomGrow.pixels, 0, reason: '贴底时不得补偿');

    // (d) 贴底 + 追加条目 → 同样贴底。
    final atBottomAppend = await run(
      count: 20,
      newCount: 21,
      startOffset: 0,
      reference: 'item 17',
    );
    // ignore: avoid_print
    print(
      '--- D6d 贴底 + 追加条目（生产实现）--- pixels=${atBottomAppend.pixels}（期望仍为 0）',
    );
    expect(atBottomAppend.pixels, 0, reason: '贴底时不得补偿');
  });

  testWidgets('D7 视口上方条目长高：不产生可见位移、也不误补偿', (tester) async {
    final anchor = ReadingAnchor();
    final cfg = ValueNotifier<_Cfg>(const _Cfg(count: 20));
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, cfg, controller, anchor: anchor);
    controller.jumpTo(300);
    await tester.pump();

    // logical 13 的区间（reverse 坐标系）= [920, 1040]：在视口顶（900）之上、
    // cache 区内 → 被布局但不在视口内；它长高**不应**推动视口内容。
    const reference = 'item 17';
    final topBefore = _topOf(tester, reference);
    cfg.value = cfg.value.copyWith(extraLogical: 13, extraHeight: 60);
    await tester.pump();
    await tester.pump();
    final drift = _topOf(tester, reference) - topBefore;

    // ignore: avoid_print
    print(
      '--- D7 上方条目长高 60px（生产实现）--- 参考项位移=${drift.toStringAsFixed(1)}px，'
      'pixels=300 → ${_pos(tester).pixels}（期望 300：只有末尾条目参与测量）',
    );
    expect(drift.abs(), lessThan(1), reason: '上方条目长高不影响可视内容');
    expect(_pos(tester).pixels, closeTo(300, 1), reason: '不得误补偿');
  });

  testWidgets('D8 手势方向：reverse 列表里向下/向上拖动各把 pixels 带向哪边', (tester) async {
    final cfg = ValueNotifier<_Cfg>(const _Cfg(count: 20));
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, cfg, controller);
    expect(_pos(tester).pixels, 0, reason: '初始在底部');

    // 向下拖动（手指向下 300px）。
    final down = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await down.moveBy(const Offset(0, 300));
    await tester.pump();
    final afterDown = _pos(tester).pixels;
    await down.up();
    await tester.pump();

    // 向上拖动（手指向上 300px）。
    controller.jumpTo(0);
    await tester.pump();
    final upGesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await upGesture.moveBy(const Offset(0, -300));
    await tester.pump();
    final afterUp = _pos(tester).pixels;
    await upGesture.up();
    await tester.pump();

    // ignore: avoid_print
    print(
      '--- D8 手势方向 --- 手指向下 300px：pixels 0 → $afterDown；'
      '手指向上 300px：pixels 0 → $afterUp（max=${_pos(tester).maxScrollExtent}）',
    );
  });
}
