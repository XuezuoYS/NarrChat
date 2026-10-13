import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/app_paths.dart';
import 'sqflite_desktop.dart';

/// 本地同步元数据库访问入口（单例）：`local_config/local_db/narrchat_sync.db`。
///
/// 承载云同步的**本地元数据**（非用户资产，不云同步）：
/// - `sync_state`：单行，本设备标识、上次同步时间/代数、同步进行中标记与上次阶段/错误；
/// - `sync_book_base`：per‑book 三向合并的 common base（主键即书籍 uuid）；
/// - `sync_mod_base`：per‑mod 合并共基（主键即 Mod uuid）。
///
/// 与用户库（`user_data/narrchat.db`）分离的原因：用户库整库字节即云端快照，
/// 元数据随快照上传既带本机信息（device_id）又徒增体积。v20 起三表**数据**
/// 只存本库；用户库内保留同 schema **空表壳**，兼容「v20 → 回退 ≤v19 旧版」
/// （旧版 `SyncStateDao` 直接查用户库，空壳 = 空共基，同步功能可用而非报错）。
///
/// 后续如需新增不云同步的本地 sqlite 库，沿用 `local_config/local_db/` 目录、
/// 按 `narrchat_xxx.db` 命名（见 [AppPaths.localDbDir]）。
class LocalSyncDb {
  LocalSyncDb._();

  static final LocalSyncDb instance = LocalSyncDb._();

  static const int _dbVersion = 1;

  Database? _database;

  /// 测试用数据库路径覆盖（null 时走真实 [AppPaths.localSyncDatabasePath]）。
  ///
  /// 与 `DatabaseHelper.debugDatabasePathOverride` 同口径：供 DAO / 迁移测试
  /// 指向临时库，避免触碰真实本地配置目录；生产代码不设置。
  @visibleForTesting
  static String? debugDatabasePathOverride;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _open();
    return _database!;
  }

  Future<Database> _open() async {
    ensureDesktopSqfliteFactory();
    final dbPath =
        debugDatabasePathOverride ?? await AppPaths.localSyncDatabasePath();
    return openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await createSyncTables(db);
      },
    );
  }

  /// 当前本地同步元数据库 schema 版本（调试展示、测试断言用）。
  static int get currentDbVersion => _dbVersion;

  /// 云同步辅助表 DDL（**唯一来源**）。
  ///
  /// 三处共用同一份定义，保证 schema 逐字一致：
  /// - 本库（数据权威，`onCreate`）；
  /// - 用户库的空表壳（`DatabaseHelper` 新装库与 v20 迁移，`IF NOT EXISTS` 幂等）；
  /// - v12/v13 历史迁移分支在用户库建过渡表（v20 迁出前临时承载）。
  static Future<void> createSyncTables(Database db) async {
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
    // 图片删除墓碑已文件化（img_tombstones.dart），不进任何数据库：
    // 仅保留版本注释，避免后续误加同表。
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
