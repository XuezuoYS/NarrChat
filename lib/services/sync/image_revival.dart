import '../../database/sync_dao.dart';

/// 图片"再添加复活"服务。
///
/// 用户先删图（写入 `sync_pending_del` 墓碑、云端删除传播），后又重新添加了
/// 同一张图（内容寻址哈希一致）：若保存得到的路径命中待推送删除墓碑，
/// 应立即移除墓碑、取消删除意图——否则下次同步会把这张"已复活"的图当删除传播丢到云端。
///
/// 接入点：图片导入 / 粘贴 / 拖拽保存成功后调用 [revive]。复活后的重传与
/// `manifest.deletedImages` 撤销由 `SyncService`（`ImageSyncPlanner.revived` 逻辑）完成。
abstract class ImageRevivalService {
  /// 若 [path] 命中待推送删除墓碑则移除并返回 true；未命中返回 false。
  Future<bool> revive(String path);
}

/// 真实实现：从 [SyncStateStore] 读墓碑并移除。
class SyncImageRevivalService implements ImageRevivalService {
  SyncImageRevivalService({SyncStateStore? store})
      : _store = store ?? SyncStateDao();

  final SyncStateStore _store;

  @override
  Future<bool> revive(String path) => reviveTombstonedImage(_store, path);
}

/// 纯逻辑：若 [path] 命中待推送删除墓碑（`sync_pending_del`）则移除并返回 true。
///
/// 独立为可测试函数：传入任意 [SyncStateStore] 替身即可验证命中 / 未命中 /
/// 移除墓碑三条路径。校验与移除在同一调用内完成。
Future<bool> reviveTombstonedImage(SyncStateStore store, String path) async {
  final pending = await store.getPendingDeletes();
  if (pending.any((d) => d.path == path)) {
    await store.removePendingDelete(path);
    return true;
  }
  return false;
}
