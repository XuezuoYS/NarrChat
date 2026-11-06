import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/db_open.dart';
import '../database/db_schema.dart';
import '../database/migration/migration_paths.dart';
import 'app_stores.dart';
import 'image_store.dart';

/// 一个库文件的占用信息（R3 是多库，存储管理按"库"逐个展示）。
class StorageFileInfo {
  const StorageFileInfo({
    required this.id,
    required this.label,
    required this.path,
    required this.sizeBytes,
    required this.exists,
    this.modified,
  });

  /// 稳定标识：`library` / `mods` / `book:<uuid>` / `cache` / `sync` / `legacy-backup`。
  final String id;

  /// 展示名（书籍库用书名或 uuid 短号）。
  final String label;

  final String path;
  final int sizeBytes;
  final bool exists;
  final DateTime? modified;
}

/// 存储总览：各库 + 图片目录 + 合计。
class StorageOverview {
  const StorageOverview({
    required this.databases,
    required this.imageCount,
    required this.imageBytes,
    required this.bookCount,
  });

  /// 书籍目录库 / Mod 库 / 各书库 / 本地缓存库 / 本地同步库 / 旧版备份。
  final List<StorageFileInfo> databases;

  final int imageCount;
  final int imageBytes;
  final int bookCount;

  /// 全部库文件占用（含不存在的 0 字节项）。
  int get databaseBytes =>
      databases.fold<int>(0, (sum, file) => sum + file.sizeBytes);

  int get totalBytes => databaseBytes + imageBytes;

  /// 只保留真实存在的库文件（展示用）。
  List<StorageFileInfo> get existingDatabases =>
      databases.where((file) => file.exists).toList(growable: false);
}

/// img 目录下一张本地图片的元信息。
class StorageImageInfo {
  const StorageImageInfo({
    required this.relPath,
    required this.name,
    required this.size,
    required this.modified,
  });

  final String relPath;
  final String name;
  final int size;
  final DateTime modified;
}

/// 导入结果。失败也要有可见文案，不静默。
class StorageImportResult {
  const StorageImportResult({
    required this.ok,
    required this.message,
    this.backupPath,
    this.restoredFiles = 0,
    this.suggestRestart = false,
  });

  final bool ok;
  final String message;

  /// 落地前自动备份的目录（导入失败也能从这里手工救回来）。
  final String? backupPath;

  final int restoredFiles;

  /// 成功后是否建议重启应用。
  ///
  /// 数据库文件被整体替换了，但内存里的 provider / 仓储仍持着旧状态
  /// （书列表、当前书、轮次都在内存里），重开一次应用最稳。
  final bool suggestRestart;
}

/// 存储管理服务（可注入替身）。
///
/// R3 起"本地数据"不再是一个库，而是：
///
/// ```
/// user_data/narrchat_library.db
/// user_data/narrchat_mods.db
/// user_data/books/narrbook_<uuid>.db …
/// user_data/img/<hash>.<ext>
/// local_config/local_db/{sync.db, library_cache.db}
/// ```
///
/// 路径一律来自 [AppStores.paths]，**不允许自己拼**：书库文件名、目录结构
/// 只有 `MigrationPaths` / `AppPaths` 一处定义。
abstract class StorageService {
  /// 各库 + 图片目录的占用总览。
  Future<StorageOverview> overview();

  /// 列出 `img/` 目录下全部图片，按修改时间倒序（最新在前）。
  Future<List<StorageImageInfo>> listImages();

  /// 把 [relPaths] 对应的图片复制到 [targetDirPath] 文件夹，返回成功导出数量。
  Future<int> exportImages({
    required List<String> relPaths,
    required String targetDirPath,
  });

  /// 导出整组用户数据为 zip（`narrchat.zip`），返回目标文件绝对路径。
  ///
  /// 包含：library + mods + 全部书库 + `img/`；[includeLocalConfig] 为 true 时
  /// 额外带上 `local_config/`（设置 / 同步状态）。
  Future<String> exportArchive({
    required String targetDirPath,
    required String fileName,
    bool includeLocalConfig = false,
  });

  /// 导入整组用户数据。
  ///
  /// 流程固定：解到临时目录 → 校验清单与库版本 → **先备份现有 user_data**
  /// → 关闭书库连接 → 整组替换。任一步失败都返回带原因的失败结果。
  Future<StorageImportResult> importArchive({required String archivePath});

  /// 删除旧版（R2）备份文件 `narrchat.db.r2.bak`。
  Future<void> deleteLegacyBackup();
}

/// 真实实现：多库视角 + zip 导出导入。
class LocalStorageService implements StorageService {
  LocalStorageService({required this.stores, this.imgDirOverride});

  /// 存储装配根：从这里拿路径与书库连接池。
  final AppStores stores;

  /// 测试用图片目录覆盖（缺省 `user_data/img`）。
  final Directory? imgDirOverride;

  /// 导出包内的清单文件名（格式版本变更时改这里）。
  static const String manifestFileName = 'narrchat_export.json';

  /// 导出包格式版本（与数据库 schema 版本解耦）。
  static const int archiveFormatVersion = 1;

  MigrationPaths get _paths => stores.paths;

  Future<Directory> _imgDir() async =>
      imgDirOverride ?? Directory(p.join(_paths.userDataDir, 'img'));

  @override
  Future<StorageOverview> overview() async {
    final databases = <StorageFileInfo>[];

    databases.add(await _fileInfo(
      id: 'library',
      label: '书籍目录库',
      path: _paths.libraryDbPath,
    ));
    databases.add(await _fileInfo(
      id: 'mods',
      label: 'Mod 库',
      path: _paths.modsDbPath,
    ));

    var bookCount = 0;
    final booksDir = Directory(_paths.booksDir);
    if (await booksDir.exists()) {
      final files = <File>[];
      await for (final entity in booksDir.list(followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.db')) {
          files.add(entity);
        }
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        bookCount++;
        final name = p.basenameWithoutExtension(file.path);
        final uuid = name.startsWith('narrbook_')
            ? name.substring('narrbook_'.length)
            : name;
        final info = await _fileInfo(
          id: 'book:$uuid',
          label: '书库 ${_shortUuid(uuid)}',
          path: file.path,
        );
        databases.add(info);
      }
    }

    databases.add(await _fileInfo(
      id: 'cache',
      label: '本地缓存库',
      path: _paths.cacheDbPath,
    ));
    databases.add(await _fileInfo(
      id: 'sync',
      label: '本地备份状态库',
      path: _paths.syncDbPath,
    ));
    databases.add(await _fileInfo(
      id: 'legacy-backup',
      label: '旧版数据库备份（R2）',
      path: _paths.backupPath,
    ));

    final images = await listImages();
    final imageBytes = images.fold<int>(0, (sum, image) => sum + image.size);

    return StorageOverview(
      databases: databases,
      imageCount: images.length,
      imageBytes: imageBytes,
      bookCount: bookCount,
    );
  }

  Future<StorageFileInfo> _fileInfo({
    required String id,
    required String label,
    required String path,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      return StorageFileInfo(
        id: id,
        label: label,
        path: path,
        sizeBytes: 0,
        exists: false,
      );
    }
    final stat = await file.stat();
    return StorageFileInfo(
      id: id,
      label: label,
      path: path,
      sizeBytes: stat.size,
      exists: true,
      modified: stat.modified,
    );
  }

  static String _shortUuid(String uuid) =>
      uuid.length <= 8 ? uuid : uuid.substring(0, 8);

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
      infos.add(StorageImageInfo(
        relPath: '${ImageStore.relativeDir}/$name',
        name: name,
        size: stat.size,
        modified: stat.modified,
      ));
    }
    infos.sort((a, b) => b.modified.compareTo(a.modified));
    return infos;
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
        // 单张图片失败不阻断整体导出（缺失 / 被占用都很常见）。
      }
    }
    return done;
  }

  // ---------------------------------------------------------------------------
  // 导出（zip）
  // ---------------------------------------------------------------------------

  @override
  Future<String> exportArchive({
    required String targetDirPath,
    required String fileName,
    bool includeLocalConfig = false,
  }) async {
    final name = fileName.toLowerCase().endsWith('.zip')
        ? fileName
        : '$fileName.zip';
    final target = File(p.join(targetDirPath, name));
    await Directory(targetDirPath).create(recursive: true);
    if (await target.exists()) {
      await target.delete();
    }

    final encoder = ZipFileEncoder();
    encoder.create(target.path);
    try {
      await _addUserData(encoder);
      if (includeLocalConfig) {
        await _addDirectory(
          encoder,
          Directory(_paths.localConfigDir),
          'local_config',
        );
      }
      await _addManifest(encoder);
    } finally {
      await encoder.close();
    }
    return target.path;
  }

  Future<void> _addUserData(ZipFileEncoder encoder) async {
    await _addFileIfExists(encoder, _paths.libraryDbPath, _archiveUserDataPath);
    await _addFileIfExists(encoder, _paths.modsDbPath, _archiveUserDataPath);

    final booksDir = Directory(_paths.booksDir);
    if (await booksDir.exists()) {
      await for (final entity in booksDir.list(followLinks: false)) {
        if (entity is! File) continue;
        await encoder.addFile(
          entity,
          p.posix.join(_archiveUserDataPath, 'books', p.basename(entity.path)),
        );
      }
    }

    final imgDir = await _imgDir();
    if (await imgDir.exists()) {
      await for (final entity in imgDir.list(followLinks: false)) {
        if (entity is! File) continue;
        await encoder.addFile(
          entity,
          p.posix.join(_archiveUserDataPath, 'img', p.basename(entity.path)),
        );
      }
    }
  }

  Future<void> _addFileIfExists(
    ZipFileEncoder encoder,
    String path,
    String archiveDir,
  ) async {
    final file = File(path);
    if (!await file.exists()) return;
    await encoder.addFile(file, p.posix.join(archiveDir, p.basename(path)));
  }

  Future<void> _addDirectory(
    ZipFileEncoder encoder,
    Directory dir,
    String archiveDir,
  ) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: dir.path);
      final archivePath = p.posix.join(
        archiveDir,
        p.posix.joinAll(p.split(relative)),
      );
      await encoder.addFile(entity, archivePath);
    }
  }

  /// 清单最后写入：它记录"这个包是什么"，读导入时先校验它。
  Future<void> _addManifest(ZipFileEncoder encoder) async {
    final files = await overview();
    final manifest = <String, Object?>{
      'formatVersion': archiveFormatVersion,
      'schemaVersion': userDataDbVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': 'v3',
      'bookCount': files.bookCount,
      'imageCount': files.imageCount,
      'databaseBytes': files.databaseBytes,
      'imageBytes': files.imageBytes,
    };
    final temp = File(
      p.join(Directory.systemTemp.path, 'narrchat_manifest_${DateTime.now().microsecondsSinceEpoch}.json'),
    );
    await temp.writeAsString(jsonEncode(manifest), flush: true);
    try {
      await encoder.addFile(temp, manifestFileName);
    } finally {
      if (await temp.exists()) {
        await temp.delete();
      }
    }
  }

  static const String _archiveUserDataPath = 'user_data';

  // ---------------------------------------------------------------------------
  // 导入（zip）
  // ---------------------------------------------------------------------------

  @override
  Future<StorageImportResult> importArchive({required String archivePath}) async {
    final archive = File(archivePath);
    if (!await archive.exists()) {
      return const StorageImportResult(ok: false, message: '所选文件不存在。');
    }
    Directory? staging;
    try {
      staging = await Directory.systemTemp.createTemp('narrchat_import_');
      await extractFileToDisk(archive.path, staging.path);

      final manifestFile = File(p.join(staging.path, manifestFileName));
      if (!await manifestFile.exists()) {
        return const StorageImportResult(
          ok: false,
          message: '这不是 NarrChat 的导出包（缺少 $manifestFileName）。',
        );
      }
      final manifest = jsonDecode(await manifestFile.readAsString());
      if (manifest is! Map) {
        return const StorageImportResult(ok: false, message: '导出包清单损坏，无法识别。');
      }
      final format = (manifest['formatVersion'] as num?)?.toInt() ?? 0;
      if (format != archiveFormatVersion) {
        return StorageImportResult(
          ok: false,
          message: '导出包格式版本不支持（包内 $format，当前 $archiveFormatVersion）。',
        );
      }
      final schema = (manifest['schemaVersion'] as num?)?.toInt() ?? 0;
      if (schema != userDataDbVersion) {
        return StorageImportResult(
          ok: false,
          message: '导出包数据库版本不匹配（包内 $schema，当前 $userDataDbVersion）。'
              '3.0 不做向下兼容，请使用同版本导出的包。',
        );
      }

      final incoming = Directory(p.join(staging.path, _archiveUserDataPath));
      if (!await incoming.exists()) {
        return const StorageImportResult(ok: false, message: '导出包里没有 user_data 目录。');
      }
      final libraryFile = File(p.join(incoming.path, 'narrchat_library.db'));
      if (!await libraryFile.exists()) {
        return const StorageImportResult(ok: false, message: '导出包里缺少书籍目录库。');
      }
      final libraryVersion = await _readUserVersionOf(libraryFile.path);
      if (libraryVersion != userDataDbVersion) {
        return StorageImportResult(
          ok: false,
          message: '书籍目录库版本是 $libraryVersion，当前应用需要 $userDataDbVersion。',
        );
      }

      // 落地前先备份：失败也能从 backupPath 手工恢复。
      final backupPath = await _backupCurrentUserData();
      await _closeAllConnections();
      final restored = await _replaceUserData(incoming);

      return StorageImportResult(
        ok: true,
        message: '导入完成：$restored 个文件已落地。',
        backupPath: backupPath,
        restoredFiles: restored,
        suggestRestart: true,
      );
    } on FileSystemException catch (error) {
      return StorageImportResult(ok: false, message: '导入失败（文件操作）：$error');
    } on FormatException catch (error) {
      return StorageImportResult(ok: false, message: '导入失败（压缩包损坏）：$error');
    } catch (error) {
      return StorageImportResult(ok: false, message: '导入失败：$error');
    } finally {
      if (staging != null && await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {
          // 临时目录删不掉不影响导入结论。
        }
      }
    }
  }

  /// 读一个库文件的 `user_version`（只读打开，不改动文件）。
  Future<int> _readUserVersionOf(String path) async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      return await readUserVersion(db);
    } finally {
      await db.close();
    }
  }

  /// 关掉全部库连接。
  ///
  /// Windows 上删不掉"正被进程打开"的文件，而导入要整目录替换 `user_data`，
  /// 所以书库连接池与四个库连接都必须先关。四个库的 `close()` 都会把内部句柄
  /// 置空，下次访问时自动重开，因此不用在这里做"替换后再打开"的配对操作。
  Future<void> _closeAllConnections() async {
    await stores.books.closeAll();
    await stores.library.close();
    await stores.mods.close();
    await stores.cache.close();
    await stores.sync.close();
  }

  /// 把现有 `user_data` 整目录复制到带时间戳的备份目录，返回其路径。
  Future<String?> _backupCurrentUserData() async {
    final source = Directory(_paths.userDataDir);
    if (!await source.exists()) return null;
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final target = Directory('${_paths.userDataDir}.import-backup-$stamp');
    await _copyDirectory(source, target);
    return target.path;
  }

  /// 用解出来的 user_data 覆盖现有数据，返回落地文件数。
  Future<int> _replaceUserData(Directory incoming) async {
    final target = Directory(_paths.userDataDir);
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    await target.create(recursive: true);
    return _copyDirectory(incoming, target);
  }

  Future<int> _copyDirectory(Directory source, Directory target) async {
    var count = 0;
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: source.path);
      final destination = p.join(target.path, relative);
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(destination)).create(recursive: true);
        await entity.copy(destination);
        count++;
      }
    }
    return count;
  }

  @override
  Future<void> deleteLegacyBackup() async {
    final file = File(_paths.backupPath);
    if (!await file.exists()) return;
    await file.delete();
  }
}
