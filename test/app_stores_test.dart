import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_db.dart';
import 'package:narrchat/database/migration/migration_paths.dart';
import 'package:narrchat/models/book_meta.dart';
import 'package:narrchat/services/app_stores.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 存储装配层：一次启动把迁移与五个库准备好，书本连接池按需开关。
void main() {
  final tempDirs = <Directory>[];

  MigrationPaths makePaths() {
    final userData = Directory.systemTemp.createTempSync('app_stores_user_');
    final localConfig = Directory.systemTemp.createTempSync('app_stores_cfg_');
    tempDirs.addAll([userData, localConfig]);
    return MigrationPaths(
      userDataDir: userData.path,
      localConfigDir: localConfig.path,
    );
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    for (final dir in tempDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 清理失败不影响结论。
      }
    }
    tempDirs.clear();
  });

  BookMeta meta(String uuid) => BookMeta(
        bookUuid: uuid,
        masterUuid: 'm',
        title: '书$uuid',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      );

  Future<void> createBook(MigrationPaths paths, String uuid) async {
    final book = await BookDb.create(
      meta: meta(uuid),
      pathOverride: p.join(paths.booksDir, 'narrbook_$uuid.db'),
    );
    await book.close();
  }

  test('全新安装：迁移标记完成，五个库都可用', () async {
    final paths = makePaths();
    final stores = await AppStores.openAt(paths);
    addTearDown(stores.dispose);

    expect(stores.migration!.freshInstall, isTrue);
    expect(await stores.library.masterUuid(), isNotEmpty);
    expect(await stores.library.books(), isEmpty);
    expect(await stores.mods.list(), isEmpty);
    expect(await stores.cache.allIndex(), isEmpty);
    expect((await stores.sync.readState()).deviceId, '');
    expect(stores.books.openCount, 0);

    final failed = await stores.failedBooks();
    expect(failed, isEmpty);
  });

  test('第二次启动：迁移已完成，不再重跑', () async {
    final paths = makePaths();
    final first = await AppStores.openAt(paths);
    final master = await first.library.masterUuid();
    await first.dispose();

    final second = await AppStores.openAt(paths);
    addTearDown(second.dispose);
    expect(second.migration!.alreadyDone, isTrue);
    expect(await second.library.masterUuid(), master);
  });

  test('书本连接池：重复打开同一本只有一条连接，关掉后可重开', () async {
    final paths = makePaths();
    final stores = await AppStores.openAt(paths);
    addTearDown(stores.dispose);
    await createBook(paths, 'b1');

    final a = await stores.books.open('b1');
    final b = await stores.books.open('b1');
    expect(identical(a, b), isTrue);
    expect(stores.books.openCount, 1);
    expect(stores.books.isOpen('b1'), isTrue);

    // 并发打开也是同一条。
    final results = await Future.wait([
      stores.books.open('b1'),
      stores.books.open('b1'),
    ]);
    expect(identical(results[0], results[1]), isTrue);

    await stores.books.close('b1');
    expect(stores.books.openCount, 0);
    expect(stores.books.isOpen('b1'), isFalse);
    await stores.books.close('b1');

    final reopened = await stores.books.open('b1');
    expect((await reopened.meta.read()).bookUuid, 'b1');
  });

  test('书本连接池：存在性检查与物理删除', () async {
    final paths = makePaths();
    final stores = await AppStores.openAt(paths);
    addTearDown(stores.dispose);
    await createBook(paths, 'b2');

    expect(await stores.books.exists('b2'), isTrue);
    expect(await stores.books.exists('nope'), isFalse);
    expect(await stores.books.exists('bad/uuid'), isFalse);

    await stores.books.deleteFile('b2');
    expect(await stores.books.exists('b2'), isFalse);
  });

  test('缺文件时打开返回 null，不抛异常', () async {
    final paths = makePaths();
    final stores = await AppStores.openAt(paths);
    addTearDown(stores.dispose);

    expect(await stores.books.tryOpen('ghost'), isNull);
  });

  test('dispose 会关掉所有连接与库', () async {
    final paths = makePaths();
    final stores = await AppStores.openAt(paths);
    await createBook(paths, 'b3');
    await stores.books.open('b3');
    expect(stores.books.openCount, 1);

    await stores.dispose();
    expect(stores.books.openCount, 0);
  });
}
