import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 构建与正式库同构（v16：uuid 即身份）的内存数据库，供合并规划 / 决策测试复用。
///
/// v16 起 books / mods 两张表**没有 id 列**：`uuid TEXT PRIMARY KEY` 就是唯一身份；
/// rounds / world_book_entries / book_mods 仍保留自己的 int 自增 id（本地行号，
/// 不参与云同步），但一律改以 `book_uuid` / `mod_uuid` 引用父书的 uuid。
///
/// 涵盖 `database_merge_service.dart` 的 `buildPlan` / `applyPlan` 会读写的全部表与列
/// （books 含失败条目列、rounds 含 model_name/user_images/ai_images）。
Future<Database> createMergeDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = await openDatabase(
    inMemoryDatabasePath,
    singleInstance: false,
  );
  await _createSchema(db);
  return db;
}

/// 创建与正式库同构的临时文件备份库（写入一本 uuid=[uuid] / 书名 [title]
/// 的书后关闭），返回文件路径。
///
/// 供「本地数据库导入」测试使用：模拟用户选择了一个 `.db` 备份文件。
/// 调用方负责删除该文件的父目录（位于系统临时目录）。
Future<String> createMergeFileDb({
  String title = '导入书',
  String uuid = 'file-import-book',
}) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = await Directory.systemTemp.createTemp('narrchat_import_');
  final path = p.join(dir.path, 'backup.db');
  final db = await databaseFactoryFfi.openDatabase(path);
  await _createSchema(db);
  await db.insert('books', {'uuid': uuid, 'title': title});
  await db.close();
  return path;
}

Future<void> _createSchema(Database db) async {
  await db.execute('''
    CREATE TABLE books (
      uuid TEXT PRIMARY KEY,
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
      failed_error_message TEXT DEFAULT '',
      failed_user_images TEXT NOT NULL DEFAULT '[]',
      settings_updated_at INTEGER NOT NULL DEFAULT 0,
      rounds_updated_at INTEGER NOT NULL DEFAULT 0,
      deleted_at INTEGER
    )
  ''');
  await db.execute('''
    CREATE TABLE rounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_uuid TEXT NOT NULL,
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
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE world_book_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_uuid TEXT NOT NULL,
      keyword TEXT NOT NULL,
      content TEXT DEFAULT '',
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at DATETIME,
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE mods (
      uuid TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT DEFAULT '',
      pre_prompt TEXT DEFAULT '',
      post_prompt TEXT DEFAULT '',
      system_prompt TEXT DEFAULT '',
      world_book TEXT DEFAULT '',
      created_at DATETIME,
      updated_at DATETIME,
      deleted_at INTEGER
    )
  ''');
  await db.execute('''
    CREATE TABLE book_mods (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_uuid TEXT NOT NULL,
      preset_key TEXT,
      mod_uuid TEXT,
      sort_order INTEGER NOT NULL DEFAULT 0,
      is_enabled INTEGER NOT NULL DEFAULT 1
    )
  ''');
}
