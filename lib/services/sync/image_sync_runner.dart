import 'dart:typed_data';

import 'img_tombstones.dart';
import 'sync_image_planner.dart';
import 'sync_models.dart';
import 'sync_remote_store.dart';

/// 一次图片平面同步的结果。
///
/// 图片平面**没有代数概念**（[ImageSyncRunner] 结构上不触碰 manifest /
/// 快照），因此这里没有 generation/pushed 语义——只有"落了多少 blob、
/// 墓碑维护是否完成"。
class ImageSyncResult {
  /// 是否落地了任何 blob 动作（上传 / 拉取 / 删除传播）。
  final bool applied;

  final int uploaded;
  final int pulled;

  /// 云端 + 本机被删除传播的合计数（删除墓碑意图的落地量）。
  final int deleted;

  final String? error;

  const ImageSyncResult({
    this.applied = false,
    this.uploaded = 0,
    this.pulled = 0,
    this.deleted = 0,
    this.error,
  });
}

/// 图片平面同步执行器：锁 → 墓碑合并 → blob 收敛 → 墓碑回写 → 释放锁。
///
/// 与 [DatabaseSyncRunner] 完全独立（见 `sync_models.dart` 的 `SyncPlane`）：
/// - 只读写 `img/*` blob 与 `img_tombstones.json`（云端 + 本地工作副本）；
/// - **不读不写** manifest / 快照 / 共基 / 数据库——图片动作在结构上不可能
///   推进数据代数；
/// - 失败（如单张 blob 上传失败抛错）只影响本轮图片同步，下次触发重试，
///   不阻塞数据平面，反之亦然；
/// - 共享同一 [SyncRemoteStore]（同一 WebDAV 目录与跨设备软锁 `sync.lock`）。
///   同设备上的串行派发由 `SyncCoordinator` 单执行道保证。
class ImageSyncRunner {
  final SyncRemoteStore store;
  final String deviceId;

  /// 本地 `img/` 现存路径。
  final Future<List<String>> Function() localImages;

  final Future<Uint8List?> Function(String path) readLocalImage;
  final Future<void> Function(String path, Uint8List bytes) writeLocalImage;

  /// 删除本地 `img/` 下的图片文件（其它设备的删除传播；null 时跳过本地删除）。
  final Future<void> Function(String path)? deleteLocalImage;

  /// 图片删除墓碑工作副本（本地文件存取；云端镜像为 `img_tombstones.json`）。
  final SyncTombstoneStore tombstoneStore;

  final void Function(SyncProgressEvent)? onProgress;

  /// 协作式取消回调：返回 true 表示用户已请求取消本平面的同步，
  /// 在阶段之间与逐文件循环中检查；取消后提前返回（不回写墓碑，
  /// 本地工作副本保留离线改动，下次同步重放）。
  final bool Function()? isCancelled;

  /// 云端锁被占用时的重试间隔（测试可注入 [Duration.zero]）。
  final Duration lockRetryDelay;

  ImageSyncRunner({
    required this.store,
    required this.deviceId,
    required this.localImages,
    required this.readLocalImage,
    required this.writeLocalImage,
    required this.tombstoneStore,
    this.deleteLocalImage,
    this.onProgress,
    this.isCancelled,
    this.lockRetryDelay = const Duration(milliseconds: 400),
  });

  /// 执行一次图片同步：锁定 → 收敛 → 释放锁。
  Future<ImageSyncResult> sync() async {
    if (_cancelled) return const ImageSyncResult(error: '已取消');
    var lockHeld = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      lockHeld = await store.acquireLock(deviceId: deviceId);
      if (lockHeld) break;
      if (attempt < 2 && lockRetryDelay > Duration.zero) {
        await Future<void>.delayed(lockRetryDelay);
      }
    }
    if (!lockHeld) {
      return const ImageSyncResult(error: '另一台设备正在同步，请稍后重试');
    }
    try {
      return await _syncLocked();
    } on _Cancelled {
      // 逐文件循环中被取消：已完成的 blob 动作幂等，不回写墓碑
      //（本地工作副本保留离线改动，下次同步重放）。
      return const ImageSyncResult(error: '已取消');
    } finally {
      await store.releaseLock(deviceId: deviceId);
    }
  }

  Future<ImageSyncResult> _syncLocked() async {
    if (_cancelled) return const ImageSyncResult(error: '已取消');

    // —— 墓碑合并：云端文件 ⊕ 本地工作副本（并集 / 撤销 / 过期清除）——
    _emit(const SyncProgressEvent(
      phase: SyncPhase.tombstoneMerge,
      label: '合并删除墓碑…',
    ));
    final cloudImageFiles = await store.listImages();
    // 以「云端实际存在的 blob」为准（而非 manifest 声明）：历史版本或首次
    // 断连导致的缺失会被判定为 toUpload 自愈，图片收敛不依赖数据平面。
    final cloudTombstones =
        (await store.readImageTombstones()) ?? ImgTombstones.empty;
    final localTombstones = await tombstoneStore.load();
    final mergedTombstones = mergeTombstones(
      local: localTombstones,
      cloud: cloudTombstones,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    final plan = ImageSyncPlanner.plan(
      cloudImages: cloudImageFiles,
      localImages: await localImages(),
      tombstones: [for (final e in mergedTombstones.entries) e.path],
    );
    if (_cancelled) return const ImageSyncResult(error: '已取消');

    var pulled = 0, uploaded = 0, deleted = 0;

    // —— 拉取：云端有而本地缺 ——
    if (plan.toPull.isNotEmpty) {
      await store.ensureImagesFolder();
      pulled = await _forEach(
        plan.toPull,
        SyncPhase.pullImages,
        '下载图片',
        (p) async {
          final bytes = await store.readImage(p);
          if (bytes != null) await writeLocalImage(p, bytes);
        },
      );
    }

    // —— 删除传播（幂等）：云端 blob / 本机文件 ——
    deleted = await _forEach(
      plan.toDeleteCloud,
      SyncPhase.deleteImages,
      '清理云端图片',
      (p) => store.deleteImage(p),
    );
    final deleteLocal = plan.toDeleteLocal;
    if (deleteLocal.isNotEmpty && deleteLocalImage != null) {
      // 其它设备的删除意图 → 删除本机文件（即使仍被引用，剧情显示缺失）。
      deleted += await _forEach(
        deleteLocal,
        SyncPhase.deleteImages,
        '删除本机图片',
        (p) => deleteLocalImage!(p),
      );
    }

    // —— 上传：本地有而云端无 ——
    if (plan.toUpload.isNotEmpty) {
      await store.ensureImagesFolder();
      uploaded = await _forEach(
        plan.toUpload,
        SyncPhase.pushImages,
        '上传图片',
        (p) async {
          final bytes = await readLocalImage(p);
          if (bytes != null) await store.writeImage(p, bytes);
        },
      );
    }

    if (_cancelled) return const ImageSyncResult(error: '已取消');

    // —— 墓碑回写：与云端不一致（离线删除 / 复活标记 / 过期清除）时覆盖云端
    // 文件；本地工作副本刷新为合并结果（复活标记随副本保留至过期）。
    // 任何 blob 动作完成后都执行；取消路径已提前返回，不消费删除意图。
    await _persistTombstones(mergedTombstones, cloudTombstones);

    final applied = uploaded > 0 || pulled > 0 || deleted > 0;
    return ImageSyncResult(
      applied: applied,
      uploaded: uploaded,
      pulled: pulled,
      deleted: deleted,
    );
  }

  /// 逐文件执行（带进度与协作式取消），返回处理条数；取消时抛 [_Cancelled]
  /// 由外层收敛为「已取消」结果（云端已写入的部分动作幂等，下次重放）。
  Future<int> _forEach(
    List<String> paths,
    SyncPhase phase,
    String label,
    Future<void> Function(String path) run,
  ) async {
    for (var i = 0; i < paths.length; i++) {
      if (_cancelled) throw const _Cancelled();
      _emit(SyncProgressEvent(
        phase: phase,
        label: label,
        currentItem: i,
        totalItems: paths.length,
      ));
      await run(paths[i]);
    }
    return paths.length;
  }

  /// 回写墓碑：合并结果（条目 + 复活标记）与云端文件不一致时覆盖云端
  /// `img_tombstones.json`——复活标记必须上云传播，否则他机工作副本里的
  /// 陈旧条目会在下次并集合并时"复活"删除意图、反杀刚重新上传的 blob；
  /// 随后把本地工作副本刷新为合并结果（标记随副本保留至过期）。
  Future<void> _persistTombstones(
    ImgTombstones merged,
    ImgTombstones cloud,
  ) async {
    if (!_sameTombstones(merged, cloud)) {
      await store.writeImageTombstones(merged);
    }
    await tombstoneStore.save(merged);
  }

  /// 两份墓碑文件是否语义一致（条目与顺序无关按路径对齐比较；复活标记按
  /// 路径与时刻全等比较）。
  static bool _sameTombstones(ImgTombstones a, ImgTombstones b) {
    if (a.entries.length != b.entries.length) return false;
    for (final e in a.entries) {
      final matches = b.entries.where((x) => x.path == e.path).toList();
      if (matches.length != 1) return false;
      if (matches.single.deletedAt != e.deletedAt ||
          matches.single.expiresAt != e.expiresAt) {
        return false;
      }
    }
    if (a.revived.length != b.revived.length) return false;
    for (final e in a.revived.entries) {
      if (b.revived[e.key] != e.value) return false;
    }
    return true;
  }

  void _emit(SyncProgressEvent event) => onProgress?.call(event);

  bool get _cancelled => isCancelled?.call() ?? false;
}

/// 内部哨兵异常：图片逐文件循环中被取消。
class _Cancelled implements Exception {
  const _Cancelled();
}
