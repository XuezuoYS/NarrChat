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
}
