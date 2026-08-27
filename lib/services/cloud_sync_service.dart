import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../database/database_helper.dart';
import 'app_paths.dart';
import 'webdav_service.dart';

/// 云同步数据落地服务：负责数据库文件生命周期的关闭/复制/重开，
/// 以及快照（云端数据库备份）的下载落盘与替换本地数据。
///
/// 云端文件名约定（新版同步规则，见 [WebDavSyncStore]）：
/// - manifest：`manifest.json`；
/// - 数据库快照：`narrchat_snapshot_g<gen>_<yyyyMMdd_HHmmss>.db`。
/// 旧版 `narrchat_<user>_<yyyy-MM-dd_HH-mm-ss>.db` 命名不再支持。
class CloudSyncService {
  CloudSyncService._();

  /// 把已下载的快照字节写入临时目录，返回临时文件路径（由调用方在应用后清理）。
  static Future<String> saveSnapshotToTemp(String name, Uint8List bytes) async {
    final tempDir = await Directory.systemTemp.createTemp('narrchat_download');
    final file = File(p.join(tempDir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 从云端下载指定快照到临时目录，返回临时文件路径（由调用方在应用后清理）。
  static Future<String> downloadBackup({
    required WebDavService dav,
    required String folder,
    required String name,
  }) async {
    final bytes = await dav.get(folder, name);
    return saveSnapshotToTemp(name, bytes);
  }

  /// 替换本地数据：删除本地 `narrchat.db`，用下载的备份取而代之。
  static Future<void> applyReplace(String tempPath) async {
    final dbPath = await AppPaths.userDatabasePath();
    final dbFile = File(dbPath);
    await DatabaseHelper.instance.close();
    try {
      if (await dbFile.exists()) {
        await dbFile.delete();
      }
      await File(tempPath).copy(dbPath);
    } finally {
      // 重开本地库（即使复制失败也重开，避免后续请求悬挂）。
      await DatabaseHelper.instance.database;
    }
  }

  /// 从本地库导出一致字节快照（用于同步上传）。
  ///
  /// 一致性策略：关闭库 → 复制到临时 → 重开库，然后读取临时文件字节
  /// （保证副本一致，不携带写入中的半成品）。
  static Future<Uint8List> buildSnapshotBytes() async {
    final dbPath = await AppPaths.userDatabasePath();
    final dbFile = File(dbPath);
    if (!await dbFile.exists()) {
      throw StateError('本地数据库不存在，无法构建快照');
    }
    final tempDir = await Directory.systemTemp.createTemp('narrchat_syncsnap');
    try {
      final tempFile = File(p.join(tempDir.path, 'narrchat.db'));
      await DatabaseHelper.instance.close();
      try {
        await dbFile.copy(tempFile.path);
      } finally {
        await DatabaseHelper.instance.database;
      }
      return await tempFile.readAsBytes();
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // 临时目录清理失败可忽略。
      }
    }
  }
}
