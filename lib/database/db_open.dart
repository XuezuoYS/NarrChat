import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sqflite_desktop.dart';

/// 库结构 / 身份校验失败。
///
/// 刻意做成异常而不是静默修复：几个库互相对不上（`master_uuid` 不一致、
/// 文件名与 `book_meta.book_uuid` 不一致、单行表多行）时，自动"修一下"
/// 只会把数据的毛病藏起来，宁可拒绝加载并提示。
class DbIntegrityException implements Exception {
  DbIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'DbIntegrityException: $message';
}

/// R3 各数据库统一的打开入口。
///
/// 集中四件事，避免每个库各写一遍还写歪：
///
/// 1. 桌面端先装好 FFI 工厂（[ensureDesktopSqfliteFactory]）；
/// 2. 文件所在目录不存在时先建目录（`books/`、`local_db/` 都可能不存在）；
/// 3. `PRAGMA foreign_keys = ON`，与 R2 行为保持一致；
/// 4. **降级守卫**：库版本高于当前应用支持的版本时明确报错，而不是让 sqflite
///    把 `user_version` 静默写低（写低之后旧版本一保存就会整行覆盖、清空新列）。
///
/// **刻意不启用 WAL**：云端快照就是「一个 .db 文件」，WAL 会把最新数据留在
/// `-wal` 旁挂文件里，直接复制 `.db` 会丢掉最近的写入。
Future<Database> openAppDatabase({
  required String path,
  required int version,
  required Future<void> Function(Database db) onCreate,
  Future<void> Function(Database db, int oldVersion, int newVersion)? onUpgrade,
}) async {
  ensureDesktopSqfliteFactory();
  await Directory(p.dirname(path)).create(recursive: true);
  // 标记写在外面：sqflite 可能把回调里的异常包成自己的 `DatabaseException`，
  // 这里按标记重抛本文件的类型，调用方才有稳定可判的错误。
  var downgraded = false;
  try {
    return await openDatabase(
      path,
      version: version,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, v) async {
        await onCreate(db);
      },
      onUpgrade: onUpgrade,
      onDowngrade: (db, oldVersion, newVersion) async {
        downgraded = true;
        throw DbIntegrityException(
          '库版本（$oldVersion）高于当前应用支持的版本（$newVersion）：$path',
        );
      },
    );
  } catch (_) {
    if (downgraded) {
      throw DbIntegrityException(
        '库版本高于当前应用支持的版本（$version），已拒绝打开以免数据被降级：$path',
      );
    }
    rethrow;
  }
}

/// 只读打开一个**已存在**的库文件执行只读查询；文件不存在返回 null。
///
/// 只给「打开前的预检」用（例如 Mod 库是否被旧版本访问过）：不建库、不迁移、
/// 不改版本，用完即关。库损坏等错误照常抛给调用方。
Future<T?> withReadOnlyDatabase<T>(
  String path,
  Future<T> Function(Database db) action,
) async {
  if (!await File(path).exists()) return null;
  ensureDesktopSqfliteFactory();
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
  );
  try {
    return await action(db);
  } finally {
    await db.close();
  }
}

/// 读取库的 `user_version`。
///
/// 这是 schema 版本的**唯一权威**；`meta.database_version` 只是迁移后写入的镜像。
Future<int> readUserVersion(DatabaseExecutor db) async {
  final rows = await db.rawQuery('PRAGMA user_version');
  if (rows.isEmpty) return 0;
  final value = rows.first.values.first;
  return value is int ? value : int.tryParse('$value') ?? 0;
}

/// 判断库里是否已有某张表（快照兼容、老库守卫用）。
Future<bool> tableExists(DatabaseExecutor db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    [table],
  );
  return rows.isNotEmpty;
}

/// 判断库里某张表是否有某一列。
Future<bool> columnExists(
  DatabaseExecutor db,
  String table,
  String column,
) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  for (final row in rows) {
    if (row['name'] == column) return true;
  }
  return false;
}
