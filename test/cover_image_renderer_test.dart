import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/cover_image_renderer.dart';
import 'package:narrchat/utils/cover_crop_geometry.dart';

/// 封面渲染：输出必须是 2 : 3 的 PNG，画面与几何描述一致（居中 / 旋转 / 裁切）。
void main() {
  /// 造一张「左右两半」的图（左 [left]、右 [right]），用来验证水平方向的裁切。
  Future<ui.Image> makeSplitImage(
    int width,
    int height, {
    required ui.Color left,
    required ui.Color right,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final half = width / 2;
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, half, height.toDouble()),
      ui.Paint()..color = left,
    );
    canvas.drawRect(
      ui.Rect.fromLTWH(half, 0, half, height.toDouble()),
      ui.Paint()..color = right,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  /// 造一张四象限图（TL 红 / TR 绿 / BL 蓝 / BR 黄），用来验证旋转方向。
  Future<ui.Image> makeQuadrantImage(int size) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final half = size / 2;
    void rect(double left, double top, ui.Color color) {
      canvas.drawRect(
        ui.Rect.fromLTWH(left, top, half, half),
        ui.Paint()..color = color,
      );
    }

    rect(0, 0, const ui.Color(0xFFFF0000));
    rect(half, 0, const ui.Color(0xFF00FF00));
    rect(0, half, const ui.Color(0xFF0000FF));
    rect(half, half, const ui.Color(0xFFFFFF00));
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(size, size);
    } finally {
      picture.dispose();
    }
  }

  /// 解码 PNG 并取 RGBA 像素（便于断言画面内容）。
  Future<
    ({int width, int height, ByteData rgba})
  > decodePng(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        final rgba = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        return (
          width: frame.image.width,
          height: frame.image.height,
          rgba: rgba!,
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  /// 取某个像素的 RGB（忽略 alpha，便于 compare）。
  List<int> pixelAt(
    ({int width, int height, ByteData rgba}) image,
    int x,
    int y,
  ) {
    final offset = (y * image.width + x) * 4;
    return [
      image.rgba.getUint8(offset),
      image.rgba.getUint8(offset + 1),
      image.rgba.getUint8(offset + 2),
      image.rgba.getUint8(offset + 3),
    ];
  }

  /// 颜色断言：允许 1 的取整误差（缩放采样）。
  void expectColor(List<int> actual, ui.Color expected, {String? reason}) {
    expect(actual[0], closeTo((expected.r * 255).round(), 2), reason: reason);
    expect(actual[1], closeTo((expected.g * 255).round(), 2), reason: reason);
    expect(actual[2], closeTo((expected.b * 255).round(), 2), reason: reason);
    expect(
      actual[3],
      closeTo((expected.a * 255).round(), 0),
      reason: reason,
    );
  }

  test('输出恒定 2 : 3 的 PNG（600×900）', () async {
    final source = await makeSplitImage(
      90,
      60,
      left: const ui.Color(0xFFFF0000),
      right: const ui.Color(0xFF0000FF),
    );
    try {
      final geometry = CoverCropGeometry(
        imageSize: ui.Size(source.width.toDouble(), source.height.toDouble()),
        viewportSize: const ui.Size(200, 300),
      );
      final bytes = await renderCoverPng(image: source, geometry: geometry);
      // PNG 文件头。
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      final decoded = await decodePng(bytes);
      expect(decoded.width, kCoverOutputWidth);
      expect(decoded.height, kCoverOutputHeight);
    } finally {
      source.dispose();
    }
  });

  test('非 2 : 3 的图：居中等比放大裁切（左右两半仍各占一半）', () async {
    // 90×60 cover 适配到 200×300 取景框 → 放大 5 倍显示 450×300，
    // 横向裁掉两侧各 125，画面里正好是中缝附近的一条。
    final source = await makeSplitImage(
      90,
      60,
      left: const ui.Color(0xFFFF0000),
      right: const ui.Color(0xFF0000FF),
    );
    try {
      final geometry = CoverCropGeometry(
        imageSize: ui.Size(source.width.toDouble(), source.height.toDouble()),
        viewportSize: const ui.Size(200, 300),
      );
      final decoded = await decodePng(
        await renderCoverPng(image: source, geometry: geometry),
      );
      expectColor(
        pixelAt(decoded, 10, 450),
        const ui.Color(0xFFFF0000),
        reason: '左边缘应来自源图左半',
      );
      expectColor(
        pixelAt(decoded, 590, 450),
        const ui.Color(0xFF0000FF),
        reason: '右边缘应来自源图右半',
      );
    } finally {
      source.dispose();
    }
  });

  test('旋转 90°：四角颜色按顺时针方向对应源图四象限', () async {
    final source = await makeQuadrantImage(60);
    try {
      final geometry = CoverCropGeometry(
        imageSize: ui.Size(source.width.toDouble(), source.height.toDouble()),
        viewportSize: const ui.Size(200, 300),
      );
      // 顺时针转 90°：源左下 → 输出左上、源左上 → 输出右上，依次类推。
      final decoded = await decodePng(
        await renderCoverPng(
          image: source,
          geometry: geometry.rotateBy(math.pi / 2),
        ),
      );
      expectColor(pixelAt(decoded, 60, 60), const ui.Color(0xFF0000FF),
          reason: '左上 = 源左下');
      expectColor(pixelAt(decoded, 540, 60), const ui.Color(0xFFFF0000),
          reason: '右上 = 源左上');
      expectColor(pixelAt(decoded, 540, 840), const ui.Color(0xFF00FF00),
          reason: '右下 = 源右上');
      expectColor(pixelAt(decoded, 60, 840), const ui.Color(0xFFFFFF00),
          reason: '左下 = 源右下');
    } finally {
      source.dispose();
    }
  });

  test('缩放：放大后看到的源区域更窄（只取中间一条）', () async {
    final source = await makeSplitImage(
      90,
      60,
      left: const ui.Color(0xFFFF0000),
      right: const ui.Color(0xFF0000FF),
    );
    try {
      final base = CoverCropGeometry(
        imageSize: ui.Size(source.width.toDouble(), source.height.toDouble()),
        viewportSize: const ui.Size(200, 300),
      );
      // 改看源图最左侧一条（放大后向左平移到底）：整张输出都应是左侧颜色。
      final zoomed = base.zoomTo(3).pan(const ui.Offset(1000, 0));
      final decoded = await decodePng(
        await renderCoverPng(image: source, geometry: zoomed),
      );
      expectColor(pixelAt(decoded, 10, 450), const ui.Color(0xFFFF0000));
      expectColor(pixelAt(decoded, 590, 450), const ui.Color(0xFFFF0000),
          reason: '放大并移到最左后，右边缘也还在源图左半');
    } finally {
      source.dispose();
    }
  });

  test('尺寸非法：抛 StateError（不产出坏图）', () async {
    final source = await makeQuadrantImage(30);
    try {
      final geometry = CoverCropGeometry(
        imageSize: ui.Size(source.width.toDouble(), source.height.toDouble()),
        viewportSize: ui.Size.zero,
      );
      await expectLater(
        renderCoverPng(image: source, geometry: geometry),
        throwsA(isA<StateError>()),
      );
    } finally {
      source.dispose();
    }
  });

  test('UiCoverRenderer 委托给同一套渲染（结果尺寸一致）', () async {
    final source = await makeQuadrantImage(30);
    try {
      final geometry = CoverCropGeometry(
        imageSize: ui.Size(source.width.toDouble(), source.height.toDouble()),
        viewportSize: const ui.Size(200, 300),
      );
      final bytes = await const UiCoverRenderer().render(
        image: source,
        geometry: geometry,
      );
      final decoded = await decodePng(bytes);
      expect(decoded.width, kCoverOutputWidth);
      expect(decoded.height, kCoverOutputHeight);
    } finally {
      source.dispose();
    }
  });
}
