import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/migration/migration_paths.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/repositories/book_repository.dart';
import 'package:narrchat/services/app_stores.dart';
import 'package:narrchat/services/storage_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 导入整组数据后的可见性回归。
///
/// 背景（P0）：导入只替换 `user_data/`，而 `library_cache.book_index` 在
/// `local_config/` 里、不在导出包内。缓存是**副本**，副本为空绝不能让用户
/// 看到"书全没了"。`BookRepositorySqlite.listBooks()` 因此会在「目录里有、
/// 缓存里没有」时自愈重建。
void main() {
  final tempDirs = <Directory>[];

  MigrationPaths makePaths(String tag) {
    final userData = Directory.systemTemp.createTempSync('${tag}_user_');
    final localConfig = Directory.systemTemp.createTempSync('${tag}_cfg_');
    tempDirs.addAll([userData, localConfig]);
    return MigrationPaths(
      userDataDir: userData.path,
      localConfigDir: localConfig.path,
    );
  }

  BookRepositorySqlite repoOf(AppStores stores) => BookRepositorySqlite(
        library: stores.library,
        cache: stores.cache,
        books: stores.books,
      );

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

  test('导入后 listBooks 仍能列出书（缓存副本为空时自愈重建）', () async {
    // ---- A：造数据并导出 ----
    final storesA = await AppStores.openAt(makePaths('import_a'));
    final repoA = repoOf(storesA);
    final uuid = await repoA.createBook(const Book(
      title: '导出的书',
      category: '武侠',
      baseSetting: '设定',
      historyRounds: 6,
    ));
    final bookDb = await storesA.books.open(uuid);
    await bookDb.rounds.insert(RoundGeneration(
      meta: RoundMeta(
        uuid: 'g1',
        roundIndex: 1,
        roundSerialNum: 1,
        isUsing: true,
        operatedAt: DateTime.utc(2026, 3, 4),
      ),
      userInput: '问',
      aiNarrative: '答',
    ));
    await storesA.books.close(uuid);

    final exportDir = Directory.systemTemp.createTempSync('import_zip_');
    tempDirs.add(exportDir);
    final archivePath = await LocalStorageService(stores: storesA).exportArchive(
      targetDirPath: exportDir.path,
      fileName: 'backup.zip',
    );
    expect(File(archivePath).existsSync(), isTrue);
    await storesA.dispose();

    // ---- B：全新实例导入（缓存库此时是空的）----
    final storesB = await AppStores.openAt(makePaths('import_b'));
    addTearDown(storesB.dispose);
    expect(await repoOf(storesB).listBooks(), isEmpty, reason: '导入前是空的');

    final result = await LocalStorageService(stores: storesB)
        .importArchive(archivePath: archivePath);
    expect(result.ok, isTrue, reason: result.message);
    expect(result.suggestRestart, isTrue);
    expect(result.backupPath, isNotNull);

    // ---- P0 回归断言 ----
    final repoB = repoOf(storesB);
    final books = await repoB.listBooks();
    expect(books.map((book) => book.uuid), [uuid], reason: '导入后书必须能列出来');
    expect(books.single.title, '导出的书');
    expect(books.single.category, '武侠');
    expect(books.single.baseSetting, '设定');
    expect(books.single.historyRounds, 6);

    // 自愈同时补回了「最近对话时间」（它也来自缓存副本）。
    final times = await repoB.lastRoundTimes();
    expect(times[uuid], DateTime.utc(2026, 3, 4));
  });

  test('缓存行被误删时 listBooks 自愈，墓碑书不会再被复活', () async {
    final stores = await AppStores.openAt(makePaths('heal'));
    addTearDown(stores.dispose);
    final repo = repoOf(stores);
    final kept = await repo.createBook(const Book(title: '留下的'));
    final removed = await repo.createBook(const Book(title: '删掉的'));
    await repo.deleteBook(removed);

    // 模拟缓存库被删 / 换机：清空副本
    await stores.cache.replaceAllIndex(const []);
    expect(await stores.cache.allIndex(includeDeleted: true), isEmpty);

    // 缓存空着也必须能把书找回来（这是 P0 的根因）。
    final visible = await repo.listBooks();
    expect(visible.map((book) => book.uuid), [kept], reason: '墓碑书不该被复活');

    final all = await repo.listBooks(includeDeleted: true);
    expect(all.map((book) => book.uuid).toSet(), {kept, removed});
    expect(
      all.firstWhere((book) => book.uuid == removed).title,
      '删掉的',
      reason: '墓碑书名从目录库合成',
    );
    expect(
      await stores.books.exists(removed),
      isFalse,
      reason: '墓碑不重建书库文件',
    );
  });

  test('书库文件缺失时不写脏索引，也不抛异常', () async {
    final stores = await AppStores.openAt(makePaths('missing'));
    addTearDown(stores.dispose);
    final repo = repoOf(stores);
    final uuid = await repo.createBook(const Book(title: '会被删掉文件'));

    await stores.cache.replaceAllIndex(const []);
    await stores.books.deleteFile(uuid);

    expect(await repo.listBooks(), isEmpty);
    final all = await repo.listBooks(includeDeleted: true);
    expect(all, isEmpty, reason: '文件不在就不该凭空造一条索引');
  });
}
