import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/sync_dao.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/sync/database_sync_runner.dart';

import 'helpers/fakes.dart';

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

final _snapshotBytes = Uint8List.fromList([11, 22, 33]);

void main() {
  test('检出 remoteOnly 书 → 读取当前代快照并交给 applyRemoteBooks', () async {
    final store = MemorySyncStore()
      ..manifest = SyncManifest(
        generation: 2,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
        books: [
          const SyncBookEntry(
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
          const SyncBookEntry(
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
      ..snapshots['narrchat_snapshot_g2_20260101_000000.db'] = _snapshotBytes;
    final state = MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      );

    List<String>? pulledUuids;
    Uint8List? pulledBytes;
    // 拉取后本地快照应纳入远端书（真实场景由库重建产生；此处模拟）。
    var local = _localSnapshot;
    final svc = DatabaseSyncRunner(
      store: store,
      stateStore: state,
      deviceId: 'dev-1',
      buildLocalSnapshot: () async => local,
      buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
      referencedImages: () async => const [],
      lockRetryDelay: Duration.zero,
      applyRemoteBooks: (mergePlan, action, bytes) async {
        pulledUuids = action.pullBookUuids;
        pulledBytes = bytes;
        local = const SyncLocalSnapshot(
          books: {
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
          bookMeta: {
            'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200),
            'u2': SyncBookMeta(settingsUpdatedAt: 300, roundsUpdatedAt: 400),
          },
          mods: {},
        );
      },
    );

    final result = await svc.sync();

    expect(result.applied, isTrue);
    expect(result.pushed, isFalse, reason: '仅拉取落地 → 不推进代数');
    expect(result.hasConflict, isFalse);
    expect(pulledUuids, ['u2']);
    expect(pulledBytes, same(_snapshotBytes));
    // 拉取后本地与云端一致 → manifest 保持当前代（不重写）；基表照常刷新。
    final manifest = store.manifest!;
    expect(manifest.generation, 2);
    expect(
      manifest.books.map((b) => b.uuid),
      containsAll(['u1', 'u2']),
      reason: '远端清单原样保留（本地未推进）',
    );
    // 拉取后的书必须写入共基（否则下一轮同步会重复弹冲突）。
    expect(
      state.bookBases.keys,
      contains('u2'),
      reason: '拉取的书应写入共基',
    );
    expect(state.bookBases['u2']!.settingsFp, 'RS');
  });

  test('同一本书（同 uuid）远端轮次更新 → 部件级 remoteOnly 交给 applyRemoteBooks', () async {
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
        generation: 2,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
        books: [
          SyncBookEntry(
            uuid: 'u1',
            title: '书A',
            deleted: false,
            settingsFp: 'S0',
            settingsUpdatedAt: 100,
            roundsFp: 'R2', // 远端轮次更新（本地仍为 base R1）
            roundsUpdatedAt: 400,
            worldBookFp: '',
            bookModsFp: '',
          ),
        ],
      )
      ..snapshots['narrchat_snapshot_g2_20260101_000000.db'] = _snapshotBytes;
    final state = MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      );

    List<String>? pulledUuids;
    SyncMergePlan? passedPlan;
    // 本地 == base（仅远端改动轮次）；拉取后本地与远端一致。
    var local = _localSnapshot;
    final svc = DatabaseSyncRunner(
      store: store,
      stateStore: state,
      deviceId: 'dev-1',
      buildLocalSnapshot: () async => local,
      buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
      referencedImages: () async => const [],
      lockRetryDelay: Duration.zero,
      applyRemoteBooks: (mergePlan, action, bytes) async {
        passedPlan = mergePlan;
        pulledUuids = action.pullBookUuids;
        local = const SyncLocalSnapshot(
          books: {
            'u1': SyncBookRecord(
              uuid: 'u1',
              title: '书A',
              parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R2'),
            ),
          },
          bookMeta: {
            'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 400),
          },
          mods: {},
        );
      },
    );

    final result = await svc.sync();

    expect(result.hasConflict, isFalse);
    expect(pulledUuids, ['u1'], reason: '同一 uuid 的书，部件级更新也应进入拉取清单');
    final bookDecision = passedPlan!.books.single;
    expect(bookDecision.presence, SyncBookPresence.both);
    expect(bookDecision.rounds, SyncPartStatus.remoteOnly);
    expect(bookDecision.settings, SyncPartStatus.unchanged);
    // 拉取后本地与云端一致 → manifest 保持当前代（远端清单原样）；
    // 共基按拉取后内容刷新（防止下一轮误判冲突 / 重复拉取）。
    expect(store.manifest!.generation, 2);
    expect(store.manifest!.books.single.roundsFp, 'R2');
    expect(state.bookBases['u1']!.roundsFp, 'R2');
  });

  test('远端独立 Mod（未被书引用）→ 拉取清单含 pullModUuids 并写入本代', () async {
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
        generation: 2,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
        mods: [
          SyncModEntry(uuid: 'm2', name: 'm2', deleted: false, updatedAt: 0, fingerprint: 'F2'),
        ],
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
      ..snapshots['narrchat_snapshot_g2_20260101_000000.db'] = _snapshotBytes;
    final state = MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      );

    List<String>? pulledMods;
    // 本地无 m2、无 base → 该 Mod 为 remoteOnly。
    var local = _localSnapshot;
    final svc = DatabaseSyncRunner(
      store: store,
      stateStore: state,
      deviceId: 'dev-1',
      buildLocalSnapshot: () async => local,
      buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
      referencedImages: () async => const [],
      lockRetryDelay: Duration.zero,
      applyRemoteBooks: (mergePlan, action, bytes) async {
        pulledMods = action.pullModUuids;
        expect(mergePlan.mods.single.status, SyncModStatus.remoteOnly);
        // 模拟拉取后本地新增该 Mod。
        local = const SyncLocalSnapshot(
          books: {
            'u1': SyncBookRecord(
              uuid: 'u1',
              title: '书A',
              parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R1'),
            ),
          },
          bookMeta: {
            'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200),
          },
          mods: {
            'm2': SyncModRecord(uuid: 'm2', name: 'm2', fingerprint: 'F2'),
          },
        );
      },
    );

    final result = await svc.sync();

    expect(result.applied, isTrue);
    expect(result.pushed, isFalse, reason: '仅拉取落地 → 不推进代数');
    expect(pulledMods, ['m2'], reason: '独立 Mod 应进入拉取清单');
    // 拉取后的 Mod 写入共基（manifest 保持当前代）。
    expect(store.manifest!.generation, 2);
    expect(store.manifest!.mods.single.uuid, 'm2');
    expect(store.manifest!.mods.single.fingerprint, 'F2');
    expect(state.modBases['m2']!.fingerprint, 'F2');
  });

  test('远端同名但 uuid 不同 → 清单按 uuid 独立分组：整本拉取，不与本地同名书合并', () async {
    // 云端两本书与本地那本**同名同内容**，但只有 u1 与本地是同一本书（uuid 相同）。
    final store = MemorySyncStore()
      ..manifest = SyncManifest(
        generation: 2,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
        books: [
          const SyncBookEntry(
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
          const SyncBookEntry(
            uuid: 'u2',
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
      ..snapshots['narrchat_snapshot_g2_20260101_000000.db'] = _snapshotBytes;
    final state = MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      );

    SyncMergePlan? passedPlan;
    List<String>? pulledUuids;
    var local = _localSnapshot;
    final svc = DatabaseSyncRunner(
      store: store,
      stateStore: state,
      deviceId: 'dev-1',
      buildLocalSnapshot: () async => local,
      buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
      referencedImages: () async => const [],
      lockRetryDelay: Duration.zero,
      applyRemoteBooks: (mergePlan, action, bytes) async {
        passedPlan = mergePlan;
        pulledUuids = action.pullBookUuids;
        local = const SyncLocalSnapshot(
          books: {
            'u1': SyncBookRecord(
              uuid: 'u1',
              title: '书A',
              parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R1'),
            ),
            'u2': SyncBookRecord(
              uuid: 'u2',
              title: '书A',
              parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R1'),
            ),
          },
          bookMeta: {
            'u1': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200),
            'u2': SyncBookMeta(settingsUpdatedAt: 100, roundsUpdatedAt: 200),
          },
          mods: {},
        );
      },
    );

    final result = await svc.sync();

    // 远端那本没有共基 → 按独立新书（remoteOnly）整本拉取，绝不按标题认亲。
    expect(pulledUuids, ['u2']);
    final remoteDecision =
        passedPlan!.books.firstWhere((b) => b.remoteUuid == 'u2');
    expect(remoteDecision.presence, SyncBookPresence.remoteOnly);
    expect(remoteDecision.localUuid, isNull,
        reason: '分组只按 uuid：同名不会链接到本地那本');
    expect(
      passedPlan!.books.firstWhere((b) => b.remoteUuid == 'u1').presence,
      SyncBookPresence.both,
    );
    expect(result.applied, isTrue);
    expect(result.pushed, isFalse);
    // 拉取落地后为 u2 建立共基（本地身份就是远端 uuid）。
    expect(state.bookBases.containsKey('u2'), isTrue);
    expect(state.bookBases['u2']!.uuid, 'u2');
  });

  test('无拉取书时不读取快照（与云端一致 → 无变更）', () async {
    final store = MemorySyncStore()
      ..manifest = const SyncManifest(
        generation: 2,
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
        ],
      );
    final state = MemorySyncStateStore()
      ..bookBases['u1'] = const SyncBookBase(
        uuid: 'u1',
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R1',
      );

    var called = false;
    final svc = DatabaseSyncRunner(
      store: store,
      stateStore: state,
      deviceId: 'dev-1',
      buildLocalSnapshot: () async => _localSnapshot,
      buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
      referencedImages: () async => const [],
      lockRetryDelay: Duration.zero,
      applyRemoteBooks: (_, _, _) async => called = true,
    );

    final result = await svc.sync();

    expect(result.applied, isFalse, reason: '仅书A 且与云端一致 → 无变更');
    expect(called, isFalse, reason: '无拉取书名，不应读取快照');
  });
}
