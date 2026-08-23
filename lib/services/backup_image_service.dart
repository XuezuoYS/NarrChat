import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'webdav_service.dart';

/// 图片目录 WebDAV 备份（与数据库 `.db` 备份相互独立）。
///
/// 把 `user_data/img/` 打成一个 zip，按「[图片备份文件名] + 保留版本数」上传 /
/// 下载恢复；进度通过 [onProgress] 汇报（`progress` 为 null 表示不确定阶段）。
class BackupImageService {
  BackupImageService._();

  /// 图片备份文件名：`img_<user>_<yyyyMMdd-HHmmss>.zip`。
  static String buildImageBackupFileName(String userName, DateTime time) {
    final safe = _sanitizeFileName(userName.trim());
    final u = safe.isEmpty ? 'user' : safe;
    final ts =
        '${time.year}${_two(time.month)}${_two(time.day)}'
        '_${_two(time.hour)}${_two(time.minute)}${_two(time.second)}';
    return 'img_${u}_$ts.zip';
  }

  static final RegExp backupNameRegex = RegExp(
    r'^img_[^/]+_\d{8}_\d{6}\.zip$',
  );

  /// 从服务器文件列表筛出本应用的图片备份。
  static List<WebDavFile> matchImageBackups(List<WebDavFile> files) {
    return files.where((f) => backupNameRegex.hasMatch(f.name)).toList();
  }

  /// 备份排序：修改时间新 → 旧；均无时按文件名倒序（文件内含时间戳）。
  static int compareBackups(WebDavFile a, WebDavFile b) {
    final am = a.lastModified;
    final bm = b.lastModified;
    if (am != null && bm != null && am != bm) return bm.compareTo(am);
    if (am != null) return -1;
    if (bm != null) return 1;
    return b.name.compareTo(a.name);
  }

  /// 上传：把 `img/` 打 zip → 上传 → 按 [keepVersions] 修剪历史图片备份。
  ///
  /// 若无图片则抛 [StateError]（提示「暂无图片可备份」）。
  static Future<void> uploadImageBackup({
    required WebDavService dav,
    required String folder,
    required String userName,
    required int keepVersions,
    void Function(double? progress, String message)? onProgress,
  }) async {
    final imgDir = await _imgDir();
    final files = imgDir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();
    if (files.isEmpty) {
      throw StateError('暂无图片可备份');
    }
    onProgress?.call(null, '打包图片…');
    final zipBytes = await _zipDir(imgDir, files, onProgress);

    await dav.ensureCollection(folder);
    onProgress?.call(0.95, '上传中…');
    final name = buildImageBackupFileName(userName, DateTime.now());
    await dav.put(folder, name, zipBytes);
    onProgress?.call(1, '上传完成');

    if (keepVersions > 0) {
      final backups = matchImageBackups(await dav.list(folder))
        ..sort(compareBackups);
      for (final f in backups.skip(keepVersions)) {
        try {
          await dav.delete(folder, f.name);
        } catch (_) {
          // 单个删除失败不阻断整体结果。
        }
      }
    }
  }

  /// 下载指定图片备份 zip 并解压到本地 `img/`（替换）。
  static Future<void> downloadImageBackup({
    required WebDavService dav,
    required String folder,
    required String name,
    void Function(double? progress, String message)? onProgress,
  }) async {
    onProgress?.call(null, '下载中…');
    final zipBytes = await dav.get(folder, name);
    onProgress?.call(0.5, '解压中…');
    await _extractZipToImgDir(zipBytes, onProgress);
    onProgress?.call(1, '应用完成');
  }

  static Future<Directory> _imgDir() async {
    final userData = await AppPaths.userData();
    final dir = Directory(p.join(userData.path, 'img'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<Uint8List> _zipDir(
    Directory imgDir,
    List<File> files,
    void Function(double? progress, String message)? onProgress,
  ) async {
    final archive = Archive();
    var total = 0;
    for (final f in files) {
      total += await f.length();
    }
    var read = 0;
    for (final f in files) {
      final rel = p.relative(f.path, from: imgDir.path);
      final bytes = await f.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
      read += bytes.length;
      onProgress?.call(total == 0 ? null : read / total, '打包图片…');
    }
    final encoder = ZipEncoder();
    return Uint8List.fromList(encoder.encode(archive));
  }

  static Future<void> _extractZipToImgDir(
    Uint8List zipBytes,
    void Function(double? progress, String message)? onProgress,
  ) async {
    final imgDir = await _imgDir();
    // 清空旧图片再解压（替换语义）。
    for (final entity in imgDir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {
          // 忽略单个删除失败。
        }
      }
    }
    final archive = ZipDecoder().decodeBytes(zipBytes);
    var done = 0;
    for (final entry in archive.files) {
      if (entry.isFile && !entry.isDirectory) {
        final target = File(p.join(imgDir.path, entry.name));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(entry.content, flush: true);
      }
      done++;
      onProgress?.call(
        archive.files.isEmpty ? null : done / archive.files.length,
        '解压中…',
      );
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

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
