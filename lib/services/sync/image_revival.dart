import 'img_tombstones.dart';

/// 图片"重新添加复活"服务。
///
/// 图片库删除是**全局语义**。用户删除后又重新添加了同一张图（内容寻址哈希一致）
/// 时，必须在墓碑文件（工作副本）上**删除对应条目记录**——否则下次同步会把
/// 这张"已复活"的图按删除传播丢到云端。
///
/// 接入点：图片导入 / 粘贴 / 拖拽保存成功后调用 [revive]。
/// 撤销是**全局语义**：登记带时间戳的 [ImgTombstones.revived] 标记，同步合并时
/// 凭标记抵消云端残留条目**与其它设备工作副本里的陈旧条目**（标记随云端文件
/// 传播），防止"复活在他端被陈旧墓碑反杀"。
abstract class ImageRevivalService {
  /// 图片内容落盘后调用：若 [path] 命中了墓碑条目则删除该条目并登记复活标记，
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
        // 复活时刻即撤销时刻：晚于（或等于）删除的标记抵消条目。
        revived: {
          ...current.revived,
          path: DateTime.now().millisecondsSinceEpoch,
        },
      ),
    );
    return true;
  }
}
