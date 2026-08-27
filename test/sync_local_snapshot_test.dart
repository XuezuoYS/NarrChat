import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `SyncLocalSnapshot` 测试：从内存库读出部件级指纹 + 软删标记（uuid 键，
/// 设置类为 5 个子部件）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Database> buildDb() async {
    final db = await openDatabase(inMemoryDatabasePath, singleInstance: false);
    await db.execute('''
      CREATE TABLE books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT NOT NULL DEFAULT '',
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
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE world_book_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        keyword TEXT NOT NULL,
        content TEXT DEFAULT '',
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at DATETIME,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE mods (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT NOT NULL DEFAULT '',
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
        book_id INTEGER NOT NULL,
        preset_key TEXT,
        mod_id INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_enabled INTEGER NOT NULL DEFAULT 1
      )
    ''');
    return db;
  }

  test('按 uuid 读出书/轮次/世界书/书-Mod 的部件指纹与软删标记（5 个子部件）', () async {
    final db = await buildDb();
    addTearDown(db.close);

    final bookId = await db.insert('books', {
      'uuid': 'u-book-1',
      'title': '书A',
      'category': '玄幻',
      'global_post_prompt': '请继续',
      'settings_updated_at': 1000,
      'rounds_updated_at': 2000,
    });
    await db.insert('rounds', {
      'book_id': bookId,
      'round_index': 1,
      'user_input': '开始',
      'ai_narrative': '正文',
    });
    await db.insert('world_book_entries', {
      'book_id': bookId,
      'keyword': '主角',
      'content': '设定',
    });
    final modId = await db.insert('mods', {'uuid': 'u-mod-1', 'name': '风格'});
    await db.insert('book_mods', {
      'book_id': bookId,
      'mod_id': modId,
      'sort_order': 0,
      'is_enabled': 1,
    });

    final snap = await SyncLocalSnapshot.build(db);
    final record = snap.books['u-book-1'];
    expect(record, isNotNull);
    expect(record!.title, '书A');
    expect(record.parts.deleted, isFalse);
    expect(record.parts.settingsFp, isNotEmpty);
    expect(record.parts.roundsFp, isNotEmpty, reason: '轮次部件含失败条目（rounds+failed）');
    expect(record.parts.worldBookFp, isNotEmpty);
    expect(record.parts.bookModsFp, isNotEmpty);
    expect(snap.bookMeta['u-book-1']!.settingsUpdatedAt, 1000);
    expect(snap.bookMeta['u-book-1']!.roundsUpdatedAt, 2000);
    final mod = snap.mods['u-mod-1'];
    expect(mod, isNotNull);
    expect(mod!.name, '风格');
    expect(mod.fingerprint, isNotEmpty);
  });

  test('软删书标记 deleted=true，并不再计入 mods；uuid 缺失行用 legacy 键兜底', () async {
    final db = await buildDb();
    addTearDown(db.close);
    await db.insert('books', {
      'uuid': 'u-del',
      'title': '已删书',
      'deleted_at': 9999,
    });
    await db.insert('mods', {'uuid': 'u-m1', 'name': 'm1'});
    await db.insert('mods', {'uuid': '', 'name': 'm2', 'deleted_at': 8888});

    final snap = await SyncLocalSnapshot.build(db);
    expect(snap.books['u-del']!.parts.deleted, isTrue);
    expect(snap.mods.keys, contains('u-m1'));
    expect(snap.mods.keys, isNot(contains('u-m2'))); // m2 已软删，不进入 mods
  });

  test('uuid 为空的历史行（迁移前）→ 以 legacy 键进入快照（自愈路径）', () async {
    final db = await buildDb();
    addTearDown(db.close);
    final bookId = await db.insert('books', {'title': '旧行'});

    final snap = await SyncLocalSnapshot.build(db);
    final snapRecord = snap.books['legacy-book:$bookId'];
    expect(snapRecord, isNotNull);
    expect(snapRecord!.title, '旧行');
  });
}
