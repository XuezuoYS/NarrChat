import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/cloud_backup/backup_mods_conflict.dart';
import 'package:narrchat/services/cloud_backup/backup_runner.dart';

import 'helpers/sync_conflict_fixtures.dart';

/// Mod 库逐项 PK（内容指纹 + updated_at）与逐 Mod 合并计划：纯逻辑，无 I/O。
void main() {
  DateTime at(int month, int day) => DateTime.utc(2026, month, day);

  Map<String, Map<String, Object?>> byUuid(List<Map<String, Object?>> rows) => {
    for (final row in rows) (row['mod_uuid'] as String): row,
  };

  group('单个 Mod 的判定', () {
    test('内容指纹一致 → same，updated_at 差再大也不影响', () {
      final local = modRow(
        uuid: 'm1',
        name: '同一个 Mod',
        content: '完全一样的内容',
        updatedAt: at(1, 1),
      );
      final remote = modRow(
        uuid: 'm1',
        name: '同一个 Mod',
        content: '完全一样的内容',
        updatedAt: at(6, 1),
      );
      expect(ModContentDigest.ofRow(local), ModContentDigest.ofRow(remote));

      final pk = ModsPk.compare(localRows: [local], remoteRows: [remote]);

      expect(pk.comparable, isTrue);
      final entry = pk.entries.single;
      expect(entry.uuid, 'm1');
      expect(entry.name, '同一个 Mod');
      expect(entry.status, ModsPkStatus.same);
      expect(entry.needsChoice, isFalse);
      expect(entry.localUpdatedAt, at(1, 1));
      expect(entry.remoteUpdatedAt, at(6, 1));
      expect(pk.outcome, ModsPkOutcome.tie);
      expect(pk.differenceCount, 0);
      expect(pk.explanation, contains('两侧 Mod 内容一致'));
    });

    test('内容不同按 updated_at 判方向，新者胜', () {
      final localWin = ModsPk.compare(
        localRows: [
          modRow(
            uuid: 'm1',
            name: '本地较新',
            content: '本地内容',
            updatedAt: at(3, 1),
          ),
        ],
        remoteRows: [
          modRow(
            uuid: 'm1',
            name: '本地较新',
            content: '云端内容',
            updatedAt: at(1, 1),
          ),
        ],
      );
      expect(localWin.entries.single.status, ModsPkStatus.local);
      expect(localWin.entries.single.localUpdatedAt, at(3, 1));
      expect(localWin.outcome, ModsPkOutcome.local);

      final remoteWin = ModsPk.compare(
        localRows: [
          modRow(
            uuid: 'm1',
            name: '云端较新',
            content: '本地内容',
            updatedAt: at(1, 1),
          ),
        ],
        remoteRows: [
          modRow(
            uuid: 'm1',
            name: '云端较新',
            content: '云端内容',
            updatedAt: at(3, 1),
          ),
        ],
      );
      expect(remoteWin.entries.single.status, ModsPkStatus.remote);
      expect(remoteWin.outcome, ModsPkOutcome.remote);
    });

    test('内容不同但时间相同 / 缺失 → unknown，需要用户选择', () {
      final sameTime = ModsPk.compare(
        localRows: [
          modRow(uuid: 'm1', name: '判不了', content: 'A', updatedAt: at(2, 1)),
        ],
        remoteRows: [
          modRow(uuid: 'm1', name: '判不了', content: 'B', updatedAt: at(2, 1)),
        ],
      );
      expect(sameTime.entries.single.status, ModsPkStatus.unknown);
      expect(sameTime.entries.single.needsChoice, isTrue);
      expect(sameTime.outcome, ModsPkOutcome.unknown);

      final localMissing = {
        ...modRow(uuid: 'm2', name: '缺时间', content: 'A', updatedAt: at(2, 1)),
        'updated_at': '',
      };
      final remoteMissing = {
        ...modRow(uuid: 'm2', name: '缺时间', content: 'B', updatedAt: at(2, 1)),
        'updated_at': '',
      };
      final missing = ModsPk.compare(
        localRows: [localMissing],
        remoteRows: [remoteMissing],
      );
      expect(missing.entries.single.status, ModsPkStatus.unknown);
      expect(missing.entries.single.localUpdatedAt, isNull);
      expect(missing.entries.single.remoteUpdatedAt, isNull);
    });

    test('仅一侧有 → onlyLocal / onlyRemote，都不需要选择', () {
      final pk = ModsPk.compare(
        localRows: [modRow(uuid: 'm-local', name: '只有本地', updatedAt: at(1, 1))],
        remoteRows: [
          modRow(uuid: 'm-remote', name: '只有云端', updatedAt: at(1, 1)),
        ],
      );

      expect(pk.entries, hasLength(2));
      final onlyLocal = pk.entries.firstWhere(
        (entry) => entry.uuid == 'm-local',
      );
      expect(onlyLocal.status, ModsPkStatus.onlyLocal);
      expect(onlyLocal.needsChoice, isFalse);
      expect(onlyLocal.presentLocal, isTrue);
      expect(onlyLocal.presentRemote, isFalse);

      final onlyRemote = pk.entries.firstWhere(
        (entry) => entry.uuid == 'm-remote',
      );
      expect(onlyRemote.status, ModsPkStatus.onlyRemote);
      expect(onlyRemote.needsChoice, isFalse);
      expect(onlyRemote.presentLocal, isFalse);
      expect(onlyRemote.presentRemote, isTrue);

      expect(pk.outcome, ModsPkOutcome.unknown, reason: '两个方向都有');
    });

    test('墓碑参与内容指纹：删除状态不同就算内容不同', () {
      final alive = modRow(
        uuid: 'm1',
        name: 'Mod',
        content: '内容',
        updatedAt: at(1, 1),
      );
      final tombstone = modRow(
        uuid: 'm1',
        name: 'Mod',
        content: '内容',
        updatedAt: at(2, 1),
        deletedAt: at(1, 5),
      );
      expect(
        ModContentDigest.ofRow(alive),
        isNot(ModContentDigest.ofRow(tombstone)),
      );

      // 删除时间本身不入指纹：都带墓碑、只有 deleted_at 时刻不同 → 指纹一致。
      final deletedLater = modRow(
        uuid: 'm1',
        name: 'Mod',
        content: '内容',
        updatedAt: at(2, 1),
        deletedAt: at(3, 1),
      );
      expect(
        ModContentDigest.ofRow(tombstone),
        ModContentDigest.ofRow(deletedLater),
      );
    });

    test('墓碑较新的一侧胜出，删除会跟着传播', () {
      final localDeleted = modRow(
        uuid: 'm1',
        name: '删掉的 Mod',
        content: '内容',
        updatedAt: at(3, 1),
        deletedAt: at(3, 1),
      );
      final remoteAlive = modRow(
        uuid: 'm1',
        name: '删掉的 Mod',
        content: '内容',
        updatedAt: at(1, 1),
      );

      final localWins = ModsPk.compare(
        localRows: [localDeleted],
        remoteRows: [remoteAlive],
      );
      final localEntry = localWins.entries.single;
      expect(localEntry.status, ModsPkStatus.local);
      expect(localEntry.localDeleted, isTrue);
      expect(localEntry.remoteDeleted, isFalse);
      expect(localWins.outcome, ModsPkOutcome.local);

      final remoteWins = ModsPk.compare(
        localRows: [remoteAlive],
        remoteRows: [localDeleted],
      );
      expect(remoteWins.entries.single.status, ModsPkStatus.remote);
    });

    test('状态文案与 uuid 短名', () {
      expect(ModsPkStatus.local.label, '本地较新');
      expect(ModsPkStatus.remote.label, '云端较新');
      expect(ModsPkStatus.same.label, '一致');
      expect(ModsPkStatus.onlyLocal.label, '仅本地有');
      expect(ModsPkStatus.onlyRemote.label, '仅云端有');
      expect(ModsPkStatus.unknown.label, '需要你选');

      const longEntry = ModsPkEntry(
        uuid: '1234567890abcdef',
        name: '长 uuid',
        status: ModsPkStatus.same,
      );
      expect(longEntry.uuidShort, '12345678');
      const shortEntry = ModsPkEntry(
        uuid: 'short',
        name: '短 uuid',
        status: ModsPkStatus.same,
      );
      expect(shortEntry.uuidShort, 'short');
    });
  });

  group('聚合结论与解释', () {
    test('全部差异指向云端：outcome remote，解释带计数', () {
      final pk = ModsPk.compare(
        localRows: [
          modRow(uuid: 'm1', name: '云端较新', content: '旧', updatedAt: at(1, 1)),
        ],
        remoteRows: [
          modRow(uuid: 'm1', name: '云端较新', content: '新', updatedAt: at(2, 1)),
          modRow(uuid: 'm2', name: '仅云端有', updatedAt: at(1, 1)),
        ],
      );

      expect(pk.outcome, ModsPkOutcome.remote);
      expect(pk.remoteWinCount, 1);
      expect(pk.onlyRemoteCount, 1);
      expect(pk.differenceCount, 2);
      expect(pk.explanation, contains('云端较新 1 个'));
      expect(pk.explanation, contains('仅云端有 1 个'));
      expect(pk.explanation, contains('全部指向云端'));
    });

    test('全部差异指向本地：outcome local，解释可自动保留本地', () {
      final pk = ModsPk.compare(
        localRows: [
          modRow(uuid: 'm1', name: '本地较新', content: '新', updatedAt: at(3, 1)),
          modRow(uuid: 'm2', name: '仅本地有', updatedAt: at(1, 1)),
        ],
        remoteRows: [
          modRow(uuid: 'm1', name: '本地较新', content: '旧', updatedAt: at(1, 1)),
        ],
      );

      expect(pk.outcome, ModsPkOutcome.local);
      expect(pk.localWinCount, 1);
      expect(pk.onlyLocalCount, 1);
      expect(pk.explanation, contains('全部指向本地'));
    });

    test('方向不一致：outcome unknown，提示逐个选择', () {
      final pk = ModsPk.compare(
        localRows: [
          modRow(
            uuid: 'm-local',
            name: '本地新',
            content: '本地',
            updatedAt: at(3, 1),
          ),
          modRow(
            uuid: 'm-remote',
            name: '云端新',
            content: '本地',
            updatedAt: at(1, 1),
          ),
        ],
        remoteRows: [
          modRow(
            uuid: 'm-local',
            name: '本地新',
            content: '云端',
            updatedAt: at(1, 1),
          ),
          modRow(
            uuid: 'm-remote',
            name: '云端新',
            content: '云端',
            updatedAt: at(3, 1),
          ),
        ],
      );

      expect(pk.outcome, ModsPkOutcome.unknown);
      expect(pk.localWinCount, 1);
      expect(pk.remoteWinCount, 1);
      expect(pk.needsChoiceCount, 2);
      expect(pk.explanation, contains('本地较新 1 个'));
      expect(pk.explanation, contains('云端较新 1 个'));
      expect(pk.explanation, contains('需要你逐个选择'));
    });

    test('判不了的项优先：其余都指向云端也不自动裁决', () {
      final pk = ModsPk.compare(
        localRows: [
          modRow(uuid: 'm1', name: '云端新', content: '旧', updatedAt: at(1, 1)),
          modRow(uuid: 'm2', name: '时间相同', content: '本地', updatedAt: at(2, 1)),
        ],
        remoteRows: [
          modRow(uuid: 'm1', name: '云端新', content: '新', updatedAt: at(2, 1)),
          modRow(uuid: 'm2', name: '时间相同', content: '云端', updatedAt: at(2, 1)),
        ],
      );

      expect(pk.remoteWinCount, 1);
      expect(pk.unknownCount, 1);
      expect(pk.outcome, ModsPkOutcome.unknown);
      expect(pk.explanation, contains('时间相同或缺失 1 个'));
      expect(pk.explanation, contains('需要你逐个选择'));
    });

    test('两侧都没有 Mod：tie，解释直说没有 Mod', () {
      final pk = ModsPk.compare(localRows: const [], remoteRows: const []);

      expect(pk.comparable, isTrue);
      expect(pk.entries, isEmpty);
      expect(pk.outcome, ModsPkOutcome.tie);
      expect(pk.differenceCount, 0);
      expect(pk.explanation, '两侧都没有 Mod。');
    });

    test('不可比较：outcome unknown，原因原样作解释', () {
      const pk = ModsPk.unavailable('读不到云端快照，需要你选择保留哪一侧。');
      expect(pk.comparable, isFalse);
      expect(pk.entries, isEmpty);
      expect(pk.outcome, ModsPkOutcome.unknown);
      expect(pk.explanation, '读不到云端快照，需要你选择保留哪一侧。');

      const noReason = ModsPk.unavailable('  ');
      expect(noReason.explanation, contains('读不到两侧的逐 Mod 明细'));
    });

    test('排序：unknown → local → remote → onlyLocal → onlyRemote → same', () {
      final pk = ModsPk.compare(
        localRows: [
          modRow(uuid: 'u', name: '未知', content: '本地', updatedAt: at(2, 1)),
          modRow(uuid: 'l', name: '本地新', content: '本地', updatedAt: at(3, 1)),
          modRow(uuid: 'r', name: '云端新', content: '本地', updatedAt: at(1, 1)),
          modRow(uuid: 'lo', name: '仅本地', updatedAt: at(1, 1)),
          modRow(uuid: 's', name: '一致', content: '一样', updatedAt: at(1, 1)),
        ],
        remoteRows: [
          modRow(uuid: 'u', name: '未知', content: '云端', updatedAt: at(2, 1)),
          modRow(uuid: 'l', name: '本地新', content: '云端', updatedAt: at(1, 1)),
          modRow(uuid: 'r', name: '云端新', content: '云端', updatedAt: at(3, 1)),
          modRow(uuid: 'ro', name: '仅云端', updatedAt: at(1, 1)),
          modRow(uuid: 's', name: '一致', content: '一样', updatedAt: at(1, 1)),
        ],
      );

      expect(pk.entries.map((entry) => entry.status).toList(), [
        ModsPkStatus.unknown,
        ModsPkStatus.local,
        ModsPkStatus.remote,
        ModsPkStatus.onlyLocal,
        ModsPkStatus.onlyRemote,
        ModsPkStatus.same,
      ]);
    });

    test('同状态按名称（忽略大小写）再按 uuid 排', () {
      final pk = ModsPk.compare(
        localRows: [
          modRow(
            uuid: 'z-2',
            name: 'b Mod',
            content: '本地',
            updatedAt: at(3, 1),
          ),
          modRow(
            uuid: 'a-1',
            name: 'A Mod',
            content: '本地',
            updatedAt: at(3, 1),
          ),
        ],
        remoteRows: [
          modRow(
            uuid: 'z-2',
            name: 'b Mod',
            content: '云端',
            updatedAt: at(1, 1),
          ),
          modRow(
            uuid: 'a-1',
            name: 'A Mod',
            content: '云端',
            updatedAt: at(1, 1),
          ),
        ],
      );

      expect(pk.entries.map((entry) => entry.uuid).toList(), ['a-1', 'z-2']);
    });
  });

  group('ModsPk.sameEntries（防陈旧决策）', () {
    test('uuid 集合与逐项状态都对上才算同一份', () {
      final localRows = [
        modRow(
          uuid: 'm-local',
          name: '本地新',
          content: '本地',
          updatedAt: at(3, 1),
        ),
        modRow(uuid: 'm-same', name: '一致', content: '一样', updatedAt: at(1, 1)),
      ];
      final remoteRows = [
        modRow(
          uuid: 'm-local',
          name: '本地新',
          content: '云端',
          updatedAt: at(1, 1),
        ),
        modRow(uuid: 'm-same', name: '一致', content: '一样', updatedAt: at(1, 1)),
      ];
      final first = ModsPk.compare(
        localRows: localRows,
        remoteRows: remoteRows,
      );
      final again = ModsPk.compare(
        localRows: localRows,
        remoteRows: remoteRows,
      );
      expect(ModsPk.sameEntries(first, again), isTrue);

      final withNewRemote = ModsPk.compare(
        localRows: localRows,
        remoteRows: [
          ...remoteRows,
          modRow(uuid: 'm-new', name: '云端新增', updatedAt: at(1, 1)),
        ],
      );
      expect(ModsPk.sameEntries(first, withNewRemote), isFalse, reason: '多了一行');

      final swapped = ModsPk.compare(
        localRows: localRows,
        remoteRows: [
          modRow(
            uuid: 'm-local',
            name: '本地新',
            content: '云端',
            updatedAt: at(4, 1),
          ),
          remoteRows.last,
        ],
      );
      expect(
        ModsPk.sameEntries(first, swapped),
        isFalse,
        reason: 'm-local 从 local 变成 remote',
      );

      expect(
        ModsPk.sameEntries(const ModsPk.unavailable('读不到'), first),
        isFalse,
      );
    });
  });

  group('ModsMergePlanner 合并计划', () {
    test('选云端写入远端整行、选本地保留，local / remote / unknown 都按选择走', () {
      final localRows = [
        modRow(
          uuid: 'm-local',
          name: '本地状态',
          content: '本地',
          updatedAt: at(3, 1),
        ),
        modRow(
          uuid: 'm-remote',
          name: '云端状态',
          content: '本地',
          updatedAt: at(1, 1),
        ),
        modRow(
          uuid: 'm-unknown',
          name: '未知状态',
          content: '本地',
          updatedAt: at(2, 1),
        ),
      ];
      final remoteRows = [
        modRow(
          uuid: 'm-local',
          name: '本地状态',
          content: '云端',
          updatedAt: at(1, 1),
        ),
        modRow(
          uuid: 'm-remote',
          name: '云端状态',
          content: '云端',
          updatedAt: at(3, 1),
        ),
        modRow(
          uuid: 'm-unknown',
          name: '未知状态',
          content: '云端',
          updatedAt: at(2, 1),
        ),
      ];
      final comparison = ModsPk.compare(
        localRows: localRows,
        remoteRows: remoteRows,
      );
      expect(comparison.entries.map((entry) => entry.status).toSet(), {
        ModsPkStatus.local,
        ModsPkStatus.remote,
        ModsPkStatus.unknown,
      });
      final remoteByUuid = byUuid(remoteRows);

      final plan = ModsMergePlanner.plan(
        comparison: comparison,
        choices: const {
          'm-local': BackupConflictChoice.remote,
          'm-remote': BackupConflictChoice.local,
          'm-unknown': BackupConflictChoice.remote,
        },
        remoteRowsByUuid: remoteByUuid,
      );

      expect(
        plan.rowsToWrite.map((row) => row['mod_uuid']),
        unorderedEquals(['m-local', 'm-unknown']),
      );
      for (final row in plan.rowsToWrite) {
        expect(
          row,
          equals(remoteByUuid[row['mod_uuid']]),
          reason: '写入的是远端整行（含时间与墓碑）',
        );
      }
      expect(plan.localKept, 1);
      expect(plan.remoteTaken, 2);
      expect(plan.isEmpty, isFalse);
    });

    test('仅云端有 → 自动带入，无需选择', () {
      final localRows = [
        modRow(uuid: 'm-same', name: '一致', content: '一样', updatedAt: at(1, 1)),
      ];
      final remoteRows = [
        modRow(uuid: 'm-same', name: '一致', content: '一样', updatedAt: at(1, 1)),
        modRow(
          uuid: 'm-only-remote',
          name: '仅云端',
          content: '云端独有',
          updatedAt: at(2, 1),
        ),
      ];
      final comparison = ModsPk.compare(
        localRows: localRows,
        remoteRows: remoteRows,
      );

      final plan = ModsMergePlanner.plan(
        comparison: comparison,
        choices: const {},
        remoteRowsByUuid: byUuid(remoteRows),
      );

      expect(plan.rowsToWrite.single['mod_uuid'], 'm-only-remote');
      expect(plan.rowsToWrite.single['name'], '仅云端');
      expect(plan.localKept, 1);
      expect(plan.remoteTaken, 1);
    });

    test('一致 / 仅本地 → 计划为空，不会删除本地行', () {
      final localRows = [
        modRow(uuid: 'm-same', name: '一致', content: '一样', updatedAt: at(1, 1)),
        modRow(
          uuid: 'm-only-local',
          name: '仅本地',
          content: '本地独有',
          updatedAt: at(2, 1),
        ),
      ];
      final remoteRows = [
        modRow(uuid: 'm-same', name: '一致', content: '一样', updatedAt: at(1, 1)),
      ];
      final comparison = ModsPk.compare(
        localRows: localRows,
        remoteRows: remoteRows,
      );

      final plan = ModsMergePlanner.plan(
        comparison: comparison,
        choices: const {},
        remoteRowsByUuid: byUuid(remoteRows),
      );

      expect(plan.rowsToWrite, isEmpty);
      expect(plan.isEmpty, isTrue);
      expect(plan.localKept, 2);
      expect(plan.remoteTaken, 0);
    });

    test('有差异项没给选择 → ModsMergeException，报错带 Mod 名', () {
      final localRows = [
        modRow(
          uuid: 'm-local',
          name: '本地较新的 Mod',
          content: '本地',
          updatedAt: at(3, 1),
        ),
        modRow(
          uuid: 'm-remote',
          name: '云端较新的 Mod',
          content: '本地',
          updatedAt: at(1, 1),
        ),
      ];
      final remoteRows = [
        modRow(
          uuid: 'm-local',
          name: '本地较新的 Mod',
          content: '云端',
          updatedAt: at(1, 1),
        ),
        modRow(
          uuid: 'm-remote',
          name: '云端较新的 Mod',
          content: '云端',
          updatedAt: at(3, 1),
        ),
      ];
      final comparison = ModsPk.compare(
        localRows: localRows,
        remoteRows: remoteRows,
      );

      expect(
        () => ModsMergePlanner.plan(
          comparison: comparison,
          choices: const {'m-local': BackupConflictChoice.local},
          remoteRowsByUuid: byUuid(remoteRows),
        ),
        throwsA(
          isA<ModsMergeException>()
              .having(
                (error) => error.message,
                'message',
                contains('还有 1 个 Mod 没有选择'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('云端较新的 Mod'),
              ),
        ),
      );
    });

    test('选择 skip 等同于没选 → 同样报错', () {
      final localRows = [
        modRow(
          uuid: 'm1',
          name: '需要选择的 Mod',
          content: '本地',
          updatedAt: at(3, 1),
        ),
      ];
      final remoteRows = [
        modRow(
          uuid: 'm1',
          name: '需要选择的 Mod',
          content: '云端',
          updatedAt: at(1, 1),
        ),
      ];
      final comparison = ModsPk.compare(
        localRows: localRows,
        remoteRows: remoteRows,
      );

      expect(
        () => ModsMergePlanner.plan(
          comparison: comparison,
          choices: const {'m1': BackupConflictChoice.skip},
          remoteRowsByUuid: byUuid(remoteRows),
        ),
        throwsA(
          isA<ModsMergeException>().having(
            (error) => error.message,
            'message',
            contains('还有 1 个 Mod 没有选择'),
          ),
        ),
      );
    });

    test('选了云端但远端行缺失 → 抛错并点名 Mod', () {
      final localRows = [
        modRow(uuid: 'm1', name: '找不到远端行', content: '本地', updatedAt: at(3, 1)),
      ];
      final remoteRows = [
        modRow(uuid: 'm1', name: '找不到远端行', content: '云端', updatedAt: at(1, 1)),
      ];
      final comparison = ModsPk.compare(
        localRows: localRows,
        remoteRows: remoteRows,
      );

      expect(
        () => ModsMergePlanner.plan(
          comparison: comparison,
          choices: const {'m1': BackupConflictChoice.remote},
          remoteRowsByUuid: const <String, Map<String, Object?>>{},
        ),
        throwsA(
          isA<ModsMergeException>().having(
            (error) => error.message,
            'message',
            contains('云端缺少 Mod「找不到远端行」'),
          ),
        ),
      );
    });

    test('逐 Mod 明细不可比较时拒绝合并', () {
      expect(
        () => ModsMergePlanner.plan(
          comparison: const ModsPk.unavailable('读不到'),
          choices: const {},
          remoteRowsByUuid: const <String, Map<String, Object?>>{},
        ),
        throwsA(
          isA<ModsMergeException>().having(
            (error) => error.message,
            'message',
            contains('无法合并'),
          ),
        ),
      );
    });
  });
}
