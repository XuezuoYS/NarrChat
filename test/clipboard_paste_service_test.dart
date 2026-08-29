import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/clipboard_paste_service.dart';
import 'package:narrchat/services/image_store.dart';
import 'package:path/path.dart' as p;

/// 测试 [SystemClipboardPasteService] 的「字节 → 校验大小 + 哈希去重落盘」。
///
/// 只测纯逻辑层 [SystemClipboardPasteService.savePastedBytes]（依赖 [ImageStore]
/// 与临时目录），不触碰 `pasteboard` 平台通道。
void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('narrchat_clip_paste');
    ImageStore.testUserDataRoot = tempRoot.path;
  });

  tearDown(() {
    ImageStore.testUserDataRoot = null;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test('普通字节：按内容哈希去重落盘，返回 img/<hash>.png', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    final r1 = await SystemClipboardPasteService.savePastedBytes(
      bytes,
      sizeLimitMb: 16,
      convertJpgToJpeg: false,
    );
    final r2 = await SystemClipboardPasteService.savePastedBytes(
      bytes,
      sizeLimitMb: 16,
      convertJpgToJpeg: false,
    );

    expect(r1.warning, isNull);
    expect(r1.relPath, isNotNull);
    // 同内容去重 → 相同相对路径。
    expect(r2.relPath, r1.relPath);
    // 文件确实落盘。
    expect(File(p.join(tempRoot.path, r1.relPath!)).existsSync(), isTrue);
  });

  test('不同内容：相对路径不同（不误去重）', () async {
    final r1 = await SystemClipboardPasteService.savePastedBytes(
      Uint8List.fromList([1, 2, 3]),
      sizeLimitMb: 16,
      convertJpgToJpeg: false,
    );
    final r2 = await SystemClipboardPasteService.savePastedBytes(
      Uint8List.fromList([9, 9, 9]),
      sizeLimitMb: 16,
      convertJpgToJpeg: false,
    );
    expect(r1.relPath, isNot(r2.relPath));
  });

  test('超过大小上限：返回警告且不落盘', () async {
    // 1MB 上限，传入 > 1MB 字节。
    final bytes = Uint8List(1024 * 1024 + 1);
    final r = await SystemClipboardPasteService.savePastedBytes(
      bytes,
      sizeLimitMb: 1,
      convertJpgToJpeg: false,
    );
    expect(r.relPath, isNull);
    expect(r.warning, contains('超过 1MB'));
  });

  test('Windows 剪贴板 BMP 读回：重编码为 PNG 后大小校验、落盘为真 PNG', () async {
    // 600×600 24bpp 未压缩 BMP ≈ 1.03MB，超过 1MB 上限；
    // 但重编码为 PNG（纯色高度可压缩）后应远小于上限 → 不再误触发「超过 1MB」。
    final bmp = buildBmp(width: 600, height: 600);
    expect(bmp.length, greaterThan(1024 * 1024)); // 原始 BMP 确实超限
    final r = await SystemClipboardPasteService.savePastedBytes(
      bmp,
      sizeLimitMb: 1,
      convertJpgToJpeg: false,
    );
    expect(r.warning, isNull);
    expect(r.relPath, isNotNull);
    final saved = File(p.join(tempRoot.path, r.relPath!));
    final bytes = saved.readAsBytesSync();
    // 落盘是真正的 PNG 魔数（而非 BMP 魔数），且体积小于原始未压缩像素。
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
    expect(bytes.length, lessThan(bmp.length));
  });

  test('文件来源粘贴：保留原始文件名与扩展名（JPEG 复制后仍是 JPEG）', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final r = await SystemClipboardPasteService.savePastedBytes(
      bytes,
      sizeLimitMb: 16,
      convertJpgToJpeg: false,
      fileName: 'photo.jpg',
    );
    expect(r.warning, isNull);
    expect(r.relPath, endsWith('.jpg'));
  });

  test('normalizeBmpToPng：非 BMP 字节原样返回；BMP 解码失败回退原字节', () async {
    final raw = Uint8List.fromList([1, 2, 3]);
    expect(await SystemClipboardPasteService.normalizeBmpToPng(raw), same(raw));

    final fakeBmp = Uint8List.fromList([0x42, 0x4d, 0, 0, 0, 0, 0, 0]);
    final out = await SystemClipboardPasteService.normalizeBmpToPng(fakeBmp);
    expect(out, same(fakeBmp)); // 解码失败 → 原样返回。
  });
}

/// 构造 [width]×[height] 24bpp 未压缩纯红 BMP（54 字节头 + 按 4 字节对齐的行）。
Uint8List buildBmp({required int width, required int height}) {
  final rowStride = (width * 3 + 3) & ~3;
  const bfOffBits = 54;
  final size = bfOffBits + rowStride * height;
  final buf = ByteData(size);
  buf.setUint8(0, 0x42); // 'B'
  buf.setUint8(1, 0x4d); // 'M'
  buf.setUint32(2, size, Endian.little); // bfSize
  buf.setUint32(10, bfOffBits, Endian.little); // bfOffBits
  buf.setUint32(14, 40, Endian.little); // biSize
  buf.setInt32(18, width, Endian.little); // biWidth
  buf.setInt32(22, height, Endian.little); // biHeight
  buf.setUint16(26, 1, Endian.little); // biPlanes
  buf.setUint16(28, 24, Endian.little); // biBitCount
  buf.setUint32(30, 0, Endian.little); // biCompression = BI_RGB
  buf.setUint32(34, rowStride * height, Endian.little); // biSizeImage
  for (var i = 0; i < rowStride * height; i += rowStride) {
    // 纯红像素 BGR = 0,0,255。
    for (var x = 0; x < rowStride; x += 4) {
      buf.setUint8(bfOffBits + i + x, 0); // B
      buf.setUint8(bfOffBits + i + x + 1, 0); // G
      buf.setUint8(bfOffBits + i + x + 2, 255); // R
    }
  }
  return buf.buffer.asUint8List();
}
