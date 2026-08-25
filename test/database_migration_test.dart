import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据库迁移回归测试（sqflite_common_ffi + 临时文件库，不触碰真实库）。
///
/// 背景：1.3.1 将 DB 版本升至 9（rounds 新增 `model_name`）。若用户先运行过
/// 1.3.1 再运行 1.3.0（v8），sqflite 降级仅把 `user_version` 写回 8、
/// 但**不会移除**已存在的 `model_name` 列 → 1.3.1 再次启动时迁移执行
/// `ALTER TABLE rounds ADD COLUMN model_name` 报 `duplicate column name`，
/// 整个库无法打开且每次启动都失败。
/// 修复：所有 ADD COLUMN 迁移改为先查 `PRAGMA table_info`，列已存在则跳过。
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

  test('版本回退遗留（user_version=8 但 model_name 已存在）迁移成功且数据保留', () async {
    final path = _newDbPath();

    // 1. 创建 v8 库并写入数据。
    final db8 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 8, onCreate: _createV8Schema),
    );
    await db8.insert('books', {
      'title': '书A',
      'category': '玄幻',
      'base_setting': '基础设定',
      'writing_requirements': '文笔要求',
      'writing_style': '参考段落',
      'history_rounds': 1,
      'role_hierarchy': '主角 > 女主角',
      'role_hierarchy_detail': '[]',
    });
    await db8.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '你好',
      'ai_narrative': '正文',
      'tokens_in': 10,
      'tokens_out': 20,
      'created_at': DateTime(2026, 8, 16).toIso8601String(),
    });

    // 2. 模拟「1.3.0 打开过 v9 库被降级」的遗留状态：列已存在、user_version 仍为 8。
    await db8.execute("ALTER TABLE rounds ADD COLUMN model_name TEXT DEFAULT ''");
    await db8.close();

    // 3. 以当前版本重开（模拟 1.3.1 修复后首次启动，迁移不再抛 duplicate column）。
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    expect(await db.rawQuery('SELECT COUNT(*) AS c FROM books'), [
      {'c': 1},
    ]);
    expect(await db.rawQuery('SELECT COUNT(*) AS c FROM rounds'), [
      {'c': 1},
    ]);
    final cols = await db.rawQuery('PRAGMA table_info(rounds)');
    expect(cols.map((c) => c['name']), contains('model_name'));
    await db.close();
  });

  test('正常 v8→v9 迁移新增 model_name 列且数据保留', () async {
    final path = _newDbPath();

    final db8 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 8, onCreate: _createV8Schema),
    );
    await db8.insert('books', {
      'title': '书B',
      'category': '都市',
      'base_setting': '设定',
      'writing_requirements': '',
      'writing_style': '',
      'history_rounds': 1,
      'role_hierarchy': '',
      'role_hierarchy_detail': '',
    });
    await db8.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '继续',
      'ai_narrative': '后续正文',
      'tokens_in': 1,
      'tokens_out': 2,
    });
    await db8.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    final cols = await db.rawQuery('PRAGMA table_info(rounds)');
    expect(cols.map((c) => c['name']), contains('model_name'));
    final round = (await db.rawQuery('SELECT * FROM rounds')).first;
    expect(round['user_input'], '继续');
    expect(round['ai_narrative'], '后续正文');
    await db.close();
  });

  test('v9→v10 迁移新增 user_images / ai_images 列且数据保留', () async {
    final path = _newDbPath();

    final db9 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 8, onCreate: _createV8Schema),
    );
    // 模拟 v9：先补上 model_name 列（前一版本迁移），此时无 user_images/ai_images。
    await db9.execute("ALTER TABLE rounds ADD COLUMN model_name TEXT DEFAULT ''");
    await db9.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '看图',
      'ai_narrative': '正文',
      'tokens_in': 1,
      'tokens_out': 2,
      'created_at': DateTime(2026, 8, 16).toIso8601String(),
    });
    await db9.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    final cols = await db.rawQuery('PRAGMA table_info(rounds)');
    expect(cols.map((c) => c['name']), contains('user_images'));
    expect(cols.map((c) => c['name']), contains('ai_images'));
    final round = (await db.rawQuery('SELECT * FROM rounds')).first;
    expect(round['user_input'], '看图');
    expect(round['user_images'], '[]');
    expect(round['ai_images'], '[]');
    await db.close();
  });

  test('v10→v11 迁移新增 failed_user_images 列且失败条目数据保留', () async {
    final path = _newDbPath();

    final db10 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 10, onCreate: _createV10Schema),
    );
    await db10.insert('books', {
      'title': '书E',
      'category': '玄幻',
      'base_setting': '设定',
      'failed_user_input': '带图失败',
      'failed_error_message': '模拟失败',
    });
    await db10.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    final bookCols = (await db.rawQuery('PRAGMA table_info(books)'))
        .map((c) => c['name'])
        .toList();
    expect(bookCols, contains('failed_user_images'));
    final book = (await db.rawQuery('SELECT * FROM books')).first;
    expect(book['failed_user_input'], '带图失败');
    expect(book['failed_error_message'], '模拟失败');
    // 新列默认空图片数组（历史失败条目不丢数据）。
    expect(book['failed_user_images'], '[]');
    await db.close();
  });

  test('v5→当前版本全链路迁移（含 rounds 重建）成功且数据保留', () async {
    final path = _newDbPath();

    final db5 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 5, onCreate: _createV5Schema),
    );
    await db5.insert('books', {
      'title': '书C',
      'category': '仙侠',
      'base_setting': '设定',
      'writing_requirements': '要求',
      'writing_style': '',
      'history_rounds': 1,
      'role_hierarchy': '主角',
      'role_hierarchy_detail': '[]',
    });
    await db5.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '开局',
      'ai_narrative': '正文内容',
      'tokens_in': 3,
      'tokens_out': 4,
      'created_at': DateTime(2026, 8, 1).toIso8601String(),
    });
    await db5.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);

    // rounds：重建后含 model_name，且不含历史中间版本（v6/v7）的失败列。
    final roundCols = (await db.rawQuery('PRAGMA table_info(rounds)'))
        .map((c) => c['name'])
        .toList();
    expect(roundCols, contains('model_name'));
    expect(roundCols, isNot(contains('is_truncated')));
    expect(roundCols, isNot(contains('error_message')));

    // books：补齐 v3/v4/v8 列。
    final bookCols = (await db.rawQuery('PRAGMA table_info(books)'))
        .map((c) => c['name'])
        .toList();
    expect(bookCols, containsAll(['role_hierarchy_detail', 'writing_requirements', 'failed_user_input', 'failed_error_message']));

    // 数据保留。
    final round = (await db.rawQuery('SELECT * FROM rounds')).first;
    expect(round['user_input'], '开局');
    expect(round['ai_narrative'], '正文内容');
    expect(await db.rawQuery('SELECT COUNT(*) AS c FROM books'), [
      {'c': 1},
    ]);
    await db.close();
  });

  test('修复后迁移幂等：同一列重复出现在后续版本也不会重复 ADD', () async {
    // 模拟「v9 建表但 user_version 被降回 5」的极端遗留：migrate(5, current)
    // 中途 v8 重建会丢弃 model_name，v9 再补回，整个过程不应报 duplicate column。
    final path = _newDbPath();
    final db5 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 5, onCreate: _createV5Schema),
    );
    await db5.insert('books', {'title': '书D'});
    // 预置一个已存在的 model_name 列（模拟降级遗留）。
    await db5.execute("ALTER TABLE rounds ADD COLUMN model_name TEXT DEFAULT ''");
    await db5.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    final roundCols = (await db.rawQuery('PRAGMA table_info(rounds)'))
        .map((c) => c['name'])
        .toList();
    expect(roundCols, contains('model_name'));
    await db.close();
  });
}

final List<Directory> _tempDirs = [];

String _newDbPath() {
  final dir = Directory.systemTemp.createTempSync('db_migration_test_');
  _tempDirs.add(dir);
  return p.join(dir.path, 'narrchat.db');
}

/// 历史 v10 schema（books 含 failed_user_input/error；rounds 含
/// model_name/user_images/ai_images，尚无 failed_user_images）。
Future<void> _createV10Schema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      category TEXT DEFAULT '',
      base_setting TEXT DEFAULT '',
      writing_requirements TEXT DEFAULT '',
      writing_style TEXT DEFAULT '',
      global_pre_prompt TEXT DEFAULT '',
      global_post_prompt TEXT DEFAULT '',
      history_rounds INTEGER NOT NULL DEFAULT 1,
      role_hierarchy TEXT DEFAULT '',
      role_hierarchy_detail TEXT DEFAULT '',
      failed_user_input TEXT DEFAULT '',
      failed_error_message TEXT DEFAULT ''
    )
  ''');
  await db.execute('''
    CREATE TABLE rounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      round_index INTEGER NOT NULL,
      user_input TEXT DEFAULT '',
      ai_narrative TEXT DEFAULT '',
      world_state TEXT DEFAULT '',
      character_state TEXT DEFAULT '',
      memory_summary TEXT DEFAULT '',
      current_time TEXT DEFAULT '',
      recommended_action TEXT DEFAULT '',
      tokens_in INTEGER NOT NULL DEFAULT 0,
      tokens_out INTEGER NOT NULL DEFAULT 0,
      model_name TEXT DEFAULT '',
      user_images TEXT NOT NULL DEFAULT '[]',
      ai_images TEXT NOT NULL DEFAULT '[]',
      created_at DATETIME,
      FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_rounds_book_index ON rounds (book_id, round_index)',
  );
  await _createCommonTables(db);
}

/// 历史 v8 schema（books 含 v3/v4/v8 列；rounds 不含 model_name）。
Future<void> _createV8Schema(Database db, int version) async {  await db.execute('''
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      category TEXT DEFAULT '',
      base_setting TEXT DEFAULT '',
      writing_requirements TEXT DEFAULT '',
      writing_style TEXT DEFAULT '',
      global_pre_prompt TEXT DEFAULT '',
      global_post_prompt TEXT DEFAULT '',
      history_rounds INTEGER NOT NULL DEFAULT 1,
      role_hierarchy TEXT DEFAULT '',
      role_hierarchy_detail TEXT DEFAULT '',
      failed_user_input TEXT DEFAULT '',
      failed_error_message TEXT DEFAULT ''
    )
  ''');
  await db.execute('''
    CREATE TABLE rounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      round_index INTEGER NOT NULL,
      user_input TEXT DEFAULT '',
      ai_narrative TEXT DEFAULT '',
      world_state TEXT DEFAULT '',
      character_state TEXT DEFAULT '',
      memory_summary TEXT DEFAULT '',
      current_time TEXT DEFAULT '',
      recommended_action TEXT DEFAULT '',
      tokens_in INTEGER NOT NULL DEFAULT 0,
      tokens_out INTEGER NOT NULL DEFAULT 0,
      created_at DATETIME,
      FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
    )
  ''');
  await db.execute('CREATE INDEX idx_rounds_book_index ON rounds (book_id, round_index)');
  await _createCommonTables(db);
}

/// 历史 v5 schema（books 尚无 failed_* 列；含 world_book/mods/book_mods）。
Future<void> _createV5Schema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      category TEXT DEFAULT '',
      base_setting TEXT DEFAULT '',
      writing_requirements TEXT DEFAULT '',
      writing_style TEXT DEFAULT '',
      global_pre_prompt TEXT DEFAULT '',
      global_post_prompt TEXT DEFAULT '',
      history_rounds INTEGER NOT NULL DEFAULT 1,
      role_hierarchy TEXT DEFAULT '',
      role_hierarchy_detail TEXT DEFAULT ''
    )
  ''');
  await db.execute('''
    CREATE TABLE rounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      round_index INTEGER NOT NULL,
      user_input TEXT DEFAULT '',
      ai_narrative TEXT DEFAULT '',
      world_state TEXT DEFAULT '',
      character_state TEXT DEFAULT '',
      memory_summary TEXT DEFAULT '',
      current_time TEXT DEFAULT '',
      recommended_action TEXT DEFAULT '',
      tokens_in INTEGER NOT NULL DEFAULT 0,
      tokens_out INTEGER NOT NULL DEFAULT 0,
      created_at DATETIME,
      FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
    )
  ''');
  await db.execute('CREATE INDEX idx_rounds_book_index ON rounds (book_id, round_index)');
  await _createCommonTables(db);
}

/// v2 引入的世界书 + v5 引入的 mods / book_mods 表（迁移全链路会用到）。
Future<void> _createCommonTables(Database db) async {
  await db.execute('''
    CREATE TABLE world_book_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      keyword TEXT NOT NULL,
      content TEXT DEFAULT '',
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at DATETIME
    )
  ''');
  await db.execute('''
    CREATE TABLE mods (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      description TEXT DEFAULT '',
      pre_prompt TEXT DEFAULT '',
      post_prompt TEXT DEFAULT '',
      system_prompt TEXT DEFAULT '',
      world_book TEXT DEFAULT '',
      created_at DATETIME,
      updated_at DATETIME
    )
  ''');
  await db.execute('''
    CREATE TABLE book_mods (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      preset_key TEXT,
      mod_id INTEGER,
      sort_order INTEGER NOT NULL DEFAULT 0,
      is_enabled INTEGER NOT NULL DEFAULT 1
    )
  ''');
}
