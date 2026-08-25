import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'image_store.dart';

/// 本地数据库信息（供「存储管理」展示 DB 路径 / 大小 / 修改时间）。
class StorageDbInfo {
  final String path;
  final int size;
  final DateTime modified;

  const StorageDbInfo({
    required this.path,
    required this.size,
    required this.modified,
  });
}

/// img 目录下一张本地图片的元信息。
class StorageImageInfo {
  final String relPath;
  final String name;
  final int size;
  final DateTime modified;

  const StorageImageInfo({
    required this.relPath,
    required this.name,
    required this.size,
    required this.modified,
  });
}

/// 存储管理服务（可注入替身）。
///
/// 抽象「本地数据库信息 / 列出图片（按修改时间）/ 导出数据库 / 删除单张图片」，
/// 供测试注入假实现，避免触碰真实数据库与真实图片目录。
abstract class StorageService {
  /// 本地数据库信息（不存在返回 null）。
  Future<StorageDbInfo?> dbInfo();

  /// 列出 `img/` 目录下全部图片，按修改时间倒序（最新在前）。
  Future<List<StorageImageInfo>> listImages();

  /// 把本地数据库复制到 [targetDirPath] 下的 [fileName]，返回目标文件绝对路径。
  ///
  /// 数据库不存在时抛 [StateError]。SQLite 若开启了 WAL，会一并复制
  /// `-wal` / `-shm` 伴生文件（保证导出副本的完整性）。
  Future<String> exportDatabase({
    required String targetDirPath,
    required String fileName,
  });

  /// 删除单张本地图片（相对路径）。
  Future<void> deleteImage(String relPath);

  /// 把 [relPaths] 对应的图片复制到 [targetDirPath] 文件夹，返回成功导出数量。
  Future<int> exportImages({
    required List<String> relPaths,
    required String targetDirPath,
  });
}

/// 真实实现：基于 [ImageStore]（img 目录）与 [AppPaths]（数据库路径）。
class LocalStorageService implements StorageService {
  /// [dbPathOverride] / [imgDirOverride] 仅供测试指定明确的文件系统位置；
  /// 运行时缺省走 [AppPaths] / [ImageStore]。
  LocalStorageService({this.dbPathOverride, this.imgDirOverride});

  /// 测试用的数据库路径覆盖。
  final String? dbPathOverride;

  /// 测试用的图片目录覆盖。
  final Directory? imgDirOverride;

  Future<String> _dbFilePath() async =>
      dbPathOverride ?? await AppPaths.userDatabasePath();

  Future<Directory> _imgDir() async =>
      imgDirOverride ?? await ImageStore.imgDirectory();

  @override
  Future<StorageDbInfo?> dbInfo() async {
    final path = await _dbFilePath();
    final file = File(path);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    return StorageDbInfo(path: path, size: stat.size, modified: stat.modified);
  }

  @override
  Future<List<StorageImageInfo>> listImages() async {
    final dir = await _imgDir();
    if (!await dir.exists()) return const [];
    final infos = <StorageImageInfo>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
      if (!ImageStore.allowedExtensions.contains(ext)) continue;
      final stat = await entity.stat();
      infos.add(
        StorageImageInfo(
          relPath: '${ImageStore.relativeDir}/$name',
          name: name,
          size: stat.size,
          modified: stat.modified,
        ),
      );
    }
    // 按修改时间倒序（最新在前）。
    infos.sort((a, b) => b.modified.compareTo(a.modified));
    return infos;
  }

  @override
  Future<String> exportDatabase({
    required String targetDirPath,
    required String fileName,
  }) async {
    final src = await _dbFilePath();
    final srcFile = File(src);
    if (!await srcFile.exists()) {
      throw StateError('数据库文件不存在');
    }
    final target = p.join(targetDirPath, fileName);
    await srcFile.copy(target);
    // SQLite 开启 WAL 时会生成 -wal / -shm 伴生文件；一并复制保证导出可恢复。
    await _copyIfExists('$src-wal', '$target-wal');
    await _copyIfExists('$src-shm', '$target-shm');
    return target;
  }

  @override
  Future<void> deleteImage(String relPath) async {
    final abs = await ImageStore.resolveAbsolute(relPath);
    final file = File(abs);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<int> exportImages({
    required List<String> relPaths,
    required String targetDirPath,
  }) async {
    var done = 0;
    for (final rel in relPaths) {
      try {
        final abs = await ImageStore.resolveAbsolute(rel);
        final src = File(abs);
        if (!await src.exists()) continue;
        await src.copy(p.join(targetDirPath, p.basename(abs)));
        done++;
      } catch (_) {
        // 单个图片失败（缺失/被占用等）跳过，不阻断整体导出。
      }
    }
    return done;
  }

  Future<void> _copyIfExists(String from, String to) async {
    final f = File(from);
    if (!await f.exists()) return;
    try {
      await f.copy(to);
    } catch (_) {
      // 伴生文件复制失败可忽略（主库已复制成功）。
    }
  }
}
