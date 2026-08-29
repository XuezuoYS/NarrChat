import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';

/// 冲突检测回归：双端都修改**同一本书（同一 uuid）** / **同一 Mod** 时，必须
/// 判定为「真冲突」（走冲突解决提示），绝不能被静默覆盖 / 静默拉取。
/// 身份只有 uuid：同名而 uuid 不同 = 两个独立实体，各自判定，绝不互相链接。
/// 设置类为单部件（任一字段双改即冲突）；**仅云端改动的设置类部件**不再是
/// "自动拉取"，而是 `remoteOnly + needsReview` → 动作层折叠进确认通道
/// （冲突对话框 + 合并决策页），本文件在规划层断言状态与 needsReview。
void main() {
  SyncBookRecord rec(String uuid, String title, String s, String r) =>
      SyncBookRecord(
        uuid: uuid,
        title: title,
        parts: SyncBookParts(settingsFp: s, roundsFp: r),
      );

  RemoteBookParts rem(String uuid, String title, String s, String r) =>
      RemoteBookParts(uuid: uuid, title: title, settingsFp: s, roundsFp: r);

  group('书籍设置双端都改（同一 uuid 才算同一本书）', () {
    test('同 uuid（正常同步态）→ 冲突', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R1'),
        },
        local: {'u1': rec('u1', '书A', 'S2', 'R1')},
        remote: {'u1': rem('u1', '书A', 'S1', 'R1')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books.single.hasConflict, isTrue, reason: '双改必须先弹冲突');
      expect(plan.books.single.settings, SyncPartStatus.conflict);
    });

    test('同名但 uuid 不同 → 不链接：本地侧走删除冲突进人工通道，远端那本独立拉取', () {
      // 共基 / 本地一侧是 uL，远端清单里是另一本同名书 uR：标题不参与匹配，
      // 因此不会出现「按名并成一本后双改冲突」，而是两个独立实体各自判定。
      final plan = SyncMergePlanner.plan(
        base: const {
          'uL': SyncBookBaseParts(
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R1',
          ),
        },
        local: {'uL': rec('uL', '书A', 'S2', 'R1')},
        remote: {'uR': rem('uR', '书A', 'S1', 'R1')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books, hasLength(2));
      // 本地这本改过 → 不能被远端同名书的「删除」静默带走 → 删除冲突，仍进人工通道。
      final localSide = plan.books.firstWhere((b) => b.localUuid == 'uL');
      expect(localSide.presence, SyncBookPresence.deletionConflict);
      expect(localSide.hasConflict, isTrue);
      // 远端那本与本地无共基 → 独立新书，按 remoteOnly 拉取。
      final remoteSide = plan.books.firstWhere((b) => b.remoteUuid == 'uR');
      expect(remoteSide.presence, SyncBookPresence.remoteOnly);
      expect(remoteSide.hasConflict, isFalse);
      expect(plan.hasConflict, isTrue);
    });

    test('共基为空（升级重建/首连）+ 同一 uuid 双端内容不同 → 冲突（无 base 时不静默）', () {
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: {'u1': rec('u1', '书A', 'S2', 'R1')},
        remote: {'u1': rem('u1', '书A', 'S1', 'R1')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books.single.hasConflict, isTrue);
      expect(plan.books.single.settings, SyncPartStatus.conflict);
    });

    test('共基键也必须是 uuid：三侧键各异（哪怕同名同内容）→ 不链接、不判双改冲突', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'uB': SyncBookBaseParts(
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R1',
          ),
        },
        local: {'uL': rec('uL', '书A', 'S2', 'R1')},
        remote: {'uR': rem('uR', '书A', 'S1', 'R1')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      // 三侧各一条：本地推、远端拉、只存在于共基的那本既不冲突也不落地。
      expect(plan.books, hasLength(3));
      expect(
        plan.books.where((b) => b.presence == SyncBookPresence.localOnly),
        hasLength(1),
      );
      expect(
        plan.books.where((b) => b.presence == SyncBookPresence.remoteOnly),
        hasLength(1),
      );
      expect(
        plan.books.where((b) => b.presence == SyncBookPresence.none),
        hasLength(1),
      );
      expect(plan.hasConflict, isFalse);
    });
  });

  group('设置部件为单部件（任一字段双改即冲突）', () {
    test('A 改分类、B 改后置词（不同字段）→ 仍为设置冲突（单部件语义）', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'u1': SyncBookBaseParts(
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R1',
          ),
        },
        local: {
          'u1': SyncBookRecord(
            uuid: 'u1',
            title: '书A',
            parts: SyncBookParts(settingsFp: 'S1', roundsFp: 'R1'),
          ),
        },
        remote: {
          'u1': RemoteBookParts(
            uuid: 'u1',
            title: '书A',
            settingsFp: 'S2',
            roundsFp: 'R1',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      final d = plan.books.single;
      expect(d.hasConflict, isTrue, reason: '设置任一字段双改必须先弹冲突');
      expect(d.settings, SyncPartStatus.conflict);
    });

    test('仅本地改设置 → localOnly 自动推；仅远端改 → remoteOnly + 待确认', () {
      final localOnly = SyncMergePlanner.plan(
        base: const {
          'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R1'),
        },
        local: {'u1': rec('u1', '书A', 'S2', 'R1')},
        remote: {'u1': rem('u1', '书A', 'S0', 'R1')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(localOnly.books.single.settings, SyncPartStatus.localOnly);
      expect(localOnly.books.single.hasConflict, isFalse);

      final remoteOnly = SyncMergePlanner.plan(
        base: const {
          'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R1'),
        },
        local: {'u1': rec('u1', '书A', 'S0', 'R1')},
        remote: {'u1': rem('u1', '书A', 'S2', 'R1')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(remoteOnly.books.single.settings, SyncPartStatus.remoteOnly);
      expect(remoteOnly.books.single.hasConflict, isFalse);
      expect(remoteOnly.books.single.needsReview, isTrue,
          reason: '设置类仅云端改动 → 动作层折叠进确认通道');
    });
  });

  group('轮次：无冲突新增自动合并，内容分歧才冲突', () {
    test('远端新增轮次（本地未改）→ remoteOnly 自动拉', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R12'),
        },
        local: {'u1': rec('u1', '书A', 'S0', 'R12')},
        remote: {'u1': rem('u1', '书A', 'S0', 'R13')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      final d = plan.books.single;
      expect(d.rounds, SyncPartStatus.remoteOnly);
      expect(d.hasConflict, isFalse, reason: '无冲突的轮次新增应自动合并');
    });

    test('双方轮次都改（共同轮次分歧）→ 轮次冲突', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R10'),
        },
        local: {'u1': rec('u1', '书A', 'S0', 'R12A')},
        remote: {'u1': rem('u1', '书A', 'S0', 'R12B')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books.single.rounds, SyncPartStatus.conflict);
      expect(plan.books.single.hasConflict, isTrue);
    });
  });

  group('Mod 双端都改', () {
    test('同 uuid → Mod 冲突', () {
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: const {},
        remote: const {},
        localMods: const {
          'm1': SyncModRecord(uuid: 'm1', name: '风格', fingerprint: 'F2'),
        },
        remoteMods: const {
          'm1': RemoteModParts(uuid: 'm1', name: '风格', fingerprint: 'F1'),
        },
        baseMods: const {
          'm1': SyncModBaseParts(name: '风格', fingerprint: 'F0'),
        },
      );
      expect(plan.mods.single.isConflict, isTrue);
    });

    test('同名 Mod 但 uuid 不同 → 不链接：本地侧 deletedOnRemote、远端侧独立导入', () {
      // 共基与本地都在 mL，远端清单里是另一本同名 Mod mR：名称不参与匹配。
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: const {},
        remote: const {},
        localMods: const {
          'mL': SyncModRecord(uuid: 'mL', name: '风格', fingerprint: 'F2'),
        },
        remoteMods: const {
          'mR': RemoteModParts(uuid: 'mR', name: '风格', fingerprint: 'F1'),
        },
        baseMods: const {
          'mL': SyncModBaseParts(name: '风格', fingerprint: 'F0'),
        },
      );
      expect(plan.mods, hasLength(2));
      expect(
        plan.mods.firstWhere((m) => m.localUuid == 'mL').status,
        SyncModStatus.deletedOnRemote,
        reason: '本地这本改过，但远端清单里没有它的 uuid → 按删除流转，不并名',
      );
      expect(
        plan.mods.firstWhere((m) => m.remoteUuid == 'mR').status,
        SyncModStatus.remoteOnly,
      );
      expect(plan.mods.any((m) => m.isConflict), isFalse);
    });

    test('共基为空 + 同一 uuid 双方内容不同 → 冲突（不静默覆盖）', () {
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: const {},
        remote: const {},
        localMods: const {
          'm1': SyncModRecord(uuid: 'm1', name: '风格', fingerprint: 'F2'),
        },
        remoteMods: const {
          'm1': RemoteModParts(uuid: 'm1', name: '风格', fingerprint: 'F1'),
        },
        baseMods: const {},
      );
      expect(plan.mods.single.localUuid, 'm1');
      expect(plan.mods.single.remoteUuid, 'm1');
      expect(plan.mods.single.isConflict, isTrue);
    });
  });

  group('单向修改（不应弹冲突）', () {
    test('仅本地改（远端未改）→ localOnly 自动推', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R1'),
        },
        local: {'u1': rec('u1', '书A', 'S2', 'R1')},
        remote: {'u1': rem('u1', '书A', 'S0', 'R1')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books.single.hasConflict, isFalse);
      expect(plan.books.single.settings, SyncPartStatus.localOnly);
    });

    test('仅远端改（本地未改）→ remoteOnly + 待人工确认', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'u1': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R1'),
        },
        local: {'u1': rec('u1', '书A', 'S0', 'R1')},
        remote: {'u1': rem('u1', '书A', 'S2', 'R1')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books.single.hasConflict, isFalse);
      expect(plan.books.single.settings, SyncPartStatus.remoteOnly);
      expect(plan.books.single.needsReview, isTrue,
          reason: '设置类仅云端改动 → 动作层进确认通道');
      expect(plan.needsReview, isTrue);
    });
  });
}
