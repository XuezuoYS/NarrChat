import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/app_paths.dart';

/// 数据库访问入口（单例）。
///
/// - Android/iOS：使用 sqflite 原生插件；
/// - Windows/Linux/macOS：自动切换到 sqflite_common_ffi（基于 sqlite3 的 FFI 实现）。
/// - 数据库位于 `<文档目录>/NarrChat/user_data/narrchat.db`（用户数据，可云同步）。
class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();

  static const int _dbVersion = 8;

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _open();
    return _database!;
  }

  Future<Database> _open() async {
    // 桌面端需要 FFI 数据库工厂。
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dbPath = await AppPaths.userDatabasePath();
    return openDatabase(
      dbPath,
      version: _dbVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createBooksTable(db);
        await _createRoundsTable(db);
        await _createWorldBookTable(db);
        await _createModsTable(db);
        await _createBookModsTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createWorldBookTable(db);
        }
        if (oldVersion < 3) {
          // 新增角色类别详细描述格式列。
          await db.execute(
            "ALTER TABLE books ADD COLUMN role_hierarchy_detail TEXT DEFAULT ''",
          );
        }
        if (oldVersion < 4) {
          // 新增文笔要求描述列（区别于文笔参考段落 writing_style）。
          await db.execute(
            "ALTER TABLE books ADD COLUMN writing_requirements TEXT DEFAULT ''",
          );
        }
        if (oldVersion < 5) {
          // Mod 功能：mods（用户自定义 Mod）+ book_mods（书籍启用与顺序）。
          await _createModsTable(db);
          await _createBookModsTable(db);
        }
        if (oldVersion < 6) {
          // 历史中间版本曾在 rounds 表加入失败列（未发布），此处先补列以便后续重建。
          await db.execute(
            'ALTER TABLE rounds ADD COLUMN is_truncated INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 7) {
          await db.execute(
            "ALTER TABLE rounds ADD COLUMN error_message TEXT DEFAULT ''",
          );
        }
        if (oldVersion < 8) {
          // 失败处理重构：失败条目从 rounds 轮次行迁移为 books 上的独立条目。
          // 1) 重建 rounds 表，移除 v6/v7 引入的失败列（保持 schema 干净）；
          // 2) books 表新增失败条目两列。
          await _rebuildRoundsTable(db);
          await db.execute(
            "ALTER TABLE books ADD COLUMN failed_user_input TEXT DEFAULT ''",
          );
          await db.execute(
            "ALTER TABLE books ADD COLUMN failed_error_message TEXT DEFAULT ''",
          );
        }
      },
    );
  }

  /// 重建 `rounds` 表：移除历史中间版本（v6/v7）加入的失败列，
  /// 保留全部数据、主键、外键与索引（无其他表引用 rounds，FK 安全）。
  Future<void> _rebuildRoundsTable(Database db) async {
    await db.execute('''
      CREATE TABLE rounds_new (
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
    await db.execute('''
      INSERT INTO rounds_new (
        id, book_id, round_index, user_input, ai_narrative, world_state,
        character_state, memory_summary, current_time, recommended_action,
        tokens_in, tokens_out, created_at
      )
      SELECT
        id, book_id, round_index, user_input, ai_narrative, world_state,
        character_state, memory_summary, current_time, recommended_action,
        tokens_in, tokens_out, created_at
      FROM rounds
    ''');
    await db.execute('DROP TABLE rounds');
    await db.execute('ALTER TABLE rounds_new RENAME TO rounds');
    await db.execute(
      'CREATE INDEX idx_rounds_book_index ON rounds (book_id, round_index)',
    );
  }

  Future<void> _createBooksTable(Database db) async {
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
  }

  Future<void> _createRoundsTable(Database db) async {
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
    await db.execute(
      'CREATE INDEX idx_rounds_book_index ON rounds (book_id, round_index)',
    );
  }

  Future<void> _createWorldBookTable(Database db) async {
    await db.execute('''
      CREATE TABLE world_book_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        keyword TEXT NOT NULL,
        content TEXT DEFAULT '',
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at DATETIME,
        FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_world_book_book_id ON world_book_entries (book_id)',
    );
  }

  Future<void> _createModsTable(Database db) async {
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
  }

  Future<void> _createBookModsTable(Database db) async {
    await db.execute('''
      CREATE TABLE book_mods (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        preset_key TEXT,
        mod_id INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_enabled INTEGER NOT NULL DEFAULT 1,
        FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE,
        FOREIGN KEY (mod_id) REFERENCES mods (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_book_mods_book_id ON book_mods (book_id)',
    );
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
