import '../../database/sync_store.dart';
import 'backup_manifest.dart';
import 'backup_remote.dart';
import 'backup_unit.dart';

/// 删除书籍后的云端处理。
///
/// 两种动作：
/// - [retainLatestRemoteBookSnapshot]：正常删除，云端只留最新同步的一代，
///   供「书籍回收站」还原；
/// - [purgeRemoteBook]：回收站里「彻底删除」，把该书的快照 / 清单 / 本机
///   同步单元全部清干净。
///
/// 只认 R3 命名：
/// - `manifest_narrbook_<uuid>.json`
/// - `narrbook_<uuid>_shot-g<N>.db`
///
/// 其它文件（library / mods / 别人的书 / 图片 / 墓碑文件）一律不碰：
/// 图片是共享资产池，书的删除不做引用回收（见 `backup_image_plane.dart`）。
///
/// 两个函数都可以重复调用：删除不存在的文件视为成功（[BackupRemote.delete]
/// 的约定），所以删除时先跑一次，之后每次数据面同步再按墓碑兜底。
class DeletedBookRetention {
  const DeletedBookRetention({this.keptSnapshotName, this.removed = 0});

  static const DeletedBookRetention empty = DeletedBookRetention();

  /// 保留下来的快照名；null = 云端本来就没有该书的快照。
  final String? keptSnapshotName;

  /// 本轮真正删掉的旧代快照数。
  final int removed;
}

/// 只保留一本已删除书籍在云端的**最新一代**快照。
///
/// - 按代数取最高的一代留下，其余代删掉；
/// - 删过旧代时顺带校验清单：清单指向保留代才留着，否则删掉，避免以后
///   还原/复活时同步去拉一个已经不存在的快照；
/// - 云端一个快照都没有时，残留清单与本机同步单元一起清掉（这本书没有
///   可还原的内容）；
/// - 有快照时保留 `sync.db` 单元，留住同步基线。
Future<DeletedBookRetention> retainLatestRemoteBookSnapshot({
  required BackupRemote remote,
  required String bookUuid,
  Iterable<String>? remoteNames,
  SyncStore? store,
}) async {
  final unit = BackupUnit.book(bookUuid);
  final names = (remoteNames ?? await remote.list()).toSet();
  final snapshots = [
    for (final name in names)
      if (BackupUnit.fromSnapshotName(name) == unit) name,
  ]..sort(_compareSnapshots);

  if (snapshots.isEmpty) {
    if (names.contains(unit.manifestName)) {
      await remote.delete(unit.manifestName);
    }
    await store?.removeUnit(unit.unitKey);
    return DeletedBookRetention.empty;
  }

  final kept = snapshots.first;
  var removed = 0;
  for (final name in snapshots.skip(1)) {
    await remote.delete(name);
    removed++;
  }

  if (removed > 0 && names.contains(unit.manifestName)) {
    var keepManifest = false;
    try {
      final manifest = BackupManifest.decode(
        await remote.read(unit.manifestName),
      );
      keepManifest = manifest.snapshotName == kept;
    } catch (_) {
      // 清单读不懂 / 损坏：删掉，别留下指向已删快照的坏指针。
    }
    if (!keepManifest) {
      await remote.delete(unit.manifestName);
    }
  }

  return DeletedBookRetention(keptSnapshotName: kept, removed: removed);
}

/// 彻底删除一本已删除书籍在云端的全部备份文件（清单 + 所有代快照）。
///
/// 用于「书籍回收站 → 彻底删除」：墓碑仍留在 `library` 里，用于继续向其它
/// 设备传播删除；这里只清云端内容与本机同步记录。
Future<int> purgeRemoteBook({
  required BackupRemote remote,
  required String bookUuid,
  Iterable<String>? remoteNames,
  SyncStore? store,
}) async {
  final unit = BackupUnit.book(bookUuid);
  final names = (remoteNames ?? await remote.list()).toSet();
  final targets = <String>{
    if (names.contains(unit.manifestName)) unit.manifestName,
    for (final name in names)
      if (BackupUnit.fromSnapshotName(name) == unit) name,
  };
  for (final name in targets) {
    await remote.delete(name);
  }
  // 书已经不存在了，本机记的「上次同步到哪一代」也一起清掉。
  await store?.removeUnit(unit.unitKey);
  return targets.length;
}

/// 快照从新到旧：先按代数降序，再按名字倒序（与备份列表同一套顺序）。
int _compareSnapshots(String a, String b) {
  final ga = BackupUnit.generationOfSnapshotName(a);
  final gb = BackupUnit.generationOfSnapshotName(b);
  if (ga != gb) return gb.compareTo(ga);
  return b.compareTo(a);
}
