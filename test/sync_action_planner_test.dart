import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_action_planner.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';

/// `SyncActionPlanner` 测试：把三向计划 + 图片状态翻译为 push/pull/conflict/删除动作
/// （uuid 标识；设置类为 5 个子部件，本组用例以 info 子部件代表"设置"）。
void main() {
  SyncMergePlan buildPlan({
    required Map<String, SyncBookBaseParts> base,
    required Map<String, SyncBookRecord> local,
    required Map<String, RemoteBookParts> remote,
    Map<String, SyncModRecord> localMods = const {},
    Map<String, RemoteModParts> remoteMods = const {},
    Map<String, SyncModBaseParts> baseMods = const {},
  }) {
    return SyncMergePlanner.plan(
      base: base,
      local: local,
      remote: remote,
      localMods: localMods,
      remoteMods: remoteMods,
      baseMods: baseMods,
    );
  }

  SyncAction toAction(SyncMergePlan merge) {
    return SyncActionPlanner.plan(
      mergePlan: merge,
      referencedImages: const [],
      cloudImages: const [],
      localImages: const [],
      tombstones: const [],
    );
  }

  SyncBookRecord rec(String uuid, String title, String s, String r) =>
      SyncBookRecord(
        uuid: uuid,
        title: title,
        parts: SyncBookParts(settingsFp: s, roundsFp: r),
      );

  RemoteBookParts rem(String uuid, String title, String s, String r) =>
      RemoteBookParts(uuid: uuid, title: title, settingsFp: s, roundsFp: r);

  test('两端都无变化 → 无任何动作', () {
    final a = toAction(buildPlan(
      base: const {'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R1')},
      local: {'u1': rec('u1', '书A', 'S0', 'R1')},
      remote: {'u1': rem('u1', '书A', 'S0', 'R1')},
    ));
    expect(a.hasChanges, isFalse);
    expect(a.hasConflict, isFalse);
  });

  test('场景3：远端加轮次(remoteOnly)+本地改设置(localOnly) → 该书既拉又推、无冲突', () {
    final a = toAction(buildPlan(
      base: const {'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R12')},
      local: {'u1': rec('u1', '书A', 'S1', 'R12')},
      remote: {'u1': rem('u1', '书A', 'S0', 'R13')},
    ));
    expect(a.hasConflict, isFalse);
    expect(a.pullBookUuids, contains('u1'));
    expect(a.pushBookUuids, contains('u1'));
  });

  test('仅远端变化 → 拉取；仅本地变化 → 推送', () {
    final pull = toAction(buildPlan(
      base: const {},
      local: const {},
      remote: {'uB': rem('uB', '书B', 'S0', '')},
    ));
    expect(pull.pullBookUuids, ['uB']);

    final push = toAction(buildPlan(
      base: const {},
      local: {'uA': rec('uA', '书A', 'S0', '')},
      remote: const {},
    ));
    expect(push.pushBookUuids, ['uA']);
  });

  test('双方都改同一子部件 → 冲突（进合并决策页）', () {
    final a = toAction(buildPlan(
      base: const {'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R1')},
      local: {'u1': rec('u1', '书A', 'S1', 'R1')},
      remote: {'u1': rem('u1', '书A', 'S2', 'R1')},
    ));
    expect(a.hasConflict, isTrue);
    expect(a.conflictBookUuids, contains('u1'));
  });

  test('本地删除且远端未改 → 传播删除云端书籍', () {
    final a = toAction(buildPlan(
      base: const {'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R1')},
      local: const {},
      remote: {'u1': rem('u1', '书A', 'S0', 'R1')},
    ));
    expect(a.deleteRemoteBookUuids, contains('u1'));
  });

  test('图片：删除后被重新引用 → 复活并重传，不删除云端', () {
    final merge = buildPlan(base: const {}, local: const {}, remote: const {});
    final a = SyncActionPlanner.plan(
      mergePlan: merge,
      referencedImages: const ['img/b.png'],
      cloudImages: const [], // 云端已被清
      localImages: const ['img/b.png'],
      tombstones: const ['img/b.png'],
    );
    expect(a.images.revived, ['img/b.png']);
    expect(a.images.toUpload, contains('img/b.png'));
    expect(a.images.toDeleteCloud, isEmpty);
  });

  test('Mod：仅远端有 → 拉取；Mod 冲突 → 冲突；远端删 Mod → 本地删除清单', () {
    final a = toAction(buildPlan(
      base: const {},
      local: const {},
      remote: const {},
      remoteMods: const {'m1': RemoteModParts(uuid: 'm1', name: 'm1', fingerprint: 'F1')},
    ));
    expect(a.pullModUuids, contains('m1'));

    final c = toAction(buildPlan(
      base: const {},
      local: const {},
      remote: const {},
      localMods: const {'m1': SyncModRecord(uuid: 'm1', name: 'm1', fingerprint: 'F1')},
      remoteMods: const {'m1': RemoteModParts(uuid: 'm1', name: 'm1', fingerprint: 'F2')},
    ));
    expect(c.hasConflict, isTrue);
    expect(c.conflictModUuids, contains('m1'));

    // 远端删除（本地未删）→ 删除本地 Mod。
    final d = toAction(buildPlan(
      base: const {},
      local: const {},
      remote: const {},
      localMods: const {'m1': SyncModRecord(uuid: 'm1', name: 'm1', fingerprint: 'F1')},
      remoteMods: const {},
      baseMods: const {'m1': SyncModBaseParts(name: 'm1', fingerprint: 'F1')},
    ));
    expect(d.deleteLocalModUuids, contains('m1'));
  });
}
