import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';

/// 数据库中一列的结构信息。
class DebugColumn {
  final String name;
  final String type;
  final bool notNull;
  final bool isPrimaryKey;
  final Object? defaultValue;

  const DebugColumn({
    required this.name,
    required this.type,
    required this.notNull,
    required this.isPrimaryKey,
    this.defaultValue,
  });
}

/// 数据库中一个索引的结构信息。
class DebugIndex {
  final String name;
  final bool unique;
  final List<String> columns;

  const DebugIndex({required this.name, required this.unique, required this.columns});
}

/// 数据库表列表中的一项（表名 + 总行数）。
class DebugTableSummary {
  final String name;
  final int rowCount;

  const DebugTableSummary({required this.name, required this.rowCount});
}

/// 一张表的某一页数据（结构 + 本页内容），供调试查看。
class DebugTablePage {
  final String name;
  final List<DebugColumn> columns;
  final List<DebugIndex> indexes;

  /// 本页的行数据。
  final List<Map<String, Object?>> rows;

  /// 该表总行数（非本页行数）。
  final int totalCount;

  /// 当前页（0 基）。
  final int page;

  /// 每页行数。
  final int pageSize;

  const DebugTablePage({
    required this.name,
    required this.columns,
    required this.indexes,
    required this.rows,
    required this.totalCount,
    required this.page,
    required this.pageSize,
  });
}

/// 数据库版本信息（调试查看用）。
class DebugDbVersion {
  /// 应用代码期望的 schema 版本（[DatabaseHelper.currentDbVersion]）。
  final int expectedVersion;

  /// 数据库文件实际的 `user_version`（迁移后 / 迁移失败 / 版本回退时可与
  /// [expectedVersion] 不一致，即本调试页要暴露的差异）。
  final int actualVersion;

  const DebugDbVersion({required this.expectedVersion, required this.actualVersion});
}

/// 调试数据库访问抽象（可注入替身，避免测试触碰真实库）。
abstract class DebugDatabaseService {
  /// 当前数据库版本（代码期望 schema 版本 + 库文件实际 version）。
  Future<DebugDbVersion> readVersion();

  /// 列出全部业务表（排除 `sqlite_*` 系统表）及各自总行数。
  Future<List<DebugTableSummary>> listTables();

  /// 读取 [tableName] 第 [page] 页（每页 [pageSize] 行）的结构与内容。
  Future<DebugTablePage> loadTable(
    String tableName, {
    int page = 0,
    int pageSize = 20,
  });
}

/// 真实实现：基于 [DatabaseHelper] 的 sqlite 库，只读查询。
class SqliteDebugDatabaseService implements DebugDatabaseService {
  SqliteDebugDatabaseService({Future<Database> Function()? dbOpener})
      : _dbOpener = dbOpener ?? (() => DatabaseHelper.instance.database);

  final Future<Database> Function() _dbOpener;

  @override
  Future<DebugDbVersion> readVersion() async {
    final db = await _dbOpener();
    final actual = await db.getVersion();
    return DebugDbVersion(
      expectedVersion: DatabaseHelper.currentDbVersion,
      actualVersion: actual,
    );
  }

  @override
  Future<List<DebugTableSummary>> listTables() async {
    final db = await _dbOpener();
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    final result = <DebugTableSummary>[];
    for (final row in rows) {
      final name = row['name'] as String;
      final count =
          await db.rawQuery('SELECT COUNT(*) AS c FROM "$name"');
      result.add(
        DebugTableSummary(name: name, rowCount: _asInt(count.first['c'])),
      );
    }
    return result;
  }

  @override
  Future<DebugTablePage> loadTable(
    String tableName, {
    int page = 0,
    int pageSize = 20,
  }) async {
    final db = await _dbOpener();
    final columns = _readColumns(
      await db.rawQuery('PRAGMA table_info("$tableName")'),
    );
    final indexes = await _readIndexes(db, tableName);
    final count =
        await db.rawQuery('SELECT COUNT(*) AS c FROM "$tableName"');
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
