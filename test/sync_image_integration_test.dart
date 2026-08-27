import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/sync_dao.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/sync/sync_service.dart';

import 'helpers/fakes.dart';

/// `SyncService` 图片同步端到端（不触碰真实网络 / 真库 / 真密钥库）：
/// - 显式删除 → 云端删除：
///   本地取消引用 + 待推送墓碑 → 同步把云端对应 blob 删除；
/// - 再添加复活 → 重传：
///   本地重新引用一张带墓碑的图 → 同步取消删除意图并重新上传。
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
  MemorySyncStateStore state, {
  required List<String> referenced,
  required List<String> local,
  Map<String, Uint8List> imageBytes = const {},
}) {
  return SyncService(
    store: store,
    stateStore: state,
    deviceId: 'dev-1',
    buildLocalSnapshot: () async => _localSnapshot,
    buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
    referencedImages: () async => referenced,
    localImages: () async => local,
    readLocalImage: (p) async => imageBytes[p],
    writeLocalImage: (_, _) async {},
    keepVersions: 5,
    lockRetryDelay: Duration.zero,
  );
}

void main() {
  test('显式删除（本地不引用 + 墓碑）→ 同步删除云端 blob', () async {
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
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
    final state = MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      )
      ..pending.add(const SyncPendingDelete(path: 'img/c.png', deletedAt: 100));
    final svc = _service(store, state, referenced: const [], local: const []);

    final result = await svc.sync();

    expect(result.applied, isTrue);
    expect(result.hasConflict, isFalse);
    expect(result.pushed, isTrue, reason: '图片删除需重写 manifest');
    expect(store.images.containsKey('img/c.png'), isFalse, reason: '云端 blob 被删除');
    expect(store.manifest!.images, isEmpty, reason: 'manifest 清空已删图');
    expect(store.manifest!.generation, 4, reason: '图片变更推进代数');
  });

  test('再添加复活（本地重引用 + 墓碑）→ 撤销删除并重新上传', () async {
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
        generation: 2,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
        images: [],
        deletedImages: [SyncDeletedImage(path: 'img/b.png', deletedAt: 50)],
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
    final state = MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      )
      ..pending.add(const SyncPendingDelete(path: 'img/b.png', deletedAt: 60));
    final svc = _service(
      store,
      state,
      referenced: const ['img/b.png'],
      local: const ['img/b.png'],
      imageBytes: {'img/b.png': Uint8List.fromList([7, 8, 9])},
    );

    final result = await svc.sync();

    expect(result.applied, isTrue);
    expect(result.hasConflict, isFalse);
    // 复活：重新上传云端 blob。
    expect(store.images.containsKey('img/b.png'), isTrue);
    expect(store.images['img/b.png'], [7, 8, 9]);
    // 撤销删除：manifest.deletedImages 移除，本地待推送墓碑移除。
    expect(store.manifest!.deletedImages, isEmpty);
    expect(state.pending, isEmpty);
    expect(store.manifest!.images, contains('img/b.png'));
  });
}
