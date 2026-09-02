import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/app_paths.dart';
import '../utils/uuid_utils.dart';

/// 数据库访问入口（单例）。
///
/// - Android/iOS：使用 sqflite 原生插件；
/// - Windows/Linux/macOS：自动切换到 sqflite_common_ffi（基于 sqlite3 的 FFI 实现）。
/// - 数据库位于 `<文档目录>/NarrChat/user_data/narrchat.db`（用户数据，可云同步）。
class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();

  static const int _dbVersion = 16;

  Database? _database;

  /// 测试用数据库路径覆盖（null 时走真实 [AppPaths.userDatabasePath]）。
  ///
  /// 供 DAO 单元测试指向临时库，避免触碰真实用户数据目录；生产代码不设置。
  @visibleForTesting
  static String? debugDatabasePathOverride;

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
    final dbPath = debugDatabasePathOverride ?? await AppPaths.userDatabasePath();
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
        await _createBookIndexes(db);
        await _createSyncTables(db);
      },
      onUpgrade: migrate,
    );
  }

  /// 当前数据库 schema 版本（迁移测试断言目标版本、调试页展示代码期望版本）。
  static int get currentDbVersion => _dbVersion;

  /// 数据库版本迁移入口（幂等）。
  ///
  /// 由 [openDatabase] 的 `onUpgrade` 调用；独立为静态方法以便测试直接注入
  /// 内存 / 临时库验证各历史版本升级路径。
  ///
  /// 所有 `ADD COLUMN` 迁移均先经 [_addColumnIfMissing] 检查列是否存在，
  /// 避免「版本回退后 schema 已带新列、但 `user_version` 已回退」导致的
  /// `duplicate column name` 使整个库无法打开（1.3.0/1.3.1 回退已实测复现）。
  @visibleForTesting
  static Future<void> migrate(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createLegacyWorldBookTable(db);
    }
    if (oldVersion < 3) {
          // 新增角色类别详细描述格式列。
          await _addColumnIfMissing(
            db,
            'books',
            'role_hierarchy_detail',
            "ALTER TABLE books ADD COLUMN role_hierarchy_detail TEXT DEFAULT ''",
          );
        }
        if (oldVersion < 4) {
          // 新增文笔要求描述列（区别于文笔参考段落 writing_style）。
          await _addColumnIfMissing(
            db,
            'books',
            'writing_requirements',
            "ALTER TABLE books ADD COLUMN writing_requirements TEXT DEFAULT ''",
          );
        }
        if (oldVersion < 5) {
          // Mod 功能：mods（用户自定义 Mod）+ book_mods（书籍启用与顺序）。
          await _createLegacyModsTable(db);
          await _createLegacyBookModsTable(db);
        }
        if (oldVersion < 6) {
          // 历史中间版本曾在 rounds 表加入失败列（未发布），此处先补列以便后续重建。
          await _addColumnIfMissing(
            db,
            'rounds',
            'is_truncated',
            'ALTER TABLE rounds ADD COLUMN is_truncated INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 7) {
          await _addColumnIfMissing(
            db,
            'rounds',
            'error_message',
            "ALTER TABLE rounds ADD COLUMN error_message TEXT DEFAULT ''",
          );
        }
        if (oldVersion < 8) {
          // 失败处理重构：失败条目从 rounds 轮次行迁移为 books 上的独立条目。
          // 1) 重建 rounds 表，移除 v6/v7 引入的失败列（保持 schema 干净）；
          // 2) books 表新增失败条目两列。
          await _rebuildRoundsTable(db);
          await _addColumnIfMissing(
            db,
            'books',
            'failed_user_input',
            "ALTER TABLE books ADD COLUMN failed_user_input TEXT DEFAULT ''",
          );
          await _addColumnIfMissing(
            db,
            'books',
            'failed_error_message',
            "ALTER TABLE books ADD COLUMN failed_error_message TEXT DEFAULT ''",
          );
        }
        if (oldVersion < 9) {
          // 每轮落库模型名（{{model}} 解析值），用于气泡 Token 旁展示。
          await _addColumnIfMissing(
            db,
            'rounds',
            'model_name',
            "ALTER TABLE rounds ADD COLUMN model_name TEXT DEFAULT ''",
          );
        }
        if (oldVersion < 10) {
          // 图片模块：每轮用户消息 / AI 返回附带的图片（相对路径 JSON 数组）。
          await _addColumnIfMissing(
            db,
            'rounds',
            'user_images',
            "ALTER TABLE rounds ADD COLUMN user_images TEXT NOT NULL DEFAULT '[]'",
          );
          await _addColumnIfMissing(
            db,
            'rounds',
            'ai_images',
            "ALTER TABLE rounds ADD COLUMN ai_images TEXT NOT NULL DEFAULT '[]'",
          );
        }
        if (oldVersion < 11) {
          // 失败条目随书持久化其用户消息图片：失败后气泡保留展示并供重新提问复用。
          await _addColumnIfMissing(
            db,
            'books',
            'failed_user_images',
            "ALTER TABLE books ADD COLUMN failed_user_images TEXT NOT NULL DEFAULT '[]'",
          );
        }
        if (oldVersion < 12) {
          // 云同步（三向部件级）：为各实体补充变更时间戳与软删墓碑，
          // 并新增同步状态 / 三向合并共基 / 待推送删除墓碑表。
          await _addColumnIfMissing(
            db,
            'books',
            'settings_updated_at',
            'ALTER TABLE books ADD COLUMN settings_updated_at INTEGER NOT NULL DEFAULT 0',
          );
          await _addColumnIfMissing(
            db,
            'books',
            'rounds_updated_at',
            'ALTER TABLE books ADD COLUMN rounds_updated_at INTEGER NOT NULL DEFAULT 0',
          );
          await _addColumnIfMissing(
            db,
            'books',
            'deleted_at',
            'ALTER TABLE books ADD COLUMN deleted_at INTEGER',
          );
          await _addColumnIfMissing(
            db,
            'rounds',
            'updated_at',
            'ALTER TABLE rounds ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
          );
          await _addColumnIfMissing(
            db,
            'world_book_entries',
            'updated_at',
            'ALTER TABLE world_book_entries ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
          );
          await _addColumnIfMissing(
            db,
            'mods',
            'deleted_at',
            'ALTER TABLE mods ADD COLUMN deleted_at INTEGER',
          );
          await _createSyncTables(db);
        }
        if (oldVersion < 13) {
          // 同步身份层：书籍 / Mod 引入跨设备 UUID（v13，尚未发布即重构）。
          // - 为用户数据补 uuid 列并回填（含软删/墓碑行，墓碑必须保留身份）；
          // - 开发/测试库中已按旧 schema（title/name 主键）创建的同步表重建为 uuid 主键；
          // - 已发布用户（v11 及以下）无同步表，v12 分支会用新 schema 直接创建。
          await _addColumnIfMissing(
            db,
            'books',
            'uuid',
            "ALTER TABLE books ADD COLUMN uuid TEXT NOT NULL DEFAULT ''",
          );
          await _addColumnIfMissing(
            db,
            'mods',
            'uuid',
            "ALTER TABLE mods ADD COLUMN uuid TEXT NOT NULL DEFAULT ''",
          );
          await _backfillUuids(db, 'books');
          await _backfillUuids(db, 'mods');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_books_uuid ON books (uuid)');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_mods_uuid ON mods (uuid)');
          await _rebuildSyncTablesForUuid(db);
        }
        if (oldVersion < 14) {
          // 设置类部件拆分（书籍信息/角色/基础设定/文笔与全局提示词/失败条目）：
          // sync_book_base 增加 4 个子部件列，旧行按 settings_fp 整书回填
          // （新列为空时读取即视为整书单值，行为退化为旧语义直到下次同步重写）。
          for (final col in const [
            ('info_fp', 'settings_fp'),
            ('roles_fp', 'settings_fp'),
            ('base_setting_fp', 'settings_fp'),
            ('prompts_fp', 'settings_fp'),
            ('failed_fp', 'settings_fp'),
          ]) {
            await _addColumnIfMissing(
              db,
              'sync_book_base',
              col.$1,
              "ALTER TABLE sync_book_base ADD COLUMN ${col.$1} TEXT DEFAULT ''",
            );
          }
          await db.execute('''
            UPDATE sync_book_base
            SET info_fp = COALESCE(NULLIF(info_fp, ''), settings_fp),
                roles_fp = COALESCE(NULLIF(roles_fp, ''), settings_fp),
                base_setting_fp = COALESCE(NULLIF(base_setting_fp, ''), settings_fp),
                prompts_fp = COALESCE(NULLIF(prompts_fp, ''), settings_fp),
                failed_fp = COALESCE(NULLIF(failed_fp, ''), settings_fp)
          ''');
        }
        if (oldVersion < 16) {
          // v16 前置清理：图片删除墓碑早已改为文件化（WebDAV
          // `img_tombstones.json` + 本地工作副本，见 img_tombstones.dart），
          // 本系列开发期遗留的 sync_pending_del / sync_image_revived 两张表在
          // 现行 schema 中已不存在（`onCreate` 从不建它们）。清理放在 v16 分支
          // 而非按版本分叉，使「升级到 v16 后库内必无墓碑表」成为无条件不变量。
          await db.execute('DROP TABLE IF EXISTS sync_pending_del');
          await db.execute('DROP TABLE IF EXISTS sync_image_revived');
          // v16：books / mods 去除本地 int 主键，uuid 成为唯一身份（顺序见
          // [_recreateWithUuidIdentity]）。
          await _recreateWithUuidIdentity(db);
        }
  }

  /// v15 → v16：`books` / `mods` 去 int 主键，改由 uuid 承担唯一身份；子表
  /// `rounds` / `world_book_entries` / `book_mods` 的 `book_id` / `mod_id` 改为
  /// `book_uuid` / `mod_uuid`（TEXT，FK → 父表 uuid；子表自身 int 主键保留）。
  ///
  /// **外键陷阱（顺序不可改）**：本库在 `onConfigure` 里开了
  /// `PRAGMA foreign_keys = ON`，而 sqflite 的 `onUpgrade` 在事务内执行，事务内
  /// 无法关闭外键，且 `DROP TABLE` 会先做隐式 DELETE 并触发子表的
  /// `ON DELETE CASCADE`。因此顺序固定为：
  /// 1. 预清洗 uuid（补空 / 去重）—— uuid 即将成为主键，非空且唯一是前提；
  /// 2. 建全部 `*_new` 表：新子表的外键**只能**指向 `books_new` / `mods_new`——
  ///    旧 `books` 的 uuid 列上没有唯一索引，FK 指向它写数据会直接
  ///    `foreign key mismatch`（实测）。`ALTER TABLE ... RENAME` 会把外键引用改写
  ///    为最终表名，迁移测试用 `PRAGMA foreign_key_list` 锁死这一行为；
  /// 3. 拷贝：父表先、子表后；子表 JOIN 旧父表把 int 主键换成父表 uuid，
  ///    父行不存在的孤儿轮次 / 条目随 JOIN 丢弃（新表有 FK，留着写不进去）；
  /// 4. 按「子 → 父」顺序 DROP 旧表；此时 `*_new` 引用的是新表名，旧父表的隐式
  ///    DELETE 级联不到已拷好的数据；
  /// 5. RENAME 全部 `*_new` → 最终名（先父后子，与建表引用方向一致）；
  /// 6. 重建三张索引（索引随旧表 DROP 一并消失）。
  static Future<void> _recreateWithUuidIdentity(Database db) async {
    await _normalizeIdentityUuids(db, 'books');
    await _normalizeIdentityUuids(db, 'mods');

    await _createBooksTable(db, suffix: '_new');
    await _createModsTable(db, suffix: '_new');
    await _createRoundsTable(db, suffix: '_new', booksTable: 'books_new');
    await _createWorldBookTable(db, suffix: '_new', booksTable: 'books_new');
    await _createBookModsTable(
      db,
      suffix: '_new',
      booksTable: 'books_new',
      modsTable: 'mods_new',
    );

    await db.execute('''
      INSERT INTO books_new (
        uuid, title, category, base_setting, writing_requirements,
        writing_style, global_pre_prompt, global_post_prompt, history_rounds,
        role_hierarchy, role_hierarchy_detail, failed_user_input,
        failed_error_message, failed_user_images, settings_updated_at,
        rounds_updated_at, deleted_at
      )
      SELECT
        uuid, title, category, base_setting, writing_requirements,
        writing_style, global_pre_prompt, global_post_prompt, history_rounds,
        role_hierarchy, role_hierarchy_detail, failed_user_input,
        failed_error_message, failed_user_images, settings_updated_at,
        rounds_updated_at, deleted_at
      FROM books
    ''');
    await db.execute('''
      INSERT INTO mods_new (
        uuid, name, description, pre_prompt, post_prompt, system_prompt,
        world_book, created_at, updated_at, deleted_at
      )
      SELECT
        uuid, name, description, pre_prompt, post_prompt, system_prompt,
        world_book, created_at, updated_at, deleted_at
      FROM mods
    ''');
    // 子表保留原自增 id（仅本地行标识，同步从不引用）；书籍身份取父表 uuid。
    await db.execute('''
      INSERT INTO rounds_new (
        id, book_uuid, round_index, user_input, ai_narrative, world_state,
        character_state, memory_summary, current_time, recommended_action,
        tokens_in, tokens_out, model_name, user_images, ai_images, created_at,
        updated_at
      )
      SELECT
        r.id, b.uuid, r.round_index, r.user_input, r.ai_narrative,
        r.world_state, r.character_state, r.memory_summary, r.current_time,
        r.recommended_action, r.tokens_in, r.tokens_out, r.model_name,
        r.user_images, r.ai_images, r.created_at, r.updated_at
      FROM rounds r
      JOIN books b ON b.id = r.book_id
    ''');
    await db.execute('''
      INSERT INTO world_book_entries_new (
        id, book_uuid, keyword, content, is_active, created_at, updated_at
      )
      SELECT
        w.id, b.uuid, w.keyword, w.content, w.is_active, w.created_at,
        w.updated_at
      FROM world_book_entries w
      JOIN books b ON b.id = w.book_id
    ''');
    // LEFT JOIN mods：预置 Mod 行 mod_id 为 NULL，必须保住（INNER JOIN 会丢行）。
    await db.execute('''
      INSERT INTO book_mods_new (
        id, book_uuid, preset_key, mod_uuid, sort_order, is_enabled
      )
      SELECT
        bm.id, b.uuid, bm.preset_key, m.uuid, bm.sort_order, bm.is_enabled
      FROM book_mods bm
      JOIN books b ON b.id = bm.book_id
      LEFT JOIN mods m ON m.id = bm.mod_id
    ''');

    await db.execute('DROP TABLE rounds');
    await db.execute('DROP TABLE world_book_entries');
    await db.execute('DROP TABLE book_mods');
    await db.execute('DROP TABLE books');
    await db.execute('DROP TABLE mods');

    await db.execute('ALTER TABLE books_new RENAME TO books');
    await db.execute('ALTER TABLE mods_new RENAME TO mods');
    await db.execute('ALTER TABLE rounds_new RENAME TO rounds');
    await db.execute(
      'ALTER TABLE world_book_entries_new RENAME TO world_book_entries',
    );
    await db.execute('ALTER TABLE book_mods_new RENAME TO book_mods');

    await _createBookIndexes(db);
  }

  /// v16 前置清洗：把 [table]（旧 int 主键形态）的 uuid 规整为「非空且唯一」。
  ///
  /// - 空 uuid（v13 之前的遗留行）→ 分配新 v4；
  /// - 重复 uuid → 保留 `MIN(id)` 那行的原值，其余行重新分配 v4；
  /// - 新生成的值仍可能撞上既有 uuid，故 while 直到未出现过才收。
  ///
  /// 只在 v15 → v16 分支内使用，跑完即弃：不留任何 uuid ↔ int 映射。
  static Future<void> _normalizeIdentityUuids(
    Database db,
    String table,
  ) async {
    final rows = await db.query(
      table,
      columns: ['id', 'uuid'],
      orderBy: 'id ASC',
    );
    final taken = <String>{};
    for (final row in rows) {
      final id = row['id'];
      if (id == null) continue;
      final raw = (row['uuid'] as String? ?? '').trim();
      if (raw.isNotEmpty && !taken.contains(raw)) {
        taken.add(raw);
        continue;
      }
      var uuid = UuidUtils.generateUuidV4();
      while (taken.contains(uuid)) {
        uuid = UuidUtils.generateUuidV4();
      }
      debugPrint(
        '[db][v16] $table id=$id 的 uuid '
        '${raw.isEmpty ? '为空' : '重复（$raw）'} → 重新分配为 $uuid',
      );
      await db.update(table, {'uuid': uuid}, where: 'id = ?', whereArgs: [id]);
      taken.add(uuid);
    }
  }


  /// 判断 [table] 是否已包含 [column] 列。
  ///
  /// 迁移前先查询 `PRAGMA table_info` 再决定是否执行 ALTER，避免「版本回退后
  /// schema 仍带新列、但 `user_version` 已回退」导致的 `duplicate column name`
  /// 使整个数据库无法打开（1.3.0/1.3.1 回退场景已实测复现）。
  static Future<bool> _columnExists(
    Database db,
    String table,
    String column,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.any((row) => row['name'] == column);
  }

  /// 仅当 [column] 不存在时才执行 [ddl]（ADD COLUMN 迁移的幂等保护）。
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String ddl,
  ) async {
    if (await _columnExists(db, table, column)) return;
    await db.execute(ddl);
  }

  /// 为 [table] 中 uuid 为空的行回填 UUID v4（含软删/墓碑行）。
  static Future<void> _backfillUuids(Database db, String table) async {
    final rows = await db.query(
      table,
      columns: ['id', 'uuid'],
      where: "uuid IS NULL OR uuid = ''",
    );
    for (final r in rows) {
      final id = r['id'];
      if (id == null) continue;
      await db.update(
        table,
        {'uuid': UuidUtils.generateUuidV4()},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  /// 把仅存在于未发布开发/测试库中的旧同步表（title/name 主键）重建为 uuid 主键。
  ///
  /// 已发布版本（v11 及以下）没有同步表，无需处理；v12 开发库按主键列名检测，
  /// 命中旧 schema 时 DROP 后交由 [_createSyncTables] 重建（同步表仅存合并元数据，
  /// 非用户资产，重建无损）。
  static Future<void> _rebuildSyncTablesForUuid(Database db) async {
    for (final table in const ['sync_book_base', 'sync_mod_base']) {
      final rows = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table],
      );
      if (rows.isEmpty) continue;
      final sql = rows.first['sql'] as String? ?? '';
      if (!sql.contains('uuid TEXT PRIMARY KEY')) {
        await db.execute('DROP TABLE IF EXISTS $table');
      }
    }
    await _createSyncTables(db);
  }

  /// 重建 `rounds` 表：移除历史中间版本（v6/v7）加入的失败列，
  /// 保留全部数据、主键、外键与索引（无其他表引用 rounds，FK 安全）。
  static Future<void> _rebuildRoundsTable(Database db) async {
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

  // ---------------------------------------------------------------------------
  // v16 业务表（books / mods 以 uuid 为主键；子表以 uuid 引用父表，自身 int 主键保留）
  //
  // 表名后缀参数 [suffix] 仅供 v16 迁移建中间表（`*_new`）复用同一份 DDL：
  // 新库（onCreate）传空后缀，迁移传 `_new`。**新装库与迁移结果逐字一致**，
  // 不存在第二套 schema 定义。
  // ---------------------------------------------------------------------------

  /// `books`：uuid 即主键，无第二个 id 列。
  static Future<void> _createBooksTable(
    Database db, {
    String suffix = '',
  }) async {
    await db.execute('''
      CREATE TABLE books@S@ (
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
    '''.replaceAll('@S@', suffix));
  }

  /// `rounds`：自增 id 保留，所属书籍以 [booksTable]（v16 迁移期为 `books_new`）
  /// 的 uuid 外键引用。
  static Future<void> _createRoundsTable(
    Database db, {
    String suffix = '',
    String booksTable = 'books',
  }) async {
    await db.execute('''
      CREATE TABLE rounds@S@ (
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
        updated_at INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (book_uuid) REFERENCES @B@ (uuid) ON DELETE CASCADE
      )
    '''.replaceAll('@S@', suffix).replaceAll('@B@', booksTable));
  }

  /// `world_book_entries`：自增 id 保留，书籍以 uuid 引用。
  static Future<void> _createWorldBookTable(
    Database db, {
    String suffix = '',
    String booksTable = 'books',
  }) async {
    await db.execute('''
      CREATE TABLE world_book_entries@S@ (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_uuid TEXT NOT NULL,
        keyword TEXT NOT NULL,
        content TEXT DEFAULT '',
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at DATETIME,
        updated_at INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (book_uuid) REFERENCES @B@ (uuid) ON DELETE CASCADE
      )
    '''.replaceAll('@S@', suffix).replaceAll('@B@', booksTable));
  }

  /// `mods`：uuid 即主键，无第二个 id 列。
  static Future<void> _createModsTable(
    Database db, {
    String suffix = '',
  }) async {
    await db.execute('''
      CREATE TABLE mods@S@ (
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
    '''.replaceAll('@S@', suffix));
  }

  /// `book_mods`：自增 id 保留，书 / Mod 均以 uuid 引用（预置行为 mod_uuid NULL）。
  static Future<void> _createBookModsTable(
    Database db, {
    String suffix = '',
    String booksTable = 'books',
    String modsTable = 'mods',
  }) async {
    await db.execute('''
      CREATE TABLE book_mods@S@ (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_uuid TEXT NOT NULL,
        preset_key TEXT,
        mod_uuid TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_enabled INTEGER NOT NULL DEFAULT 1,
        FOREIGN KEY (book_uuid) REFERENCES @B@ (uuid) ON DELETE CASCADE,
        FOREIGN KEY (mod_uuid) REFERENCES @M@ (uuid) ON DELETE CASCADE
      )
    '''
        .replaceAll('@S@', suffix)
        .replaceAll('@B@', booksTable)
        .replaceAll('@M@', modsTable));
  }

  /// 三张子表的检索索引（v16 迁移在 RENAME 之后调用；旧索引随旧表 DROP 消失）。
  static Future<void> _createBookIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX idx_rounds_book_index ON rounds (book_uuid, round_index)',
    );
    await db.execute(
      'CREATE INDEX idx_world_book_book_uuid ON world_book_entries (book_uuid)',
    );
    await db.execute(
      'CREATE INDEX idx_book_mods_book_uuid ON book_mods (book_uuid)',
    );
  }

  // ---------------------------------------------------------------------------
  // 迁移链起点的历史表形状（v2 / v5 分支）
  //
  // 仅用于「比 v16 更老的版本」逐版本 ALTER 的中间形态（int 主键 + book_id 引用），
  // 迁移链末尾的 v16 分支会统一重建为上面的最终形状。新装库不走这里。
  // ---------------------------------------------------------------------------

  static Future<void> _createLegacyWorldBookTable(Database db) async {
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
  }

  static Future<void> _createLegacyModsTable(Database db) async {
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
        updated_at DATETIME
      )
    ''');
  }

  static Future<void> _createLegacyBookModsTable(Database db) async {
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


  /// 云同步相关辅助表。
  ///
  /// - `sync_state`：单行，记录本设备标识、上次同步时间/代数、同步进行中标记与上次阶段/错误；
  /// - `sync_book_base`：per‑book 三向合并的 common base（主键即书籍 uuid；
  ///   title 仅供展示，从不参与身份匹配）；
  /// - `sync_mod_base`：per‑mod 合并共基（主键即 Mod uuid；name 同上）。
  ///
  /// 图片删除墓碑**不在数据库中**：由 `img_tombstones.dart` 的云端文件 +
  /// 本地工作副本承载；开发期遗留的 `sync_pending_del` / `sync_image_revived`
  /// 已在 v16 迁移里彻底移除，此处不再建表。
  static Future<void> _createSyncTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        device_id TEXT DEFAULT '',
        last_synced_at INTEGER NOT NULL DEFAULT 0,
        last_generation INTEGER NOT NULL DEFAULT 0,
        sync_in_flight INTEGER NOT NULL DEFAULT 0,
        last_phase TEXT DEFAULT '',
        last_error TEXT DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_book_base (
        uuid TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        info_fp TEXT DEFAULT '',
        roles_fp TEXT DEFAULT '',
        base_setting_fp TEXT DEFAULT '',
        prompts_fp TEXT DEFAULT '',
        failed_fp TEXT DEFAULT '',
        settings_fp TEXT DEFAULT '',
        rounds_fp TEXT DEFAULT '',
        worldbook_fp TEXT DEFAULT '',
        bookmods_fp TEXT DEFAULT '',
        settings_updated_at INTEGER NOT NULL DEFAULT 0,
        rounds_updated_at INTEGER NOT NULL DEFAULT 0,
        worldbook_updated_at INTEGER NOT NULL DEFAULT 0,
        bookmods_updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_mod_base (
        uuid TEXT PRIMARY KEY,
        name TEXT NOT NULL DEFAULT '',
        fingerprint TEXT DEFAULT '',
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // 图片删除墓碑已文件化（img_tombstones.dart），不再进数据库：
    // 仅保留版本注释，避免后续误加同表。
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  /// 更新某本书的同步写时间戳（供各 DAO 在写入其子表后调用）。
  ///
  /// - 轮次变更 → [rounds]（`books.rounds_updated_at`）；
  /// - 世界书 / 书‑Mod 挂载 / 设置变更 → [settings]（`books.settings_updated_at`）。
  ///
  /// 接收 [DatabaseExecutor] 以便在既有事务内一并提交；[bookUuid] 为空（未落库
  /// 草稿 / 预置行）时静默跳过——uuid 即主键，没有第二种标识可回退。
  static Future<void> touchBook(
    DatabaseExecutor db,
    String bookUuid, {
    bool settings = false,
    bool rounds = false,
  }) async {
    if (bookUuid.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final data = <String, Object?>{
      if (settings) 'settings_updated_at': now,
      if (rounds) 'rounds_updated_at': now,
    };
    if (data.isEmpty) return;
    await db.update('books', data, where: 'uuid = ?', whereArgs: [bookUuid]);
  }
}