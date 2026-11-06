import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/debug_file_service.dart';
import 'package:path/path.dart' as p;

import 'helpers/fakes.dart';

/// 调试页文件浏览服务：列目录、类型识别、路径安全、文本读取。
void main() {
  late TestStack stack;
  late LocalDebugFileService service;

  setUp(() async {
    stack = await TestStack.create();
    service = LocalDebugFileService(rootPath: stack.rootDir.path);
  });

  tearDown(() async {
    await stack.dispose();
  });

  test('根目录列出 user_data / local_config，目录排在文件前', () async {
    await File(p.join(stack.rootDir.path, 'root.txt')).writeAsString('root');

    final entries = await service.listDirectory('');

    expect(
      entries.map((entry) => entry.name),
      containsAll(['user_data', 'local_config', 'root.txt']),
    );
    expect(
      entries.where((entry) => entry.isDirectory).map((entry) => entry.name),
      ['local_config', 'user_data'],
    );
    expect(entries.last.name, 'root.txt');

    final userData = entries.firstWhere((entry) => entry.name == 'user_data');
    expect(userData.isDirectory, isTrue);
    expect(userData.kind, DebugFileKind.directory);
    expect(userData.relativePath, 'user_data');
  });

  test('按扩展名与 SQLite 文件头识别文件类型', () async {
    final bookUuid = await stack.seedBook(title: '书A');

    final books = await service.listDirectory('user_data/books');
    final book = books.firstWhere(
      (entry) => entry.name == 'narrbook_$bookUuid.db',
    );
    expect(book.kind, DebugFileKind.sqlite);
    expect(book.isBookDatabase, isTrue);

    // `.bak` 不是 `.db`，靠文件头识别为 SQLite。
    final backup = File(p.join(stack.paths.userDataDir, 'narrchat.db.r2.bak'));
    await File(stack.paths.libraryDbPath).copy(backup.path);

    final settings = File(
      p.join(stack.paths.localConfigDir, 'app_settings.json'),
    );
    await settings.writeAsString('{"a":1}');
    final notes = File(p.join(stack.paths.localConfigDir, 'notes.md'));
    await notes.writeAsString('# hi');
    final blob = File(p.join(stack.paths.localConfigDir, 'blob.bin'));
    await blob.writeAsBytes([0, 1, 2, 3]);

    final imageDir = Directory(p.join(stack.paths.userDataDir, 'img'));
    await imageDir.create(recursive: true);
    await File(p.join(imageDir.path, 'cover.png'))
        .writeAsBytes([0x89, 0x50, 0x4e, 0x47]);

    final userDataEntries = await service.listDirectory('user_data');
    expect(
      userDataEntries
          .firstWhere((entry) => entry.name == 'narrchat.db.r2.bak')
          .kind,
      DebugFileKind.sqlite,
    );

    final localEntries = await service.listDirectory('local_config');
    expect(
      localEntries
          .firstWhere((entry) => entry.name == 'app_settings.json')
          .kind,
      DebugFileKind.json,
    );
    expect(
      localEntries.firstWhere((entry) => entry.name == 'notes.md').kind,
      DebugFileKind.text,
    );
    expect(
      localEntries.firstWhere((entry) => entry.name == 'blob.bin').kind,
      DebugFileKind.binary,
    );

    final imageEntries = await service.listDirectory('user_data/img');
    expect(imageEntries.single.kind, DebugFileKind.image);
  });

  test('readTextFile 读取文本，非法路径与缺失文件明确报错', () async {
    final file = File(p.join(stack.paths.localConfigDir, 'app_settings.json'));
    await file.writeAsString('{"name":"深深"}');

    expect(
      await service.readTextFile('local_config/app_settings.json'),
      '{"name":"深深"}',
    );

    expect(
      () => service.absolutePathOf('../secret.txt'),
      throwsA(isA<DebugFileException>()),
    );
    await expectLater(
      service.readTextFile('../secret.txt'),
      throwsA(isA<DebugFileException>()),
    );
    await expectLater(
      service.readTextFile('local_config/missing.json'),
      throwsA(isA<DebugFileException>()),
    );
  });

  test('文本超过上限时拒绝预览', () async {
    final file = File(p.join(stack.paths.localConfigDir, 'big.log'));
    await file.writeAsBytes(
      List<int>.filled(LocalDebugFileService.maxTextBytes + 1, 0x61),
    );

    await expectLater(
      service.readTextFile('local_config/big.log'),
      throwsA(isA<DebugFileException>()),
    );
  });

  test('根目录不存在时报错', () async {
    final missing = LocalDebugFileService(
      rootPath: p.join(stack.rootDir.path, 'no-such-dir'),
    );

    await expectLater(
      missing.listDirectory(''),
      throwsA(isA<DebugFileException>()),
    );
  });

  test('空目录返回空列表', () async {
    final empty = Directory(p.join(stack.paths.localConfigDir, 'empty'));
    await empty.create();

    expect(await service.listDirectory('local_config/empty'), isEmpty);
  });
}
