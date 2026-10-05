import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/database/round_stack_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round_stack.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// [RoundStackDao] 契约（真库 + 临时目录，不触碰用户数据）。
///
/// 覆盖分组读写、序号分配与复用、use 状态归一化、物理删除、整体替换排序，
/// 以及两条「删书无孤儿」路径（硬删外键级联 / 软删显式清理）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late String dbPath;
  late String bookUuid;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('round_stack_dao_test_');
    dbPath = p.join(dir.path, 'narrchat.db');
    DatabaseHelper.debugDatabasePathOverride = dbPath;
    bookUuid = await BookDao().insertBook(const Book(title: '书A'));
  });

  tearDown(() async {
    DatabaseHelper.debugDatabasePathOverride = null;
    await DatabaseHelper.instance.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 忽略清理失败。
    }
  });

  RoundStackRow row({
    required String uuid,
    int roundIndex = 1,
    int serial = 1,
    String? father,
    String? state,
    String narrative = '',
    List<String> userImages = const [],
  }) {
    return RoundStackRow(
      uuid: uuid,
      bookUuid: bookUuid,
      fatherUuid: father,
      roundIndex: roundIndex,
      roundSerialNum: serial,
      roundState: state,
      roundCreatedAt: DateTime.fromMillisecondsSinceEpoch(1000 + serial),
      userInput: '输入$serial',
      aiNarrative: narrative.isEmpty ? '正文$serial' : narrative,
      userImages: userImages,
    );
  }

  test('insertGeneration + loadByBook / getByUuid / getMetaByUuid：全量与元数据两条读路径', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    await dao.insertGeneration(db, row(uuid: 'g2', roundIndex: 2, serial: 1));
    await dao.insertGeneration(db, row(uuid: 'g1', roundIndex: 1, serial: 2));
    await dao.insertGeneration(
      db,
      row(uuid: 'g3', roundIndex: 1, serial: 1, state: 'use'),
    );

    final all = await dao.loadByBook(bookUuid);
    expect(all.map((r) => r.uuid).toList(), ['g3', 'g1', 'g2'],
        reason: '按 round_index 升序、同轮按序号升序');

    final loaded = await dao.getByUuid('g1');
    expect(loaded!.aiNarrative, '正文2');
    expect(loaded.fatherUuid, isNull);
    expect(await dao.getByUuid(''), isNull);
    expect(await dao.getByUuid('missing'), isNull);

    final meta = await dao.getMetaByUuid('g3');
    expect(meta!.isUse, isTrue);
    expect(meta.roundSerialNum, 1);
    expect(meta.roundCreatedAt, DateTime.fromMillisecondsSinceEpoch(1001));

    final metas = await dao.loadMetaByBook(bookUuid);
    expect(metas.map((m) => m.uuid).toList(), ['g3', 'g1', 'g2']);
  });

  test('loadGroup：根分组与非根分组互不串台，按序号升序', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    await dao.insertGeneration(db, row(uuid: 'root1', serial: 1, state: 'use'));
    await dao.insertGeneration(db, row(uuid: 'root2', serial: 2));
    await dao.insertGeneration(db, row(uuid: 'kid1', serial: 1, father: 'p1'));
    await dao.insertGeneration(
      db,
      row(uuid: 'kid2', roundIndex: 2, serial: 1, father: 'p1'),
    );

    expect(
      (await dao.loadGroup(bookUuid, 1, null)).map((m) => m.uuid).toList(),
      ['root1', 'root2'],
    );
    expect(
      (await dao.loadGroup(bookUuid, 1, 'p1')).map((m) => m.uuid).toList(),
      ['kid1'],
    );
    expect(
      (await dao.loadGroup(bookUuid, 1, '')).map((m) => m.uuid).toList(),
      ['root1', 'root2'],
      reason: '空串父亲等价于根分组',
    );
  });

  test('nextSerial：空分组为 1；有 survivors 时 max+1；物理删除后可复用旧号', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    expect(await dao.nextSerial(db, bookUuid, 1, null), 1);

    await dao.insertGeneration(db, row(uuid: 'a', serial: 1));
    await dao.insertGeneration(db, row(uuid: 'b', serial: 3));
    expect(await dao.nextSerial(db, bookUuid, 1, null), 4);
    expect(await dao.nextSerial(db, bookUuid, 1, 'p1'), 1,
        reason: '不同分组各算各的');

    await dao.deleteByUuids(db, ['b']);
    expect(await dao.nextSerial(db, bookUuid, 1, null), 2,
        reason: '物理删除后序号可复用（身份靠 uuid）');
  });

  test('setGroupUseState：置 use 与清 use 各自生效', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    await dao.insertGeneration(db, row(uuid: 'a', serial: 1, state: 'use'));
    await dao.insertGeneration(db, row(uuid: 'b', serial: 2));

    await dao.setGroupUseState(db, setUse: ['b'], clearUse: ['a']);
    expect((await dao.getMetaByUuid('a'))!.roundState, isNull);
    expect((await dao.getMetaByUuid('b'))!.isUse, isTrue);

    await dao.setGroupUseState(db, clearUse: ['b']);
    expect((await dao.getMetaByUuid('b'))!.roundState, isNull);
    // 空集合不得报错（归一化会传入空列表）。
    await dao.setGroupUseState(db);
    expect((await dao.getMetaByUuid('b'))!.roundState, isNull);
  });

  test('updateContent：只改内容列，uuid / 序号 / 父 / 状态 / 创建时间不动', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    await dao.insertGeneration(
      db,
      row(uuid: 'a', serial: 2, state: 'use', userImages: const ['old.png']),
    );

    await dao.updateContent(
      db,
      row(uuid: 'a', serial: 99, state: null, narrative: '改后正文',
          userImages: const ['new.png'])
          .copyWith(fatherUuid: 'p9'),
    );

    final after = (await dao.getByUuid('a'))!;
    expect(after.aiNarrative, '改后正文');
    expect(after.userImages, ['new.png']);
    expect(after.roundSerialNum, 2, reason: '序号不变');
    expect(after.roundState, 'use', reason: '状态不变');
    expect(after.fatherUuid, isNull, reason: '父不变');
    expect(after.roundCreatedAt, DateTime.fromMillisecondsSinceEpoch(1002),
        reason: '本代创建时间不变');
  });

  test('deleteByUuids / deleteFromRound：物理删除且不影响其它轮次', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    await dao.insertGeneration(db, row(uuid: 'a', roundIndex: 1));
    await dao.insertGeneration(db, row(uuid: 'b', roundIndex: 2));
    await dao.insertGeneration(db, row(uuid: 'c', roundIndex: 3));

    await dao.deleteByUuids(db, ['a']);
    expect((await dao.loadByBook(bookUuid)).map((r) => r.uuid), ['b', 'c']);
    await dao.deleteByUuids(db, const []);
    expect((await dao.loadByBook(bookUuid)).length, 2, reason: '空列表是 no-op');

    await dao.deleteFromRound(db, bookUuid, 3);
    expect((await dao.loadByBook(bookUuid)).map((r) => r.uuid), ['b'],
        reason: '仅删该轮及之后（第 3 轮起）');

    await dao.deleteFromRound(db, bookUuid, 1);
    expect(await dao.loadByBook(bookUuid), isEmpty);
  });

  test('replaceBookStack：先清后插且按 round_index 升序落库（拓扑序）', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    await dao.insertGeneration(db, row(uuid: 'stale', roundIndex: 9));

    await dao.replaceBookStack(db, bookUuid, [
      row(uuid: 'r3', roundIndex: 3, serial: 1),
      row(uuid: 'r1', roundIndex: 1, serial: 1),
      row(uuid: 'r2', roundIndex: 2, serial: 1, father: 'r1'),
    ]);

    final byRowid = await db.rawQuery(
      'SELECT uuid FROM round_stack WHERE book_uuid = ? ORDER BY rowid ASC',
      [bookUuid],
    );
    expect(byRowid.map((r) => r['uuid']), ['r1', 'r2', 'r3'],
        reason: '插入顺序 = round_index 升序（father 总在更早轮次）');
    expect(await dao.loadByBook(bookUuid), hasLength(3));

    // 再替换为空：整树清空。
    await dao.replaceBookStack(db, bookUuid, const []);
    expect(await dao.loadByBook(bookUuid), isEmpty);
  });

  test('hasTable：真实库有表；老 schema 库（无该表）返回 false', () async {
    final db = await DatabaseHelper.instance.database;
    expect(await RoundStackDao.hasTable(db), isTrue);

    final legacyDir = Directory.systemTemp.createTempSync('round_stack_legacy_');
    addTearDown(() {
      try {
        legacyDir.deleteSync(recursive: true);
      } catch (_) {
        // 忽略清理失败。
      }
    });
    final legacy = await databaseFactoryFfi.openDatabase(
      p.join(legacyDir.path, 'v18.db'),
      options: OpenDatabaseOptions(
        version: 18,
        onCreate: (d, v) => d.execute('CREATE TABLE books (uuid TEXT PRIMARY KEY)'),
      ),
    );
    expect(await RoundStackDao.hasTable(legacy), isFalse,
        reason: '老快照 / 老备份库必须能被守卫识别');
    await legacy.close();
  });

  test('删书：硬删无孤儿行（外键级联 + 显式删除）；软删清 stack 但保留 rounds', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    await dao.insertGeneration(db, row(uuid: 'a'));
    await db.insert('rounds', {
      'book_uuid': bookUuid,
      'round_index': 1,
      'use_stack_uuid': 'a',
    });

    await BookDao().softDeleteBook(bookUuid);
    expect(await dao.loadByBook(bookUuid), isEmpty, reason: '软删即清版本树');
    expect(
      await db.query('rounds', where: 'book_uuid = ?', whereArgs: [bookUuid]),
      hasLength(1),
      reason: 'rounds 行保留（同步删除传播仍以内容部件为准）',
    );
    expect(
      await db.query('books', where: 'uuid = ?', whereArgs: [bookUuid]),
      hasLength(1),
      reason: '软删只打墓碑',
    );

    await dao.insertGeneration(db, row(uuid: 'b'));
    await BookDao().deleteBook(bookUuid);
    expect(await dao.loadByBook(bookUuid), isEmpty);
    expect(await db.query('books'), isEmpty);
    expect(await db.query('rounds'), isEmpty);
  });

  test('DB-6：三个索引存在，分组查询走 ix_stack_group', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    for (var i = 0; i < 8; i++) {
      await dao.insertGeneration(db, row(uuid: 'g$i', serial: i + 1));
    }
    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND tbl_name = 'round_stack'",
    );
    expect(
      indexes.map((r) => r['name']).toSet(),
      containsAll(<String>['ix_stack_group', 'ix_stack_father', 'ix_stack_book']),
    );

    final plan = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT uuid FROM round_stack '
      'WHERE book_uuid = ? AND round_index = ? AND father_uuid IS NULL '
      'ORDER BY round_serial_num',
      [bookUuid, 1],
    );
    final detail = plan.map((r) => r['detail'] ?? '').join(' | ');
    expect(detail, contains('ix_stack_group'),
        reason: '分组查询必须命中复合索引（实际计划：$detail）');
  });

  test('根口径：NULL 与空串父亲都算「根」，分组查询 / 序号分配同一口径', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    await dao.insertGeneration(db, row(uuid: 'g-null', serial: 1, state: 'use'));
    // 手工写入空串父亲（老客户端 / 手工改库的脏数据）：内存侧算根，SQL 也必须算根。
    await db.insert(
      'round_stack',
      row(uuid: 'g-empty', serial: 2).toMap()..['father_uuid'] = '',
    );
    await dao.insertGeneration(
      db,
      row(uuid: 'g-kid', roundIndex: 2, serial: 1, father: 'g-null'),
    );

    final group = await dao.loadGroup(bookUuid, 1, null);
    expect(
      group.map((m) => m.uuid),
      ['g-null', 'g-empty'],
      reason: '空串父亲与 NULL 同属「根」分组（否则同一行在内存算根、SQL 被漏掉）',
    );
    expect(group.first.fatherUuid, isNull);
    expect(await dao.nextSerial(db, bookUuid, 1, null), 3,
        reason: '根分组序号把空串行也算进去');
    expect((await dao.getByUuid('g-empty'))!.fatherUuid, isNull,
        reason: '空串父亲读出来归一化为「根」');

    // 非空父亲的子分组不受影响。
    expect((await dao.loadGroup(bookUuid, 2, 'g-null')).map((m) => m.uuid), ['g-kid']);
  });

  test('versionLabel（合并页只读指示器）：按末轮当前代所属分组给出「第 x 代 / 最新第 y 代」', () async {
    final dao = RoundStackDao();
    final db = await DatabaseHelper.instance.database;
    await dao.insertGeneration(db, row(uuid: 'g1', roundIndex: 1, serial: 1, state: 'use'));
    await dao.insertGeneration(db, row(uuid: 'g2', roundIndex: 2, serial: 3, father: 'g1', state: 'use'));
    await dao.insertGeneration(db, row(uuid: 'g3', roundIndex: 2, serial: 5, father: 'g1'));
    await db.insert('rounds', {
      'book_uuid': bookUuid,
      'round_index': 1,
      'use_stack_uuid': 'g1',
    });
    // 末轮（第 2 轮）尚无投影行 → 取第 1 轮锚点所在分组。
    expect(
      await RoundStackDao.versionLabel(db, bookUuid),
      '第 1 代 / 最新第 1 代',
    );

    await db.insert('rounds', {
      'book_uuid': bookUuid,
      'round_index': 2,
      'use_stack_uuid': 'g2',
    });
    expect(
      await RoundStackDao.versionLabel(db, bookUuid),
      '第 3 代 / 最新第 5 代',
      reason: '取最末轮当前代（g2 序号 3）与同组最大存活序号（5）',
    );

    // 无锚点 / 空书 → ''。
    expect(await RoundStackDao.versionLabel(db, 'no-such-book'), '');
    expect(await RoundStackDao.versionLabel(db, ''), '');

    // 老库（无 round_stack 表）→ ''（合并页据此不显示指示器）。
    final legacyDir = Directory.systemTemp.createTempSync('round_stack_label_');
    addTearDown(() {
      try {
        legacyDir.deleteSync(recursive: true);
      } catch (_) {
        // 忽略清理失败。
      }
    });
    final legacy = await databaseFactoryFfi.openDatabase(
      p.join(legacyDir.path, 'v18.db'),
      options: OpenDatabaseOptions(
        version: 18,
        onCreate: (d, v) async {
          await d.execute('CREATE TABLE books (uuid TEXT PRIMARY KEY)');
          await d.execute(
            'CREATE TABLE rounds (id INTEGER PRIMARY KEY, book_uuid TEXT, round_index INTEGER, use_stack_uuid TEXT)',
          );
        },
      ),
    );
    expect(await RoundStackDao.versionLabel(legacy, bookUuid), '');
    await legacy.close();
  });
}
