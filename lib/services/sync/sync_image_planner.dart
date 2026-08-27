/// 图片同步规划（内容寻址 + 显式删除传播 + "再添加复活"）。
///
/// 纯逻辑，不读写文件/网络。输入均为**内容寻址路径**（`img/<hash>.<ext>`）。
///
/// 规则：
/// - **只靠显式删除**：图片仅在用户于图片管理删除后才离开云端；删书不自动清图。
/// - **删除传播**：[tombstones]（`manifest.deletedImages` + 本地待推送删除）中的图片，
///   只要**当前快照不再引用**，就应在云端删除并推广到其它设备；
/// - **再添加复活（不被"吃掉"）**：若某删除图**当前快照重新引用**（即被导入复活），
///   则撤销该墓碑、重新上传该 blob、并从删除列表移除。
class ImageSyncPlanner {
  ImageSyncPlanner._();

  /// 计算图片同步动作。
  ///
  /// - [referencedImages]：当前快照（DB）实际引用的图片路径（存活集）；
  /// - [cloudImages]：manifest 里云端应存在的图片路径；
  /// - [localImages]：本地 `img/` 目录现存路径；
  /// - [tombstones]：删除墓碑路径集合。
  static ImageSyncPlan plan({
    required List<String> referencedImages,
    required List<String> cloudImages,
    required List<String> localImages,
    required List<String> tombstones,
  }) {
    final referenced = referencedImages.toSet();
    final cloud = cloudImages.toSet();
    final local = localImages.toSet();
    final tombstonesSet = tombstones.toSet();

    final toUpload = <String>{};
    final toPull = <String>{};
    final toDeleteCloud = <String>{};
    final revived = <String>{};

    // 1. 处理墓碑：被重新引用→复活；否则→删除云端。
    for (final t in tombstonesSet) {
      if (referenced.contains(t)) {
        revived.add(t);
        // 复活：需要上云（若本地有字节）或保留引用。
        if (local.contains(t)) toUpload.add(t);
      } else {
        toDeleteCloud.add(t);
      }
    }

    // 2. push：本地有而云端无（非将删除的），或复活项。
    for (final p in local) {
      if (toDeleteCloud.contains(p)) continue;
      if (!cloud.contains(p) || revived.contains(p)) {
        toUpload.add(p);
      }
    }

    // 3. pull：云端有而本地无，且未被墓碑删除、也未被删除。
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
      revived: revived.toList(),
    );
  }
}

/// 图片同步动作结果。
class ImageSyncPlan {
  /// 需要推送到云端的图片路径（本地字节→云端 blob）。
  final List<String> toUpload;

  /// 需要从云端拉取到本地的图片路径。
  final List<String> toPull;

  /// 需要从云端删除的图片路径（被显式删除且未被重新引用）。
  final List<String> toDeleteCloud;

  /// 被"再添加"复活、应撤销的墓碑路径。
  final List<String> revived;

  const ImageSyncPlan({
    required this.toUpload,
    required this.toPull,
    required this.toDeleteCloud,
    required this.revived,
  });
}
