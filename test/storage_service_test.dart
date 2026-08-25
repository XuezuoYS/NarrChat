import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/image_store.dart';
import 'package:narrchat/services/storage_service.dart';
import 'package:path/path.dart' as p;

/// 测试 [LocalStorageService]：列出图片（按修改时间）、导出数据库、删除图片。
///
/// 用临时目录 + `ImageStore.testUserDataRoot` 隔离真实路径，不触碰真实库。
void main() {
  late Directory tempRoot;
  late Directory imgDir;
  late File dbFile;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('storage_test_');
    ImageStore.testUserDataRoot = tempRoot.path;
    imgDir = Directory(p.join(tempRoot.path, 'img'));
    imgDir.createSync(recursive: true);
    dbFile = File(p.join(tempRoot.path, 'narrchat.db'));
    dbFile.writeAsBytesSync([1, 2, 3, 4]);
  });

  tearDown(() {
    ImageStore.testUserDataRoot = null;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test('listImages：仅列允许扩展名，按修改时间倒序', () async {
    File(p.join(imgDir.path, 'a.png')).writeAsBytesSync([1]);
    File(p.join(imgDir.path, 'b.jpeg')).writeAsBytesSync([2]);
    File(p.join(imgDir.path, 'c.txt')).writeAsBytesSync([3]);
    // 时间戳取远距离日期，避免同秒与磁盘精度误差。
    File(p.join(imgDir.path, 'a.png')).setLastModifiedSync(DateTime(2025, 1, 1));
    File(p.join(imgDir.path, 'b.jpeg')).setLastModifiedSync(DateTime(2025, 2, 1));

    final list = await LocalStorageService().listImages();

    // 最新在前；c.txt 扩展名非法被过滤。
    expect(list.map((i) => i.name).toList(), ['b.jpeg', 'a.png']);
    expect(list.first.relPath, 'img/b.jpeg');
    expect(list.first.size, 1);
  });

  test('dbInfo：返回路径 / 大小', () async {
    final info = await LocalStorageService(dbPathOverride: dbFile.path).dbInfo();
    expect(info, isNotNull);
    expect(info!.path, dbFile.path);
    expect(info.size, 4);
  });

  test('exportDatabase：按自定义名复制到目标文件夹', () async {
    final outDir = Directory(p.join(tempRoot.path, 'out'));
    outDir.createSync();

    final target = await LocalStorageService(dbPathOverride: dbFile.path)
        .exportDatabase(targetDirPath: outDir.path, fileName: 'my_backup.db');

    expect(p.basename(target), 'my_backup.db');
    expect(File(target).existsSync(), isTrue);
    expect(File(target).readAsBytesSync(), [1, 2, 3, 4]);
  });

  test('exportDatabase：数据库不存在时抛错', () async {
    final outDir = Directory(p.join(tempRoot.path, 'out2'));
    outDir.createSync();
    final service = LocalStorageService(
      dbPathOverride: p.join(tempRoot.path, 'nope.db'),
    );
    expect(
      () => service.exportDatabase(
        targetDirPath: outDir.path,
        fileName: 'x.db',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('deleteImage：删除相对路径对应的文件', () async {
    final file = File(p.join(imgDir.path, 'a.png'));
    file.writeAsBytesSync([1]);
    expect(file.existsSync(), isTrue);

    await LocalStorageService().deleteImage('img/a.png');

    expect(file.existsSync(), isFalse);
  });
}
