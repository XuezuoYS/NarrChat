import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/reading_anchor.dart';

/// [ReadingAnchor] / [ReadingAnchorItem] / [ReadingAnchorScrollPhysics] 的隔离层测试。
///
/// 被测行为：`reverse: true` 底部锚定列表里，**离底阅读期间**「视口下方条目长高」
/// 应被补偿回滚动偏移（阅读位置不动）；贴底时不得补偿（新内容要顶上来）。
void main() {
  group('ReadingAnchor', () {
    test('首次上报只对基，不产生增长量', () {
      final anchor = ReadingAnchor();
      expect(anchor.takeGrowth(), 0, reason: '从未上报 → 无增长');

      anchor.record(Object(), 120);
      expect(anchor.takeGrowth(), 0, reason: '首个高度只作为基线');
    });

    test('同一来源长高 → 增量即增长量，且读取后清零', () {
      final anchor = ReadingAnchor();
      final source = Object();
      anchor.record(source, 120);
      anchor.takeGrowth();

      anchor.record(source, 156);
      expect(anchor.takeGrowth(), 36);
      expect(anchor.takeGrowth(), 0, reason: '读取即清零（同一次布局的重试不重复补偿）');
    });

    test('来源更换 → 重新对基（不把新条目的绝对高度当增长）', () {
      final anchor = ReadingAnchor();
      anchor.record(Object(), 120);
      anchor.takeGrowth();

      anchor.record(Object(), 900);
      expect(
        anchor.takeGrowth(),
        0,
        reason: '末尾条目易主（流式插槽 → 落库气泡）时不得按 780px 补偿',
      );
    });

    test('变矮也如实上报（负增量）', () {
      final anchor = ReadingAnchor();
      final source = Object();
      anchor.record(source, 200);
      anchor.takeGrowth();
      anchor.record(source, 150);
      expect(anchor.takeGrowth(), -50);
    });
  });

  group('ReadingAnchorItem', () {
    testWidgets('只有 active 条目参与测量（高度变化被上报为增长量）', (tester) async {
      final anchor = ReadingAnchor();
      final activeHeight = ValueNotifier<double>(100);
      addTearDown(activeHeight.dispose);

      Widget host() => MaterialApp(
        home: ValueListenableBuilder<double>(
          valueListenable: activeHeight,
          builder: (context, height, _) => Column(
            children: [
              ReadingAnchorItem(
                anchor: anchor,
                active: true,
                child: SizedBox(height: height, width: 100),
              ),
              // inactive 条目更高；若它也上报，来源会变 → 下一帧读到的增量会是 0。
              ReadingAnchorItem(
                anchor: anchor,
                active: false,
                child: const SizedBox(height: 300, width: 100),
              ),
            ],
          ),
        ),
      );

      await tester.pumpWidget(host());
      expect(anchor.takeGrowth(), 0, reason: '首帧对基');

      activeHeight.value = 160;
      await tester.pump();
      expect(
        anchor.takeGrowth(),
        60,
        reason: 'active 条目长高 60px 应被上报（inactive 条目 300px 不参与）',
      );
    });

    testWidgets('纯代理：不改变被包裹子项的尺寸', (tester) async {
      final anchor = ReadingAnchor();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ReadingAnchorItem(
              anchor: anchor,
              active: true,
              child: const SizedBox(
                key: Key('anchor_probe_child'),
                height: 42,
                width: 77,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const Key('anchor_probe_child'))),
        const Size(77, 42),
        reason: '测量部件必须对布局透明（不改变子项尺寸）',
      );
    });
  });

  group('ReadingAnchorScrollPhysics', () {
    ScrollMetrics metrics({required double pixels, double max = 2000}) =>
        FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: max,
          pixels: pixels,
          viewportDimension: 800,
          axisDirection: AxisDirection.up,
          devicePixelRatio: 1.0,
        );

    /// 造一个「已上报 300 → 长高到 300 + growth」的锚点。
    ReadingAnchor anchored(double growth) {
      final anchor = ReadingAnchor();
      final source = Object();
      anchor.record(source, 300);
      anchor.takeGrowth();
      anchor.record(source, 300 + growth);
      return anchor;
    }

    test('离底 + 视口下方长高 → 滚动偏移按增长量推进', () {
      final physics = ReadingAnchorScrollPhysics(anchor: anchored(80));
      final pixels = physics.adjustPositionForNewDimensions(
        oldPosition: metrics(pixels: 500),
        newPosition: metrics(pixels: 500),
        isScrolling: false,
        velocity: 0,
      );
      expect(pixels, 580, reason: '内容长高 80px → 偏移后移 80px（视觉位置不动）');
    });

    test('贴底 + 长高 → 不补偿（保留「新内容顶上去」的语义）', () {
      final physics = ReadingAnchorScrollPhysics(anchor: anchored(80));
      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: metrics(pixels: 0),
          newPosition: metrics(pixels: 0),
          isScrolling: false,
          velocity: 0,
        ),
        0,
      );
    });

    test('无增长 → 不动', () {
      final physics = ReadingAnchorScrollPhysics(anchor: ReadingAnchor());
      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: metrics(pixels: 500),
          newPosition: metrics(pixels: 500),
          isScrolling: false,
          velocity: 0,
        ),
        500,
      );
    });

    test('补偿结果被夹取在合法范围（不越过 maxScrollExtent）', () {
      final physics = ReadingAnchorScrollPhysics(anchor: anchored(5000));
      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: metrics(pixels: 1900),
          newPosition: metrics(pixels: 1900),
          isScrolling: false,
          velocity: 0,
        ),
        2000,
      );
    });

    test('applyTo 传递同一个 anchor（与平台物理叠加后仍读到测量值）', () {
      final anchor = ReadingAnchor();
      final composed = ReadingAnchorScrollPhysics(
        anchor: anchor,
      ).applyTo(const ClampingScrollPhysics());
      expect(composed, isA<ReadingAnchorScrollPhysics>());
      expect(identical(composed.anchor, anchor), isTrue);
      expect(composed.parent, isA<ClampingScrollPhysics>());
    });
  });
}
