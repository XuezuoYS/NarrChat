import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/image_viewer_window.dart';

/// 桌面端图片查看器纯逻辑单测：适配比例、滚轮缩放（含焦点保持与边界钳制）、
/// 跨窗口入参的编解码。窗口本身的创建/显示不做单测（需真实桌面窗口）。
void main() {
  group('fitScale', () {
    test('正方形视口与正方形图片 → 1', () {
      expect(fitScale(100, 100, 100, 100), 1.0);
    });

    test('视口小于图片 → 按比例缩小', () {
      expect(fitScale(100, 100, 200, 200), 0.5);
    });

    test('取两轴更小者（contain）', () {
      // 横向可放 100/100=1，纵向 50/200=0.25 → 0.25
      expect(fitScale(100, 50, 100, 200), 0.25);
    });

    test('非法尺寸回退 1', () {
      expect(fitScale(100, 100, 0, 200), 1.0);
      expect(fitScale(0, 100, 100, 100), 1.0);
    });
  });

  group('zoomAt', () {
    test('放大：比例按 factor 变化', () {
      final m = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
      final out = zoomAt(m, const Offset(10, 10), 1.1,
          minScale: 1.0, maxScale: 5.0);
      expect(out.getMaxScaleOnAxis(), closeTo(2.2, 0.001));
    });

    test('缩小但被 minScale 钳制', () {
      final m = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
      final out = zoomAt(m, const Offset(10, 10), 0.1,
          minScale: 1.0, maxScale: 5.0);
      expect(out.getMaxScaleOnAxis(), closeTo(1.0, 0.001));
    });

    test('放大被 maxScale 钳制', () {
      final m = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
      final out = zoomAt(m, const Offset(10, 10), 100,
          minScale: 1.0, maxScale: 3.0);
      expect(out.getMaxScaleOnAxis(), closeTo(3.0, 0.001));
    });

    test('焦点在缩放前后保持不变（光标下的内容不动）', () {
      final m = Matrix4.identity()..scaleByDouble(1.5, 1.5, 1, 1);
      const focal = Offset(80, 40);
      final childFocal =
          MatrixUtils.transformPoint(Matrix4.inverted(m), focal);
      final out = zoomAt(m, focal, 1.2, minScale: 1.0, maxScale: 5.0);
      final after = MatrixUtils.transformPoint(out, childFocal);
      expect(after.dx, closeTo(focal.dx, 0.001));
      expect(after.dy, closeTo(focal.dy, 0.001));
    });

    test('factor 为 1 时不改变矩阵', () {
      final m = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
      final out = zoomAt(m, const Offset(10, 10), 1.0,
          minScale: 1.0, maxScale: 5.0);
      expect(out, m);
    });
  });

  group('imageScale', () {
    test('fit 缩放（<1）返回真实 2D 缩放，而非 getMaxScaleOnAxis 的 1', () {
      final m = Matrix4.identity()..scaleByDouble(0.5, 0.5, 1, 1);
      expect(imageScale(m), closeTo(0.5, 0.001));
    });

    test('放大（>1）正常', () {
      final m = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
      expect(imageScale(m), closeTo(2, 0.001));
    });
  });

  group('clampTransform', () {
    test('fit 缩放（<1）时按真实缩放居中（而非错误地按 1 计算）', () {
      final m = Matrix4.identity()..scaleByDouble(0.5, 0.5, 1, 1);
      final clamped = clampTransform(
        m,
        const Size(300, 300),
        const Size(200, 200),
      );
      // content = 200*0.5 = 100，两轴均 < 300 → 居中 (300-100)/2=100。
      expect(clamped.storage[12], closeTo(100, 0.001));
      expect(clamped.storage[13], closeTo(100, 0.001));
    });

    test('内容小于视口的轴（letterbox）居中', () {
      final clamped = clampTransform(
        Matrix4.identity(),
        const Size(200, 100),
        const Size(100, 100),
      );
      // X：内容 100 < 视口 200 → 居中 (200-100)/2=50；Y：内容 == 视口 → 0。
      expect(clamped.storage[12], closeTo(50, 0.001));
      expect(clamped.storage[13], closeTo(0, 0.001));
    });

    test('放大后平移被钳制到视口内（不出现黑边）', () {
      final m = Matrix4.identity();
      m.storage[12] = 100;
      m.storage[13] = 100;
      // 手动设 scale=2（对角项）。
      m.storage[0] = 2;
      m.storage[5] = 2;
      final clamped = clampTransform(
        m,
        const Size(200, 200),
        const Size(100, 100),
      );
      // 内容 200x200 == 视口 → 居中 (0,0)，把越界的 100 拉回。
      expect(clamped.storage[12], closeTo(0, 0.001));
      expect(clamped.storage[13], closeTo(0, 0.001));
    });

    test('内容两轴均小于视口时两轴居中', () {
      final clamped = clampTransform(
        Matrix4.identity(),
        const Size(400, 400),
        const Size(100, 50),
      );
      expect(clamped.storage[12], closeTo((400 - 100) / 2, 0.001)); // 150
      expect(clamped.storage[13], closeTo((400 - 50) / 2, 0.001)); // 175
    });
  });

  group('ImageWindowArgs', () {
    test('encode / tryDecode 往返一致', () {
      const args = ImageWindowArgs(
        images: ['img/a.png', 'img/b.png'],
        index: 1,
      );
      final decoded = ImageWindowArgs.tryDecode(args.encode());
      expect(decoded, isNotNull);
      expect(decoded!.images, ['img/a.png', 'img/b.png']);
      expect(decoded.index, 1);
    });

    test('非法输入返回 null', () {
      expect(ImageWindowArgs.tryDecode('not json'), isNull);
      expect(ImageWindowArgs.tryDecode('{"images":[]}'), isNull);
      expect(ImageWindowArgs.tryDecode(''), isNull);
      expect(ImageWindowArgs.tryDecode('{"images":["a.png"]}'), isNotNull);
    });

    test('warm 预热窗口编码 / 解码往返一致（允许空图片列表）', () {
      const args = ImageWindowArgs(images: [], index: 0, warm: true);
      final decoded = ImageWindowArgs.tryDecode(args.encode());
      expect(decoded, isNotNull);
      expect(decoded!.warm, isTrue);
      expect(decoded.images, isEmpty);
      expect(decoded.index, 0);
    });

    test('非 warm 窗口解码时 warm 为 false', () {
      final decoded = ImageWindowArgs.tryDecode('{"images":["a.png"],"index":2}');
      expect(decoded!.warm, isFalse);
      expect(decoded.index, 2);
    });
  });

  group('tryDecodeLoadPayload', () {
    test('合法载荷解析出图片组与序号', () {
      final params =
          tryDecodeLoadPayload({'images': ['a.png', 'b.png'], 'index': 3});
      expect(params, isNotNull);
      expect(params!.images, ['a.png', 'b.png']);
      expect(params.index, 3);
    });

    test('缺省 index 默认为 0', () {
      final params = tryDecodeLoadPayload({'images': ['a.png']});
      expect(params!.index, 0);
    });

    test('非 map / 空图片列表 / 非字符串列表返回 null', () {
      expect(tryDecodeLoadPayload(null), isNull);
      expect(tryDecodeLoadPayload('x'), isNull);
      expect(tryDecodeLoadPayload({'images': <String>[]}), isNull);
      expect(tryDecodeLoadPayload({'images': [1, 2]}), isNull);
    });
  });
}
