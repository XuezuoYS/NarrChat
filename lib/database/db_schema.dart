/// R3 全部建表语句的**唯一来源**（新装库、迁移产物、测试库共用同一份 DDL）。
///
/// 设计依据：`docs/000temp_database_next.md`。约定：
///
/// - 时间戳一律 `TEXT`，定长 `YYYY-MM-DDTHH:MM:SS.sssZ`（UTC，毫秒补零）；
///   见 `lib/utils/timestamp_format.dart`；禁止 `datetime()` / `strftime()` 参与索引查询。
/// - 布尔一律 `INTEGER` 的 `0` / `1`，`NOT NULL`。
/// - 主键一律业务 UUID（`TEXT`），不设自增 id。
/// - `meta` / `book_meta` 是单行表；`database_version` 只是迁移后写入的**镜像**，
///   任何代码不得据此判断版本（唯一权威是 `PRAGMA user_version`）。
/// - 不启用 WAL：云端快照就是「一个 .db 文件」，WAL 会把最新数据留在 `-wal`
///   旁挂文件里，导致上传的快照缺数据。
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `user_data/` 下四个库（library / mods / 每本书）**共用的 schema 版本**。
///
/// 3.0 是软件大版本号，数据库版本继续沿用旧编号，从 22 起算。
/// 23：library 增加删除时的轮号（回收站展示用）。
const int userDataDbVersion = 23;

/// 本地缓存库 `library_cache.db` 的 schema 版本（本地库单独管理）。
const int localCacheDbVersion = 1;

/// 本地云备份库 `sync.db` 的 schema 版本（本地库单独管理）。
const int localSyncDbVersion = 1;

// ---------------------------------------------------------------------------
// narrchat_library.db
// ---------------------------------------------------------------------------

/// 书籍目录库：只有目录与墓碑，不存内容。
///
/// 列表页读 `library_cache.db`，不打开本库做全量查询。
Future<void> createLibrarySchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS meta (
      master_uuid      TEXT PRIMARY KEY,
      database_version INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS books (
      book_uuid           TEXT PRIMARY KEY,
      title               TEXT NOT NULL,
      deleted_at          TEXT,
      deleted_round_index INTEGER
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_books_deleted ON books (deleted_at)',
  );
}

// ---------------------------------------------------------------------------
// narrchat_mods.db
// ---------------------------------------------------------------------------

/// Mod 库：用户自定义 Mod。
///
/// 预置 Mod 不落本表（程序内置），引用标识固定 `preset::<id>`。
Future<void> createModsSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS meta (
      master_uuid      TEXT PRIMARY KEY,
      database_version INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS mods (
      mod_uuid      TEXT PRIMARY KEY,
      name          TEXT NOT NULL,
      description   TEXT DEFAULT '',
      pre_prompt    TEXT DEFAULT '',
      post_prompt   TEXT DEFAULT '',
      system_prompt TEXT DEFAULT '',
      world_book    TEXT DEFAULT '',
      created_at    TEXT NOT NULL,
      updated_at    TEXT NOT NULL,
      deleted_at    TEXT
    )
  ''');
}

// ---------------------------------------------------------------------------
// narrbook_<book_uuid>.db
// ---------------------------------------------------------------------------

/// 单本书库：这本书的**唯一信源**。
///
/// 所有 `book_uuid` 列都不存在——库文件本身就是书的边界。
Future<void> createBookSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS book_meta (
      master_uuid            TEXT NOT NULL,
      database_version       INTEGER NOT NULL,
      book_uuid              TEXT PRIMARY KEY,
      title                  TEXT NOT NULL,
      category               TEXT DEFAULT '',
      created_at             TEXT NOT NULL,
      updated_at             TEXT NOT NULL,
      base_setting           TEXT DEFAULT '',
      writing_requirements   TEXT DEFAULT '',
      writing_style          TEXT DEFAULT '',
      global_pre_prompt      TEXT DEFAULT '',
      global_post_prompt     TEXT DEFAULT '',
      history_rounds         INTEGER NOT NULL DEFAULT 1,
      memory_summary_rounds  INTEGER NOT NULL DEFAULT 0,
      role_hierarchy         TEXT DEFAULT '',
      role_hierarchy_detail  TEXT DEFAULT ''
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS world_book_entries (
      uuid       TEXT PRIMARY KEY,
      keyword    TEXT NOT NULL,
      content    TEXT DEFAULT '',
      is_using   INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS use_mods (
      mod_uuid   TEXT PRIMARY KEY,
      sort_order INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await _createRoundStackTable(db);
  await _createBranchesTable(db);
}

/// `round_stack`：**唯一**的轮次记录表，没有投影表。
///
/// 数据模型：`library(db) -> book(db) -> branch(表) -> round(逻辑分层) -> 代(row)`。
///
/// - `father_uuid` 指向**上一轮当时活动代**；`NULL` / 空串 = 链首。
///   非空但指向的行不存在 → 视为该父已被删除，本代不可达。
/// - 分组键 = `(branch_uuid, round_index, father_uuid)`：同一上文下重生成的
///   多个版本才属于同一组，因此「切上一轮 → 下一轮跟着切」天然成立。
/// - `is_using`：组内当前选中的代。同组至多一个 1（不建唯一索引，读时归一化自愈）。
/// - **不建 `father_uuid` 自引用外键**：删除是物理删除，自引用外键会阻止删父行；
///   不可达行靠「父查不到 → 不可达 → 清理」规则处理。
Future<void> _createRoundStackTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS round_stack (
      uuid               TEXT PRIMARY KEY,
      father_uuid        TEXT,
      branch_uuid        TEXT DEFAULT '',
      round_index        INTEGER NOT NULL,
      round_serial_num   INTEGER NOT NULL,
      is_using           INTEGER NOT NULL,
      operated_at        TEXT NOT NULL,
      message_status     TEXT DEFAULT '',
      message            TEXT DEFAULT '',
      model_name         TEXT DEFAULT '',
      tokens_in          INTEGER,
      tokens_cached_in   INTEGER,
      tokens_out         INTEGER,
      raw_response       TEXT DEFAULT '',
      user_input         TEXT DEFAULT '',
      ai_narrative       TEXT DEFAULT '',
      world_state        TEXT DEFAULT '',
      character_state    TEXT DEFAULT '',
      memory_summary     TEXT DEFAULT '',
      current_time       TEXT DEFAULT '',
      recommended_action TEXT DEFAULT '',
      user_images        TEXT NOT NULL DEFAULT '[]',
      ai_images          TEXT NOT NULL DEFAULT '[]'
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_stack_group ON round_stack '
    '(branch_uuid, round_index, father_uuid, round_serial_num)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_stack_father ON round_stack (father_uuid)',
  );
}

/// `branches`：书籍分支（IF 线）。
///
/// - **默认分支不记本表**（`branch_uuid = ''`），不可删除、不可重命名。
/// - 分支链首代的 `father_uuid = NULL`；父级信息记在 `father_row` /
///   `father_branch` / `father_row_shot` 上，父行被删也不影响分支本身。
/// - `branch_working` 是本机会话状态：不进同步摘要、切换分支不触发云备份。
Future<void> _createBranchesTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS branches (
      branch_uuid      TEXT PRIMARY KEY,
      father_row       TEXT DEFAULT '',
      father_row_index INTEGER NOT NULL DEFAULT 1,
      father_branch    TEXT DEFAULT '',
      branch_name      TEXT NOT NULL,
      father_row_shot  TEXT DEFAULT '',
      branch_working   INTEGER NOT NULL DEFAULT 0,
      created_at       TEXT NOT NULL,
      updated_at       TEXT NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_branches_working ON branches (branch_working)',
  );
}

// ---------------------------------------------------------------------------
// local_config/local_db/library_cache.db
// ---------------------------------------------------------------------------

/// 本地缓存库：**纯派生数据，可随时重建**。
///
/// 存在意义只有一个——列表 / 搜索 / 高度缓存这类跨书高频操作不必打开 N 个书库。
/// 任何情况下都不得把这里的值当信源写回书库。
Future<void> createCacheSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS book_index (
      book_uuid    TEXT PRIMARY KEY,
      title        TEXT NOT NULL DEFAULT '',
      category     TEXT NOT NULL DEFAULT '',
      created_at   TEXT NOT NULL DEFAULT '',
      updated_at   TEXT NOT NULL DEFAULT '',
      last_round_at TEXT NOT NULL DEFAULT '',
      deleted_at   TEXT,
      db_mtime_ms  INTEGER NOT NULL DEFAULT 0,
      base_setting            TEXT NOT NULL DEFAULT '',
      writing_requirements    TEXT NOT NULL DEFAULT '',
      writing_style           TEXT NOT NULL DEFAULT '',
      global_pre_prompt       TEXT NOT NULL DEFAULT '',
      global_post_prompt      TEXT NOT NULL DEFAULT '',
      history_rounds          INTEGER NOT NULL DEFAULT 1,
      memory_summary_rounds   INTEGER NOT NULL DEFAULT 0,
      role_hierarchy          TEXT NOT NULL DEFAULT '',
      role_hierarchy_detail   TEXT NOT NULL DEFAULT ''
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS image_refs (
      image_path TEXT NOT NULL,
      book_uuid  TEXT NOT NULL,
      ref_count  INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (image_path, book_uuid)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS ix_image_refs_book ON image_refs (book_uuid)',
  );
  // 聊天条目实测高度（C4 起写入）：命中条件 = 条目 + 列宽档 + 字号档三者一致。
  await db.execute('''
    CREATE TABLE IF NOT EXISTS chat_heights (
      book_uuid         TEXT NOT NULL,
      item_key          TEXT NOT NULL,
      width_bucket      INTEGER NOT NULL,
      type_scale_bucket INTEGER NOT NULL,
      height            REAL NOT NULL,
      updated_at        TEXT NOT NULL,
      PRIMARY KEY (book_uuid, item_key, width_bucket, type_scale_bucket)
    )
  ''');
}

// ---------------------------------------------------------------------------
// local_config/local_db/sync.db
// ---------------------------------------------------------------------------

/// 本地云备份库：本机状态 + 每个同步单元的共基。丢了只会导致下次全量比对。
Future<void> createSyncSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_state (
      id           INTEGER PRIMARY KEY CHECK (id = 1),
      device_id    TEXT NOT NULL DEFAULT '',
      last_phase   TEXT NOT NULL DEFAULT '',
      last_error   TEXT NOT NULL DEFAULT '',
      in_flight    INTEGER NOT NULL DEFAULT 0,
      updated_at   TEXT NOT NULL DEFAULT ''
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_unit (
      unit_key       TEXT PRIMARY KEY,
      kind           TEXT NOT NULL,
      ref_uuid       TEXT NOT NULL DEFAULT '',
      generation     INTEGER NOT NULL DEFAULT 0,
      remote_digest  TEXT NOT NULL DEFAULT '',
      base_digest    TEXT NOT NULL DEFAULT '',
      last_synced_at TEXT NOT NULL DEFAULT ''
    )
  ''');
}

// ---------------------------------------------------------------------------
// 单行表辅助
// ---------------------------------------------------------------------------

/// 写入 `meta` / `book_meta` 的 `database_version` 镜像值。
///
/// 只用于调试页展示，迁移收尾调用；**不得**用它判断版本。
Future<void> writeDatabaseVersion(
  DatabaseExecutor e,
  String table,
  int version,
) async {
  await e.update(table, {'database_version': version});
}
