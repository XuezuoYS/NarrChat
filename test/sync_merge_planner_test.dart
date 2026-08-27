import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';

/// 三向部件级合并规划器测试（uuid 身份 + title/name 唯一回退）。
/// 设置类为 5 个子部件：本组"设置"用例以 info 子部件为代表。
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

      final a = plan.books.firstWhere((b) => b.title == '书A');
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
      final a = plan.books.firstWhere((b) => b.title == '书A');
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
      final a = plan.books.firstWhere((b) => b.title == '书A');
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
      final a = plan.books.firstWhere((b) => b.title == '书A');
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
      final a = plan.books.firstWhere((b) => b.title == '书A');
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
      final a = plan.books.firstWhere((b) => b.title == '书A');
      expect(a.presence, SyncBookPresence.localOnly);
      expect(a.localUuid, 'uA');
      final b = plan.books.firstWhere((b) => b.title == '书B');
      expect(b.presence, SyncBookPresence.remoteOnly);
      expect(b.remoteUuid, 'uB');
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
      final a = plan.books.firstWhere((b) => b.title == '书A');
      expect(a.settings, SyncPartStatus.unchanged);
      expect(a.rounds, SyncPartStatus.unchanged);
      expect(a.hasConflict, isFalse);
    });
  });

  group('uuid 身份 + 名称唯一回退', () {
    test('两侧 uuid 不同但书名唯一相同（首连/手动合并过渡态）→ 按书名回退视为同一本书', () {
      final plan = SyncMergePlanner.plan(
        // 共基为远端 uuid（手动合并后 adopt 云端共基的过渡态）。
        base: const {
          'uR': SyncBookBaseParts(
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R12',
          ),
        },
        local: const {
          // 本地保留自己的 uuid，书名相同、设置未改。
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
      // 三侧只应出现一条决策（同一本书），且未被孤立成 localOnly/remoteOnly。
      expect(plan.books, hasLength(1));
      final a = plan.books.single;
      expect(a.presence, SyncBookPresence.both);
      expect(a.settings, SyncPartStatus.unchanged);
      expect(a.localUuid, 'uL');
      expect(a.remoteUuid, 'uR');
      expect(a.hasConflict, isFalse);
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

    test('同名多书（一侧多本同名 → 该侧名称不唯一）→ 不链接，各自按独立实体判定', () {
      // 本地有两本同名「重名」（本地名称不唯一 → 不参与回退链接）；
      // 远端有一本「重名」→ 按独立实体：本地两本 localOnly、远端一本 remoteOnly。
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

    test('同名 Mod 回退：两侧 uuid 不同但名称唯一相同 → 视为同一 Mod', () {
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: const {},
        remote: const {},
        localMods: const {
          'mL': SyncModRecord(uuid: 'mL', name: '风格', fingerprint: 'F1'),
        },
        remoteMods: const {
          'mR': RemoteModParts(uuid: 'mR', name: '风格', fingerprint: 'F1'),
        },
        baseMods: const {},
      );
      // 同名链接成一条决策。
      expect(plan.mods, hasLength(1));
      expect(plan.mods.single.status, SyncModStatus.unchanged);
      expect(plan.mods.single.localUuid, 'mL');
      expect(plan.mods.single.remoteUuid, 'mR');
    });

    test('旧版清单（远端 uuid 为空 → legacy 键）按名称回退匹配，与 legacy 共基对齐', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'legacy:书A': SyncBookBaseParts(
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
          // SyncService 已把缺失 uuid 的清单条目归一化为 legacy 键（见 _toRemoteBooks）。
          'legacy:书A': RemoteBookParts(
            uuid: 'legacy:书A',
            title: '书A',
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
      expect(a.settings, SyncPartStatus.unchanged);
      expect(a.remoteUuid, 'legacy:书A');
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
