import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/database_helper.dart';
import 'app_paths.dart';
import 'webdav_service.dart';

/// 云同步编排服务：负责数据库文件的生命周期管理（关闭/复制/重开）、
/// 备份文件名生成、历史版本修剪，以及下载后的替换/合并落地。
class CloudSyncService {
  CloudSyncService._();

  /// 备份文件名格式：`narrchat_{userName}_{yyyy-MM-dd_HH-mm-ss}.db`。
  ///
  /// [userName] 中的非法文件名字符会被替换为 `_`。
  static String buildBackupFileName(String userName, DateTime time) {
    final safe = _sanitizeFileName(userName.trim());
    final u = safe.isEmpty ? 'user' : safe;
    final ts =
        '${time.year}-${_two(time.month)}-${_two(time.day)}'
        '_${_two(time.hour)}-${_two(time.minute)}-${_two(time.second)}';
    return 'narrchat_${u}_$ts.db';
  }

  /// 备份文件名匹配正则（`narrchat_*.db`，含固定时间戳段）。
  static final RegExp backupNameRegex = RegExp(
    r'^narrchat_[^/]+_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.db$',
  );

  /// 从服务器文件列表中筛出本应用备份文件。
  static List<WebDavFile> matchBackups(List<WebDavFile> files) {
    return files.where((f) => backupNameRegex.hasMatch(f.name)).toList();
  }

  /// 备份排序：修改时间新 → 旧；无修改时间的视为最旧；
  /// 均无修改时间时按文件名倒序（文件名内嵌时间戳，同格式下字典序即时间序）。
  static int compareBackups(WebDavFile a, WebDavFile b) {
    final am = a.lastModified;
    final bm = b.lastModified;
    if (am != null && bm != null && am != bm) {
      return bm.compareTo(am);
    }
    if (am != null) return -1; // a 有时间、b 没有：a 更新
    if (bm != null) return 1; // b 有时间、a 没有：b 更新
    return b.name.compareTo(a.name);
  }

  /// 执行一次完整上传：
  /// 1. 关闭本地库 → 复制到临时文件 → 重新打开本地库；
  /// 2. 确保云端目录存在并上传临时副本；
  /// 3. 按 [keepVersions] 修剪云端历史备份（仅删除本应用格式的备份）。
  static Future<void> uploadBackup({
    required WebDavService dav,
    required String folder,
    required String userName,
    required int keepVersions,
  }) async {
    final dbPath = await AppPaths.userDatabasePath();
    final dbFile = File(dbPath);
    if (!await dbFile.exists()) {
      throw StateError('本地数据库不存在，无法上传');
    }
    final tempDir = await Directory.systemTemp.createTemp('narrchat_upload');
    try {
      final tempFile = File(p.join(tempDir.path, 'narrchat.db'));
      // 关闭后复制，保证副本一致；复制完立即重开。
      await DatabaseHelper.instance.close();
      try {
        await dbFile.copy(tempFile.path);
      } finally {
        await DatabaseHelper.instance.database;
      }

      await dav.ensureCollection(folder);
      final name = buildBackupFileName(userName, DateTime.now());
      await dav.put(folder, name, await tempFile.readAsBytes());

      // 修剪历史版本：保留最新 keepVersions 份。
      if (keepVersions > 0) {
        final backups = matchBackups(await dav.list(folder))
          ..sort(compareBackups);
        for (final f in backups.skip(keepVersions)) {
          try {
            await dav.delete(folder, f.name);
          } catch (_) {
            // 单个删除失败不阻塞整体上传结果。
          }
        }
      }
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // 临时目录清理失败可忽略。
      }
    }
  }

  /// 从云端下载指定备份到临时目录，返回临时文件路径（由调用方在应用后清理）。
  static Future<String> downloadBackup({
    required WebDavService dav,
    required String folder,
    required String name,
  }) async {
    final bytes = await dav.get(folder, name);
    final tempDir = await Directory.systemTemp.createTemp('narrchat_download');
    final file = File(p.join(tempDir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
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

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 替换文件名非法字符（`<>:"/\|?*` 与控制字符）为 `_`。
  static String _sanitizeFileName(String s) {
    final buffer = StringBuffer();
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      if (rune < 0x20 || r'<>:"/\|?*'.contains(ch)) {
        buffer.write('_');
      } else {
        buffer.write(ch);
      }
    }
    return buffer.toString();
  }
}
