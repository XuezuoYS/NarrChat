import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'database_helper.dart';

/// `sync_state` 单行记录：本设备同步状态与崩溃恢复标记。
class SyncStateRecord {
  final String deviceId;
  final int lastSyncedAt;
  final int lastGeneration;
  final bool syncInFlight;
  final String lastPhase;
  final String lastError;

  const SyncStateRecord({
    this.deviceId = '',
    this.lastSyncedAt = 0,
    this.lastGeneration = 0,
    this.syncInFlight = false,
    this.lastPhase = '',
    this.lastError = '',
  });
}

/// `sync_book_base` 一行：某本书在三向合并中的 common base（uuid 主键）。
///
/// 设置为**单部件**（settings_fp）。开发期过渡列（info_fp 等子部件列）仅作
/// 降级回退：settings_fp 为空时取首个非空子部件值（下一次同步重写后自愈）。
class SyncBookBase {
  final String uuid;
  final String title;
  final String settingsFp;
  final String roundsFp;
  final String worldbookFp;
  final String bookmodsFp;
  final int settingsUpdatedAt;
  final int roundsUpdatedAt;
  final int worldbookUpdatedAt;
  final int bookmodsUpdatedAt;

  const SyncBookBase({
    required this.uuid,
    this.title = '',
    this.settingsFp = '',
    this.roundsFp = '',
    this.worldbookFp = '',
    this.bookmodsFp = '',
    this.settingsUpdatedAt = 0,
    this.roundsUpdatedAt = 0,
    this.worldbookUpdatedAt = 0,
    this.bookmodsUpdatedAt = 0,
  });

  /// 读行：settings_fp 优先；空时回退到过渡期子部件列（首个非空）。
  factory SyncBookBase.fromRow(Map<String, Object?> r) {
    final single = (r['settings_fp'] as String?) ?? '';
    final fallback = single.isNotEmpty
        ? single
        : (r['info_fp'] as String? ?? '')
            .isNotEmpty
            ? r['info_fp'] as String
            : (r['roles_fp'] as String? ?? r['base_setting_fp'] as String? ??
                    r['prompts_fp'] as String? ?? '');
    return SyncBookBase(
      uuid: (r['uuid'] as String?) ?? '',
      title: (r['title'] as String?) ?? '',
      settingsFp: fallback,
      roundsFp: (r['rounds_fp'] as String?) ?? '',
      worldbookFp: (r['worldbook_fp'] as String?) ?? '',
      bookmodsFp: (r['bookmods_fp'] as String?) ?? '',
      settingsUpdatedAt: (r['settings_updated_at'] as int?) ?? 0,
      roundsUpdatedAt: (r['rounds_updated_at'] as int?) ?? 0,
      worldbookUpdatedAt: (r['worldbook_updated_at'] as int?) ?? 0,
      bookmodsUpdatedAt: (r['bookmods_updated_at'] as int?) ?? 0,
    );
  }
}

/// `sync_mod_base` 一行：某 Mod 的合并共基（uuid 主键）。
class SyncModBase {
  final String uuid;
  final String name;
  final String fingerprint;
  final int updatedAt;

  const SyncModBase({
    required this.uuid,
    this.name = '',
    this.fingerprint = '',
    this.updatedAt = 0,
  });

  factory SyncModBase.fromRow(Map<String, Object?> r) => SyncModBase(
        uuid: (r['uuid'] as String?) ?? '',
        name: (r['name'] as String?) ?? '',
        fingerprint: (r['fingerprint'] as String?) ?? '',
        updatedAt: (r['updated_at'] as int?) ?? 0,
      );
}

/// 云同步状态 / 共基数据访问抽象，供 `DatabaseSyncRunner` 依赖（便于注入内存替身）。
///
/// 图片删除墓碑**不在此列**（不进入数据库）：由独立的墓碑文件承载
/// （`img_tombstones.dart`——WebDAV 云端文件 + 本地工作副本）。
abstract class SyncStateStore {
  Future<SyncStateRecord> getState();
  Future<void> saveState(SyncStateRecord s);
  Future<Map<String, SyncBookBase>> getAllBookBases();
  Future<void> putBookBase(SyncBookBase b);
  Future<void> deleteBookBase(String title);
  Future<Map<String, SyncModBase>> getAllModBases();
  Future<void> putModBase(SyncModBase b);
  Future<void> deleteModBase(String name);
}

/// 云同步状态 / 共基数据访问对象（仅读写同步辅助表，不触碰业务表）。
class SyncStateDao implements SyncStateStore {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  // ---------------------------------------------------------------------------
  // sync_state
  // ---------------------------------------------------------------------------
  @override
  Future<SyncStateRecord> getState() async {
    final db = await _helper.database;
    final rows = await db.query('sync_state', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return const SyncStateRecord();
    final r = rows.first;
    return SyncStateRecord(
      deviceId: (r['device_id'] as String?) ?? '',
      lastSyncedAt: (r['last_synced_at'] as int?) ?? 0,
      lastGeneration: (r['last_generation'] as int?) ?? 0,
      syncInFlight: ((r['sync_in_flight'] as int?) ?? 0) == 1,
      lastPhase: (r['last_phase'] as String?) ?? '',
      lastError: (r['last_error'] as String?) ?? '',
    );
  }

  @override
  Future<void> saveState(SyncStateRecord s) async {
    final db = await _helper.database;
    await db.insert(
      'sync_state',
      {
        'id': 1,
        'device_id': s.deviceId,
        'last_synced_at': s.lastSyncedAt,
        'last_generation': s.lastGeneration,
        'sync_in_flight': s.syncInFlight ? 1 : 0,
        'last_phase': s.lastPhase,
        'last_error': s.lastError,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------------------------------------------------------------------------
  // sync_book_base
  // ---------------------------------------------------------------------------
  @override
  Future<Map<String, SyncBookBase>> getAllBookBases() async {
    final db = await _helper.database;
    final rows = await db.query('sync_book_base');
    return {
      for (final r in rows) (r['uuid'] as String? ?? ''): SyncBookBase.fromRow(r),
    };
  }

  @override
  Future<void> putBookBase(SyncBookBase b) async {
    final db = await _helper.database;
    await db.insert(
      'sync_book_base',
      {
        'uuid': b.uuid,
        'title': b.title,
        'settings_fp': b.settingsFp,
        // 过渡期子部件列清空（单部件为准；避免残留旧的拆分值干扰回退）。
        'info_fp': '',
        'roles_fp': '',
        'base_setting_fp': '',
        'prompts_fp': '',
        'failed_fp': '',
        'rounds_fp': b.roundsFp,
        'worldbook_fp': b.worldbookFp,
        'bookmods_fp': b.bookmodsFp,
        'settings_updated_at': b.settingsUpdatedAt,
        'rounds_updated_at': b.roundsUpdatedAt,
        'worldbook_updated_at': b.worldbookUpdatedAt,
        'bookmods_updated_at': b.bookmodsUpdatedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteBookBase(String uuid) async {
    final db = await _helper.database;
    await db.delete('sync_book_base', where: 'uuid = ?', whereArgs: [uuid]);
  }

  // ---------------------------------------------------------------------------
  // sync_mod_base
  // ---------------------------------------------------------------------------
  @override
  Future<Map<String, SyncModBase>> getAllModBases() async {
    final db = await _helper.database;
    final rows = await db.query('sync_mod_base');
    return {
      for (final r in rows) (r['uuid'] as String? ?? ''): SyncModBase.fromRow(r),
    };
  }

  @override
  Future<void> putModBase(SyncModBase b) async {
    final db = await _helper.database;
    await db.insert(
      'sync_mod_base',
      {'uuid': b.uuid, 'name': b.name, 'fingerprint': b.fingerprint, 'updated_at': b.updatedAt},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteModBase(String uuid) async {
    final db = await _helper.database;
    await db.delete('sync_mod_base', where: 'uuid = ?', whereArgs: [uuid]);
  }
}
