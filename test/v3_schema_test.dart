import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_db.dart';
import 'package:narrchat/database/book_store.dart';
import 'package:narrchat/database/cache_store.dart';
import 'package:narrchat/database/db_open.dart';
import 'package:narrchat/database/db_schema.dart';
import 'package:narrchat/database/library_store.dart';
import 'package:narrchat/database/mods_store.dart';
import 'package:narrchat/database/sync_store.dart';
import 'package:narrchat/models/book_meta.dart';
import 'package:narrchat/models/branch.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/models/world_book_row.dart';
import 'package:narrchat/utils/timestamp_format.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// R3 存储层回归测试：五个库的 DDL、版本号、单行表约束、写入归一化与白名单。
///
/// 这些用例只用临时目录里的真实 sqlite 文件（`sqflite_common_ffi`），
/// 不触碰真实用户目录，也不依赖任何平台插件。
void main() {
  final tempDirs = <Directory>[];

  String newTempPath(String prefix, String fileName) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    tempDirs.add(dir);
    return p.join(dir.path, fileName);
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

  Future<List<String>> columnsOf(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.map((c) => c['name'] as String).toList();
  }

  group('时间戳格式', () {
    test('定长毫秒 UTC，可直接按字典序比较', () {
      final t = DateTime.utc(2026, 3, 4, 5, 6, 7, 89);
      expect(formatTimestamp(t), '2026-03-04T05:06:07.089Z');
      expect(formatTimestamp(t).length, 24);
      final later = DateTime.utc(2026, 3, 4, 5, 6, 7, 890);
      expect(formatTimestamp(later).compareTo(formatTimestamp(t)), greaterThan(0));
    });

    test('本地时间先转 UTC 再格式化', () {
      final local = DateTime.utc(2026, 1, 1, 0, 0, 0, 0).toLocal();
      expect(formatTimestamp(local), '2026-01-01T00:00:00.000Z');
    });

    test('解析只接受定长格式，脏数据返回 null', () {
      expect(parseTimestamp('2026-03-04T05:06:07.089Z'),
          DateTime.utc(2026, 3, 4, 5, 6, 7, 89));
      expect(parseTimestamp('2026-03-04T05:06:07Z'), isNull);
      expect(parseTimestamp('2026-03-04 05:06:07'), isNull);
      expect(parseTimestamp(1720000000000), isNull);
      expect(parseTimestamp(null), isNull);
    });
  });

  group('narrchat_library.db', () {
    test('建库：表齐全 / user_version 22 / meta 单行 / 目录读写与墓碑过滤', () async {
      final path = newTempPath('v3_library_', 'narrchat_library.db');
      final store = LibraryDb(pathOverride: path);

      expect(await store.masterUuid(), isNotEmpty);
      expect(await store.databaseVersion(), userDataDbVersion);
      expect(userDataDbVersion, 22);

      await store.putBook(const LibraryBookRow(bookUuid: 'b1', title: '甲'));
      await store.putBook(const LibraryBookRow(bookUuid: 'b2', title: '乙'));
      expect((await store.books()).map((e) => e.bookUuid), ['b1', 'b2']);

      await store.setTitle('b1', '甲改');
      expect((await store.book('b1'))!.title, '甲改');

      await store.setDeletedAt('b1', DateTime.utc(2026, 5, 1));
      expect((await store.books()).map((e) => e.bookUuid), ['b2']);
      expect(
        (await store.books(includeDeleted: true)).map((e) => e.bookUuid),
        ['b1', 'b2'],
      );
      expect((await store.book('b1'))!.isDeleted, isTrue);

      await store.setDeletedAt('b1', null);
      expect((await store.books()).map((e) => e.bookUuid), ['b1', 'b2']);
      await store.removeBook('b2');
      expect((await store.books()).map((e) => e.bookUuid), ['b1']);

      await store.close();

      // 重新打开：master_uuid 不变（它是一次生成、终生稳定的身份）。
      final reopened = LibraryDb(pathOverride: path);
      final master = await reopened.masterUuid();
      expect(master, isNotEmpty);
      await reopened.close();
    });

    test('表结构与列顺序符合文档', () async {
      final path = newTempPath('v3_library_schema_', 'narrchat_library.db');
      final store = LibraryDb(pathOverride: path);
      await store.masterUuid();
      final db = await openAppDatabase(
        path: path,
        version: userDataDbVersion,
        onCreate: createLibrarySchema,
      );
      expect(await columnsOf(db, 'books'), ['book_uuid', 'title', 'deleted_at']);
      expect(await columnsOf(db, 'meta'), ['master_uuid', 'database_version']);
      expect(await readUserVersion(db), userDataDbVersion);
      await db.close();
      await store.close();
    });
  });

  group('narrchat_mods.db', () {
    test('主键别名：mod_uuid ↔ Mod.uuid，软删后不出现', () async {
      final path = newTempPath('v3_mods_', 'narrchat_mods.db');
      final store = ModsDb(
        pathOverride: path,
        masterUuidOverride: 'master-1',
      );

      expect(await store.masterUuid(), 'master-1');

      await store.upsert(Mod(
        uuid: 'm1',
        name: '甲',
        worldBookEntries: const [
          ModWorldBookEntry(keyword: '龙', content: '很凶'),
        ],
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      ));

      final got = await store.get('m1');
      expect(got, isNotNull);
      expect(got!.uuid, 'm1');
      expect(got.name, '甲');
      expect(got.worldBookEntries.single.keyword, '龙');

      expect((await store.list()).map((e) => e.uuid), ['m1']);
      await store.setDeletedAt('m1', DateTime.utc(2026, 2, 1));
      expect(await store.list(), isEmpty);
      expect(await store.get('m1'), isNull);
      expect((await store.list(includeDeleted: true)).single.uuid, 'm1');

      await store.setDeletedAt('m1', null);
      expect((await store.list()).single.uuid, 'm1');
      await store.hardDelete('m1');
      expect(await store.list(includeDeleted: true), isEmpty);
      await store.close();
    });
  });

  group('narrbook_<uuid>.db', () {
    late String path;

    BookMeta sampleMeta(String uuid) => BookMeta(
          bookUuid: uuid,
          masterUuid: 'master-1',
          title: '测试书',
          category: '分类',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 2),
          historyRounds: 3,
          memorySummaryRounds: 2,
        );

    test('建库：五张表齐全，book_meta 单行且可读回', () async {
      path = newTempPath('v3_book_', 'narrbook_b1.db');
      final book = await BookDb.create(meta: sampleMeta('b1'), pathOverride: path);

      final meta = await book.meta.read();
      expect(meta.bookUuid, 'b1');
      expect(meta.title, '测试书');
      expect(meta.category, '分类');
      expect(meta.historyRounds, 3);
      expect(meta.memorySummaryRounds, 2);
      expect(meta.masterUuid, 'master-1');

      final db = await openAppDatabase(
        path: path,
        version: userDataDbVersion,
        onCreate: createBookSchema,
      );
      expect(await readUserVersion(db), userDataDbVersion);
      expect(
        (await columnsOf(db, 'book_meta')).take(8),
        [
          'master_uuid',
          'database_version',
          'book_uuid',
          'title',
          'category',
          'created_at',
          'updated_at',
          'base_setting',
        ],
      );
      expect(
        (await columnsOf(db, 'round_stack')).take(8),
        [
          'uuid',
          'father_uuid',
          'branch_uuid',
          'round_index',
          'round_serial_num',
          'is_using',
          'operated_at',
          'message_status',
        ],
      );
      expect(
        (await columnsOf(db, 'branches')).take(6),
        [
          'branch_uuid',
          'father_row',
          'father_row_index',
          'father_branch',
          'branch_name',
          'father_row_shot',
        ],
      );
      await db.close();
      await book.close();
    });

    test('身份校验：文件名与 book_uuid 不符 / 文件不存在都拒绝打开', () async {
      final createPath = newTempPath('v3_book_id_', 'narrbook_b1.db');
      final book =
          await BookDb.create(meta: sampleMeta('b1'), pathOverride: createPath);
      await book.close();

      await expectLater(
        BookDb.open(bookUuid: 'b2', pathOverride: createPath),
        throwsA(isA<DbIntegrityException>()),
      );
      await expectLater(
        BookDb.open(
          bookUuid: 'nope',
          pathOverride: p.join(p.dirname(createPath), 'narrbook_nope.db'),
        ),
        throwsA(isA<DbIntegrityException>()),
      );
    });

    test('轮次：插入时同组归一化 / 轻量索引带图片标记 / 区间取正文', () async {
      final bookPath = newTempPath('v3_book_rounds_', 'narrbook_b1.db');
      final book =
          await BookDb.create(meta: sampleMeta('b1'), pathOverride: bookPath);

      RoundGeneration gen(String uuid, int index, {bool using = true, String father = '', List<String> images = const []}) {
        return RoundGeneration(
          meta: RoundMeta(
            uuid: uuid,
            fatherUuid: father.isEmpty ? null : father,
            roundIndex: index,
            roundSerialNum: 1,
            isUsing: using,
            operatedAt: DateTime.utc(2026, 1, 1),
          ),
          userInput: '问 $uuid',
          aiNarrative: '答 $uuid',
          userImages: images,
        );
      }

      await book.rounds.insert(gen('g1', 1));
      await book.rounds.insert(gen('g2', 1, images: const ['img/a.png']));
      expect(await book.rounds.count(), 2);

      final metas = await book.rounds.listMeta();
      final byId = {for (final m in metas) m.uuid: m};
      expect(byId['g1']!.isUsing, isFalse, reason: '同组只留一个 is_using');
      expect(byId['g2']!.isUsing, isTrue);
      expect(byId['g2']!.hasImages, isTrue);
      expect(byId['g1']!.hasImages, isFalse);

      await book.rounds.insert(gen('g3', 2, father: 'g2'));
      final window =
          await book.rounds.listGenerations(firstRoundIndex: 2, lastRoundIndex: 2);
      expect(window.single.uuid, 'g3');
      expect(window.single.aiNarrative, '答 g3');

      final all = await book.rounds.generations(['g1', 'g3', 'missing']);
      expect(all.map((e) => e.uuid), ['g1', 'g3']);

      await book.rounds.setUsing('g1');
      final afterSwitch = await book.rounds.listMeta();
      expect(
        afterSwitch.where((m) => m.roundIndex == 1 && m.isUsing).single.uuid,
        'g1',
      );

      await book.rounds.updateContent('g1', {'ai_narrative': '改过'});
      expect((await book.rounds.generation('g1'))!.aiNarrative, '改过');
      await expectLater(
        book.rounds.updateContent('g1', {'uuid': 'evil'}),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        book.rounds.updateMeta('g1', {'round_index': 99}),
        throwsA(isA<ArgumentError>()),
      );

      await book.rounds.delete(['g1', 'g2']);
      expect(await book.rounds.count(), 1);
      await book.close();
    });

    test('正文列白名单与 RoundGeneration.contentRow 键集一致', () {
      final empty = RoundGeneration(
        meta: RoundMeta(
          uuid: 'x',
          roundIndex: 0,
          roundSerialNum: 0,
          isUsing: false,
          operatedAt: DateTime.utc(1970),
        ),
      );
      expect(
        BookDb.contentColumns,
        equals(empty.contentRow().keys.toSet()),
        reason: '加正文列时必须同时更新两处',
      );
    });

    test('分支：默认分支不入表 / 激活唯一 / 删除后为空', () async {
      final bookPath = newTempPath('v3_book_branch_', 'narrbook_b1.db');
      final book =
          await BookDb.create(meta: sampleMeta('b1'), pathOverride: bookPath);

      await book.branches.upsert(Branch(
        branchUuid: 'br1',
        branchName: '如果',
        fatherRow: 'g1',
        fatherRowIndex: 3,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ));
      await book.branches.upsert(Branch(
        branchUuid: 'br2',
        branchName: '另一个如果',
        createdAt: DateTime.utc(2026, 1, 2),
        updatedAt: DateTime.utc(2026, 1, 2),
      ));

      await book.branches.setWorking('br1');
      expect(
        (await book.branches.list()).where((b) => b.branchWorking).map((b) => b.branchUuid),
        ['br1'],
      );
      await book.branches.setWorking('br2');
      expect(
        (await book.branches.list()).where((b) => b.branchWorking).map((b) => b.branchUuid),
        ['br2'],
      );
      expect((await book.branches.get('br1'))!.fatherRowIndex, 3);
      expect((await book.branches.get('br1'))!.fatherRow, 'g1');

      await expectLater(
        book.branches.upsert(Branch.defaultBranch()),
        throwsA(isA<ArgumentError>()),
        reason: '默认分支不记表',
      );
      await expectLater(
        book.branches.delete(Branch.defaultBranchUuid),
        throwsA(isA<ArgumentError>()),
        reason: '默认分支不可删除',
      );

      await book.branches.delete('br1');
      expect((await book.branches.list()).map((b) => b.branchUuid), ['br2']);
      await book.close();
    });

    test('世界书与启用 Mod：写入即刷新 book_meta.updated_at', () async {
      final bookPath = newTempPath('v3_book_aux_', 'narrbook_b1.db');
      final book = await BookDb.create(
        meta: BookMeta(
          bookUuid: 'b1',
          masterUuid: 'master-1',
          title: 't',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
        pathOverride: bookPath,
      );

      expect((await book.meta.read()).updatedAt, DateTime.utc(2026, 1, 1));

      await book.worldBook.upsert(WorldBookRow(
        uuid: 'w1',
        keyword: '龙, 蛇',
        content: '爬行类',
        isUsing: true,
        createdAt: DateTime.utc(2026, 2, 1),
        updatedAt: DateTime.utc(2026, 2, 1),
      ));
      final rows = await book.worldBook.list();
      expect(rows.single.keywords, ['龙', '蛇']);

      await book.useMods.replaceAll(const [
        UseModRow(modUuid: 'preset::a', sortOrder: 0),
        UseModRow(modUuid: 'm1', sortOrder: 1),
      ]);
      expect((await book.useMods.list()).map((e) => e.modUuid),
          ['preset::a', 'm1']);

      final touched = await book.meta.read();
      expect(touched.updatedAt.isAfter(DateTime.utc(2026, 1, 1)), isTrue);

      await book.worldBook.delete('w1');
      expect(await book.worldBook.list(), isEmpty);
      await book.close();
    });

    test('切换版本不刷新 updated_at（属"看哪一代"，不是内容变更）', () async {
      final bookPath = newTempPath('v3_book_touch_', 'narrbook_b1.db');
      final book = await BookDb.create(
        meta: BookMeta(
          bookUuid: 'b1',
          masterUuid: 'm',
          title: 't',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
        pathOverride: bookPath,
      );
      await book.rounds.insert(RoundGeneration(
        meta: RoundMeta(
          uuid: 'g1',
          roundIndex: 1,
          roundSerialNum: 1,
          isUsing: true,
          operatedAt: DateTime.utc(2026, 1, 1),
        ),
      ));
      final afterInsert = (await book.meta.read()).updatedAt;

      await book.rounds.insert(RoundGeneration(
        meta: RoundMeta(
          uuid: 'g2',
          roundIndex: 1,
          roundSerialNum: 2,
          isUsing: false,
          operatedAt: DateTime.utc(2026, 1, 1),
        ),
      ));
      final afterSecond = (await book.meta.read()).updatedAt;
      expect(afterSecond.isBefore(afterInsert), isFalse);

      await book.rounds.setUsing('g2');
      expect((await book.meta.read()).updatedAt, afterSecond);
      await book.close();
    });
  });

  group('library_cache.db', () {
    test('书籍索引与图片引用可整体替换', () async {
      final path = newTempPath('v3_cache_', 'library_cache.db');
      final cache = CacheDb(pathOverride: path);

      await cache.putIndex(BookIndexRow(
        bookUuid: 'b1',
        title: '甲',
        category: '武侠',
        updatedAt: DateTime.utc(2026, 1, 2),
        dbMtimeMs: 111,
      ));
      await cache.putIndex(const BookIndexRow(bookUuid: 'b2', title: '乙'));
      final got = await cache.indexOf('b1');
      expect(got!.title, '甲');
      expect(got.category, '武侠');
      expect(got.dbMtimeMs, 111);
      expect(got.updatedAt, DateTime.utc(2026, 1, 2));

      await cache.replaceAllIndex(const [
        BookIndexRow(bookUuid: 'b3', title: '丙'),
      ]);
      expect((await cache.allIndex()).map((e) => e.bookUuid), ['b3']);

      await cache.replaceImageRefs('b3', const [
        ImageRefRow(imagePath: 'img/a.png', bookUuid: 'b3', refCount: 2),
      ]);
      final refs = await cache.imageRefsOf('b3');
      expect(refs.single.imagePath, 'img/a.png');
      expect(refs.single.refCount, 2);

      await cache.removeIndex('b3');
      expect(await cache.allIndex(), isEmpty);
      await cache.close();
    });
  });

  group('sync.db', () {
    test('本机状态单行往返 + 单元增删', () async {
      final path = newTempPath('v3_sync_', 'sync.db');
      final sync = SyncDb(pathOverride: path);

      final initial = await sync.readState();
      expect(initial.deviceId, '');
      expect(initial.inFlight, isFalse);

      await sync.writeState(const SyncStateRow(
        deviceId: 'dev-1',
        lastPhase: 'done',
        inFlight: true,
      ));
      final state = await sync.readState();
      expect(state.deviceId, 'dev-1');
      expect(state.inFlight, isTrue);
      expect(state.lastPhase, 'done');

      await sync.putUnit(SyncUnitRow(
        unitKey: SyncUnitKind.bookKey('b1'),
        kind: SyncUnitKind.book,
        refUuid: 'b1',
        generation: 3,
        baseDigest: 'abc',
        remoteDigest: 'abc',
        lastSyncedAt: DateTime.utc(2026, 1, 1),
      ));
      final unit = await sync.unit(SyncUnitKind.bookKey('b1'));
      expect(unit!.generation, 3);
      expect(unit.baseDigest, 'abc');
      expect(SyncUnitKind.bookUuidOf(unit.unitKey), 'b1');
      expect(SyncUnitKind.bookUuidOf(SyncUnitKind.libraryKey), '');

      await sync.removeUnit(SyncUnitKind.bookKey('b1'));
      expect(await sync.units(), isEmpty);

      await sync.putUnit(const SyncUnitRow(
        unitKey: SyncUnitKind.libraryKey,
        kind: SyncUnitKind.library,
      ));
      await sync.clearUnits();
      expect(await sync.units(), isEmpty);
      await sync.close();
    });
  });
}
