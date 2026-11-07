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

    await repository.saveBook(
      loaded.copyWith(title: '改名后', historyRounds: 9, baseSetting: '新设定'),
    );

    expect((await library.book(uuid))!.title, '改名后');
    expect((await cache.indexOf(uuid))!.title, '改名后');
    expect((await cache.indexOf(uuid))!.historyRounds, 9);

    final fresh = (await repository.loadBook(uuid))!;
    expect(fresh.title, '改名后');
    expect(fresh.historyRounds, 9);
    expect(fresh.baseSetting, '新设定');
  });

  test('删除：墓碑留在目录，书库文件 / 连接 / 缓存行 / 高度 / 图片引用全清掉', () async {
    final uuid = await repository.createBook(sample());
    final db = await pool.open(uuid);
    await db.rounds.insert(
      RoundGeneration(
        meta: RoundMeta(
          uuid: 'r3',
          roundIndex: 3,
          roundSerialNum: 1,
          isUsing: true,
          operatedAt: DateTime.utc(2026, 3, 1),
        ),
        aiNarrative: '三',
      ),
    );
    await db.rounds.insert(
      RoundGeneration(
        meta: RoundMeta(
          uuid: 'r7',
          roundIndex: 7,
          roundSerialNum: 1,
          isUsing: true,
          operatedAt: DateTime.utc(2026, 3, 7),
        ),
        aiNarrative: '七',
      ),
    );
    await cache.putHeights(
      uuid,
      {'r1': 42},
      widthBucket: 0,
      typeScaleBucket: 0,
    );
    await cache.replaceImageRefs(uuid, [
      ImageRefRow(imagePath: 'img/a.png', bookUuid: uuid, refCount: 1),
    ]);

    await repository.deleteBook(uuid);

    expect(await repository.listBooks(), isEmpty);
    final tombstone = (await repository.listBooks(includeDeleted: true)).single;
    expect(tombstone.uuid, uuid);
    expect(tombstone.title, '新书', reason: '墓碑书名从目录库合成');

    expect((await library.book(uuid))!.isDeleted, isTrue);
    expect(
      (await library.book(uuid))!.deletedRoundIndex,
      7,
      reason: '墓碑要带删除时的最大轮号',
    );
    expect(await pool.exists(uuid), isFalse);
    expect(pool.isOpen(uuid), isFalse, reason: '删除要关掉连接');
    expect(await cache.indexOf(uuid), isNull, reason: '缓存行也要删');
    expect(await cache.imageRefsOf(uuid), isEmpty);
    expect(
      await cache.heightsOf(uuid, widthBucket: 0, typeScaleBucket: 0),
      isEmpty,
    );
    expect(db.bookUuid, uuid, reason: '删除前连接确实开着');
  });

  test('删除不存在的书：不抛异常，也不凭空写墓碑', () async {
    await repository.deleteBook('ghost');
    expect(await library.book('ghost'), isNull);
    await repository.deleteBook('');
  });

  test('重复删除幂等：墓碑时间与轮号不被刷新', () async {
    final uuid = await repository.createBook(sample());
    await repository.deleteBook(uuid);
    final first = (await library.book(uuid))!.deletedAt!;
    final firstRound = (await library.book(uuid))!.deletedRoundIndex;
    expect(firstRound, 0, reason: '没有轮次的书记为 0');

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repository.deleteBook(uuid);

    expect((await library.book(uuid))!.deletedAt, first);
    expect((await library.book(uuid))!.deletedRoundIndex, firstRound);
    expect(await pool.exists(uuid), isFalse);
  });

  test('purgeTombstonedBooks：清历史墓碑残留，墓碑保留、活书不动', () async {
    final live = await repository.createBook(sample(title: '活书'));
    final legacy = await repository.createBook(sample(title: '旧墓碑书'));
    // 模拟旧版本：只打墓碑，书库文件与缓存都还在。
    await library.setDeletedAt(legacy, DateTime.utc(2025, 1, 1));
    expect(await pool.exists(legacy), isTrue);

    final purged = await repository.purgeTombstonedBooks();

    expect(purged, 1);
    expect(await pool.exists(legacy), isFalse);
    expect(await cache.indexOf(legacy), isNull);
    expect((await library.book(legacy))!.isDeleted, isTrue);
    expect(await pool.exists(live), isTrue);
    expect((await repository.listBooks()).single.uuid, live);
  });

  test('reviveBook：云端快照还原后清墓碑、回写书名并重建索引', () async {
    final uuid = await repository.createBook(sample(title: '旧名'));
    final path = p.join(pool.booksDir, 'narrbook_$uuid.db');

    // 模拟云端快照：书库里的书名与目录副本不同。
    final db = await pool.open(uuid);
    final meta = await db.meta.read();
    await db.meta.writeSettings(meta.copyWith(title: '云端名'));
    await db.close();
    await pool.close(uuid);
    final bytes = await File(path).readAsBytes();

    await repository.deleteBook(uuid);
    expect(await pool.exists(uuid), isFalse);
    // 模拟还原：把快照字节写回书库路径。
    await File(path).writeAsBytes(bytes, flush: true);

    await repository.reviveBook(uuid);

    expect((await library.book(uuid))!.isDeleted, isFalse);
    expect((await library.book(uuid))!.deletedRoundIndex, isNull);
    expect((await library.book(uuid))!.title, '云端名', reason: '还原后目录副本要跟书库信源对齐');
    final listed = (await repository.listBooks()).single;
    expect(listed.uuid, uuid);
    expect(listed.title, '云端名');
    expect((await cache.indexOf(uuid))!.title, '云端名');
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
    await db.rounds.insert(
      RoundGeneration(
        meta: RoundMeta(
          uuid: 'g1',
          roundIndex: 1,
          roundSerialNum: 1,
          isUsing: true,
          operatedAt: DateTime.utc(2026, 3, 4, 5),
        ),
        aiNarrative: '正文',
      ),
    );
    await db.close();
    await pool.close(uuid);

    // 缓存里还没有这个时间
    expect(await repository.lastRoundTimes(), isEmpty);

    // 打开一次即校正
    await repository.loadBook(uuid);
    final times = await repository.lastRoundTimes();
    expect(times[uuid], DateTime.utc(2026, 3, 4, 5));
  });

  test('新建书：updated_at 视为 created_at，updatedTimes 返回它', () async {
    final uuid = await repository.createBook(sample());
    final db = await pool.open(uuid);
    final meta = await db.meta.read();
    expect(meta.updatedAt, meta.createdAt, reason: '创建时两个时间必须同源');

    final times = await repository.updatedTimes();
    expect(times[uuid], meta.updatedAt);
  });

  test('更新时间：书库内容变化后 updatedTimes 自动校正缓存', () async {
    final uuid = await repository.createBook(sample());
    final before = (await repository.updatedTimes())[uuid]!;
    final db = await pool.open(uuid);
    await db.rounds.insert(
      RoundGeneration(
        meta: RoundMeta(
          uuid: 'g1',
          roundIndex: 1,
          roundSerialNum: 1,
          isUsing: true,
          operatedAt: DateTime.utc(2026, 3, 4, 5),
        ),
        aiNarrative: '正文',
      ),
    );

    // RoundStore.insert 会 touch book_meta.updated_at。
    final meta = await db.meta.read();
    expect(meta.updatedAt.isBefore(before), isFalse);

    // 不手动 loadBook，直接读首页时间即应按文件 mtime 自愈。
    final after = (await repository.updatedTimes())[uuid]!;
    expect(after, meta.updatedAt, reason: '首页排序必须读到 book_meta 的信源时间');
    // 顺带把最近对话时间也校正了。
    expect(
      (await repository.lastRoundTimes())[uuid],
      DateTime.utc(2026, 3, 4, 5),
    );
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
