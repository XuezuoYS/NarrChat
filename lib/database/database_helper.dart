import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据库访问入口（单例）。
///
/// - Android/iOS：使用 sqflite 原生插件；
/// - Windows/Linux/macOS：自动切换到 sqflite_common_ffi（基于 sqlite3 的 FFI 实现）。
class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();

  static const int _dbVersion = 4;

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
    final documentsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(documentsDir.path, 'narrchat.db');
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
      },
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
        role_hierarchy_detail TEXT DEFAULT ''
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

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
