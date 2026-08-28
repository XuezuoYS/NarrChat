import 'dart:io';

import '../image_store.dart';
import 'img_tombstones.dart';

/// 图片"删除"服务（图片库删除入口）。
///
/// 图片库删除是**全局语义**（不进入数据库）：删除本机文件的同时，
/// 在墓碑工作副本（[SyncTombstoneStore]，`local_config/img_tombstones.json`）
/// 添加条目并写入**过期日期**（删除时间 + 一年）。下次同步把工作副本合并进
/// 云端 `img_tombstones.json`：删除云端 blob、向其它设备传播删除
/// （其它设备收到墓碑后删除本地文件，即使仍被引用——与图片库删除确认文案一致）。
abstract class ImageDeletionService {
  /// 删除 [relPath]（内容寻址相对路径）：删除本机文件并登记删除墓碑条目。
  Future<void> delete(String relPath);
}

/// 真实实现：基于 [ImageStore]（本机文件）与 [SyncTombstoneStore]（墓碑工作副本）。
class SyncImageDeletionService implements ImageDeletionService {
  SyncImageDeletionService({SyncTombstoneStore? store})
      : _store = store ?? FileTombstoneStore();

  final SyncTombstoneStore _store;

  @override
  Future<void> delete(String relPath) async {
    final abs = await ImageStore.resolveAbsolute(relPath);
    final file = File(abs);
    if (await file.exists()) await file.delete();

    final current = await _store.load();
    // 删除必晚于既有复活标记（同一毫秒 / 时钟回摆时抬升 1ms）：
    // 「最后一次操作为准」由时间戳严格性保证，复活标记原样保留（更晚的
    // 删除天然不被其抵消，无需清除）。
    final now = DateTime.now().millisecondsSinceEpoch;
    final revivedAt = current.revived[relPath] ?? -1;
    final deletedAt = now > revivedAt ? now : revivedAt + 1;
    final byPath = <String, ImgTombstoneEntry>{
      for (final e in current.entries) e.path: e,
    };
    // 重复删除同图：刷新删除时间与过期时间。
    byPath[relPath] = ImgTombstoneEntry.deleted(relPath, deletedAt);
    await _store.save(
      ImgTombstones(entries: byPath.values.toList(), revived: current.revived),
    );
  }
}
