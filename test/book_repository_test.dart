import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_db_pool.dart';
import 'package:narrchat/database/cache_store.dart';
import 'package:narrchat/database/library_store.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/repositories/book_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 书籍门面：一本书的事实分散在目录库 / 书库 / 缓存副本，这里验证三者不漂移。
void main() {
  final tempDirs = <Directory>[];
  late Directory userData;
  late Directory localConfig;
  late LibraryDb library;
  late CacheDb cache;
  late BookDbPool pool;
  late BookRepositorySqlite repository;

  String newTempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    tempDirs.add(dir);
    return dir.path;
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    userData = Directory(newTempDir('book_repo_user_'));
    localConfig = Directory(newTempDir('book_repo_cfg_'));
    library = LibraryDb(
      pathOverride: p.join(userData.path, 'narrchat_library.db'),
      masterUuidOverride: 'master-1',
    );
    cache = CacheDb(pathOverride: p.join(localConfig.path, 'library_cache.db'));
    pool = BookDbPool(booksDir: p.join(userData.path, 'books'));
    repository = BookRepositorySqlite(
      library: library,
      cache: cache,
      books: pool,
    );
  });

  tearDown(() async {
    await pool.closeAll();
    await library.close();
    await cache.close();
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

  Book sample({String uuid = '', String title = '新书'}) => Book(
        uuid: uuid,
        title: title,
        category: '武侠',
        baseSetting: '设定',
        writingRequirements: '要求',
        writingStyle: '范文',
        globalPrePrompt: '前置',
        globalPostPrompt: '后置',
        historyRounds: 6,
        memorySummaryRounds: 5,
        roleHierarchy: '层级',
      );

  test('新建：书库 + 目录行 + 缓存副本一次写好', () async {
    final uuid = await repository.createBook(sample());

    final listed = await repository.listBooks();
    expect(listed.single.uuid, uuid);
    expect(listed.single.title, '新书');
    expect(listed.single.historyRounds, 6);
    expect(listed.single.memorySummaryRounds, 5);

    expect((await library.book(uuid))!.title, '新书');
    expect(await pool.exists(uuid), isTrue);
    expect((await cache.indexOf(uuid))!.dbMtimeMs, greaterThan(0));

    final loaded = await repository.loadBook(uuid);
    expect(loaded!.baseSetting, '设定');
    expect(loaded.memorySummaryRounds, 5);
  });

  test('保存设置：书名信源与目录副本、缓存副本一起更新', () async {
    final uuid = await repository.createBook(sample());
    final loaded = (await repository.loadBook(uuid))!;

    await repository.saveBook(loaded.copyWith(
      title: '改名后',
      historyRounds: 9,
      baseSetting: '新设定',
    ));

    expect((await library.book(uuid))!.title, '改名后');
    expect((await cache.indexOf(uuid))!.title, '改名后');
    expect((await cache.indexOf(uuid))!.historyRounds, 9);

    final fresh = (await repository.loadBook(uuid))!;
    expect(fresh.title, '改名后');
    expect(fresh.historyRounds, 9);
    expect(fresh.baseSetting, '新设定');
  });

  test('墓碑：软删后列表隐藏、文件还在；还原后回来', () async {
    final uuid = await repository.createBook(sample());

    await repository.softDeleteBook(uuid);
    expect(await repository.listBooks(), isEmpty);
    expect((await repository.listBooks(includeDeleted: true)).single.uuid, uuid);
    expect(await pool.exists(uuid), isTrue);
    expect((await library.book(uuid))!.isDeleted, isTrue);
    expect((await cache.indexOf(uuid))!.isDeleted, isTrue);
    expect(pool.isOpen(uuid), isFalse, reason: '软删要关掉连接');

    await repository.restoreBook(uuid);
    expect((await repository.listBooks()).single.uuid, uuid);
    expect((await library.book(uuid))!.isDeleted, isFalse);
    expect((await cache.indexOf(uuid))!.isDeleted, isFalse);
  });

  test('物理删除：目录行 / 缓存行 / 库文件全部消失', () async {
    final uuid = await repository.createBook(sample());
    await repository.purgeBook(uuid);

    expect(await repository.listBooks(includeDeleted: true), isEmpty);
    expect(await library.book(uuid), isNull);
    expect(await cache.indexOf(uuid), isNull);
    expect(await pool.exists(uuid), isFalse);
  });

  test('最近对话时间：打开书时按书库内容校正缓存', () async {
    final uuid = await repository.createBook(sample());
    final db = await pool.open(uuid);
    await db.rounds.insert(RoundGeneration(
      meta: RoundMeta(
        uuid: 'g1',
        roundIndex: 1,
        roundSerialNum: 1,
        isUsing: true,
        operatedAt: DateTime.utc(2026, 3, 4, 5),
      ),
      aiNarrative: '正文',
    ));
    await db.close();
    await pool.close(uuid);

    // 缓存里还没有这个时间
    expect(await repository.lastRoundTimes(), isEmpty);

    // 打开一次即校正
    await repository.loadBook(uuid);
    final times = await repository.lastRoundTimes();
    expect(times[uuid], DateTime.utc(2026, 3, 4, 5));
  });

  test('缺文件时 loadBook 返回 null，不抛异常', () async {
    expect(await repository.loadBook('ghost'), isNull);
    expect(await repository.loadBook(''), isNull);
  });

  test('saveBook 对空 uuid 明确报错（新书必须先 createBook）', () async {
    await expectLater(
      repository.saveBook(sample()),
      throwsA(isA<ArgumentError>()),
    );
  });
}
