import 'sync_merge_planner.dart';

/// 把三向部件级规划结果翻译成语义化的"数据同步动作"清单（**仅数据平面**）。
///
/// 供 `DatabaseSyncRunner` 消费：它只描述"要做哪些 pull/push/conflict/删除"，
/// 不读写库/网络。清单一律以 **uuid** 标识目标对象（跨设备身份），
/// 落地层负责 uuid → 本地行 的映射（必要时回退 title/name）。
/// 图片 blob / 墓碑属独立图片平面（见 `sync_image_planner.dart`），
/// 不进入本清单——从结构上保证图片动作不可能推进数据代数。
class SyncActionPlanner {
  SyncActionPlanner._();

  static SyncAction plan({required SyncMergePlan mergePlan}) {
    final pullBooks = <String>{};
    final pushBooks = <String>{};
    final conflictBooks = <String>{};
    final deleteLocalBooks = <String>{};
    final deleteRemoteBooks = <String>{};

    for (final b in mergePlan.books) {
      switch (b.presence) {
        case SyncBookPresence.localOnly:
          if (b.localUuid != null) pushBooks.add(b.localUuid!);
        case SyncBookPresence.remoteOnly:
          if (b.remoteUuid != null) pullBooks.add(b.remoteUuid!);
        case SyncBookPresence.deletedOnRemote:
          if (b.localUuid != null) deleteLocalBooks.add(b.localUuid!);
        case SyncBookPresence.deletedOnLocal:
          if (b.remoteUuid != null) deleteRemoteBooks.add(b.remoteUuid!);
        case SyncBookPresence.deletionConflict:
          if (b.localUuid != null) conflictBooks.add(b.localUuid!);
          if (b.remoteUuid != null) conflictBooks.add(b.remoteUuid!);
        case SyncBookPresence.both:
          if (b.hasConflict) {
            if (b.localUuid != null) conflictBooks.add(b.localUuid!);
            if (b.remoteUuid != null) conflictBooks.add(b.remoteUuid!);
          } else {
            if (_hasLocalChange(b) && b.localUuid != null) {
              pushBooks.add(b.localUuid!);
            }
            if (_hasRemoteChange(b) && b.remoteUuid != null) {
              pullBooks.add(b.remoteUuid!);
            }
          }
        case SyncBookPresence.none:
          break;
      }
    }

    final pushMods = <String>{};
    final pullMods = <String>{};
    final conflictMods = <String>{};
    final deleteRemoteMods = <String>{};
    final deleteLocalMods = <String>{};
    for (final m in mergePlan.mods) {
      switch (m.status) {
        case SyncModStatus.localOnly:
          if (m.localUuid != null) pushMods.add(m.localUuid!);
        case SyncModStatus.remoteOnly:
          if (m.remoteUuid != null) pullMods.add(m.remoteUuid!);
        case SyncModStatus.conflict:
          if (m.localUuid != null) conflictMods.add(m.localUuid!);
          if (m.remoteUuid != null) conflictMods.add(m.remoteUuid!);
        case SyncModStatus.deletedOnLocal:
          if (m.remoteUuid != null) deleteRemoteMods.add(m.remoteUuid!);
        case SyncModStatus.deletedOnRemote:
          if (m.localUuid != null) deleteLocalMods.add(m.localUuid!);
        case SyncModStatus.deletionConflict:
          if (m.localUuid != null) conflictMods.add(m.localUuid!);
          if (m.remoteUuid != null) conflictMods.add(m.remoteUuid!);
        case SyncModStatus.unchanged:
        case SyncModStatus.absent:
          break;
      }
    }

    return SyncAction(
      pullBookUuids: pullBooks.toList(),
      pushBookUuids: pushBooks.toList(),
      conflictBookUuids: conflictBooks.toList(),
      deleteLocalBookUuids: deleteLocalBooks.toList(),
      deleteRemoteBookUuids: deleteRemoteBooks.toList(),
      pushModUuids: pushMods.toList(),
      pullModUuids: pullMods.toList(),
      conflictModUuids: conflictMods.toList(),
      deleteRemoteModUuids: deleteRemoteMods.toList(),
      deleteLocalModUuids: deleteLocalMods.toList(),
    );
  }

  static bool _hasLocalChange(BookSyncDecision b) =>
      b.settings == SyncPartStatus.localOnly ||
      b.rounds == SyncPartStatus.localOnly ||
      b.worldBook == SyncPartStatus.localOnly ||
      b.bookMods == SyncPartStatus.localOnly;

  static bool _hasRemoteChange(BookSyncDecision b) =>
      b.settings == SyncPartStatus.remoteOnly ||
      b.rounds == SyncPartStatus.remoteOnly ||
      b.worldBook == SyncPartStatus.remoteOnly ||
      b.bookMods == SyncPartStatus.remoteOnly;
}

/// 一次数据同步的语义化动作清单（uuid 标识；图片平面不在此列）。
class SyncAction {
  final List<String> pullBookUuids;
  final List<String> pushBookUuids;
  final List<String> conflictBookUuids;
  final List<String> deleteLocalBookUuids;
  final List<String> deleteRemoteBookUuids;
  final List<String> pushModUuids;
  final List<String> pullModUuids;
  final List<String> conflictModUuids;
  final List<String> deleteRemoteModUuids;
  final List<String> deleteLocalModUuids;

  const SyncAction({
    required this.pullBookUuids,
    required this.pushBookUuids,
    required this.conflictBookUuids,
    required this.deleteLocalBookUuids,
    required this.deleteRemoteBookUuids,
    required this.pushModUuids,
    required this.pullModUuids,
    required this.conflictModUuids,
    required this.deleteRemoteModUuids,
    required this.deleteLocalModUuids,
  });

  /// 是否存在任何需要落地的**数据**变更（图片平面不在此列）。
  bool get hasChanges =>
      pullBookUuids.isNotEmpty ||
      pushBookUuids.isNotEmpty ||
      conflictBookUuids.isNotEmpty ||
      deleteLocalBookUuids.isNotEmpty ||
      deleteRemoteBookUuids.isNotEmpty ||
      pushModUuids.isNotEmpty ||
      pullModUuids.isNotEmpty ||
      conflictModUuids.isNotEmpty ||
      deleteRemoteModUuids.isNotEmpty ||
      deleteLocalModUuids.isNotEmpty;

  bool get hasConflict =>
      conflictBookUuids.isNotEmpty || conflictModUuids.isNotEmpty;
}
