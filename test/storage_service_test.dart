import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/storage_service.dart';
import 'package:path/path.dart' as p;

import 'helpers/fakes.dart';

/// 存储管理：多库总览、图片列表、整组 zip 导出 / 导入、旧版备份清理。
///
/// R3 是"一本书一个库文件"，所以存储页按库逐个展示；导出/导入是**整组**
/// （library + mods + 全部书库 + img），不再有单库导出。
void main() {
  late TestStack stack;
  late Directory imgDir;
  late LocalStorageService service;

  setUp(() async {
    stack = await TestStack.create();
    imgDir = Directory(p.join(stack.rootDir.path, 'img_override'))
      ..createSync(recursive: true);
    service = LocalStorageService(stores: stack.stores, imgDirOverride: imgDir);
  });

  tearDown(() async {
    await stack.dispose();
  });

  void writeImage(String name, List<int> bytes, DateTime modified) {
    final file = File(p.join(imgDir.path, name))..writeAsBytesSync(bytes);
    file.setLastModifiedSync(modified);
  }

  test('listImages：仅列允许扩展名，按修改时间倒序', () async {
    writeImage('a.png', [1], DateTime(2025, 1, 1));
    writeImage('b.jpeg', [2], DateTime(2025, 2, 1));
    writeImage('c.txt', [3], DateTime(2025, 3, 1));

    final list = await service.listImages();

    expect(list.map((i) => i.name).toList(), ['b.jpeg', 'a.png']);
    expect(list.first.relPath, 'img/b.jpeg');
    expect(list.first.size, 1);
  });

  test('overview：五个库都登记，缺失的库 size 为 0 但仍在列表里', () async {
    await stack.seedBook(title: '书A');
    writeImage('a.png', [1, 2, 3], DateTime(2025, 1, 1));

    final overview = await service.overview();

    final ids = overview.databases.map((d) => d.id).toList();
    expect(ids, containsAll(['library', 'mods', 'cache', 'sync']));
    expect(
      overview.databases.where((d) => d.id.startsWith('book:')).length,
      1,
      reason: '一本书一个库文件',
    );
    expect(overview.bookCount, 1);
    expect(overview.imageCount, 1);
    expect(overview.imageBytes, 3);

    final library = overview.databases.firstWhere((d) => d.id == 'library');
    expect(library.exists, isTrue);
    expect(library.sizeBytes, greaterThan(0));
    expect(overview.databaseBytes, greaterThan(0));
    expect(overview.totalBytes, overview.databaseBytes + overview.imageBytes);
    expect(overview.existingDatabases.length, lessThanOrEqualTo(ids.length));
  });

  test('旧版备份：存在时登记为 legacy-backup，可单独删除', () async {
    final legacy = File(p.join(stack.paths.userDataDir, 'narrchat.db.r2.bak'))
      ..writeAsBytesSync([9, 9]);

    final before = await service.overview();
    final entry = before.databases.firstWhere((d) => d.id == 'legacy-backup');
    expect(entry.exists, isTrue);
    expect(entry.sizeBytes, 2);

    await service.deleteLegacyBackup();
    expect(legacy.existsSync(), isFalse);

    final after = await service.overview();
    expect(
      after.databases.firstWhere((d) => d.id == 'legacy-backup').exists,
      isFalse,
    );
  });

  test('exportArchive：整组打包，含清单与各库文件', () async {
    final bookUuid = await stack.seedBook(title: '书A');
    // mods 库懒建：先读一次，保证导出包里确实有这个文件。
    await stack.stores.mods.list();
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '正文');
    writeImage('a.png', [1, 2, 3], DateTime(2025, 1, 1));

    final outDir = Directory(p.join(stack.rootDir.path, 'out'))..createSync();
    final path = await service.exportArchive(
      targetDirPath: outDir.path,
      fileName: 'narrchat.zip',
    );

    expect(File(path).existsSync(), isTrue);
    final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    final names = archive.files.map((f) => f.name).toList();

    expect(names, contains(LocalStorageService.manifestFileName));
    expect(names, contains('user_data/narrchat_library.db'));
    expect(names, contains('user_data/img/a.png'));
    expect(
      names.any((n) => n.startsWith('user_data/books/') && n.endsWith('.db')),
      isTrue,
      reason: '每本书一个库文件',
    );
    expect(
      names.any((n) => n.startsWith('local_config/')),
      isFalse,
      reason: '默认不导出本地配置',
    );

    final manifest = jsonDecode(
      utf8.decode(
        archive.files
            .firstWhere((f) => f.name == LocalStorageService.manifestFileName)
            .content as List<int>,
      ),
    ) as Map<String, dynamic>;
    expect(manifest['formatVersion'], LocalStorageService.archiveFormatVersion);
    expect(manifest['schemaVersion'], isNotNull);
    expect(manifest['bookCount'], 1);
  });

  test('exportArchive：includeLocalConfig 时带上本地配置目录', () async {
    await stack.seedBook();
    File(p.join(stack.paths.localConfigDir, 'app_settings.json'))
        .writeAsStringSync('{}');

    final outDir = Directory(p.join(stack.rootDir.path, 'out2'))..createSync();
    final path = await service.exportArchive(
      targetDirPath: outDir.path,
      fileName: 'narrchat.zip',
      includeLocalConfig: true,
    );

    final names = ZipDecoder()
        .decodeBytes(File(path).readAsBytesSync())
        .files
        .map((f) => f.name)
        .toList();
    expect(names.any((n) => n.startsWith('local_config/')), isTrue);
  });

  test('importArchive：导出的包能整组还原到另一套存储', () async {
    final bookUuid = await stack.seedBook(title: '要还原的书');
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '还原后可见');
    writeImage('a.png', [7, 8], DateTime(2025, 1, 1));

    final outDir = Directory(p.join(stack.rootDir.path, 'out3'))..createSync();
    final archivePath = await service.exportArchive(
      targetDirPath: outDir.path,
      fileName: 'narrchat.zip',
    );

    final target = await TestStack.create(prefix: 'narrchat_import_');
    addTearDown(target.dispose);
    final targetService = LocalStorageService(stores: target.stores);

    final result = await targetService.importArchive(archivePath: archivePath);

    expect(result.ok, isTrue, reason: result.message);
    expect(result.restoredFiles, greaterThan(0));

    // 注意：这里断言的是**信源层**（library.books + 书库文件），不是
    // `repos.books.listBooks()`。后者读的是 library_cache 副本，而导入只替换
    // user_data/，缓存库是本地数据不随包走 —— 见汇报里「导入后缓存未重建」缺口。
    final libraryRows = await target.stores.library.books();
    expect(libraryRows.map((b) => b.title), contains('要还原的书'));

    final bookUuidAfterImport = libraryRows
        .firstWhere((b) => b.title == '要还原的书')
        .bookUuid;
    final loaded = await target.repos.books.loadBook(bookUuidAfterImport);
    expect(loaded, isNotNull, reason: '书库文件与库名都对得上才能打开');
    final chain = await target.repos.rounds.loadChain(bookUuidAfterImport);
    expect(chain.rounds.single.aiNarrative, '还原后可见');
  });

  test('importArchive：不是 zip / 缺清单时给失败结果，不抛异常', () async {
    final bad = File(p.join(stack.rootDir.path, 'bad.zip'))
      ..writeAsBytesSync([1, 2, 3]);
    final result = await service.importArchive(archivePath: bad.path);
    expect(result.ok, isFalse);
    expect(result.message, isNotEmpty);

    final missing = await service.importArchive(
      archivePath: p.join(stack.rootDir.path, 'nope.zip'),
    );
    expect(missing.ok, isFalse);
    expect(missing.message, isNotEmpty);
  });
}
