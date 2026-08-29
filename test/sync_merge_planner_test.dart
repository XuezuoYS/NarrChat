import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';

/// 三向部件级合并规划器测试。**身份只有 uuid**：共基 / 本地 / 远端三侧的键
/// 就是各自库的主键，title / name 仅随决策携带供展示，从不参与身份判定。
/// 设置为单部件（含全部设置字段）：本组「设置」用例以 settings 部件为代表。
void main() {
  group('三向部件级规划', () {
    // 共基：书A（uuid u1）有 1-12 轮，设置 S0；远端设置 S0。
    const base = <String, SyncBookBaseParts>{
      'u1': SyncBookBaseParts(
        title: '书A',
        settingsFp: 'S0',
        roundsFp: 'R12',
        worldBookFp: 'W0',
        bookModsFp: 'M0',
      ),
    };
    const baseMods = <String, SyncModBaseParts>{};

    test('场景1：云端12轮(较新) vs 本地15轮(日期旧)——轮次内容一致时自动并成15轮，不弹窗', () {
      final plan = SyncMergePlanner.plan(
        base: base,
        local: const {
          // 本地 1-15 轮（比 base 多 13-15），设置没改。
          'u1': SyncBookRecord(
            uuid: 'u1',
            title: '书A',
            parts: SyncBookParts(
              settingsFp: 'S0',
              roundsFp: 'R15',
              worldBookFp: 'W0',
              bookModsFp: 'M0',
            ),
          ),
        },
        remote: const {
          // 云端 1-12 轮 == base（云端没改轮次，只是"日期较新"）。
          'u1': RemoteBookParts(
            uuid: 'u1',
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R12',
            worldBookFp: 'W0',
            bookModsFp: 'M0',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: baseMods,
      );

      final a = plan.books.single;
      expect(a.presence, SyncBookPresence.both);
      expect(a.rounds, SyncPartStatus.localOnly); // 自动用本地（15 轮）
      expect(a.settings, SyncPartStatus.unchanged);
      expect(a.hasConflict, isFalse); // 不弹窗
    });

    test('场景1变体×轮次内容分歧：任一共同轮次不一致 → 轮次冲突', () {
      final plan = SyncMergePlanner.plan(
        base: base,
        local: const {
          'u1': SyncBookRecord(
            uuid: 'u1',
            title: '书A',
            parts: SyncBookParts(
              settingsFp: 'S0',
              roundsFp: 'R15',
              worldBookFp: 'W0',
              bookModsFp: 'M0',
            ),
          ),
        },
        remote: const {
          'u1': RemoteBookParts(
            uuid: 'u1',
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R12x',
            worldBookFp: 'W0',
            bookModsFp: 'M0',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: baseMods,
      );
      final a = plan.books.single;
      expect(a.rounds, SyncPartStatus.conflict);
      expect(a.hasConflict, isTrue);
    });

    test('场景2：云端12轮 vs 本地仅10轮且第10轮不一致 → 轮次冲突（弹窗）', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'u1': SyncBookBaseParts(
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R09',
            worldBookFp: 'W0',
            bookModsFp: 'M0',
          ),
        },
        local: const {
          // 本地 1-10 轮，但第 10 轮内容==本地版本（与云端不同）。
          'u1': SyncBookRecord(
            uuid: 'u1',
            title: '书A',
            parts: SyncBookParts(
              settingsFp: 'S0',
              roundsFp: 'R10A',
              worldBookFp: 'W0',
              bookModsFp: 'M0',
            ),
          ),
        },
        remote: const {
          // 云端 1-12 轮，第 10 轮==云端版本（与本地不同）。
          'u1': RemoteBookParts(
            uuid: 'u1',
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R12B',
            worldBookFp: 'W0',
            bookModsFp: 'M0',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: baseMods,
      );
      final a = plan.books.single;
      expect(a.rounds, SyncPartStatus.conflict);
      expect(a.hasConflict, isTrue);
    });

    test('场景3：云端轮次时间均新、轮次无冲突、但设置不同 → 轮次自动拉、设置仅本地改自动推', () {
      final plan = SyncMergePlanner.plan(
        base: base,
        local: const {
          // 本地轮次未变（== base 1-12），但设置改了（S1）。
          'u1': SyncBookRecord(
            uuid: 'u1',
            title: '书A',
            parts: SyncBookParts(
              settingsFp: 'S1',
              roundsFp: 'R12',
              worldBookFp: 'W0',
              bookModsFp: 'M0',
            ),
          ),
        },
        remote: const {
          // 云端追加到 13 轮（R13 != base），设置未改（S0）。
          'u1': RemoteBookParts(
            uuid: 'u1',
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R13',
            worldBookFp: 'W0',
            bookModsFp: 'M0',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: baseMods,
      );
      final a = plan.books.single;
      expect(a.rounds, SyncPartStatus.remoteOnly); // 自动拉
      expect(a.settings, SyncPartStatus.localOnly); // 自动推
      expect(a.hasConflict, isFalse); // 分开判定，互不牵连
    });

    test('场景3变体：设置双方都改 → 仅设置冲突（轮次仍不冲突）', () {
      final plan = SyncMergePlanner.plan(
        base: base,
        local: const {
          'u1': SyncBookRecord(
            uuid: 'u1',
            title: '书A',
            parts: SyncBookParts(
              settingsFp: 'S1',
              roundsFp: 'R12',
              worldBookFp: 'W0',
              bookModsFp: 'M0',
            ),
          ),
        },
        remote: const {
          'u1': RemoteBookParts(
            uuid: 'u1',
            title: '书A',
            settingsFp: 'S2',
            roundsFp: 'R13',
            worldBookFp: 'W0',
            bookModsFp: 'M0',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: baseMods,
      );
      final a = plan.books.single;
      expect(a.settings, SyncPartStatus.conflict);
      expect(a.rounds, SyncPartStatus.remoteOnly); // 轮次仍自动拉
      expect(a.hasConflict, isTrue);
    });

    test('仅本地新增书 → push；仅远端新增书 → pull', () {
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: const {
          'uA': SyncBookRecord(
            uuid: 'uA',
            title: '书A',
            parts: SyncBookParts(settingsFp: 'S0'),
          ),
        },
        remote: const {
          'uB': RemoteBookParts(
            uuid: 'uB',
            title: '书B',
            settingsFp: 'S0',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      final a = plan.books.firstWhere((d) => d.localUuid == 'uA');
      expect(a.presence, SyncBookPresence.localOnly);
      expect(a.localUuid, 'uA');
      expect(a.remoteUuid, isNull, reason: '标题不参与匹配：远端那本是另一本书');
      final b = plan.books.firstWhere((d) => d.remoteUuid == 'uB');
      expect(b.presence, SyncBookPresence.remoteOnly);
      expect(b.remoteUuid, 'uB');
      expect(b.localUuid, isNull);
    });

    test('两端都无变化 → 全部 unchanged', () {
      final plan = SyncMergePlanner.plan(
        base: base,
        local: const {
          'u1': SyncBookRecord(
            uuid: 'u1',
            title: '书A',
            parts: SyncBookParts(
              settingsFp: 'S0',
              roundsFp: 'R12',
              worldBookFp: 'W0',
              bookModsFp: 'M0',
            ),
          ),
        },
        remote: const {
          'u1': RemoteBookParts(
            uuid: 'u1',
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R12',
            worldBookFp: 'W0',
            bookModsFp: 'M0',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: baseMods,
      );
      final a = plan.books.single;
      expect(a.settings, SyncPartStatus.unchanged);
      expect(a.rounds, SyncPartStatus.unchanged);
      expect(a.hasConflict, isFalse);
    });
  });

  group('身份只有 uuid：三侧只按 uuid 对齐', () {
    test('同名不同 uuid（两台设备各建同名书）→ 两个独立实体，各自 localOnly / remoteOnly', () {
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: const {
          'uL': SyncBookRecord(
            uuid: 'uL',
            title: '书A',
            parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R12'),
          ),
        },
        remote: const {
          // 远端那本：书名相同、内容也完全一致，但 uuid 不同 → 仍是另一本书。
          'uR': RemoteBookParts(
            uuid: 'uR',
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R12',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      // 不做标题回退：两条独立决策，绝不并成一本。
      expect(plan.books, hasLength(2));
      final local = plan.books.firstWhere((b) => b.localUuid == 'uL');
      expect(local.presence, SyncBookPresence.localOnly);
      expect(local.remoteUuid, isNull);
      expect(local.settings, SyncPartStatus.unchanged);
      final remote = plan.books.firstWhere((b) => b.remoteUuid == 'uR');
      expect(remote.presence, SyncBookPresence.remoteOnly);
      expect(remote.localUuid, isNull);
      expect(remote.settings, SyncPartStatus.unchanged);
      expect(plan.hasConflict, isFalse);
    });

    test('共基只按 uuid 命中：base 与远端同 uuid、本地为另一 uuid → 不链接（本地推送 / 远端删除传播）', () {
      final plan = SyncMergePlanner.plan(
        // 共基记的是远端那一本的 uuid（同名不会把本地这本拉进同一组）。
        base: const {
          'uR': SyncBookBaseParts(
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R12',
          ),
        },
        local: const {
          'uL': SyncBookRecord(
            uuid: 'uL',
            title: '书A',
            parts: SyncBookParts(settingsFp: 'S0', roundsFp: 'R12'),
          ),
        },
        remote: const {
          'uR': RemoteBookParts(
            uuid: 'uR',
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R12',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books, hasLength(2));
      // 本地这本没有共基 → 独立新书，走推送。
      expect(
        plan.books.firstWhere((b) => b.localUuid == 'uL').presence,
        SyncBookPresence.localOnly,
      );
      // 远端那本有共基且本地已无此 uuid → 按删除传播，而不是「和另一本同名书合并」。
      final remoteSide = plan.books.firstWhere((b) => b.remoteUuid == 'uR');
      expect(remoteSide.presence, SyncBookPresence.deletedOnLocal);
      expect(remoteSide.localUuid, isNull);
    });

    test('重命名（uuid 相同、书名不同）→ 视为设置变更，不是删除+新建', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'u1': SyncBookBaseParts(
            title: '旧名',
            settingsFp: 'S0',
            roundsFp: 'R12',
          ),
        },
        local: const {
          'u1': SyncBookRecord(
            uuid: 'u1',
            title: '新名',
            parts: SyncBookParts(settingsFp: 'S1', roundsFp: 'R12'),
          ),
        },
        remote: const {
          'u1': RemoteBookParts(
            uuid: 'u1',
            title: '旧名',
            settingsFp: 'S0',
            roundsFp: 'R12',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books, hasLength(1));
      final a = plan.books.single;
      expect(a.presence, SyncBookPresence.both);
      expect(a.settings, SyncPartStatus.localOnly); // 改名=设置变更，自动推
      expect(a.hasConflict, isFalse);
    });

    test('多本同名书（uuid 各不相同）→ 三个独立实体：本地两本 localOnly、远端一本 remoteOnly', () {
      // 本地两本 + 远端一本同名「重名」，三个 uuid 互不相同 → 各自独立判定，
      // 绝不按标题把远端那一本并进本地任何一本。
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: const {
          'uL1': SyncBookRecord(
            uuid: 'uL1',
            title: '重名',
            parts: SyncBookParts(settingsFp: 'SL1'),
          ),
          'uL2': SyncBookRecord(
            uuid: 'uL2',
            title: '重名',
            parts: SyncBookParts(settingsFp: 'SL2'),
          ),
        },
        remote: const {
          'uR': RemoteBookParts(uuid: 'uR', title: '重名', settingsFp: 'SR'),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books, hasLength(3));
      expect(plan.books.where((b) => b.localUuid != null), hasLength(2));
      expect(plan.books.where((b) => b.remoteUuid != null), hasLength(1));
      expect(
        plan.books.where((b) => b.presence == SyncBookPresence.localOnly),
        hasLength(2),
      );
      expect(
        plan.books.where((b) => b.presence == SyncBookPresence.remoteOnly),
        hasLength(1),
      );
    });

    test('同名 Mod 不同 uuid → 两个独立 Mod：本地 localOnly 推送、远端 remoteOnly 导入', () {
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: const {},
        remote: const {},
        localMods: const {
          'mL': SyncModRecord(uuid: 'mL', name: '风格', fingerprint: 'F1'),
        },
        remoteMods: const {
          // 名称与内容都一样，但 uuid 不同 → 不再链接成同一个 Mod。
          'mR': RemoteModParts(uuid: 'mR', name: '风格', fingerprint: 'F1'),
        },
        baseMods: const {},
      );
      expect(plan.mods, hasLength(2));
      final local = plan.mods.firstWhere((m) => m.localUuid == 'mL');
      expect(local.status, SyncModStatus.localOnly);
      expect(local.remoteUuid, isNull);
      final remote = plan.mods.firstWhere((m) => m.remoteUuid == 'mR');
      expect(remote.status, SyncModStatus.remoteOnly);
      expect(remote.localUuid, isNull);
      // 本地没有这一本 → 全新 Mod 属增量导入，不进人工确认通道。
      expect(remote.needsReview, isFalse);
      expect(plan.hasConflict, isFalse);
    });

    test('同名不同 uuid 计入摘要：push / pull 各一，conflict 为零', () {
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: const {
          'uL': SyncBookRecord(
            uuid: 'uL',
            title: '重名',
            parts: SyncBookParts(settingsFp: 'SL'),
          ),
        },
        remote: const {
          'uR': RemoteBookParts(uuid: 'uR', title: '重名', settingsFp: 'SR'),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      // 两台设备各建同名书 → 两本独立：一本推、一本拉，标题只是展示字段。
      expect(
        plan.summarize(),
        {
          'push': 1,
          'pull': 1,
          'deleteLocal': 0,
          'deleteRemote': 0,
          'conflict': 0,
        },
      );
      expect(plan.books.map((b) => b.title).toList(), ['重名', '重名']);
      expect(plan.needsReview, isFalse);
    });

    test('Mod 双向删除 → absent；远端删 Mod 且本地未改 → deletedOnRemote', () {
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: const {},
        remote: const {},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {'m1': SyncModBaseParts(name: '风格', fingerprint: 'F1')},
      );
      expect(plan.mods.single.status, SyncModStatus.absent);

      final plan2 = SyncMergePlanner.plan(
        base: const {},
        local: const {},
        remote: const {},
        localMods: const {
          'm1': SyncModRecord(uuid: 'm1', name: '风格', fingerprint: 'F1'),
        },
        remoteMods: const {},
        baseMods: const {'m1': SyncModBaseParts(name: '风格', fingerprint: 'F1')},
      );
      expect(plan2.mods.single.status, SyncModStatus.deletedOnRemote);
      expect(plan2.mods.single.localUuid, 'm1');
      expect(plan2.mods.single.remoteUuid, isNull);
    });
  });
}
