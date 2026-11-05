import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/book_db_pool.dart';
import '../database/cache_store.dart';
import '../database/library_store.dart';
import '../database/migration/migration_paths.dart';
import '../database/migration/migration_state.dart';
import '../database/migration/r2_to_v3.dart';
import '../database/mods_store.dart';
import '../database/sync_store.dart';
import 'app_paths.dart';

/// R3 的组装根：一次性把五个存储、书本连接池与迁移结果准备好。
///
/// 全应用只有这一处知道"库文件在哪、叫什么"，provider / service 只拿接口。
/// 启动顺序固定为：**先迁移，再打开**——迁移会把 `narrchat.db` 改名成
/// `.r2.bak`，晚于任何读写都会读到错的库。
class AppStores {
  AppStores({
    required this.library,
    required this.mods,
    required this.cache,
    required this.sync,
    required this.books,
    required this.paths,
    this.migration,
  });

  final LibraryStore library;
  final ModsStore mods;
  final CacheStore cache;
  final SyncStore sync;
  final BookDbPool books;

  /// 本次启动实际使用的路径（存储管理页 / 调试页要用）。
  final MigrationPaths paths;

  /// 本次启动的迁移结果（`null` = 已迁移完成，本次没跑）。
  final MigrationReport? migration;

  /// 生产入口：解析真实路径 → 迁移 → 打开各库。
  static Future<AppStores> open() async {
    final paths = await MigrationPaths.resolve();
    return openAt(paths);
  }

  /// 指定路径打开（测试 / 特殊场景）。
  ///
  /// [runMigration] 为 false 时可以跳过迁移（例如测试只想验装配）。
  static Future<AppStores> openAt(
    MigrationPaths paths, {
    bool runMigration = true,
  }) async {
    await Directory(paths.userDataDir).create(recursive: true);
    await Directory(paths.localDbDir).create(recursive: true);

    MigrationReport? report;
    if (runMigration) {
      report = await R2ToR3Migrator(paths: paths).run();
    }

    final library = LibraryDb(pathOverride: paths.libraryDbPath);
    final mods = ModsDb(pathOverride: paths.modsDbPath);
    final cache = CacheDb(pathOverride: paths.cacheDbPath);
    final sync = SyncDb(pathOverride: paths.syncDbPath);
    final books = BookDbPool(booksDir: paths.booksDir);

    return AppStores(
      library: library,
      mods: mods,
      cache: cache,
      sync: sync,
      books: books,
      paths: paths,
      migration: report,
    );
  }

  /// 是否已经迁移完成（启动时判断要不要显示进度页）。
  static Future<bool> isMigrationDone() async {
    final file = await _stateFile();
    final state = await MigrationState.read(file);
    return state?.done ?? false;
  }

  static Future<File> _stateFile() async {
    final root = await AppPaths.root();
    return File(
      p.join(root.path, AppPaths.localConfigDirName, 'migration_state.json'),
    );
  }

  /// 上次迁移里失败的书（启动后提示"可重试"）。
  Future<Map<String, String>> failedBooks() async {
    final state = await MigrationState.read(File(paths.statePath));
    return state?.failedBooks ?? const {};
  }

  Future<void> dispose() async {
    await books.closeAll();
    await library.close();
    await mods.close();
    await cache.close();
    await sync.close();
  }
}
