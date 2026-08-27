import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/sync_dao.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/sync/sync_service.dart';

import 'helpers/fakes.dart';

SyncService _service(
  MemorySyncStore store,
  MemorySyncStateStore state,
  SyncLocalSnapshot local, {
  Future<SyncLocalSnapshot> Function()? buildSnapshot,
}) {
  return SyncService(
    store: store,
    stateStore: state,
    deviceId: 'dev-1',
    buildLocalSnapshot: () async => buildSnapshot?.call() ?? local,
    buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
    referencedImages: () async => const ['img/a.png'],
    localImages: () async => const ['img/a.png'],
    readLocalImage: (_) async => Uint8List.fromList([9]),
    writeLocalImage: (_, _) async {},
    keepVersions: 5,
    lockRetryDelay: Duration.zero,
  );
}

final _localSnapshot = SyncLocalSnapshot(
  books: const {
    'u1': SyncBookRecord(
      uuid: 'u1',
      title: '书A',
      parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R1'),
    ),
  },
  bookMeta: const {
    'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200),
  },
  mods: const {'m1': SyncModRecord(uuid: 'm1', name: 'm1', fingerprint: 'F1')},
);

void main() {
  test('云端为空 → 引导推送：写入快照 + 清单(gen1, format2, uuid键) + 本地共基与状态', () async {
    final store = MemorySyncStore();
    final state = MemorySyncStateStore();
    final svc = _service(store, state, _localSnapshot);

    final result = await svc.sync();

    expect(result.applied, isTrue);
    expect(result.pushed, isTrue);
    expect(result.generation, 1);
    expect(store.manifest, isNotNull);
    expect(store.manifest!.generation, 1);
    expect(store.manifest!.format, 2);
    expect(store.manifest!.books.single.uuid, 'u1');
    expect(store.manifest!.books.single.title, '书A');
    expect(store.manifest!.books.single.roundsFp, 'R1');
    expect(store.snapshots, hasLength(1));
    // 首次同步也应把本地图片真正上传（而非只写进 manifest）。
    expect(store.images.containsKey('img/a.png'), isTrue);
    expect(store.images['img/a.png'], [9]);
    expect(state.state.deviceId, 'dev-1');
    expect(state.state.lastGeneration, 1);
    expect(state.bookBases.keys, contains('u1'));
    expect(state.bookBases['u1']!.settingsUpdatedAt, 100);
    expect(state.bookBases['u1']!.uuid, 'u1');
  });

  test('两端一致且已有共基 → 无变更（不推送、不写快照、不推进代数）', () async {
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
        generation: 5,
        lastWriterDeviceId: 'dev-1',
        knownDevices: ['dev-1'],
        images: ['img/a.png'],
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
    // 图片 blob 已真实存在于云端（否则会被判定为缺失并补传）。
    store.images['img/a.png'] = Uint8List.fromList([9]);
    final state = MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      );
    // 保持一致：本地无 mod，bookMods/worldBook 空指纹。
    final local = SyncLocalSnapshot(
      books: const {
        'u1': SyncBookRecord(
          uuid: 'u1',
          title: '书A',
          parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R1'),
        ),
      },
      bookMeta: const {
        'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200),
      },
      mods: const {},
    );
    final svc = _service(store, state, local);

    final result = await svc.sync();

    expect(result.applied, isFalse);
    expect(result.pushed, isFalse);
    expect(result.hasConflict, isFalse);
    expect(result.generation, 5);
    expect(store.snapshots, isEmpty); // 不写入快照
  });

  test('manifest 声明图片但云端 blob 缺失 → 补传（自愈缺失的图片）', () async {
    // 场景：历史版本把图片写进 manifest 却未上传（或首次同步未传图）。
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
        generation: 4,
        lastWriterDeviceId: 'dev-1',
        knownDevices: ['dev-1'],
        images: ['img/a.png'],
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
    // 注意：store.images 为空（blob 从未上传）。
    final state = MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      );
    final local = SyncLocalSnapshot(
      books: const {
        'u1': SyncBookRecord(
          uuid: 'u1',
          title: '书A',
          parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R1'),
        ),
      },
      bookMeta: const {
        'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200),
      },
      mods: const {},
    );
    final svc = _service(store, state, local);

    final result = await svc.sync();

    expect(result.applied, isTrue, reason: '缺失图片应触发补传');
    expect(store.images.containsKey('img/a.png'), isTrue);
    expect(store.images['img/a.png'], [9]);
    expect(store.manifest!.generation, 5, reason: '补传后正常推进一代');
  });

  test('同一本书两端都改同子部件（真冲突）→ 不下发、返回 hasConflict', () async {
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
        generation: 3,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
        books: [
          SyncBookEntry(
            uuid: 'u1',
            title: '书A',
            deleted: false,
            settingsFp: 'S2', // 远端改了设置
            settingsUpdatedAt: 300,
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
      );
    // 本地也改了设置（S1 != S0），远端 S2 != S0 → 冲突。
    final local = SyncLocalSnapshot(
      books: const {
        'u1': SyncBookRecord(
          uuid: 'u1',
          title: '书A',
          parts: SyncBookParts(settingsFp: 'S1', roundsFp: 'R1'),
        ),
      },
      bookMeta: const {
        'u1': SyncBookMeta(settingsUpdatedAt: 500, roundsUpdatedAt: 200),
      },
      mods: const {},
    );
    final svc = _service(store, state, local);

    final result = await svc.sync();

    expect(result.applied, isFalse);
    expect(result.hasConflict, isTrue);
    expect(store.snapshots, isEmpty);
  });

  test('远端锁被其它设备占用 → 直接失败（不读云端、不写任何文件）', () async {
    final store = MemorySyncStore()
      ..lockedBy = 'dev-2'
      ..manifest = const SyncManifest(
        generation: 5,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
      );
    final state = MemorySyncStateStore();
    final svc = _service(store, state, _localSnapshot);

    final result = await svc.sync();

    expect(result.applied, isFalse);
    expect(result.error, contains('另一台设备正在同步'));
    expect(store.manifest!.generation, 5, reason: '未改写云端');
    expect(store.snapshots, isEmpty);
  });

  test('写前校验：同步期间云端 generation 变化 → 中止且不覆盖云端', () async {
    final store = MemorySyncStore()..lockedBy = '';
    final state = MemorySyncStateStore();
    // 本地有变更 → push 路径。
    final local = SyncLocalSnapshot(
      books: const {
        'u1': SyncBookRecord(
          uuid: 'u1',
          title: '书A',
          parts: SyncBookParts(settingsFp: 'S1', roundsFp: 'R1'),
        ),
      },
      bookMeta: const {
        'u1': SyncBookMeta(settingsUpdatedAt: 500, roundsUpdatedAt: 200),
      },
      mods: const {},
    );
    var readCount = 0;
    final svc = SyncService(
      store: store,
      stateStore: state,
      deviceId: 'dev-1',
      buildLocalSnapshot: () async => local,
      buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
      referencedImages: () async => const [],
      localImages: () async => const [],
      readLocalImage: (_) async => null,
      writeLocalImage: (_, _) async {},
      keepVersions: 5,
      lockRetryDelay: Duration.zero,
    );
    // 先放入云端基态：gen 5 无书籍。
    store.manifest = const SyncManifest(
      generation: 5,
      lastWriterDeviceId: 'dev-1',
      knownDevices: ['dev-1'],
    );
    // 覆盖读 manifest：第一次读到 gen 5，第二次（写前校验）返回 gen 6（模拟并发更新）。
    store.onReadManifest = () async {
      readCount++;
      if (readCount == 2) {
        return const SyncManifest(
          generation: 6,
          lastWriterDeviceId: 'dev-2',
          knownDevices: ['dev-1', 'dev-2'],
        );
      }
      return store.manifest;
    };

    final result = await svc.sync();

    expect(result.applied, isFalse);
    expect(result.error, contains('云端状态在同步期间已更新'));
    // 云端保持本次读到的原代（未被覆盖；模拟的"并发更新 gen6"只是读侧观测）。
    expect(store.manifest!.generation, 5);
  });

  test('本地无变更、仅拉取落地 → applied 但 pushed=false、代数不推进、基表刷新', () async {
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
        generation: 5,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
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
          SyncBookEntry(
            uuid: 'u2',
            title: '远端书',
            deleted: false,
            settingsFp: 'RS',
            settingsUpdatedAt: 300,
            roundsFp: 'RR',
            roundsUpdatedAt: 400,
            worldBookFp: '',
            bookModsFp: '',
          ),
        ],
      )
      ..snapshots['narrchat_snapshot_g5_20260101_000000.db'] =
          Uint8List.fromList([11, 22, 33]);
    final state = MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      );
    // 本地只有书A（与远端一致）；拉取后 localAfter 纳入远端书。
    final local = SyncLocalSnapshot(
      books: const {
        'u1': SyncBookRecord(
          uuid: 'u1',
          title: '书A',
          parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R1'),
        ),
      },
      bookMeta: const {
        'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200),
      },
      mods: const {},
    );
    var afterApply = local;
    final svc = SyncService(
      store: store,
      stateStore: state,
      deviceId: 'dev-1',
      buildLocalSnapshot: () async => afterApply,
      buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
      referencedImages: () async => const [],
      localImages: () async => const [],
      readLocalImage: (_) async => null,
      writeLocalImage: (_, _) async {},
      keepVersions: 5,
      lockRetryDelay: Duration.zero,
      applyRemoteBooks: (mergePlan, action, bytes) async {
        afterApply = SyncLocalSnapshot(
          books: const {
            'u1': SyncBookRecord(
              uuid: 'u1',
              title: '书A',
              parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R1'),
            ),
            'u2': SyncBookRecord(
              uuid: 'u2',
              title: '远端书',
              parts: SyncBookParts(settingsFp: 'RS', roundsFp: 'RR'),
            ),
          },
          bookMeta: const {
            'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200),
            'u2': SyncBookMeta(settingsUpdatedAt: 300, roundsUpdatedAt: 400),
          },
          mods: const {},
        );
      },
    );

    final result = await svc.sync();

    expect(result.applied, isTrue, reason: '拉取落地');
    expect(result.pushed, isFalse, reason: '本地与远端一致，不推进代数');
    expect(result.generation, 5, reason: '代数保持云端当前代');
    expect(store.snapshots, hasLength(1), reason: '未新增快照（仅保留下拉用的既有快照）');
    expect(store.manifest!.generation, 5, reason: 'manifest 未被重写');
    // 拉取的书写入共基（下一轮不再重复拉取 / 弹冲突）。
    expect(state.bookBases.keys, containsAll(['u1', 'u2']));
    expect(state.bookBases['u2']!.settingsFp, 'RS');
  });

  test('拉取快照缺失 → 中止报错，不写快照不写 manifest', () async {
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
        generation: 5,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
        books: [
          SyncBookEntry(
            uuid: 'u2',
            title: '远端书',
            deleted: false,
            settingsFp: 'RS',
            settingsUpdatedAt: 300,
            roundsFp: 'RR',
            roundsUpdatedAt: 400,
            worldBookFp: '',
            bookModsFp: '',
          ),
        ],
      );
    // 无快照（listSnapshotNames 空）。
    final state = MemorySyncStateStore();
    final local = SyncLocalSnapshot(
      books: const {
        'u1': SyncBookRecord(
          uuid: 'u1',
          title: '书A',
          parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R1'),
        ),
      },
      bookMeta: const {
        'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200),
      },
      mods: const {},
    );
    var applyCalled = false;
    final svc = SyncService(
      store: store,
      stateStore: state,
      deviceId: 'dev-1',
      buildLocalSnapshot: () async => local,
      buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
      referencedImages: () async => const [],
      localImages: () async => const [],
      readLocalImage: (_) async => null,
      writeLocalImage: (_, _) async {},
      keepVersions: 5,
      lockRetryDelay: Duration.zero,
      applyRemoteBooks: (_, _, _) async => applyCalled = true,
    );

    final result = await svc.sync();

    expect(result.applied, isFalse);
    expect(result.error, contains('无法获取云端快照'));
    expect(applyCalled, isFalse);
    expect(store.snapshots, isEmpty, reason: '绝不带旧内容推送');
    expect(store.manifest!.generation, 5, reason: 'manifest 未被覆盖');
  });
}
