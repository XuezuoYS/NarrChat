import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/utils/cover_crop_geometry.dart';

/// 封面裁剪几何：cover 适配、旋转后的最小缩放、位移夹取（保证不露白边）。
void main() {
  const viewport = Size(200, 300);

  /// 断言「取景框四个角都落在图片里」（也就是没有露出底色）。
  void expectCoversViewport(CoverCropGeometry geometry) {
    final halfViewW = geometry.viewportSize.width / 2;
    final halfViewH = geometry.viewportSize.height / 2;
    final halfImageW = geometry.displaySize.width / 2;
    final halfImageH = geometry.displaySize.height / 2;
    final cos = math.cos(geometry.angle);
    final sin = math.sin(geometry.angle);
    for (final corner in <Offset>[
      Offset(-halfViewW, -halfViewH),
      Offset(halfViewW, -halfViewH),
      Offset(halfViewW, halfViewH),
      Offset(-halfViewW, halfViewH),
    ]) {
      final dx = corner.dx - geometry.offset.dx;
      final dy = corner.dy - geometry.offset.dy;
      // 取景框坐标 → 图片局部坐标（反向旋转）。
      final localX = dx * cos + dy * sin;
      final localY = -dx * sin + dy * cos;
      expect(
        localX.abs(),
        lessThanOrEqualTo(halfImageW + 1e-6),
        reason: '角 $corner 横向露白：$geometry',
      );
      expect(
        localY.abs(),
        lessThanOrEqualTo(halfImageH + 1e-6),
        reason: '角 $corner 纵向露白：$geometry',
      );
    }
  }

  group('初始状态', () {
    test('cover 适配：不缩放不旋转、居中，刚好铺满取景框', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(600, 300),
        viewportSize: viewport,
      );
      expect(geometry.zoom, 1);
      expect(geometry.angle, 0);
      expect(geometry.offset, Offset.zero);
      // baseScale = max(200/600, 300/300) = 1。
      expect(geometry.baseScale, 1);
      expect(geometry.displaySize, const Size(600, 300));
      expect(geometry.minZoom, 1);
      expectCoversViewport(geometry);
    });

    test('竖图：按高度撑满，宽度溢出（左右居中裁掉）', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(300, 600),
        viewportSize: viewport,
      );
      // baseScale = max(200/300, 300/600) = 0.6667。
      expect(geometry.baseScale, closeTo(2 / 3, 1e-9));
      expect(geometry.displaySize.width, closeTo(200, 1e-9));
      expect(geometry.displaySize.height, closeTo(400, 1e-9));
      expectCoversViewport(geometry);
    });
  });

  group('缩放夹取', () {
    final geometry = CoverCropGeometry(
      imageSize: const Size(600, 300),
      viewportSize: viewport,
    );

    test('低于 cover 适配会被抬回 1', () {
      expect(geometry.zoomTo(0.2).zoom, 1);
    });

    test('高于上限会被压到 maxZoom', () {
      expect(geometry.zoomTo(1000).zoom, CoverCropGeometry.maxZoom);
      expect(geometry.scaleBy(1e6).zoom, CoverCropGeometry.maxZoom);
    });

    test('放大后显示尺寸按倍率增长', () {
      final zoomed = geometry.zoomTo(2);
      expect(zoomed.displaySize, const Size(1200, 600));
      expectCoversViewport(zoomed);
    });
  });

  group('旋转夹取', () {
    test('90° 整格旋转只改角度', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(600, 300),
        viewportSize: viewport,
      );
      final rotated = geometry.rotateBy(math.pi / 2);
      expect(rotated.angle, closeTo(math.pi / 2, 1e-9));
      expect(rotated.zoom, 1, reason: '横向图转 90° 仍然铺满，不需要放大');
      expectCoversViewport(rotated);
    });

    test('旋转中允许四角漏白：缩放倍数不变、画面不自动放大', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(300, 300),
        viewportSize: viewport,
      );
      final rotated = geometry.rotateTo(math.pi / 4);
      // 正方形图 300×300、取景框 200×300、转 45°：
      // 要铺满需要 (200+300)/√2 ÷ 300 ≈ 1.1785 倍。
      final expected = (200 + 300) / math.sqrt2 / 300;
      expect(rotated.minZoom, closeTo(expected, 1e-9));
      expect(rotated.zoom, 1, reason: '旋转过程中不偷偷放大');
      expect(
        rotated.displayScale,
        closeTo(geometry.baseScale, 1e-9),
        reason: '画面保持原尺寸，四角先露白（这正是用户要的）',
      );
    });

    test('settle：旋转停稳后把画面补到刚好铺满', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(300, 300),
        viewportSize: viewport,
      );
      final rotated = geometry.rotateTo(math.pi / 4);
      final settled = rotated.settle();
      expect(settled.zoom, closeTo(rotated.minZoom, 1e-9));
      expect(settled.displayScale, closeTo(geometry.baseScale * rotated.minZoom, 1e-9));
      expectCoversViewport(settled);
    });

    test('settle：本来就铺满时原样返回（不多建对象）', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(300, 300),
        viewportSize: viewport,
      ).zoomTo(2);
      expect(geometry.settle(), same(geometry));
    });

    test('settle：缩小后漏白也能补回来', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(300, 300),
        viewportSize: viewport,
      ).zoomTo(2).rotateTo(0.6).zoomTo(0.2);
      expect(geometry.zoom, 1, reason: '缩放下限是 1，允许暂时漏白');
      final settled = geometry.settle();
      expect(settled.zoom, closeTo(geometry.minZoom, 1e-9));
      expectCoversViewport(settled);
    });

    test('转回 0° ：角度归一化，画面回到「刚好铺满」', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(300, 300),
        viewportSize: viewport,
      );
      final roundTrip = geometry.rotateTo(math.pi / 4).rotateTo(0);
      expect(roundTrip.angle, 0);
      expect(roundTrip.zoom, 1);
      expect(roundTrip.minZoom, 1);
      expect(roundTrip.displayScale, closeTo(geometry.baseScale, 1e-9));
    });

    test('旋转过程中缩放条数值保持不变（用户抱怨的「旋转时缩放条会动」）', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(300, 300),
        viewportSize: viewport,
      ).zoomTo(2.5);
      for (final angle in [0.3, math.pi / 4, math.pi / 2, 2.0]) {
        final rotated = geometry.rotateTo(angle);
        expect(rotated.zoom, 2.5, reason: '$angle rad 下倍数不应变化');
      }
    });

    test('角度收敛到 (-π, π]', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(600, 300),
        viewportSize: viewport,
      );
      expect(geometry.rotateBy(math.pi * 3).angle, closeTo(math.pi, 1e-9));
      expect(geometry.rotateBy(-math.pi * 3).angle, closeTo(math.pi, 1e-9));
      expect(geometry.rotateBy(-math.pi / 2).angle, closeTo(-math.pi / 2, 1e-9));
    });
  });

  group('位移夹取', () {
    final geometry = CoverCropGeometry(
      imageSize: const Size(600, 300),
      viewportSize: viewport,
    );

    test('刚好铺满时不能移动（没有多余画面）', () {
      // 2:3 的图 cover 适配后与取景框完全重合，两个方向都没有余量。
      final exact = CoverCropGeometry(
        imageSize: const Size(200, 300),
        viewportSize: viewport,
      );
      expect(exact.pan(const Offset(50, 50)).offset, Offset.zero);
      expect(exact.pan(const Offset(-1e6, 1e6)).offset, Offset.zero);
    });

    test('只有一个方向有余量时只允许该方向移动', () {
      // 600×300 cover 适配到 200×300 取景框：高度刚好、宽度余量 200。
      expect(geometry.pan(const Offset(50, 50)).offset, const Offset(50, 0));
      expect(
        geometry.pan(const Offset(-1e6, 1e6)).offset,
        const Offset(-200, 0),
      );
    });

    test('放大后按余量夹取', () {
      // 放大 2 倍：显示 1200×600，相对取景框余量是 (1200-200)/2=500 与 (600-300)/2=150。
      final zoomed = geometry.zoomTo(2);
      expect(zoomed.pan(const Offset(50, 50)).offset, const Offset(50, 50));
      expect(
        zoomed.pan(const Offset(1e6, -1e6)).offset,
        const Offset(500, -150),
      );
      expectCoversViewport(zoomed.pan(const Offset(1e6, -1e6)));
    });

    test('旋转 + 缩放 + 位移组合：settle 之后一定不露白', () {
      const images = <Size>[
        Size(300, 300),
        Size(600, 300),
        Size(300, 600),
        Size(1000, 200),
      ];
      const angles = <double>[0, 0.3, math.pi / 4, math.pi / 2, math.pi, -2.5];
      const zooms = <double>[1, 1.5, 3, 1000];
      const offsets = <Offset>[
        Offset.zero,
        Offset(75, -40),
        Offset(-1e5, 1e5),
      ];
      for (final image in images) {
        for (final angle in angles) {
          for (final zoom in zooms) {
            for (final offset in offsets) {
              final geometry = CoverCropGeometry(
                imageSize: image,
                viewportSize: viewport,
              ).rotateTo(angle).zoomTo(zoom).pan(offset);
              // 中途允许漏白（旋转时四角可以没盖住），停下 settle 后必须铺满。
              final settled = geometry.settle();
              expectCoversViewport(settled);
              expect(
                settled.zoom,
                greaterThanOrEqualTo(geometry.zoom),
                reason: 'settle 只会放大，不会缩',
              );
            }
          }
        }
      }
    });

    test('漏白中的状态：settle 才把缩放补上去（中途不改倍数）', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(300, 300),
        viewportSize: viewport,
      ).rotateTo(math.pi / 4);
      expect(geometry.zoom, 1);
      expect(geometry.settle().zoom, greaterThan(1));
    });
  });

  group('视口变化与重置', () {
    test('withViewport：位移按比例换算并重新夹取，仍不露白', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(600, 300),
        viewportSize: viewport,
      ).zoomTo(2).pan(const Offset(100, 100));
      final resized = geometry.withViewport(const Size(300, 450));
      expect(resized.viewportSize, const Size(300, 450));
      expect(resized.angle, geometry.angle);
      expectCoversViewport(resized);
    });

    test('withViewport 传相同尺寸时原样返回', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(600, 300),
        viewportSize: viewport,
      );
      expect(geometry.withViewport(viewport), same(geometry));
    });

    test('reset 回到初始状态', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(600, 300),
        viewportSize: viewport,
      ).rotateTo(0.8).zoomTo(3).pan(const Offset(120, 80));
      final reset = geometry.reset();
      expect(reset.zoom, 1);
      expect(reset.angle, 0);
      expect(reset.offset, Offset.zero);
    });
  });

  group('尺寸非法时安全兜底', () {
    test('取景框为 0：isUsable 为 false，方法不崩', () {
      final geometry = CoverCropGeometry(
        imageSize: const Size(600, 300),
        viewportSize: Size.zero,
      );
      expect(geometry.isUsable, isFalse);
      expect(geometry.zoom, 1);
      expect(geometry.angle, 0);
      expect(geometry.offset, Offset.zero);
      expect(geometry.rotateTo(1).angle, 0, reason: '不可用时回到默认状态');
      expect(geometry.pan(const Offset(10, 10)).offset, Offset.zero);
    });

    test('图片尺寸为 0：同样兜底', () {
      final geometry = CoverCropGeometry(
        imageSize: Size.zero,
        viewportSize: viewport,
      );
      expect(geometry.isUsable, isFalse);
      expect(geometry.minZoom, 1);
    });
  });
}
