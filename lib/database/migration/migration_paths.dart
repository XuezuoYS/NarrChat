import 'package:path/path.dart' as p;

import '../../services/app_paths.dart';

/// 迁移涉及的绝对路径集合。
///
/// 单独抽出来是为了让迁移**可以在临时目录里整跑一遍**：生产用
/// [MigrationPaths.resolve]，测试直接给两个临时目录。
class MigrationPaths {
  const MigrationPaths({
    required this.userDataDir,
    required this.localConfigDir,
  });

  /// `user_data/` 绝对路径。
  final String userDataDir;

  /// `local_config/` 绝对路径。
  final String localConfigDir;

  /// 生产环境的真实路径（由 [AppPaths] 解析）。
  static Future<MigrationPaths> resolve() async {
    final root = await AppPaths.root();
    return MigrationPaths(
      userDataDir: p.join(root.path, AppPaths.userDataDirName),
      localConfigDir: p.join(root.path, AppPaths.localConfigDirName),
    );
  }

  // --- R2 遗留 ---------------------------------------------------------------

  /// R2 单库：`user_data/narrchat.db`。
  String get legacyDbPath => p.join(userDataDir, AppPaths.legacyDbFileName);

  /// R2 备份：`user_data/narrchat.db.r2.bak`。
  String get backupPath => p.join(userDataDir, AppPaths.legacyR2FileName);

  /// 降级期间旧版本又生成的库，改名到这里，不再读取。
  String get downgradePath =>
      p.join(userDataDir, AppPaths.legacyAfterDowngradeFileName);

  /// R2 的本地同步库（新格式完全不同，迁移后直接丢弃）。
  String get legacySyncDbPath =>
      p.join(localDbDir, 'narrchat_sync.db');

  // --- R3 目标 ---------------------------------------------------------------

  String get libraryDbPath => p.join(userDataDir, AppPaths.libraryDbFileName);

  String get modsDbPath => p.join(userDataDir, AppPaths.modsDbFileName);

  String get booksDir => p.join(userDataDir, AppPaths.booksDirName);

  String bookDbPath(String bookUuid) =>
      p.join(booksDir, AppPaths.bookDbFileName(bookUuid));

  String get localDbDir => p.join(localConfigDir, AppPaths.localDbDirName);

  String get cacheDbPath => p.join(localDbDir, AppPaths.libraryCacheDbFileName);

  String get syncDbPath => p.join(localDbDir, AppPaths.syncDbFileName);

  /// 迁移进度文件。
  String get statePath => p.join(localConfigDir, 'migration_state.json');
}
