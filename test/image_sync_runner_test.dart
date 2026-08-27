import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/image_sync_runner.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';
import 'package:narrchat/services/sync/sync_models.dart';

import 'helpers/fakes.dart';

/// **图片平面**执行器 [ImageSyncRunner] 端到端测试
///（不触碰真实网络 / 真库 / 真密钥库）：
/// - 显式删除 → 删除云端 blob、合并结果回写云端墓碑文件；
/// - 删除传播：读云端墓碑且本地仍有文件 → 云端 + 本机删除，不重新上传；
/// - 再添加复活 → 撤销抵消云端残留条目并重新上传；
/// - 过期条目 → 清除并回写；
/// - 缺失 blob 自愈补传；
/// - **结构保证：所有路径都不触碰 manifest / 快照（无代数概念）**。
ImageSyncRunner _runner(
  MemorySyncStore store,
  MemoryTombstoneStore tombstoneStore, {
  required List<String> local,
  Map<String, Uint8List> imageBytes = const {},
  List<String>? deletedLocal,
  bool Function()? isCancelled,
}) {
  return ImageSyncRunner(
    store: store,
    deviceId: 'dev-1',
    localImages: () async => local,
    readLocalImage: (p) async => imageBytes[p],
    writeLocalImage: (_, _) async {},
    deleteLocalImage: (p) async => deletedLocal?.add(p),
    tombstoneStore: tombstoneStore,
    isCancelled: isCancelled,
    lockRetryDelay: Duration.zero,
  );
}

/// 云端已有第 3 代数据（图片平面任何动作都不许改写它）。
const _manifestBase = SyncManifest(
  generation: 3,
  lastWriterDeviceId: 'dev-2',
  knownDevices: ['dev-2'],
  images: ['img/a.png'],
);

/// 构造带墓碑条目的状态（删除时间为当前时刻，条目不立即过期）。
ImgTombstones _withEntry(String path) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return ImgTombstones(entries: [ImgTombstoneEntry.deleted(path, now)]);
}

void main() {
  test('显式删除（本地工作副本含墓碑）→ 删除云端 blob、回写云端墓碑文件', () async {
    final store = MemorySyncStore()
      ..manifest = _manifestBase
      ..images['img/c.png'] = Uint8List.fromList([1, 2, 3]);
    // 图片库删除：本机工作副本登记了墓碑条目（云端文件尚无）。
    final tombstoneStore = MemoryTombstoneStore(_withEntry('img/c.png'));
    final runner = _runner(store, tombstoneStore, local: const []);

    final result = await runner.sync();

    expect(result.error, isNull);
    expect(result.applied, isTrue);
    expect(result.deleted, 1);
    expect(store.images.containsKey('img/c.png'), isFalse, reason: '云端 blob 被删除');
    // 删除意图持久化到云端墓碑文件（供其它设备传播），工作副本刷新为合并结果。
    expect(store.tombstones!.entries.single.path, 'img/c.png');
    expect(tombstoneStore.state.entries.single.path, 'img/c.png');
    expect(tombstoneStore.state.revoked, isEmpty);
  });

  test('图片平面从不触碰 manifest / 快照（无代数概念，结构保证）', () async {
    final store = MemorySyncStore()
      ..manifest = _manifestBase
      ..images['img/x.png'] = Uint8List.fromList([1]);
    final runner = _runner(store, MemoryTombstoneStore(), local: const ['img/y.png'], imageBytes: {
      'img/y.png': Uint8List.fromList([2]),
    });

    final before = store.manifest;
    final result = await runner.sync();

    expect(result.uploaded, 1, reason: '本地新增图已上传');
    expect(identical(store.manifest, before), isTrue, reason: 'manifest 原封不动');
    expect(store.snapshots, isEmpty, reason: '不写快照、不推进代数');
    expect(store.manifest!.generation, 3, reason: '代数保持原值');
  });

  test('删除完成后的再次同步：无任何变更 → 幂等（墓碑保留，无 blob 动作）', () async {
    final store = MemorySyncStore()
      ..manifest = _manifestBase
      // 上一轮同步已完成删除：blob 已删、墓碑文件已写入。
      ..tombstones = _withEntry('img/c.png');
    final tombstoneStore = MemoryTombstoneStore(_withEntry('img/c.png'));
    final runner = _runner(store, tombstoneStore, local: const []);

    final first = await runner.sync();
    expect(first.applied, isFalse);
    expect(first.error, isNull);

    // 排队补跑 / 手动再点一次同步：仍无任何动作，墓碑条目保留一年。
    final second = await runner.sync();
    expect(second.applied, isFalse);
    expect(store.manifest!.generation, 3, reason: '图片同步永不推进代数');
    expect(store.tombstones!.entries, hasLength(1));
  });

  test('删除传播：其它设备读云端墓碑且本地仍有文件 → 云端+本机删除，不重新上传', () async {
    final store = MemorySyncStore()
      ..manifest = _manifestBase
      ..images['img/a.png'] = Uint8List.fromList([1, 2, 3])
      ..tombstones = _withEntry('img/a.png');
    final tombstoneStore = MemoryTombstoneStore(
      // 本机工作副本 = 上次同步后的云端内容（含墓碑）。
      _withEntry('img/a.png'),
    );
    final deletedLocal = <String>[];
    final runner = _runner(
      store,
      tombstoneStore,
      // 本机文件仍存在（即使 DB 仍引用也会被删除——全局删除语义）。
      local: const ['img/a.png'],
      imageBytes: {'img/a.png': Uint8List.fromList([1, 2, 3])},
      deletedLocal: deletedLocal,
    );

    final result = await runner.sync();

    expect(result.error, isNull);
    expect(result.applied, isTrue);
    expect(store.images.containsKey('img/a.png'), isFalse,
        reason: '云端 blob 删除（幂等）');
    expect(deletedLocal, ['img/a.png'], reason: '删除传播到本机文件');
    expect(store.images.containsKey('img/a.png'), isFalse, reason: '不被重新上传');
    expect(store.tombstones!.entries.single.path, 'img/a.png',
        reason: '删除意图在墓碑文件中延续，不被撤销');
    expect(tombstoneStore.state.revoked, isEmpty);
  });

  test('再添加复活（本机撤销 + 云端残留条目）→ 抵消删除并重新上传', () async {
    final store = MemorySyncStore()
      ..manifest = _manifestBase
      ..tombstones = _withEntry('img/b.png');
    // 用户重新导入过同一张图：本地工作副本删除条目并记录撤销。
    final tombstoneStore = MemoryTombstoneStore(
      ImgTombstones(revoked: ['img/b.png']),
    );
    final runner = _runner(
      store,
      tombstoneStore,
      local: const ['img/b.png'],
      imageBytes: {'img/b.png': Uint8List.fromList([7, 8, 9])},
    );

    final result = await runner.sync();

    expect(result.error, isNull);
    expect(result.uploaded, 1);
    // 复活：重新上传云端 blob；合并结果（无残留条目）回写云端文件与工作副本。
    expect(store.images['img/b.png'], [7, 8, 9]);
    expect(store.tombstones!.entries, isEmpty);
    expect(tombstoneStore.state.entries, isEmpty);
    expect(tombstoneStore.state.revoked, isEmpty, reason: '撤销清单消费');
  });

  test('过期条目：同步时清除并回写云端墓碑文件（无 blob 动作）', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final store = MemorySyncStore()
      ..manifest = _manifestBase
      ..tombstones = ImgTombstones(entries: [
        ImgTombstoneEntry(
          path: 'img/old.png',
          deletedAt: now - ImgTombstoneEntry.ttlMillis - 1000,
          expiresAt: now - 1000,
        ),
        ImgTombstoneEntry.deleted('img/live.png', now),
      ]);
    final tombstoneStore = MemoryTombstoneStore(
      (await store.readImageTombstones()) ?? ImgTombstones.empty,
    );
    final runner = _runner(store, tombstoneStore, local: const []);

    final result = await runner.sync();

    // 过期清除只维护墓碑文件，不产生 blob 动作。
    expect(result.error, isNull);
    expect(result.applied, isFalse);
    expect(store.manifest!.generation, 3);
    expect(store.tombstones!.entries.single.path, 'img/live.png');
    expect(tombstoneStore.state.entries.single.path, 'img/live.png');
  });

  test('缺失 blob 自愈：manifest 声明图片但云端无 blob → 图片平面补传（代数不变）', () async {
    // 历史版本 / 断连导致 blob 从未上传：图片平面按"本地盘 ⊕ 实际云端清单"
    // 补传，数据平面与 manifest 全程不参与。
    final store = MemorySyncStore()
      ..manifest = _manifestBase; // manifest.images 声明 img/a.png，云端无 blob
    final runner = _runner(
      store,
      MemoryTombstoneStore(),
      local: const ['img/a.png'],
      imageBytes: {'img/a.png': Uint8List.fromList([9])},
    );

    final result = await runner.sync();

    expect(result.error, isNull);
    expect(result.uploaded, 1);
    expect(store.images['img/a.png'], [9]);
    expect(store.manifest!.generation, 3, reason: '补传不推进数据代数');
    expect(store.snapshots, isEmpty);
  });

  test('取消：立即中止（error=已取消），不读写云端、不消费墓碑', () async {
    final store = MemorySyncStore()
      ..manifest = _manifestBase
      ..images['img/c.png'] = Uint8List.fromList([1]);
    final tombstoneStore = MemoryTombstoneStore(_withEntry('img/c.png'));
    final runner = _runner(
      store,
      tombstoneStore,
      local: const [],
      isCancelled: () => true,
    );

    final result = await runner.sync();

    expect(result.error, '已取消');
    // 删除意图未被消费：云端 blob 与工作副本条目都在，下次同步重放。
    expect(store.images.containsKey('img/c.png'), isTrue);
    expect(store.tombstones, isNull);
    expect(tombstoneStore.state.entries.single.path, 'img/c.png');
  });

  test('远端锁被其它设备占用 → 失败但不影响数据平面（独立重试）', () async {
    final store = MemorySyncStore()
      ..lockedBy = 'dev-2'
      ..manifest = _manifestBase;
    final runner = _runner(store, MemoryTombstoneStore(), local: const []);

    final result = await runner.sync();

    expect(result.error, contains('另一台设备正在同步'));
    expect(store.manifest!.generation, 3);
  });
}
