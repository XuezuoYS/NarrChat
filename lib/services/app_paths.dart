import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用数据目录管理（以文件形式显性区分用户数据与本地数据，见 AGENTS.md）。
///
/// 根目录：`<系统文档目录>/NarrChat/`
/// - `user_data/`    —— 用户数据（书籍、轮次、世界书等，sqlite），可 webdev 云同步；
/// - `local_config/` —— 本地数据（AI 设置、UI 设置等明文 JSON 配置），不云同步；
///   - `local_db/`   —— 本地 sqlite 库（`narrchat_xxx.db` 命名；如同步元数据
///     `narrchat_sync.db`），不云同步、不进用户库快照。
/// - AI 令牌不落盘于此，一律走系统密钥库（flutter_secure_storage）。
class AppPaths {
  AppPaths._();

  static const String rootDirName = 'NarrChat';
  static const String userDataDirName = 'user_data';
  static const String localConfigDirName = 'local_config';
  static const String localDbDirName = 'local_db';

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

  /// 用户数据库文件路径（sqlite，位于 user_data 目录下）。
  static Future<String> userDatabasePath() async {
    return p.join((await userData()).path, 'narrchat.db');
  }

  /// 本地数据库目录（`local_config/local_db/`，不存在则创建）。
  ///
  /// 存放不云同步的本地 sqlite 库，统一按 `narrchat_xxx.db` 命名
  /// （当前仅同步元数据库 [localSyncDatabasePath]）。
  static Future<Directory> localDbDir() async {
    final dir = Directory(p.join((await localConfig()).path, localDbDirName));
    await dir.create(recursive: true);
    return dir;
  }

  /// 同步元数据本地库路径（`local_config/local_db/narrchat_sync.db`）。
  ///
  /// 承载 `sync_state` / `sync_book_base` / `sync_mod_base` 三表：
  /// 合并共基与本机同步状态属本地数据，**不随用户库快照上传云端**。
  static Future<String> localSyncDatabasePath() async {
    return p.join((await localDbDir()).path, 'narrchat_sync.db');
  }
}
