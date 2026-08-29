import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/clipboard_image_service.dart';

/// Windows 剪贴板图片写入（查看器「复制图片」）测试。
///
/// 验证两层：纯逻辑组装（CF_DIB / CF_DIBV5 / CF_HDROP）与图片解码编码
/// （[encodeWindowsImage]，dart:ui）+ 注入替身的写入顺序（不触碰真实剪贴板）。
void main() {
  group('buildWindowsDibRgba（经典 CF_DIB）', () {
    test('头信息与像素布局：32bpp BI_RGB、自底向上、BGR + alpha 255', () {
      final pixels = Uint8List.fromList([
        255, 0, 0, 255, //
        0, 255, 0, 128, //
        0, 0, 255, 255, //
        255, 255, 255, 0,
      ]);
      final dib = buildWindowsDibRgba(width: 2, height: 2, pixels: pixels);

      expect(dib.length, 40 + 2 * 2 * 4);
      final data = ByteData.view(dib.buffer);
      expect(data.getUint32(0, Endian.little), 40); // biSize
      expect(data.getInt32(4, Endian.little), 2); // biWidth
      expect(data.getInt32(8, Endian.little), 2); // biHeight（正值 = 自底向上）
      expect(data.getUint16(12, Endian.little), 1); // biPlanes
      expect(data.getUint16(14, Endian.little), 32); // biBitCount
      expect(data.getUint32(16, Endian.little), 0); // biCompression = BI_RGB
      expect(data.getUint32(20, Endian.little), 2 * 2 * 4); // biSizeImage

      // DIB 首行（底部）= 输入最后一行（蓝 | 白），BGRA，alpha 归一 255。
      expect(dib.sublist(40, 44), [255, 0, 0, 255]); // 蓝
      expect(dib.sublist(44, 48), [255, 255, 255, 255]); // 白
      expect(dib.sublist(48, 52), [0, 0, 255, 255]); // 红
      expect(dib.sublist(52, 56), [0, 255, 0, 255]); // 绿（alpha 128 → 255）
    });
  });

  group('buildWindowsDibV5Rgba（Chromium 同款 CF_DIBV5）', () {
    test('BITMAPV5HEADER 字段与像素布局（保留 alpha、自底向上）', () {
      final pixels = Uint8List.fromList([
        255, 0, 0, 128, //
        0, 0, 255, 0,
      ]);
      final dib = buildWindowsDibV5Rgba(width: 1, height: 2, pixels: pixels);

      expect(dib.length, 124 + 1 * 2 * 4);
      final data = ByteData.view(dib.buffer);
      expect(data.getUint32(0, Endian.little), 124); // bV5Size
      expect(data.getInt32(4, Endian.little), 1);
      expect(data.getInt32(8, Endian.little), 2);
      expect(data.getUint16(12, Endian.little), 1);
      expect(data.getUint16(14, Endian.little), 32);
      expect(data.getUint32(16, Endian.little), 0); // BI_RGB
      expect(data.getUint32(20, Endian.little), 8);
      expect(data.getUint32(52, Endian.little), 0xff000000); // bV5AlphaMask
      expect(data.getUint32(56, Endian.little), 0x73524742); // bV5CSType = Win
      expect(data.getUint32(108, Endian.little), 2); // bV5Intent = LCS_GM_IMAGES
      // 底部（输入蓝像素）BGR + alpha 0；顶部（输入红像素）BGR + alpha 128。
      expect(dib.sublist(124, 128), [255, 0, 0, 0]);
      expect(dib.sublist(128, 132), [0, 0, 255, 128]);
    });
  });

  group('buildWindowsDropFiles（复制原始文件）', () {
    test('DROPFILES 头 + UTF-16 路径 + 双终止空字符', () {
      const path = 'C:/user_data/img/ab12.jpg';
      final drop = buildWindowsDropFiles(path);
      final data = ByteData.view(drop.buffer);
      expect(data.getUint32(0, Endian.little), 20); // pFiles
      expect(data.getUint32(4, Endian.little), 0);
      expect(data.getUint32(8, Endian.little), 0);
      expect(data.getUint32(12, Endian.little), 0);
      expect(data.getUint32(16, Endian.little), 1); // fWide
      expect(drop.length, 20 + (path.codeUnits.length + 2) * 2);
      final units = <int>[];
      for (var i = 0; i < drop.length - 20; i += 2) {
        units.add(data.getUint16(20 + i, Endian.little));
      }
      expect(units, [...path.codeUnits, 0, 0]);
    });
  });

  group('encodeWindowsImage（dart:ui 解码 + 三格式编码）', () {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );

    test('编码产出 PNG 字节 + 合法 CF_DIBV5 + 合法 CF_DIB', () async {
      final image = await encodeWindowsImage(png);
      expect(image.png.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
      final v5 = ByteData.view(image.dibV5.buffer);
      expect(v5.getUint32(0, Endian.little), 124);
      expect(v5.getInt32(4, Endian.little), 1);
      expect(v5.getUint16(14, Endian.little), 32);
      expect(image.dibV5.length, 124 + 4);
      final dib = ByteData.view(image.dib.buffer);
      expect(dib.getUint32(0, Endian.little), 40);
      expect(dib.getInt32(4, Endian.little), 1);
      expect(dib.getUint16(14, Endian.little), 32);
      expect(image.dib.length, 40 + 4);
    });

    test('写入次数：单次混合写入（避免历史条目被第二次处理移除）', () async {
      if (!Platform.isWindows) {
        markTestSkipped('仅验证 Windows 分支（非 Windows 走 pasteboard 通道）');
        return;
      }
      final pixelCalls = <(WindowsClipboardImage, Uint8List?)>[];
      debugWindowsClipboardSetterOverride = (image, dropFiles) {
        pixelCalls.add((image, dropFiles));
        return true;
      };
      addTearDown(() {
        debugWindowsClipboardSetterOverride = (image, dropFiles) => false;
      });
      const path = 'C:/user_data/img/ab12.jpg';
      await const SystemClipboardImageWriter()
          .writeImage(absPath: path, bytes: png);

      // 单次写入（一次成功，无重试）：像素三格式 + CF_HDROP 原路径。
      expect(pixelCalls.length, 1);
      final call = pixelCalls[0];
      expect(call.$2, buildWindowsDropFiles(path));
      expect(call.$1.png.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
      expect(
        ByteData.view(call.$1.dibV5.buffer).getUint32(0, Endian.little),
        124,
      );
      expect(
        ByteData.view(call.$1.dib.buffer).getUint32(0, Endian.little),
        40,
      );
    });

    test('写入失败：单次写入失败并重试后仍失败时抛出异常', () async {
      if (!Platform.isWindows) {
        markTestSkipped('仅验证 Windows 分支（非 Windows 走 pasteboard 通道）');
        return;
      }
      debugWindowsClipboardSetterOverride = (image, dropFiles) => false;
      addTearDown(() {
        debugWindowsClipboardSetterOverride = (image, dropFiles) => false;
      });
      await expectLater(
        const SystemClipboardImageWriter()
            .writeImage(absPath: 'C:/a.jpg', bytes: png),
        throwsA(isA<Exception>()),
      );
    });

    test('像素通道保持全分辨率（不做任何压缩/降采样）', () async {
      final image = await _makeNoiseImage(256, 256, seed: 7);
      try {
        final fullPng = await image.toByteData(format: ui.ImageByteFormat.png);
        final bytes = fullPng!.buffer
            .asUint8List(fullPng.offsetInBytes, fullPng.lengthInBytes);
        final encoded = await encodeWindowsImage(bytes);
        // 尺寸与源一致（无降采样）；PNG 为真 PNG 且体积≥源（保持原分辨率编码）。
        expect(ByteData.view(encoded.dibV5.buffer).getInt32(4, Endian.little),
            256);
        expect(ByteData.view(encoded.dibV5.buffer).getInt32(8, Endian.little),
            256);
        expect(encoded.png.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
      } finally {
        image.dispose();
      }
    });

    test('像素编码失败：降级为仅复制原始文件（图3 类异常图片仍可复制）', () async {
      if (!Platform.isWindows) {
        markTestSkipped('仅验证 Windows 分支（非 Windows 走 pasteboard 通道）');
        return;
      }
      final fileCalls = <String>[];
      final pixelCalls = <(WindowsClipboardImage, Uint8List?)>[];
      debugWindowsClipboardFileSetterOverride = (path) {
        fileCalls.add(path);
        return true;
      };
      debugWindowsClipboardSetterOverride = (image, dropFiles) {
        pixelCalls.add((image, dropFiles));
        return true;
      };
      addTearDown(() {
        debugWindowsClipboardFileSetterOverride = (path) => false;
        debugWindowsClipboardSetterOverride = (image, dropFiles) => false;
      });
      // 非法图片字节 → dart:ui 解码抛异常 → 走文件降级路径。
      const path = 'C:/user_data/img/weird.jpg';
      await const SystemClipboardImageWriter()
          .writeImage(absPath: path, bytes: Uint8List.fromList([0, 1, 2, 3]));
      expect(fileCalls, [path]);
      expect(pixelCalls, isEmpty);
    });
  });
}

/// 生成确定性的随机噪声图（用于逼出 PNG 体积超限场景）。
Future<ui.Image> _makeNoiseImage(int width, int height, {required int seed}) async {
  final rng = math.Random(seed);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  const cell = 8;
  final paint = ui.Paint();
  for (var y = 0; y < height; y += cell) {
    for (var x = 0; x < width; x += cell) {
      paint.color = ui.Color.fromARGB(
        255,
        rng.nextInt(256),
        rng.nextInt(256),
        rng.nextInt(256),
      );
      canvas.drawRect(
        ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), cell.toDouble(), cell.toDouble()),
        paint,
      );
    }
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  return image;
}
