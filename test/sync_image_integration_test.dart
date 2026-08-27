import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/sync_dao.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/sync/sync_service.dart';

import 'helpers/fakes.dart';

/// `SyncService` 图片同步端到端（不触碰真实网络 / 真库 / 真密钥库）：
/// - 显式删除 → 删除云端并写入墓碑文件：
///   本地工作副本含墓碑条目 → 同步删除云端 blob、合并结果回写云端文件；
/// - 删除传播到其它设备：
///   其它设备读云端墓碑文件且本地仍有文件 → 删除云端（幂等）并删除本地文件，
///   即使仍被引用也不重新上传；
/// - 再添加复活 → 重传：
///   本机撤销条目（revoked）→ 同步合并抵消云端残留条目并重新上传。
const _localSnapshot = SyncLocalSnapshot(
  books: {
    'u1': SyncBookRecord(
      uuid: 'u1',
      title: '书A',
      parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R1'),
    ),
  },
  bookMeta: {'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200)},
  mods: {},
);

SyncService _service(
  MemorySyncStore store,
  MemoryTombstoneStore tombstoneStore, {
  required List<String> referenced,
  required List<String> local,
  Map<String, Uint8List> imageBytes = const {},
  List<String>? deletedLocal,
}) {
  return SyncService(
    store: store,
    stateStore: MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      ),
    deviceId: 'dev-1',
    buildLocalSnapshot: () async => _localSnapshot,
    buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
    referencedImages: () async => referenced,
    localImages: () async => local,
    readLocalImage: (p) async => imageBytes[p],
    writeLocalImage: (_, _) async {},
    deleteLocalImage: (p) async => deletedLocal?.add(p),
    tombstoneStore: tombstoneStore,
    keepVersions: 5,
    lockRetryDelay: Duration.zero,
  );
}

const _manifestBase = SyncManifest(
  generation: 3,
  lastWriterDeviceId: 'dev-2',
  knownDevices: ['dev-2'],
  images: ['img/c.png'],
  books: [
    SyncBookEntry(
      uuid: 'u1',
      title: '书A',
      deleted: false,
      settingsFp: 'S0',
      settingsUpdatedAt: 100,
      roundsFp: 'R1',
      roundsUpdatedAt: 200,
      worldBookFp: '',
      bookModsFp: '',
    ),
  ],
);

/// 构造带墓碑条目的状态（删除时间为当前时刻，条目不立即过期）。
ImgTombstones _withEntry(String path) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return ImgTombstones(
    entries: [ImgTombstoneEntry.deleted(path, now)],
  );
}

void main() {
  test('显式删除（本地工作副本含墓碑）→ 删除云端 blob，删除不再推进代数', () async {
    final store = MemorySyncStore()
      ..manifest = _manifestBase
      ..images['img/c.png'] = Uint8List.fromList([1, 2, 3]);
    // 图片库删除：本机工作副本登记了墓碑条目（云端文件尚无）。
    final tombstoneStore = MemoryTombstoneStore(
      _withEntry('img/c.png'),
    );
    final svc = _service(
      store,
      tombstoneStore,
      referenced: const [],
      local: const [],
    );

    final result = await svc.sync();

    expect(result.applied, isTrue);
    expect(result.hasConflict, isFalse);
    // 删除经独立墓碑文件传播，无需重写 manifest / 推进代数。
    expect(result.pushed, isFalse, reason: '删除不推进代数');
    expect(result.generation, 3, reason: '代数保持不变');
    expect(store.images.containsKey('img/c.png'), isFalse, reason: '云端 blob 被删除');
    expect(store.manifest!.generation, 3);
    // 删除意图持久化到云端墓碑文件（供其它设备传播），本地工作副本刷新为云端内容。
    expect(store.tombstones!.entries.single.path, 'img/c.png');
    expect(tombstoneStore.state.entries.single.path, 'img/c.png');
    expect(tombstoneStore.state.revoked, isEmpty);
  });

  test('删除完成后的再次同步：无任何变更 → 不推进代数（幂等）', () async {
    final store = MemorySyncStore()
      ..manifest = _manifestBase
      // 上一轮同步已完成删除：blob 已删、墓碑文件已写入。
      ..tombstones = _withEntry('img/c.png');
    final tombstoneStore = MemoryTombstoneStore(
      _withEntry('img/c.png'),
    );
    final svc = _service(
      store,
      tombstoneStore,
      referenced: const [],
      local: const [],
    );

    final first = await svc.sync();
    expect(first.pushed, isFalse);
    expect(first.generation, 3);

    // 排队补跑 / 手动再点一次同步：仍无变更、代数不涨。
    final second = await svc.sync();
    expect(second.pushed, isFalse);
    expect(second.generation, 3);
    expect(store.manifest!.generation, 3);
    expect(store.tombstones!.entries, hasLength(1));
  });

  test('删除传播：其它设备读云端墓碑且本地仍有文件 → 删除云端+本地文件，不重新上传', () async {
    final store = MemorySyncStore()
      ..manifest = _manifestBase
      ..images['img/a.png'] = Uint8List.fromList([1, 2, 3])
      ..tombstones = _withEntry('img/a.png');
    final tombstoneStore = MemoryTombstoneStore(
      // 本机工作副本 = 上次同步后的云端内容（含墓碑）。
      _withEntry('img/a.png'),
    );
    final deletedLocal = <String>[];
    final svc = _service(
      store,
      tombstoneStore,
      referenced: const ['img/a.png'], // 本地仍引用
      local: const ['img/a.png'], // 文件仍存在
      deletedLocal: deletedLocal,
    );

    final result = await svc.sync();

    expect(result.applied, isTrue);
    expect(result.pushed, isFalse, reason: '删除传播不推进代数');
    expect(result.generation, 3);
    expect(store.images.containsKey('img/a.png'), isFalse, reason: '云端 blob 删除（幂等）');
    expect(deletedLocal, ['img/a.png'], reason: '删除传播到本机文件');
    expect(store.tombstones!.entries.single.path, 'img/a.png',
        reason: '删除意图在墓碑文件中延续，不被撤销');
    expect(tombstoneStore.state.revoked, isEmpty);
  });

  test('再添加复活（本机撤销 + 云端残留条目）→ 抵消删除并重新上传', () async {
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
        generation: 2,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
        images: [],
        books: [
          SyncBookEntry(
            uuid: 'u1',
            title: '书A',
            deleted: false,
            settingsFp: 'S0',
            settingsUpdatedAt: 100,
            roundsFp: 'R1',
            roundsUpdatedAt: 200,
            worldBookFp: '',
            bookModsFp: '',
          ),
        ],
      )
      ..tombstones = _withEntry('img/b.png');
    // 用户重新导入过同一张图：本地工作副本删除条目并记录撤销。
    final tombstoneStore = MemoryTombstoneStore(
      ImgTombstones(revoked: ['img/b.png']),
    );
    final svc = _service(
      store,
      tombstoneStore,
      referenced: const ['img/b.png'],
      local: const ['img/b.png'],
      imageBytes: {'img/b.png': Uint8List.fromList([7, 8, 9])},
    );

    final result = await svc.sync();

    expect(result.applied, isTrue);
    expect(result.hasConflict, isFalse);
    // 复活：重新上传云端 blob；合并结果（无残留条目）回写云端文件与工作副本。
    expect(store.images.containsKey('img/b.png'), isTrue);
    expect(store.images['img/b.png'], [7, 8, 9]);
    expect(store.tombstones!.entries, isEmpty);
    expect(tombstoneStore.state.entries, isEmpty);
    expect(tombstoneStore.state.revoked, isEmpty, reason: '撤销清单消费');
  });

  test('过期条目：同步时清除并回写云端墓碑文件（不推进代数）', () async {
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
    final svc = _service(
      store,
      tombstoneStore,
      referenced: const [],
      local: const [],
    );

    final result = await svc.sync();

    // 过期清除只维护墓碑文件，不产生图片/书籍动作 → 无推送、代数不变。
    expect(result.pushed, isFalse);
    expect(result.generation, 3);
    expect(store.manifest!.generation, 3);
    expect(store.tombstones!.entries.single.path, 'img/live.png');
    expect(tombstoneStore.state.entries.single.path, 'img/live.png');
  });
}
