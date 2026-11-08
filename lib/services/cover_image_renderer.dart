import 'dart:typed_data';
import 'dart:ui' as ui;

import '../utils/cover_crop_geometry.dart';

/// 封面裁剪结果的渲染器（可注入替身，避免用例里真的去光栅化）。
abstract class CoverRenderer {
  /// 把 [geometry] 描述的画面渲染成**2 : 3** 的 PNG 字节。
  Future<Uint8List> render({
    required ui.Image image,
    required CoverCropGeometry geometry,
  });
}

/// 真实实现：用 `dart:ui` 直接光栅化。
///
/// 界面预览与导出用的是同一份 [CoverCropGeometry]（只是把「取景框像素」
/// 换成「输出像素」按比例放大），所以所见即所得，不会出现「预览对、导出偏」。
class UiCoverRenderer implements CoverRenderer {
  const UiCoverRenderer();

  @override
  Future<Uint8List> render({
    required ui.Image image,
    required CoverCropGeometry geometry,
  }) {
    return renderCoverPng(image: image, geometry: geometry);
  }
}

/// 把取景框里的画面渲染成 2 : 3 的 PNG 字节（纯函数，便于单测）。
///
/// 变换顺序与预览完全一致：
/// `平移到输出中心 → 放大到输出尺寸 → 平移 → 旋转 → 按 displayScale 缩放`，
/// 最后把原图按中心对齐画上去，超出画布的部分由 [ui.Picture.toImage] 裁掉。
Future<Uint8List> renderCoverPng({
  required ui.Image image,
  required CoverCropGeometry geometry,
  int outWidth = kCoverOutputWidth,
  int outHeight = kCoverOutputHeight,
}) async {
  assert(outWidth * 3 == outHeight * 2, '封面导出必须保持 2 : 3');
  if (!geometry.isUsable) {
    throw StateError('封面裁剪参数不完整（图片或取景框尺寸为 0）');
  }
  final viewport = geometry.viewportSize;
  final outScale = outWidth / viewport.width;
  final imageWidth = image.width.toDouble();
  final imageHeight = image.height.toDouble();

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.translate(outWidth / 2, outHeight / 2);
  canvas.scale(outScale, outScale);
  canvas.translate(geometry.offset.dx, geometry.offset.dy);
  canvas.rotate(geometry.angle);
  canvas.scale(geometry.displayScale, geometry.displayScale);
  canvas.drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, imageWidth, imageHeight),
    ui.Rect.fromLTWH(
      -imageWidth / 2,
      -imageHeight / 2,
      imageWidth,
      imageHeight,
    ),
    ui.Paint()
      ..filterQuality = ui.FilterQuality.high
      ..isAntiAlias = true,
  );
  final picture = recorder.endRecording();
  try {
    final rendered = await picture.toImage(outWidth, outHeight);
    try {
      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('封面渲染失败：无法编码为 PNG');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      rendered.dispose();
    }
  } finally {
    picture.dispose();
  }
}
