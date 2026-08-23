import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/services/image_store.dart';

/// [ImageStore] 单元测试：哈希去重、扩展名/路径校验、相对/绝对路径解析。
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('narrchat_img_store');
    ImageStore.testUserDataRoot = temp.path;
  });

  tearDown(() async {
    ImageStore.testUserDataRoot = null;
    await temp.delete(recursive: true);
  });

  test('saveBytes：按内容哈希命名并去重，不同内容不同路径', () async {
    final bytes = Uint8List.fromList(List.generate(100, (i) => i % 256));
    final p1 = await ImageStore.saveBytes(bytes, filename: 'a.png');
    expect(p1, startsWith('img/'));
    expect(p1, endsWith('.png'));
    expect(await ImageStore.exists(p1), isTrue);

    // 同内容再次导入：相同相对路径（去重复用）。
    final p2 = await ImageStore.saveBytes(bytes, filename: 'b.png');
    expect(p2, p1);

    // 不同内容：不同路径。
    final other = await ImageStore.saveBytes(
      Uint8List.fromList([1, 2, 3]),
      filename: 'c.png',
    );
    expect(other, isNot(p1));
  });

  test('normalizeExt：非法扩展名抛异常，合法扩展名归一化为小写', () {
    expect(
      () => ImageStore.normalizeExt('a.gif'),
      throwsA(isA<ImageFormatException>()),
    );
    expect(ImageStore.normalizeExt('A.JPG'), 'jpg');
    expect(ImageStore.normalizeExt('b.JPEG'), 'jpeg');
  });

  test('saveBytes：开启 jpg→jpeg 转换时 .jpg 落盘为 .jpeg，未开启/非 jpg 不变', () async {
    final bytes = Uint8List.fromList(List.generate(64, (i) => i % 256));

    // 开启转换：.jpg → 存为 .jpeg，内容不改变。
    final converted = await ImageStore.saveBytes(
      bytes,
      filename: 'a.jpg',
      convertJpgToJpeg: true,
    );
    expect(converted, endsWith('.jpeg'));
    expect(await File(await ImageStore.resolveAbsolute(converted)).readAsBytes(),
        bytes);

    // 未开启：.jpg 保持 .jpg（默认行为不变）。
    final kept = await ImageStore.saveBytes(
      bytes,
      filename: 'a.jpg',
      convertJpgToJpeg: false,
    );
    expect(kept, endsWith('.jpg'));

    // 开启转换但对 .png 无影响。
    final png = await ImageStore.saveBytes(
      bytes,
      filename: 'a.png',
      convertJpgToJpeg: true,
    );
    expect(png, endsWith('.png'));
  });

  test('resolveAbsolute / fileNameOf', () async {
    final rel = await ImageStore.saveBytes(
      Uint8List.fromList([1, 2, 3]),
      filename: 'x.jpeg',
    );
    final abs = await ImageStore.resolveAbsolute(rel);
    expect(File(abs).existsSync(), isTrue);
    expect(ImageStore.fileNameOf(rel), endsWith('.jpeg'));
  });

  test('exists：缺失 / 非法路径返回 false', () async {
    expect(await ImageStore.exists('img/nope.png'), isFalse);
    expect(await ImageStore.exists(''), isFalse);
    expect(await ImageStore.exists('../x.png'), isFalse);
  });
}
