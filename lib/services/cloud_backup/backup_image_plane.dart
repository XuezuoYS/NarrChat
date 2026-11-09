import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../sync/img_tombstones.dart';
import 'backup_remote.dart';

/// 图片平面同步结果。
class BackupImageReport {
  const BackupImageReport({
    this.uploaded = 0,
    this.pulled = 0,
    this.deleted = 0,
    this.error,
  });

  final int uploaded;
  final int pulled;
  final int deleted;
  final String? error;
}

/// 图片平面：云端图片目录（`<folder>/img/`，默认 `narrchat/img/`）与本地
/// `user_data/img/` 之间的双向同步。
///
/// 与数据单元的关系：数据单元是"整库快照"，图片是**共享资产池**——同一张图
/// 可能被多本书引用，所以必须独立同步，不能跟着某本书的快照走。
///
/// 云端位置由外面的 [remote] 决定：provider 会给它一个指向 `<folder>/img`
/// 的远端，所以图片与数据快照各在各的目录里，这里只管文件名。
///
/// 刻意**不做引用回收**：
/// - 删除只由墓碑驱动（用户明确删过才删云端）；
/// - 不做"云端没有被任何书引用的图就删掉"——跨设备时另一台可能正引用它，
///   而历史代引用的图也算引用。代价是云端可能残留孤儿图，换取不误删。
class BackupImagePlane {
  BackupImagePlane({
    required this.remote,
    required this.imagesDir,
    required this.tombstoneStore,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final BackupRemote remote;

  /// 本地图片目录绝对路径（`user_data/img`）。
  final String imagesDir;

  /// 墓碑（本机工作副本 + 云端文件）。
  final SyncTombstoneStore tombstoneStore;

  /// 云端墓碑文件名。
  static const String tombstoneFileName = 'img_tombstones.json';

  /// 图片平面只认这些扩展名。
  ///
  /// 图片已经有独立目录（`<folder>/img/`），理论上不会再有快照 / 清单混进来；
  /// 但仍然要筛：服务器上可能有手工放进去的杂项，也顺手兜住历史混放时期的残留。
  static const Set<String> imageExtensions = {'png', 'jpg', 'jpeg'};

  static bool isImageName(String name) =>
      imageExtensions.contains(p.extension(name).toLowerCase().replaceFirst('.', ''));

  final DateTime Function() _clock;

  Future<BackupImageReport> sync({bool Function()? isCancelled}) async {
    try {
      return await _sync(isCancelled: isCancelled);
    } on BackupRemoteException catch (error) {
      return BackupImageReport(error: error.message);
    } on FileSystemException catch (error) {
      return BackupImageReport(error: error.toString());
    }
  }

  Future<BackupImageReport> _sync({bool Function()? isCancelled}) async {
    // 图片面可能单独触发（只改了图，没动数据），所以自己把云端图片目录建出来。
    await remote.ensureReady();

    final now = _clock().toUtc();
    final nowMs = now.millisecondsSinceEpoch;

    final remoteNames = await remote.list();

    // 墓碑：本地工作副本 ∪ 云端文件，取并集后回写两端。
    final localTombstones = await tombstoneStore.load();
    ImgTombstones cloudTombstones = ImgTombstones.empty;
    if (remoteNames.contains(tombstoneFileName)) {
      final bytes = await remote.read(tombstoneFileName);
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, dynamic>) {
          cloudTombstones = ImgTombstones.fromJson(decoded);
        }
      } catch (_) {
        // 云端墓碑坏了不能连累图片同步：当作空，稍后整份覆盖回去。
        cloudTombstones = ImgTombstones.empty;
      }
    }
    final merged = mergeTombstones(
      local: localTombstones,
      cloud: cloudTombstones,
      now: nowMs,
    );
    final mergedJson = jsonEncode(merged.toJson());
    await tombstoneStore.save(merged);
    if (!remoteNames.contains(tombstoneFileName) ||
        utf8.decode(await remote.read(tombstoneFileName)) != mergedJson) {
      await remote.write(tombstoneFileName, utf8.encode(mergedJson));
    }

    // 真正"已删除"的路径：合并后仍在 entries 里的。
    final deletedNames = {
      for (final entry in merged.entries) p.basename(entry.path),
    };

    final localFiles = await _localImageNames();
    final localSet = localFiles.toSet();

    var uploaded = 0;
    var pulled = 0;
    var deleted = 0;

    // 1) 本地有、云端没有 → 上传
    for (final name in localFiles) {
      if (isCancelled?.call() ?? false) break;
      if (remoteNames.contains(name)) continue;
      final bytes = await File(p.join(imagesDir, name)).readAsBytes();
      await remote.write(name, bytes);
      uploaded++;
    }

    // 2) 云端有、本地没有、且没被删除 → 下载
    for (final name in remoteNames) {
      if (isCancelled?.call() ?? false) break;
      if (name == tombstoneFileName) continue;
      if (!isImageName(name)) continue; // 快照 / 清单不属于图片平面
      if (localSet.contains(name)) continue;
      if (deletedNames.contains(name)) continue;
      final bytes = await remote.read(name);
      await File(p.join(imagesDir, name)).writeAsBytes(bytes, flush: true);
      pulled++;
    }

    // 3) 已删除的图 → 删云端（本地那份如果还在，说明是复活，跳过）
    for (final name in deletedNames) {
      if (isCancelled?.call() ?? false) break;
      if (!remoteNames.contains(name)) continue;
      if (localSet.contains(name)) continue;
      await remote.delete(name);
      deleted++;
    }

    return BackupImageReport(
      uploaded: uploaded,
      pulled: pulled,
      deleted: deleted,
    );
  }

  /// 本地图片文件名列表（目录不存在时返回空）。
  Future<List<String>> _localImageNames() async {
    final dir = Directory(imagesDir);
    if (!await dir.exists()) return const [];
    final names = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!isImageName(name)) continue;
      names.add(name);
    }
    names.sort();
    return names;
  }
}
