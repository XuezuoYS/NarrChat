/// 图片同步规划（内容寻址 + 全局删除传播）——**图片平面**唯一规划器。
///
/// 纯逻辑，不读写文件/网络。输入均为**内容寻址路径**（`img/<hash>.<ext>`）。
/// 图片平面无代数概念：不读不写 manifest / 快照，仅收敛 `img/*` blob 与
/// 墓碑文件（`img_tombstones.json`），因此也**不依赖数据库**（本地盘的镜像
/// 语义覆盖未入正文的图；「DB 引用集」只是数据平面 manifest.images 的展示项）。
///
/// 规则：
/// - **只靠显式删除**：图片仅在用户于图片库删除后才离开云端；删书不自动清图。
/// - **删除是全局意图**：[tombstones]（云端墓碑文件的合并结果）中的图片一律
///   按删除处理：删除云端 blob；其它设备收到墓碑后同时删除本地文件
///   （即使仍被引用——与图片库删除确认文案一致），且**不重新上传**。
/// - **重新添加复活**：不在本规划层处理——删除/导入流程直接在墓碑文件上
///   增删条目，同步合并（`img_tombstones.dart` 的 mergeTombstones）已把
///   本机重新添加的条目抵消，因此规划器收到的 `tombstones` 即最终删除意图。
class ImageSyncPlanner {
  ImageSyncPlanner._();

  /// 计算图片同步动作。
  ///
  /// - [cloudImages]：云端实际存在的 blob 路径；
  /// - [localImages]：本地 `img/` 目录现存路径；
  /// - [tombstones]：删除墓碑路径集合（云端墓碑文件合并后的最终意图）。
  static ImageSyncPlan plan({
    required List<String> cloudImages,
    required List<String> localImages,
    required List<String> tombstones,
  }) {
    final cloud = cloudImages.toSet();
    final local = localImages.toSet();
    final tombstonesSet = tombstones.toSet();

    final toUpload = <String>{};
    final toPull = <String>{};
    final toDeleteCloud = <String>{};
    final toDeleteLocal = <String>{};

    // 1. 墓碑：删除传播。**幂等**——只有云端 blob 仍存在时才计入「删除云端」，
    //    只有本机仍持有文件时才计入「删除本地」；已删除完成的图不再产生任何
    //    动作（否则墓碑条目保留一年，每次同步都会误判为有变更）。
    for (final t in tombstonesSet) {
      if (cloud.contains(t)) toDeleteCloud.add(t);
      if (local.contains(t)) toDeleteLocal.add(t);
    }

    // 2. push：本地有而云端无（未列入删除的）。
    for (final p in local) {
      if (toDeleteCloud.contains(p)) continue;
      if (!cloud.contains(p)) {
        toUpload.add(p);
      }
    }

    // 3. pull：云端有而本地缺，且未被墓碑删除。
    for (final p in cloud) {
      if (toDeleteCloud.contains(p)) continue;
      if (!local.contains(p)) {
        toPull.add(p);
      }
    }

    return ImageSyncPlan(
      toUpload: toUpload.toList(),
      toPull: toPull.toList(),
      toDeleteCloud: toDeleteCloud.toList(),
      toDeleteLocal: toDeleteLocal.toList(),
    );
  }
}

/// 图片同步动作结果。
class ImageSyncPlan {
  /// 需要推送到云端的图片路径（本地字节→云端 blob）。
  final List<String> toUpload;

  /// 需要从云端拉取到本地的图片路径。
  final List<String> toPull;

  /// 需要从云端删除的图片路径（删除传播）。
  final List<String> toDeleteCloud;

  /// 需要从本地 `img/` 删除的图片路径（其它设备的删除传播）。
  final List<String> toDeleteLocal;

  const ImageSyncPlan({
    required this.toUpload,
    required this.toPull,
    required this.toDeleteCloud,
    this.toDeleteLocal = const [],
  });

  /// 本轮是否存在需要落地的 blob 动作。
  bool get hasChanges =>
      toUpload.isNotEmpty ||
      toPull.isNotEmpty ||
      toDeleteCloud.isNotEmpty ||
      toDeleteLocal.isNotEmpty;
}
