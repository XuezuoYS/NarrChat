import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/app_paths.dart';
import '../utils/timestamp_format.dart';
import 'db_open.dart';
import 'db_schema.dart';

/// 同步单元的类别。
///
/// 一个单元 = 一个数据库文件 = 一个云端快照 = 一个独立代数。
class SyncUnitKind {
  SyncUnitKind._();

  static const String library = 'library';
  static const String mods = 'mods';
  static const String book = 'book';

  /// library 单元的固定键。
  static const String libraryKey = 'library';

  /// mods 单元的固定键。
  static const String modsKey = 'mods';

  /// 书单元的键：`book:<book_uuid>`。
  static String bookKey(String bookUuid) => '$book:$bookUuid';

  /// 从 books 单元键里取回书 uuid；不是书单元时返回空串。
  static String bookUuidOf(String unitKey) =>
      unitKey.startsWith('$book:') ? unitKey.substring(book.length + 1) : '';

  /// 全部合法类别。
  static const Set<String> all = {library, mods, book};
}

/// 本机同步状态（单行）。
class SyncStateRow {
  const SyncStateRow({
    this.deviceId = '',
    this.lastPhase = '',
    this.lastError = '',
    this.inFlight = false,
    this.updatedAt,
  });

  /// 本设备标识（首次同步时生成，用于区分"哪台机器推的"）。
  final String deviceId;

  /// 上次同步阶段（展示用）。
  final String lastPhase;

  /// 上次错误（空 = 无）。
  final String lastError;

  /// 是否有同步正在进行。
  final bool inFlight;

  final DateTime? updatedAt;

  factory SyncStateRow.fromRow(Map<String, Object?> row) {
    return SyncStateRow(
      deviceId: (row['device_id'] as String?) ?? '',
      lastPhase: (row['last_phase'] as String?) ?? '',
      lastError: (row['last_error'] as String?) ?? '',
      inFlight: ((row['in_flight'] as int?) ?? 0) != 0,
      updatedAt: parseTimestamp(row['updated_at']),
    );
  }

  Map<String, Object?> toRow() => {
        'id': 1,
        'device_id': deviceId,
        'last_phase': lastPhase,
        'last_error': lastError,
        'in_flight': inFlight ? 1 : 0,
        'updated_at': updatedAt == null
            ? nowTimestamp()
            : formatTimestamp(updatedAt!),
      };

  SyncStateRow copyWith({
    String? deviceId,
    String? lastPhase,
    String? lastError,
    bool? inFlight,
    DateTime? updatedAt,
  }) {
    return SyncStateRow(
      deviceId: deviceId ?? this.deviceId,
      lastPhase: lastPhase ?? this.lastPhase,
      lastError: lastError ?? this.lastError,
      inFlight: inFlight ?? this.inFlight,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 一个同步单元的共基与代数。
///
/// [baseDigest] 是"上次成功同步时本地内容的摘要"，[remoteDigest] 是云端当前
/// 快照的摘要；两者与当前摘要一比就知道该推、该拉、还是冲突。
class SyncUnitRow {
  const SyncUnitRow({
    required this.unitKey,
    required this.kind,
    this.refUuid = '',
    this.generation = 0,
    this.remoteDigest = '',
    this.baseDigest = '',
    this.lastSyncedAt,
  });

  final String unitKey;
  final String kind;

  /// 书的 uuid（library / mods 单元为空）。
  final String refUuid;

  /// 本单元最后一次成功推送 / 拉取的代数。
  final int generation;

  final String remoteDigest;
  final String baseDigest;
  final DateTime? lastSyncedAt;

  factory SyncUnitRow.fromRow(Map<String, Object?> row) {
    return SyncUnitRow(
      unitKey: (row['unit_key'] as String?) ?? '',
      kind: (row['kind'] as String?) ?? '',
      refUuid: (row['ref_uuid'] as String?) ?? '',
      generation: (row['generation'] as int?) ?? 0,
      remoteDigest: (row['remote_digest'] as String?) ?? '',
      baseDigest: (row['base_digest'] as String?) ?? '',
      lastSyncedAt: parseTimestamp(row['last_synced_at']),
    );
  }

  Map<String, Object?> toRow() => {
        'unit_key': unitKey,
        'kind': kind,
        'ref_uuid': refUuid,
        'generation': generation,
        'remote_digest': remoteDigest,
        'base_digest': baseDigest,
        'last_synced_at':
            lastSyncedAt == null ? '' : formatTimestamp(lastSyncedAt!),
      };
}

/// 本地云备份库（`local_config/local_db/sync.db`）。
///
/// 不进云、不上传、可随时重建（丢了只会导致下次全量比对）。
abstract class SyncStore {
  Future<SyncStateRow> readState();

  Future<void> writeState(SyncStateRow state);

  Future<List<SyncUnitRow>> units();

  Future<SyncUnitRow?> unit(String unitKey);

  Future<void> putUnit(SyncUnitRow row);

  Future<void> removeUnit(String unitKey);

  /// 清空全部单元记录（重建 / 换云端目录时用）。
  Future<void> clearUnits();

  Future<void> close();
}

/// SQLite 版 [SyncStore]。
class SyncDb implements SyncStore {
  SyncDb({this.pathOverride});

  final String? pathOverride;

  Database? _db;

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    final path = pathOverride ?? await AppPaths.syncDatabasePath();
    final db = await openAppDatabase(
      path: path,
      version: localSyncDbVersion,
      onCreate: createSyncSchema,
      onUpgrade: (db, oldVersion, newVersion) async {
        // 同步元数据可重建：升级即整体重建，不写逐版本迁移。
        for (final table in const ['sync_state', 'sync_unit']) {
          await db.execute('DROP TABLE IF EXISTS $table');
        }
        await createSyncSchema(db);
      },
    );
    _db = db;
    return db;
  }

  @override
  Future<SyncStateRow> readState() async {
    final db = await _database;
    final rows = await db.query('sync_state', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return const SyncStateRow();
    return SyncStateRow.fromRow(rows.first);
  }

  @override
  Future<void> writeState(SyncStateRow state) async {
    final db = await _database;
    await db.insert(
      'sync_state',
      state.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<SyncUnitRow>> units() async {
    final db = await _database;
    final rows = await db.query('sync_unit', orderBy: 'unit_key ASC');
    return rows.map(SyncUnitRow.fromRow).toList();
  }

  @override
  Future<SyncUnitRow?> unit(String unitKey) async {
    final db = await _database;
    final rows = await db.query(
      'sync_unit',
      where: 'unit_key = ?',
      whereArgs: [unitKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SyncUnitRow.fromRow(rows.first);
  }

  @override
  Future<void> putUnit(SyncUnitRow row) async {
    final db = await _database;
    await db.insert(
      'sync_unit',
      row.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> removeUnit(String unitKey) async {
    final db = await _database;
    await db.delete(
      'sync_unit',
      where: 'unit_key = ?',
      whereArgs: [unitKey],
    );
  }

  @override
  Future<void> clearUnits() async {
    final db = await _database;
    await db.delete('sync_unit');
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
