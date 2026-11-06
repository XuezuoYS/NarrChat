import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/db_open.dart';
import '../database/db_schema.dart';
import '../database/migration/migration_paths.dart';
import 'app_repositories.dart';
import 'app_stores.dart';

/// 数据库中一列的结构信息。
class DebugColumn {
  const DebugColumn({
    required this.name,
    required this.type,
    required this.notNull,
    required this.isPrimaryKey,
    this.defaultValue,
  });

  final String name;
  final String type;
  final bool notNull;
  final bool isPrimaryKey;
  final Object? defaultValue;
}

/// 数据库中一个索引的结构信息。
class DebugIndex {
  const DebugIndex({
    required this.name,
    required this.unique,
    required this.columns,
  });

  final String name;
  final bool unique;
  final List<String> columns;
}

/// 数据库表列表中的一项（表名 + 总行数）。
class DebugTableSummary {
  const DebugTableSummary({required this.name, required this.rowCount});

  final String name;
  final int rowCount;
}

/// 一张表的某一页数据（结构 + 本页内容），供调试查看。
class DebugTablePage {
  const DebugTablePage({
    required this.name,
    required this.columns,
    required this.indexes,
    required this.rows,
    required this.totalCount,
    required this.page,
    required this.pageSize,
  });

  final String name;
  final List<DebugColumn> columns;
  final List<DebugIndex> indexes;
  final List<Map<String, Object?>> rows;
  final int totalCount;
  final int page;
  final int pageSize;
}

/// 一个可查看的库文件（R3 是多库，调试页要先选库）。
class DebugDbInfo {
  const DebugDbInfo({
    required this.id,
    required this.label,
    required this.path,
    required this.expectedVersion,
    required this.actualVersion,
    required this.sizeBytes,
    required this.exists,
  });

  /// 稳定标识：`library` / `mods` / `book:<uuid>` / `cache` / `sync` / `legacy-backup`。
  final String id;

  final String label;
  final String path;

  /// 应用当前期望的 schema 版本（`user_data` 下各库统一）。
  final int expectedVersion;

  /// 库文件实际的 `user_version`（不存在时为 0）。
  final int actualVersion;

  final int sizeBytes;
  final bool exists;

  bool get versionMatches => exists && actualVersion == expectedVersion;
}

/// 调试数据库访问抽象（可注入替身，避免测试触碰真实库）。
///
/// R3 没有"当前那个库"了：先 [listDatabases] 拿到库清单，再按 [dbId] 查表。
abstract class DebugDatabaseService {
  /// 全部可查看的库文件（含不存在的项，便于暴露"文件丢了"）。
  Future<List<DebugDbInfo>> listDatabases();

  /// 列出某个库里全部业务表（排除 `sqlite_*` 系统表）及各自总行数。
  Future<List<DebugTableSummary>> listTables(String dbId);

  /// 读取某库某表的第 [page] 页（每页 [pageSize] 行）结构与内容。
  Future<DebugTablePage> loadTable(
    String dbId,
    String tableName, {
    int page = 0,
    int pageSize = 20,
  });
}

/// 真实实现：按路径只读打开选中的库，不经过任何 DAO。
class SqliteDebugDatabaseService implements DebugDatabaseService {
  SqliteDebugDatabaseService({AppStores? stores})
      : _stores = stores ?? AppRepositories.instance.stores;

  final AppStores _stores;

  MigrationPaths get _paths => _stores.paths;

  @override
  Future<List<DebugDbInfo>> listDatabases() async {
    final entries = <({String id, String label, String path})>[
      (id: 'library', label: '书籍目录库', path: _paths.libraryDbPath),
      (id: 'mods', label: 'Mod 库', path: _paths.modsDbPath),
    ];

    final booksDir = Directory(_paths.booksDir);
    if (await booksDir.exists()) {
      final files = <File>[];
      await for (final entity in booksDir.list(followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.db')) {
          files.add(entity);
        }
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final name = p.basenameWithoutExtension(file.path);
        final uuid = name.startsWith('narrbook_')
            ? name.substring('narrbook_'.length)
            : name;
        entries.add((
          id: 'book:$uuid',
          label: '书库 ${uuid.length <= 8 ? uuid : uuid.substring(0, 8)}',
          path: file.path,
        ));
      }
    }

    entries.add((id: 'cache', label: '本地缓存库', path: _paths.cacheDbPath));
    entries.add((id: 'sync', label: '本地备份状态库', path: _paths.syncDbPath));
    entries.add((id: 'legacy-backup', label: '旧版备份（R2）', path: _paths.backupPath));

    final result = <DebugDbInfo>[];
    for (final entry in entries) {
      final file = File(entry.path);
      final exists = await file.exists();
      final size = exists ? (await file.stat()).size : 0;
      final version = exists ? await _readUserVersion(entry.path) : 0;
      result.add(DebugDbInfo(
        id: entry.id,
        label: entry.label,
        path: entry.path,
        expectedVersion: userDataDbVersion,
        actualVersion: version,
        sizeBytes: size,
        exists: exists,
      ));
    }
    return result;
  }

  @override
  Future<List<DebugTableSummary>> listTables(String dbId) async {
    final db = await _open(dbId);
    try {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      );
      final result = <DebugTableSummary>[];
      for (final row in rows) {
        final name = row['name'] as String;
        final count = await db.rawQuery('SELECT COUNT(*) AS c FROM "$name"');
        result.add(
          DebugTableSummary(name: name, rowCount: _asInt(count.first['c'])),
        );
      }
      return result;
    } finally {
      await db.close();
    }
  }

  @override
  Future<DebugTablePage> loadTable(
    String dbId,
    String tableName, {
    int page = 0,
    int pageSize = 20,
  }) async {
    final db = await _open(dbId);
    try {
      final columns = _readColumns(
        await db.rawQuery('PRAGMA table_info("$tableName")'),
      );
      final indexes = await _readIndexes(db, tableName);
      final count = await db.rawQuery('SELECT COUNT(*) AS c FROM "$tableName"');
      final rows = await db.rawQuery(
        'SELECT * FROM "$tableName" LIMIT $pageSize OFFSET ${page * pageSize}',
      );
      return DebugTablePage(
        name: tableName,
        columns: columns,
        indexes: indexes,
        rows: rows,
        totalCount: _asInt(count.first['c']),
        page: page,
        pageSize: pageSize,
      );
    } finally {
      await db.close();
    }
  }

  /// 按库 id 解析路径并只读打开；库里没有这个文件时明确报错。
  Future<Database> _open(String dbId) async {
    final info = await _infoOf(dbId);
    if (!info.exists) {
      throw StateError('库文件不存在：${info.path}');
    }
    return databaseFactory.openDatabase(
      info.path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
  }

  Future<DebugDbInfo> _infoOf(String dbId) async {
    final all = await listDatabases();
    for (final info in all) {
      if (info.id == dbId) return info;
    }
    throw StateError('未知的库：$dbId');
  }

  Future<int> _readUserVersion(String path) async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      return await readUserVersion(db);
    } finally {
      await db.close();
    }
  }

  static int _asInt(Object? value) => value is int ? value : int.parse('$value');

  static List<DebugColumn> _readColumns(List<Map<String, Object?>> rows) {
    return rows
        .map((r) => DebugColumn(
              name: r['name'] as String,
              type: (r['type'] as String?) ?? '',
              notNull: _asInt(r['notnull']) != 0,
              isPrimaryKey: _asInt(r['pk']) != 0,
              defaultValue: r['dflt_value'],
            ))
        .toList();
  }

  Future<List<DebugIndex>> _readIndexes(Database db, String table) async {
    final list = await db.rawQuery('PRAGMA index_list("$table")');
    final result = <DebugIndex>[];
    for (final idx in list) {
      final name = idx['name'] as String;
      final info = await db.rawQuery('PRAGMA index_info("$name")');
      final cols = info
          .map((r) => r['name'] as String?)
          .whereType<String>()
          .toList();
      result.add(
        DebugIndex(name: name, unique: _asInt(idx['unique']) != 0, columns: cols),
      );
    }
    return result;
  }
}
