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
/// 集中三件事，避免每个库各写一遍还写歪：
///
/// 1. 桌面端先装好 FFI 工厂（[ensureDesktopSqfliteFactory]）；
/// 2. 文件所在目录不存在时先建目录（`books/`、`local_db/` 都可能不存在）；
/// 3. `PRAGMA foreign_keys = ON`，与 R2 行为保持一致。
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
  return openDatabase(
    path,
    version: version,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
    },
    onCreate: (db, v) async {
      await onCreate(db);
    },
    onUpgrade: onUpgrade,
  );
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
