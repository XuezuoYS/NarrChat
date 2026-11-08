import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/image_store.dart';
import 'package:path/path.dart' as p;

/// 图片相关测试的公共素材：现造 PNG、按 `ImageStore` 口径落盘。
///
/// 不依赖仓库里的真实素材（封面默认插画等），也不手写 base64 常量——
/// 用 `dart:ui` 现编一张一定合法的 PNG，避免「扩展名对但解码不了」的假阳性。

/// 造一张纯色 PNG 字节（默认 4×6，正好也是 2 : 3）。
///
/// 必须在 `testWidgets` 里调用（内部走 `tester.runAsync` 跑真实解码 / 编码）。
Future<Uint8List> makePngBytes(
  WidgetTester tester, {
  int width = 4,
  int height = 6,
  ui.Color color = const ui.Color(0xFF3366FF),
}) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = color,
    );
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  });
  return bytes!;
}

/// 把图片字节写进 `user_data/img/`，返回可入库的相对路径（`img/<文件名>`）。
///
/// 调用前请把 `ImageStore.testUserDataRoot` 指到同一个 `user_data` 目录。
Future<String> writeImageFixture(
  Directory userDataDir,
  Uint8List bytes, {
  String fileName = 'cover.png',
}) async {
  final dir = Directory(p.join(userDataDir.path, ImageStore.relativeDir));
  await dir.create(recursive: true);
  await File(p.join(dir.path, fileName)).writeAsBytes(bytes, flush: true);
  return '${ImageStore.relativeDir}/$fileName';
}
