import '../../database/sync_store.dart';
import 'backup_remote.dart';
import 'backup_unit.dart';

/// 清掉一本**已删除**书籍在云端的全部备份文件（清单 + 所有代快照）。
///
/// 只认 R3 命名：
/// - `manifest_narrbook_<uuid>.json`
/// - `narrbook_<uuid>_shot-g<N>.db`
///
/// 其它文件（library / mods / 别人的书 / 图片 / 墓碑文件）一律不碰：
/// 图片是共享资产池，书的删除不做引用回收（见 `backup_image_plane.dart`）。
///
/// 删除不存在的文件视为成功（[BackupRemote.delete] 的约定），因此本函数
/// **可以重复调用**：删除时先删一遍，之后每次数据面同步再按墓碑兜底。
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
