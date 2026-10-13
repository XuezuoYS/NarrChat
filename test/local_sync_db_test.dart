import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/database/local_sync_db.dart';
import 'package:narrchat/database/sync_dao.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 本地同步元数据库（`local_config/local_db/narrchat_sync.db`）回归测试。
///
/// 背景：v20 起同步元数据（sync_state / sync_book_base / sync_mod_base）从用户库
/// 迁出至本地库——用户库整库字节即云端快照，元数据随快照上传既带本机信息
///（device_id）又徒增体积。用户库内保留同 schema 空表壳兼容「回退 ≤v19 旧版」。
void main() {
  final tempDirs = <Directory>[];

  String newTempDbPath(String prefix, String fileName) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    tempDirs.add(dir);
    return p.join(dir.path, fileName);
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalSyncDb.instance.close();
    LocalSyncDb.debugDatabasePathOverride =
        newTempDbPath('local_sync_db_test_', 'narrchat_sync.db');
  });

  tearDown(() async {
    LocalSyncDb.debugDatabasePathOverride = null;
    await LocalSyncDb.instance.close();
    DatabaseHelper.debugDatabasePathOverride = null;
    await DatabaseHelper.instance.close();
  });

  tearDownAll(() async {
    for (final dir in tempDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 忽略清理失败。
      }
    }
    tempDirs.clear();
  });

  test('新装本地库：三张同步表按唯一 DDL 源建出（uuid 主键 / 单行约束 / 子部件列）', () async {
    final db = await LocalSyncDb.instance.database;

    final stateCols = (await db.rawQuery('PRAGMA table_info(sync_state)'))
        .map((c) => c['name'])
        .toList();
    expect(
      stateCols,
      containsAll([
        'id',
        'device_id',
        'last_synced_at',
        'last_generation',
        'sync_in_flight',
        'last_phase',
        'last_error',
      ]),
    );

    final bookCols = (await db.rawQuery('PRAGMA table_info(sync_book_base)'))
        .map((c) => c['name'])
        .toList();
    expect(
      bookCols,
      containsAll([
        'uuid',
        'title',
        'info_fp',
        'roles_fp',
        'base_setting_fp',
        'prompts_fp',
        'failed_fp',
        'settings_fp',
        'rounds_fp',
        'worldbook_fp',
        'bookmods_fp',
      ]),
    );

    for (final table in ['sync_book_base', 'sync_mod_base']) {
      final sql = (await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      )).first['sql'] as String;
      expect(sql, contains('uuid TEXT PRIMARY KEY'), reason: '$table 主键应为 uuid');
    }

    expect(LocalSyncDb.currentDbVersion, 1);
  });

  test('sync_state 单行约束：id 只能为 1', () async {
    final db = await LocalSyncDb.instance.database;
    await db.insert('sync_state', {'id': 1, 'device_id': 'd1'});
    await expectLater(
      () => db.insert('sync_state', {'id': 2, 'device_id': 'd2'}),
      throwsA(isA<DatabaseException>()),
    );
    // 违约插入未生效：仍只有一行。
    expect(await db.query('sync_state'), hasLength(1));
  });

  test('SyncStateDao：状态与共基 CRUD 往返，putBookBase 清空子部件列', () async {
    final dao = SyncStateDao();

    // sync_state：空表读默认，写后读回。
    final initial = await dao.getState();
    expect(initial.deviceId, '');
    expect(initial.lastGeneration, 0);
    expect(initial.syncInFlight, isFalse);
    await dao.saveState(
      const SyncStateRecord(
        deviceId: 'device-X',
        lastSyncedAt: 123,
        lastGeneration: 9,
        syncInFlight: true,
        lastPhase: 'push',
        lastError: '',
      ),
    );
    final saved = await dao.getState();
    expect(saved.deviceId, 'device-X');
    expect(saved.lastSyncedAt, 123);
    expect(saved.lastGeneration, 9);
    expect(saved.syncInFlight, isTrue);
    expect(saved.lastPhase, 'push');

    // sync_book_base：uuid 主键 upsert + 查询映射。
    await dao.putBookBase(
      const SyncBookBase(
        uuid: 'u-1',
        title: '书甲',
        settingsFp: 'S1',
        roundsFp: 'R1',
        worldbookFp: 'W1',
        bookmodsFp: 'B1',
        settingsUpdatedAt: 11,
        roundsUpdatedAt: 22,
        worldbookUpdatedAt: 33,
        bookmodsUpdatedAt: 44,
      ),
    );
    final bases = await dao.getAllBookBases();
    expect(bases.keys, ['u-1']);
    expect(bases['u-1']!.settingsFp, 'S1');
    expect(bases['u-1']!.roundsFp, 'R1');
    expect(bases['u-1']!.worldbookFp, 'W1');
    expect(bases['u-1']!.bookmodsFp, 'B1');
    expect(bases['u-1']!.settingsUpdatedAt, 11);
    // 过渡期子部件列被清空（单部件为准，避免残留干扰回退）。
    final db = await LocalSyncDb.instance.database;
    final raw = (await db.query('sync_book_base')).single;
    for (final col in ['info_fp', 'roles_fp', 'base_setting_fp', 'prompts_fp', 'failed_fp']) {
      expect(raw[col], '', reason: '子部件列 $col 应被清空');
    }
    // 覆盖写（replace）不产生重复行。
    await dao.putBookBase(
      const SyncBookBase(uuid: 'u-1', title: '书甲改', settingsFp: 'S2'),
    );
    expect(await db.query('sync_book_base'), hasLength(1));
    expect((await dao.getAllBookBases())['u-1']!.settingsFp, 'S2');
    await dao.deleteBookBase('u-1');
    expect(await dao.getAllBookBases(), isEmpty);

    // sync_mod_base。
    await dao.putModBase(
      const SyncModBase(uuid: 'm-1', name: 'Mod甲', fingerprint: 'F1', updatedAt: 7),
    );
    final mods = await dao.getAllModBases();
    expect(mods['m-1']!.fingerprint, 'F1');
    expect(mods['m-1']!.updatedAt, 7);
    await dao.deleteModBase('m-1');
    expect(await dao.getAllModBases(), isEmpty);
  });

  test('新装用户库：同步表为同 schema 空表壳（与本地库 DDL 逐字一致）', () async {
    DatabaseHelper.debugDatabasePathOverride =
        newTempDbPath('user_db_fresh_', 'narrchat.db');

    final db = await DatabaseHelper.instance.database;
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name'] as String).toSet();
    expect(
      tables,
      containsAll(['sync_state', 'sync_book_base', 'sync_mod_base']),
      reason: '新装用户库应保留回退兼容空表壳',
    );
    for (final table in ['sync_state', 'sync_book_base', 'sync_mod_base']) {
      expect(await db.rawQuery('SELECT COUNT(*) AS c FROM "$table"'), [
        {'c': 0},
      ], reason: '新装用户库的同步表应为空表壳（数据只存本地同步库）');
    }

    // 空表壳 schema 与本地库一致（同一 DDL 来源 [LocalSyncDb.createSyncTables]）。
    final local = await LocalSyncDb.instance.database;
    for (final table in ['sync_state', 'sync_book_base', 'sync_mod_base']) {
      final userSql = (await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      )).first['sql'];
      final localSql = (await local.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      )).first['sql'];
      expect(userSql, localSql, reason: '$table 空表壳与本地库 DDL 必须逐字一致');
    }
  });
}
