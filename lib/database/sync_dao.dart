import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'local_sync_db.dart';
import 'sqflite_large_text.dart';

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

  /// 读全部书的共基。
  ///
  /// 实现必须能读出**超过 Android CursorWindow 单行上限**的指纹列
  /// （`rounds_fp` 是一本书全部轮次的完整文本，长书可达数 MB）——
  /// 禁止整表 `SELECT *`，见 [SyncStateDao.getAllBookBases]。
  Future<Map<String, SyncBookBase>> getAllBookBases();
  Future<void> putBookBase(SyncBookBase b);
  /// 按 uuid（= `sync_book_base` 主键）删除共基行。
  Future<void> deleteBookBase(String uuid);
  Future<Map<String, SyncModBase>> getAllModBases();
  Future<void> putModBase(SyncModBase b);
  /// 按 uuid（= `sync_mod_base` 主键）删除共基行。
  Future<void> deleteModBase(String uuid);
}

/// 云同步状态 / 共基数据访问对象（仅读写本地同步元数据库 [LocalSyncDb]，
/// 不触碰用户库业务表）。
///
/// **大字段读法**：Android 上的 sqflite 走系统 `CursorWindow`，单行超出窗口
/// （约 1~2 MB）会抛 `Row too big to fit into CursorWindow`；桌面 FFI 无此限制。
/// 共基的指纹列（尤其 `rounds_fp`）可能远大于该上限，因此整表读一律走
/// [readRowsWithLargeText] 分片拼回，**不要**改回 `db.query('sync_book_base')`
/// （= `SELECT *`）。分片读放在一个事务里，保证各片来自同一份快照。
class SyncStateDao implements SyncStateStore {
  final LocalSyncDb _helper = LocalSyncDb.instance;

  // ---------------------------------------------------------------------------
  // 共基列清单（必须覆盖建表 DDL 的全部列，等价原 `SELECT *`）
  // ---------------------------------------------------------------------------

  /// `sync_book_base` 的轻量列：一次查询读出，不含任何可能上 MB 的指纹列。
  static const List<String> _bookBasePlainColumns = [
    'uuid',
    'title',
    'settings_updated_at',
    'rounds_updated_at',
    'worldbook_updated_at',
    'bookmods_updated_at',
  ];

  /// `sync_book_base` 的大字段列：必须分片读（`rounds_fp`/`settings_fp`/
  /// `worldbook_fp` 都可能很大；`*_fp` 过渡期子部件列一并纳入，零成本且更稳）。
  static const List<String> _bookBaseLargeTextColumns = [
    'settings_fp',
    'info_fp',
    'roles_fp',
    'base_setting_fp',
    'prompts_fp',
    'failed_fp',
    'rounds_fp',
    'worldbook_fp',
    'bookmods_fp',
  ];

  /// `sync_mod_base` 的轻量列。
  static const List<String> _modBasePlainColumns = ['uuid', 'name', 'updated_at'];

  /// `sync_mod_base` 的大字段列（Mod 的世界书 / 提示词可能很长）。
  static const List<String> _modBaseLargeTextColumns = ['fingerprint'];

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
    final rows = await db.transaction(
      (txn) => readRowsWithLargeText(
        txn,
        table: 'sync_book_base',
        keyColumn: 'uuid',
        plainColumns: _bookBasePlainColumns,
        largeTextColumns: _bookBaseLargeTextColumns,
      ),
    );
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
    final rows = await db.transaction(
      (txn) => readRowsWithLargeText(
        txn,
        table: 'sync_mod_base',
        keyColumn: 'uuid',
        plainColumns: _modBasePlainColumns,
        largeTextColumns: _modBaseLargeTextColumns,
      ),
    );
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
