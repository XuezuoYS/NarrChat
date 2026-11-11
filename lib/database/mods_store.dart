import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/mod.dart';
import '../services/app_paths.dart';
import '../utils/timestamp_format.dart';
import '../utils/uuid_utils.dart';
import 'db_open.dart';
import 'db_schema.dart';

/// Mod 库（`user_data/narrchat_mods.db`）。
///
/// 只存**用户自定义** Mod；预置 Mod 由程序内置，引用标识固定 `preset::<id>`。
/// 列名与 R2 的差别只有主键 `uuid` → `mod_uuid`，因此在 SQL 里做一次别名，
/// 复用同一份领域模型 [Mod]，避免多出一套只换列名的影子模型。
abstract class ModsStore {
  Future<String> masterUuid();

  Future<List<Mod>> list({bool includeDeleted = false});

  Future<Mod?> get(String modUuid);

  /// 新增或覆盖（`created_at` 为空时补当前时间）。
  Future<void> upsert(Mod mod);

  /// 打上 / 清除墓碑。整库同步下墓碑只影响展示，不承担删除传播。
  Future<void> setDeletedAt(String modUuid, DateTime? deletedAt);

  /// 逐 Mod 合并：按传入的原始行整行覆盖（含墓碑），不动其它行。
  ///
  /// 只给云同步的「逐 Mod 合并」用：行来自云端快照（列名与本地一致），
  /// `deleted_at` 原样写入，既能传播删除也能把被删的 Mod 复活。
  Future<void> mergeRows(List<Map<String, Object?>> rows);

  /// 物理删除。
  Future<void> hardDelete(String modUuid);

  Future<void> close();
}

/// SQLite 版 [ModsStore]。
class ModsDb implements ModsStore {
  ModsDb({this.pathOverride, this.masterUuidOverride});

  final String? pathOverride;
  final String? masterUuidOverride;

  Database? _db;

  /// `mod_uuid` → `uuid` 的别名，让 [Mod.fromMap] / `toMap` 直接可用。
  /// 唯一来源，读写两侧都从这里取，避免列清单漂移。
  static const List<String> _rowColumns = [
    'mod_uuid AS uuid',
    'name',
    'description',
    'pre_prompt',
    'post_prompt',
    'system_prompt',
    'world_book',
    'created_at',
    'updated_at',
  ];

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    final path = pathOverride ?? await AppPaths.modsDatabasePath();
    final db = await openAppDatabase(
      path: path,
      version: userDataDbVersion,
      onCreate: (db) async {
        await createModsSchema(db);
        await db.insert('meta', {
          'master_uuid': masterUuidOverride ?? UuidUtils.generateUuidV4(),
          'database_version': userDataDbVersion,
        });
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await writeDatabaseVersion(db, 'meta', newVersion);
      },
    );
    _db = db;
    return db;
  }

  @override
  Future<String> masterUuid() async {
    final db = await _database;
    final rows = await db.query('meta', orderBy: 'rowid ASC', limit: 1);
    if (rows.isEmpty) return '';
    return (rows.first['master_uuid'] as String?) ?? '';
  }

  /// 迁移时写入 `master_uuid`（复用 library 的值）。
  Future<void> putMasterUuid(String masterUuid) async {
    final db = await _database;
    await db.insert('meta', {
      'master_uuid': masterUuid,
      'database_version': userDataDbVersion,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<Mod>> list({bool includeDeleted = false}) async {
    final db = await _database;
    final rows = await db.query(
      'mods',
      columns: _rowColumns,
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy: 'created_at ASC, mod_uuid ASC',
    );
    return rows.map(Mod.fromMap).toList();
  }

  @override
  Future<Mod?> get(String modUuid) async {
    if (modUuid.isEmpty) return null;
    final db = await _database;
    final rows = await db.query(
      'mods',
      columns: _rowColumns,
      where: 'mod_uuid = ? AND deleted_at IS NULL',
      whereArgs: [modUuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Mod.fromMap(rows.first);
  }

  @override
  Future<void> upsert(Mod mod) async {
    if (mod.uuid.isEmpty) {
      throw ArgumentError('upsert 需要非空 uuid');
    }
    final db = await _database;
    final now = nowTimestamp();
    final row = mod.toMap()
      ..remove('uuid')
      ..['mod_uuid'] = mod.uuid
      ..['created_at'] = mod.createdAt == null
          ? now
          : formatTimestamp(mod.createdAt!)
      ..['updated_at'] = mod.updatedAt == null
          ? now
          : formatTimestamp(mod.updatedAt!);
    await db.insert('mods', row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> setDeletedAt(String modUuid, DateTime? deletedAt) async {
    final db = await _database;
    await db.update(
      'mods',
      {
        'deleted_at': deletedAt == null ? null : formatTimestamp(deletedAt),
        'updated_at': nowTimestamp(),
      },
      where: 'mod_uuid = ?',
      whereArgs: [modUuid],
    );
  }

  @override
  Future<void> mergeRows(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    final normalized = <Map<String, Object?>>[];
    for (final row in rows) {
      final uuid = row['mod_uuid'];
      if (uuid is! String || uuid.isEmpty) {
        throw ArgumentError('mergeRows 需要非空 mod_uuid');
      }
      final name = row['name'];
      final createdAt = row['created_at'];
      final updatedAt = row['updated_at'];
      if (name is! String || createdAt is! String || updatedAt is! String) {
        throw ArgumentError('mergeRows 的行缺少必填列：$uuid');
      }
      normalized.add({
        'mod_uuid': uuid,
        'name': name,
        'description': _textOf(row, 'description'),
        'pre_prompt': _textOf(row, 'pre_prompt'),
        'post_prompt': _textOf(row, 'post_prompt'),
        'system_prompt': _textOf(row, 'system_prompt'),
        'world_book': _textOf(row, 'world_book'),
        'created_at': createdAt,
        'updated_at': updatedAt,
        // 远端墓碑原样落地：既能传播删除，也能让被删的 Mod 复活。
        'deleted_at': row['deleted_at'],
      });
    }
    final db = await _database;
    await db.transaction((txn) async {
      for (final row in normalized) {
        await txn.insert(
          'mods',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// 取文本列；缺省统一成空串（与建表默认值一致，避免写出 NULL 让摘要漂移）。
  static String _textOf(Map<String, Object?> row, String column) {
    final value = row[column];
    if (value == null) return '';
    if (value is String) return value;
    throw ArgumentError('mergeRows 的 $column 列不是文本：$value');
  }

  @override
  Future<void> hardDelete(String modUuid) async {
    final db = await _database;
    await db.delete('mods', where: 'mod_uuid = ?', whereArgs: [modUuid]);
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
