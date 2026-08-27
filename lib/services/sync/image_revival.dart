import 'img_tombstones.dart';

/// 图片"重新添加复活"服务。
///
/// 图片库删除是**全局语义**。用户删除后又重新添加了同一张图（内容寻址哈希一致）
/// 时，必须在墓碑文件（工作副本）上**删除对应条目记录**——否则下次同步会把
/// 这张"已复活"的图按删除传播丢到云端。
///
/// 接入点：图片导入 / 粘贴 / 拖拽保存成功后调用 [revive]。
/// 条目撤销在同步合并时（`img_tombstones.mergeTombstones`）凭 [ImgTombstones.revoked]
/// 抵消云端残留条目，防止"云端仍存旧条目 → 复活被覆盖"。
abstract class ImageRevivalService {
  /// 图片内容落盘后调用：若 [path] 命中了墓碑条目则删除该条目并记录撤销，
  /// 返回 true；未命中返回 false。
  Future<bool> revive(String path);
}

/// 真实实现：读写 [SyncTombstoneStore] 墓碑工作副本。
class SyncImageRevivalService implements ImageRevivalService {
  SyncImageRevivalService({SyncTombstoneStore? store})
      : _store = store ?? FileTombstoneStore();

  final SyncTombstoneStore _store;

  @override
  Future<bool> revive(String path) async {
    final current = await _store.load();
    final hasEntry = current.entries.any((e) => e.path == path);
    if (!hasEntry) return false;
    await _store.save(
      ImgTombstones(
        entries: List.of(current.entries)..removeWhere((e) => e.path == path),
        revoked: {...current.revoked, path}.toList(),
      ),
    );
    return true;
  }
}
