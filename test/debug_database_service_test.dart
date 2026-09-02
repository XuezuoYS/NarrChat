import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/services/debug_database_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// [SqliteDebugDatabaseService] 的 SQL/解析回归测试（sqflite_common_ffi + 临时库，
/// 不触碰真实应用数据库）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    for (final dir in _tempDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 忽略清理失败。
      }
    }
    _tempDirs.clear();
  });

  test('listTables 返回业务表及总行数', () async {
    final db = await _openDb();
    await _createBooks(db);
    await db.insert('books', {'title': '书A'});
    await db.insert('books', {'title': '书B'});

    final service = SqliteDebugDatabaseService(dbOpener: () async => db);
    final tables = await service.listTables();
    expect(tables.map((t) => t.name), contains('books'));
    expect(tables.firstWhere((t) => t.name == 'books').rowCount, 2);
    await db.close();
  });

  test('loadTable 返回列结构/索引/本页行与总行数', () async {
    final db = await _openDb();
    await _createBooks(db);
    await _createRounds(db);
    await db.insert('books', {'title': '书A'});
    await db.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '你好',
      'ai_narrative': '正文',
    });

    final service = SqliteDebugDatabaseService(dbOpener: () async => db);
    final page = await service.loadTable('rounds', page: 0, pageSize: 20);
    expect(page.columns.map((c) => c.name), containsAll(['id', 'book_id', 'user_input']));
    expect(page.columns.firstWhere((c) => c.name == 'id').isPrimaryKey, true);
    expect(page.columns.firstWhere((c) => c.name == 'book_id').notNull, true);
    expect(page.indexes.map((i) => i.name), contains('idx_rounds_book_index'));
    expect(page.rows.first['user_input'], '你好');
    expect(page.rows.first['ai_narrative'], '正文');
    expect(page.totalCount, 1);
    expect(page.page, 0);
    expect(page.pageSize, 20);
    await db.close();
  });

  test('按页查询：超过一页的数据分页返回', () async {
    final db = await _openDb();
    await _createBooks(db);
    for (var i = 1; i <= 25; i++) {
      await db.insert('books', {'title': '书$i'});
    }

    final service = SqliteDebugDatabaseService(dbOpener: () async => db);
    final first = await service.loadTable('books', page: 0, pageSize: 20);
    expect(first.rows.length, 20);
    expect(first.totalCount, 25);
    final second = await service.loadTable('books', page: 1, pageSize: 20);
    expect(second.rows.length, 5);
    expect(second.page, 1);
    // 第二页第一行应为第 21 条记录。
    expect(second.rows.first['title'], '书21');
    await db.close();
  });

  test('readVersion 返回代码期望版本与库文件实际 user_version', () async {
    final dir = Directory.systemTemp.createTempSync('debug_db_service_test_');
    _tempDirs.add(dir);
    // 以旧版本号打开全新库：user_version 落为 3，模拟文件版本未到最新。
    final db = await databaseFactoryFfi.openDatabase(
      p.join(dir.path, 'narrchat.db'),
      options: OpenDatabaseOptions(version: 3, onCreate: (db, version) async {}),
    );

    final service = SqliteDebugDatabaseService(dbOpener: () async => db);
    final version = await service.readVersion();
    expect(version.expectedVersion, DatabaseHelper.currentDbVersion);
    expect(version.actualVersion, 3);
    await db.close();
  });
}

final List<Directory> _tempDirs = [];

Future<Database> _openDb() async {
  final dir = Directory.systemTemp.createTempSync('debug_db_service_test_');
  _tempDirs.add(dir);
  return databaseFactoryFfi.openDatabase(p.join(dir.path, 'narrchat.db'));
}

Future<void> _createBooks(Database db) async {
  await db.execute('''
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL
    )
  ''');
}

Future<void> _createRounds(Database db) async {
  await db.execute('''
    CREATE TABLE rounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      round_index INTEGER NOT NULL,
      user_input TEXT DEFAULT '',
      ai_narrative TEXT DEFAULT '',
      FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_rounds_book_index ON rounds (book_id, round_index)',
  );
}
