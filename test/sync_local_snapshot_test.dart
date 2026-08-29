import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 本地同步快照以 uuid 为唯一身份键（与云端 manifest / 共基同一口径）。
///
/// 夹具库就是生产 schema 的五张业务表：父表 `books` / `mods` 主键即
/// `uuid TEXT`（不再有 int id），子表 `rounds` / `world_book_entries` /
/// `book_mods` 保留自身 int id，并以 `book_uuid` / `mod_uuid` 引用父表。
void main() {
  late Database db;

  Future<Database> buildDb() async {
    final database = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      singleInstance: false,
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE books(
            uuid TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            category TEXT,
            base_setting TEXT,
            writing_style TEXT,
            global_pre_prompt TEXT,
            global_post_prompt TEXT,
            history_rounds INTEGER DEFAULT 1,
            role_hierarchy TEXT,
            role_hierarchy_detail TEXT,
            created_at INTEGER,
            settings_updated_at INTEGER,
            rounds_updated_at INTEGER,
            deleted_at INTEGER
          )
        ''');
        await d.execute('''
          CREATE TABLE rounds(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_uuid TEXT NOT NULL,
            round_index INTEGER NOT NULL,
            user_input TEXT,
            ai_narrative TEXT,
            world_state TEXT,
            character_state TEXT,
            memory_summary TEXT,
            current_time TEXT,
            recommended_action TEXT,
            tokens_in INTEGER,
            tokens_out INTEGER,
            model_name TEXT,
            created_at TEXT,
            user_images TEXT,
            ai_images TEXT,
            FOREIGN KEY (book_uuid) REFERENCES books(uuid) ON DELETE CASCADE
          )
        ''');
        await d.execute('''
          CREATE TABLE world_book_entries(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_uuid TEXT NOT NULL,
            keyword TEXT NOT NULL,
            content TEXT NOT NULL,
            is_active INTEGER DEFAULT 1,
            created_at TEXT,
            FOREIGN KEY (book_uuid) REFERENCES books(uuid) ON DELETE CASCADE
          )
        ''');
        await d.execute('''
          CREATE TABLE mods(
            uuid TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            pre_prompt TEXT,
            post_prompt TEXT,
            system_prompt TEXT,
            world_book TEXT,
            is_preset INTEGER NOT NULL DEFAULT 0,
            preset_key TEXT,
            created_at INTEGER,
            updated_at INTEGER,
            deleted_at INTEGER
          )
        ''');
        await d.execute('''
          CREATE TABLE book_mods(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_uuid TEXT NOT NULL,
            preset_key TEXT,
            mod_uuid TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0,
            is_enabled INTEGER NOT NULL DEFAULT 1,
            FOREIGN KEY (book_uuid) REFERENCES books(uuid) ON DELETE CASCADE
          )
        ''');
      },
    );
    return database;
  }

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await buildDb();
  });

  tearDown(() async {
    await db.close();
  });

  test('按 uuid 键出书与部件、Mod', () async {
    await db.insert('books', {
      'uuid': 'u-book-1',
      'title': '测试书',
      'settings_updated_at': 111,
      'rounds_updated_at': 222,
    });
    await db.insert('rounds', {
      'book_uuid': 'u-book-1',
      'round_index': 1,
      'user_input': 'x',
      'ai_narrative': 'y',
    });
    await db.insert('world_book_entries',
        {'book_uuid': 'u-book-1', 'keyword': 'k', 'content': 'c'});
    await db.insert('mods', {'uuid': 'u-mod-1', 'name': '风格'});
    await db.insert('book_mods', {
      'book_uuid': 'u-book-1',
      'mod_uuid': 'u-mod-1',
      'sort_order': 0,
      'is_enabled': 1,
    });

    final snap = await SyncLocalSnapshot.build(db);
    expect(snap.books.containsKey('u-book-1'), isTrue);
    expect(snap.books['u-book-1']!.title, '测试书');
    expect(snap.books['u-book-1']!.uuid, 'u-book-1');
    expect(snap.bookMeta['u-book-1']!.settingsUpdatedAt, 111);
    expect(snap.bookMeta['u-book-1']!.roundsUpdatedAt, 222);
    expect(snap.mods.containsKey('u-mod-1'), isTrue);
    expect(snap.mods['u-mod-1']!.name, '风格');
    final parts = snap.books['u-book-1']!.parts;
    expect(parts.settingsFp, isNotEmpty);
    expect(parts.roundsFp, isNotEmpty, reason: '轮次部件含失败条目（rounds+failed）');
    // 世界书 / 书‑Mod 部件按 book_uuid 归入本书，Mod 名称按 mod_uuid 查表。
    expect(parts.worldBookFp, contains('"k"'));
    expect(parts.bookModsFp, contains('风格'));
  });

  test('子表部件按 book_uuid 归组，不串书；空 book_uuid 的孤儿行不入任何部件', () async {
    await db.insert('books', {'uuid': 'u-b1', 'title': '书一'});
    final before = await SyncLocalSnapshot.build(db);
    final base = before.books['u-b1']!.parts;

    // 另一本书写自己的轮次 / 世界书 / Mod —— 不应改变 u-b1 的任何部件指纹。
    await db.insert('books', {'uuid': 'u-b2', 'title': '书二'});
    await db.insert('rounds',
        {'book_uuid': 'u-b2', 'round_index': 1, 'user_input': '他书', 'ai_narrative': 'y'});
    await db.insert('world_book_entries',
        {'book_uuid': 'u-b2', 'keyword': '他书', 'content': 'c'});
    await db.insert('mods', {'uuid': 'u-m2', 'name': '他书 Mod'});
    await db.insert('book_mods', {
      'book_uuid': 'u-b2',
      'mod_uuid': 'u-m2',
      'sort_order': 0,
      'is_enabled': 1,
    });
    // 孤儿行（无所属书 uuid）：只被跳过，不影响任何一本书。
    await db.insert('rounds',
        {'book_uuid': '', 'round_index': 1, 'user_input': '孤儿', 'ai_narrative': 'y'});

    final after = await SyncLocalSnapshot.build(db);
    expect(after.books.keys, unorderedEquals(['u-b1', 'u-b2']));
    final kept = after.books['u-b1']!.parts;
    expect(kept.roundsFp, base.roundsFp, reason: '轮次按 book_uuid 归组');
    expect(kept.worldBookFp, base.worldBookFp);
    expect(kept.bookModsFp, base.bookModsFp);
    expect(after.books['u-b2']!.parts.roundsFp, isNot(base.roundsFp),
        reason: '两本书的轮次部件各自独立');
    expect(after.books['u-b2']!.parts.bookModsFp, contains('他书'));
  });

  test('软删书标记 deleted=true；软删 Mod 不入快照', () async {
    await db.insert('books', {'uuid': 'u-del', 'title': '已删书', 'deleted_at': 999});
    await db.insert('mods',
        {'uuid': 'u-mod-del', 'name': '删掉的 Mod', 'deleted_at': 999});

    final snap = await SyncLocalSnapshot.build(db);
    final record = snap.books['u-del']!;
    expect(record.title, '已删书');
    expect(record.parts.deleted, isTrue);
    expect(snap.mods.containsKey('u-mod-del'), isFalse,
        reason: '软删 Mod 不参与同步');
  });

  test('同名不同 uuid 是两本独立的书；uuid 为空的行不进快照', () async {
    // 跨设备 / 跨书允许同名：uuid 是唯一身份，快照不做任何标题归并。
    await db.insert('books', {'uuid': 'u-dup-a', 'title': '同名书'});
    await db.insert('books', {'uuid': 'u-dup-b', 'title': '同名书'});
    // 未落库草稿 / 脏行（uuid 为空）没有身份可用，只能被跳过。
    await db.insert('books', {'uuid': '', 'title': '无身份书'});

    final snap = await SyncLocalSnapshot.build(db);
    expect(snap.books.keys, unorderedEquals(['u-dup-a', 'u-dup-b']));
    expect(snap.books['u-dup-a']!.parts.settingsFp,
        snap.books['u-dup-b']!.parts.settingsFp,
        reason: '同名同设置 → 部件指纹相同，但仍是两个独立实体');
  });
}
