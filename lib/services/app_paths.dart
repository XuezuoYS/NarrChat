import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用数据目录管理（以文件形式显性区分用户数据与本地数据，见 AGENTS.md）。
///
/// 根目录：`<系统文档目录>/NarrChat/`
///
/// ```
/// user_data/                        ← 用户数据，可云备份 / 可导出
///   narrchat_library.db             ← R3：书籍目录 + 墓碑
///   narrchat_mods.db                ← R3：Mod
///   books/narrbook_<uuid>.db        ← R3：单本书（唯一信源）
///   img/<sha256>.<ext>              ← 图片，扁平、内容寻址
///   narrchat.db                     ← R2 遗留单库（迁移后改名为 .r2.bak）
///
/// local_config/                     ← 本地数据，不云同步
///   local_db/
///     sync.db                       ← R3：云备份状态与共基
///     library_cache.db              ← R3：跨书高频操作缓存（纯派生）
///   *.json                          ← AI / UI 配置等
/// ```
///
/// AI 令牌不落盘于此，一律走系统密钥库（flutter_secure_storage）。
class AppPaths {
  AppPaths._();

  static const String rootDirName = 'NarrChat';
  static const String userDataDirName = 'user_data';
  static const String localConfigDirName = 'local_config';
  static const String localDbDirName = 'local_db';

  // --- R3 文件名常量（云备份提示、调试页展示、迁移都复用这一份） -----------------

  /// 书籍目录库（R3）。
  static const String libraryDbFileName = 'narrchat_library.db';

  /// Mod 库（R3）。
  static const String modsDbFileName = 'narrchat_mods.db';

  /// 单本书库所在目录（R3）。
  static const String booksDirName = 'books';

  /// 图片目录（扁平、内容寻址，R3 不变）。
  static const String imagesDirName = 'img';

  /// 本地缓存库（R3）。
  static const String libraryCacheDbFileName = 'library_cache.db';

  /// 本地云备份状态库（R3）。
  static const String syncDbFileName = 'sync.db';

  /// R2 单库文件名（迁移后改名成 [legacyR2FileName] 留作备份）。
  static const String legacyDbFileName = 'narrchat.db';

  /// R2 备份文件名（升级 3.0 时由 `narrchat.db` 改名而来）。
  static const String legacyR2FileName = 'narrchat.db.r2.bak';

  /// 降级期间旧版本又生成的库文件，迁移时改名到这里，不再读取。
  static const String legacyAfterDowngradeFileName =
      'narrchat.db.after-downgrade.bak';

  // --- 目录 -------------------------------------------------------------------

  /// 应用数据根目录。
  static Future<Directory> root() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, rootDirName));
  }

  /// 用户数据目录（不存在则创建）。
  static Future<Directory> userData() async {
    final dir = Directory(p.join((await root()).path, userDataDirName));
    await dir.create(recursive: true);
    return dir;
  }

  /// 本地配置目录（不存在则创建）。
  static Future<Directory> localConfig() async {
    final dir = Directory(p.join((await root()).path, localConfigDirName));
    await dir.create(recursive: true);
    return dir;
  }

  /// 本地数据库目录（`local_config/local_db/`，不存在则创建）。
  ///
  /// 存放不云同步的本地 sqlite 库（R3 起为 [syncDbFileName] 与
  /// [libraryCacheDbFileName]）。
  static Future<Directory> localDbDir() async {
    final dir = Directory(p.join((await localConfig()).path, localDbDirName));
    await dir.create(recursive: true);
    return dir;
  }

  /// 单本书库目录（`user_data/books/`，不存在则创建）。
  static Future<Directory> booksDir() async {
    final dir = Directory(p.join((await userData()).path, booksDirName));
    await dir.create(recursive: true);
    return dir;
  }

  /// 图片目录（`user_data/img/`，不存在则创建）。
  static Future<Directory> imagesDir() async {
    final dir = Directory(p.join((await userData()).path, imagesDirName));
    await dir.create(recursive: true);
    return dir;
  }

  // --- R3 数据库文件 -----------------------------------------------------------

  /// 书籍目录库路径。
  static Future<String> libraryDatabasePath() async {
    return p.join((await userData()).path, libraryDbFileName);
  }

  /// Mod 库路径。
  static Future<String> modsDatabasePath() async {
    return p.join((await userData()).path, modsDbFileName);
  }

  /// 单本书库路径：`user_data/books/narrbook_<book_uuid>.db`。
  ///
  /// [bookUuid] 参与文件名，必须是非空且不含路径分隔符的 UUID；非法值直接抛错，
  /// 避免拼出目录穿越路径。
  static Future<String> bookDatabasePath(String bookUuid) async {
    final name = bookDbFileName(bookUuid);
    return p.join((await booksDir()).path, name);
  }

  /// 单本书库的纯文件名（不含目录）。迁移、云备份、调试页共用。
  static String bookDbFileName(String bookUuid) {
    if (bookUuid.isEmpty ||
        bookUuid.contains('/') ||
        bookUuid.contains(r'\') ||
        bookUuid.contains('..')) {
      throw ArgumentError.value(bookUuid, 'bookUuid', '书籍 uuid 非法');
    }
    return 'narrbook_$bookUuid.db';
  }

  /// 本地缓存库路径。
  static Future<String> libraryCacheDatabasePath() async {
    return p.join((await localDbDir()).path, libraryCacheDbFileName);
  }

  /// 本地云备份状态库路径。
  static Future<String> syncDatabasePath() async {
    return p.join((await localDbDir()).path, syncDbFileName);
  }

  /// R2 备份库路径（升级 3.0 后旧用户库停在这里）。
  static Future<String> legacyR2DatabasePath() async {
    return p.join((await userData()).path, legacyR2FileName);
  }

  // --- R2 遗留路径（B2 切换完成后删除） ----------------------------------------

  /// 用户数据库文件路径（sqlite，位于 user_data 目录下）。
  static Future<String> userDatabasePath() async {
    return p.join((await userData()).path, legacyDbFileName);
  }

  /// 同步元数据本地库路径（`local_config/local_db/narrchat_sync.db`）。
  static Future<String> localSyncDatabasePath() async {
    return p.join((await localDbDir()).path, 'narrchat_sync.db');
  }
}
