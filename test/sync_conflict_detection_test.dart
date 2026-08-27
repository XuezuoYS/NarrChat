import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';

/// 冲突检测回归：双端都修改同一本书 / 同一 Mod 时，各身份形态下都必须
/// 判定为「真冲突」（走冲突解决提示），绝不能被静默覆盖 / 静默拉取。
/// 设置类拆成 5 个子部件：同子部件双改 → 冲突；不同子部件双改 → 各自动合并不冲突。
void main() {
  SyncBookRecord rec(String uuid, String title, String s, String r) =>
      SyncBookRecord(
        uuid: uuid,
        title: title,
        parts: SyncBookParts(settingsFp: s, roundsFp: r),
      );

  RemoteBookParts rem(String uuid, String title, String s, String r) =>
      RemoteBookParts(uuid: uuid, title: title, settingsFp: s, roundsFp: r);

  group('书籍设置双端都改（同子部件）', () {
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

    test('混合 uuid（首连/身份迁移过渡态，书名唯一回退）→ 冲突', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'uL': SyncBookBaseParts(title: '书A', settingsFp: 'S0', roundsFp: 'R1'),
        },
        local: {'uL': rec('uL', '书A', 'S2', 'R1')},
        remote: {'uR': rem('uR', '书A', 'S1', 'R1')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books, hasLength(1));
      expect(plan.books.single.hasConflict, isTrue);
    });

    test('共基为空（升级重建/首连）+ 双端内容均与清单不同 → 冲突', () {
      final plan = SyncMergePlanner.plan(
        base: const {},
        local: {'uL': rec('uL', '书A', 'S2', 'R1')},
        remote: {'uR': rem('uR', '书A', 'S1', 'R1')},
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books.single.hasConflict, isTrue);
    });

    test('旧版清单（legacy 键）→ 双改仍冲突', () {
      final plan = SyncMergePlanner.plan(
        base: const {
          'legacy:书A': SyncBookBaseParts(
            title: '书A',
            settingsFp: 'S0',
            roundsFp: 'R1',
          ),
        },
        local: {
          'uL': rec('uL', '书A', 'S2', 'R1'),
        },
        remote: const {
          'legacy:书A': RemoteBookParts(
            uuid: 'legacy:书A',
            title: '书A',
            settingsFp: 'S1',
            roundsFp: 'R1',
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );
      expect(plan.books.single.hasConflict, isTrue);
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

    test('仅本地改设置（远端未改）→ localOnly 自动推；仅远端改 → 自动拉', () {
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

    test('混合 uuid（名称唯一回退）→ Mod 冲突', () {
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
      expect(plan.mods, hasLength(1));
      expect(plan.mods.single.isConflict, isTrue, reason: '双改必须先弹冲突');
    });

    test('共基为空 → 双方内容不同即冲突（不静默覆盖）', () {
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
        baseMods: const {},
      );
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

    test('仅远端改（本地未改）→ remoteOnly 自动拉', () {
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
    });
  });
}
