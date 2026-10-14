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

    test('applyTo 同样传递锁顶边锚（与平台物理叠加后仍读得到请求）', () {
      final lock = ScrollLockAnchor();
      final composed = ReadingAnchorScrollPhysics(
        anchor: ReadingAnchor(),
        lock: lock,
      ).applyTo(const ClampingScrollPhysics());
      expect(identical(composed.lock, lock), isTrue);
    });
  });

  group('ScrollLockAnchor（展开 / 收起补偿请求）', () {
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

    test('请求的偏移在布局阶段补进位置，且读取即清零', () {
      final lock = ScrollLockAnchor()..request(shift: 300);
      final physics = ReadingAnchorScrollPhysics(
        anchor: ReadingAnchor(),
        lock: lock,
      );
      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: metrics(pixels: 500),
          newPosition: metrics(pixels: 500),
          isScrolling: false,
          velocity: 0,
        ),
        800,
        reason: '展开 300px → 偏移 +300（顶边视觉位置不动）',
      );
      expect(lock.takeRequest().isEmpty, isTrue, reason: '同一次布局的重试不重复补偿');
    });

    test('贴底也要补：贴底展开正是「内容向下铺开」需要的那次滚动', () {
      final physics = ReadingAnchorScrollPhysics(
        anchor: ReadingAnchor(),
        lock: ScrollLockAnchor()..request(shift: 300),
      );
      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: metrics(pixels: 0),
          newPosition: metrics(pixels: 0),
          isScrolling: false,
          velocity: 0,
        ),
        300,
        reason: '阅读锚定的贴底规则不适用于用户主动展开',
      );
    });

    test('补偿用**新**范围夹取：超过新 max 时停在端点，不会反向', () {
      final physics = ReadingAnchorScrollPhysics(
        anchor: ReadingAnchor(),
        lock: ScrollLockAnchor()..request(shift: 5000),
      );
      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: metrics(pixels: 1900, max: 2000),
          newPosition: metrics(pixels: 1900, max: 2000),
          isScrolling: false,
          velocity: 0,
        ),
        2000,
      );
    });

    test('零偏移 + 压掉锚定增长：位置完全不动（顶边已滚出视口时的收起）', () {
      final physics = ReadingAnchorScrollPhysics(
        anchor: anchored(-800),
        lock: ScrollLockAnchor()..request(suppressAnchorGrowth: true),
      );
      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: metrics(pixels: 500),
          newPosition: metrics(pixels: 500),
          isScrolling: false,
          velocity: 0,
        ),
        500,
        reason: '用户主动改高度时不该被当成「视口下方长高」再补一次',
      );
      // 压掉只作用于这一次布局。
      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: metrics(pixels: 500),
          newPosition: metrics(pixels: 500),
          isScrolling: false,
          velocity: 0,
        ),
        500,
        reason: '增长量已被清零，后续布局不再补偿',
      );
    });

    test('锁顶边与阅读锚定的增长各自独立相加', () {
      final physics = ReadingAnchorScrollPhysics(
        anchor: anchored(80),
        lock: ScrollLockAnchor()..request(shift: 40),
      );
      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: metrics(pixels: 500),
          newPosition: metrics(pixels: 500),
          isScrolling: false,
          velocity: 0,
        ),
        620,
        reason: '两件事分别补：展开 40 + 视口下方长高 80',
      );
    });

    test('未声明压掉时，锚定增长照旧补偿', () {
      final physics = ReadingAnchorScrollPhysics(
        anchor: anchored(80),
        lock: ScrollLockAnchor()..request(shift: 40, suppressAnchorGrowth: false),
      );
      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: metrics(pixels: 500),
          newPosition: metrics(pixels: 500),
          isScrolling: false,
          velocity: 0,
        ),
        620,
      );
    });

    test('极小的请求被忽略（不产生无意义位移）', () {
      final physics = ReadingAnchorScrollPhysics(
        anchor: ReadingAnchor(),
        lock: ScrollLockAnchor()..request(shift: 0.2),
      );
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
  });
}
