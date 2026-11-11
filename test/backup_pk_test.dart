import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/cloud_backup/backup_manifest.dart';
import 'package:narrchat/services/cloud_backup/backup_metrics.dart';
import 'package:narrchat/services/cloud_backup/backup_mods_conflict.dart';
import 'package:narrchat/services/cloud_backup/backup_pk.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';

import 'helpers/sync_conflict_fixtures.dart';

/// 冲突 PK：三轴口径与「只有全部一致才自动裁决」的规则。
void main() {
  BackupManifest remoteOf({
    int latestRoundIndex = 0,
    int roundGenerationCount = 0,
    String contentUpdatedAt = '2026-01-01T00:00:00.000Z',
    int digestVersion = 1,
  }) {
    return BackupManifest(
      unitKey: 'book:b1',
      kind: BackupUnitKind.book,
      refUuid: 'b1',
      generation: 3,
      digest: 'remote',
      snapshotName: 'narrbook_b1_shot-g3.db',
      savedAt: '2026-01-02T00:00:00.000Z',
      contentUpdatedAt: contentUpdatedAt,
      latestRoundIndex: latestRoundIndex,
      roundGenerationCount: roundGenerationCount,
      digestVersion: digestVersion,
    );
  }

  BackupUnitMetrics localOf({
    int latestRoundIndex = 0,
    int roundGenerationCount = 0,
    DateTime? updatedAt,
  }) {
    return BackupUnitMetrics(
      latestRoundIndex: latestRoundIndex,
      roundGenerationCount: roundGenerationCount,
      updatedAt: updatedAt,
    );
  }

  /// Mod 库单元的云端清单（没给逐 Mod 明细时只剩整库内容时间可展示）。
  BackupManifest modsRemoteOf({
    String contentUpdatedAt = '2026-01-01T00:00:00.000Z',
    int digestVersion = 1,
  }) {
    return BackupManifest(
      unitKey: BackupUnit.mods.unitKey,
      kind: BackupUnitKind.mods,
      refUuid: '',
      generation: 2,
      digest: 'remote-mods',
      snapshotName: BackupUnit.mods.snapshotName(2),
      savedAt: '2026-01-02T00:00:00.000Z',
      contentUpdatedAt: contentUpdatedAt,
      digestVersion: digestVersion,
    );
  }

  group('书籍三轴', () {
    test('三轴全指向云端：unanimous remote，可自动采用云端', () {
      final result = BackupPk.decideBook(
        local: localOf(
          latestRoundIndex: 1,
          roundGenerationCount: 2,
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
        remote: remoteOf(
          latestRoundIndex: 3,
          roundGenerationCount: 6,
          contentUpdatedAt: '2026-02-01T00:00:00.000Z',
        ),
      );

      expect(result.axes, hasLength(3));
      expect(result.unanimous, isTrue);
      expect(result.winner, SyncPkOutcome.remote);
      expect(result.winnerLabel, '云端');
      expect(result.explanation, contains('三项都指向云端'));
    });

    test('三轴全指向本地：unanimous local，可自动保留本地', () {
      final result = BackupPk.decideBook(
        local: localOf(
          latestRoundIndex: 5,
          roundGenerationCount: 9,
          updatedAt: DateTime.utc(2026, 3, 1),
        ),
        remote: remoteOf(
          latestRoundIndex: 2,
          roundGenerationCount: 3,
          contentUpdatedAt: '2026-01-01T00:00:00.000Z',
        ),
      );

      expect(result.unanimous, isTrue);
      expect(result.winner, SyncPkOutcome.local);
      expect(result.winnerLabel, '本地');
    });

    test('一轴相反：不自动，解释里说清哪一轴指向哪边', () {
      final result = BackupPk.decideBook(
        local: localOf(
          latestRoundIndex: 5,
          roundGenerationCount: 2,
          updatedAt: DateTime.utc(2026, 3, 1),
        ),
        remote: remoteOf(
          latestRoundIndex: 2,
          roundGenerationCount: 6,
          contentUpdatedAt: '2026-01-01T00:00:00.000Z',
        ),
      );

      expect(result.unanimous, isFalse);
      expect(result.winner, isNull);
      expect(result.explanation, contains('代数指向云端'));
      expect(result.explanation, contains('最新轮次'));
      expect(result.explanation, contains('需要你选择'));
    });

    test('一轴持平：不自动（持平不算「一致」）', () {
      final result = BackupPk.decideBook(
        local: localOf(
          latestRoundIndex: 2,
          roundGenerationCount: 6,
          updatedAt: DateTime.utc(2026, 3, 1),
        ),
        remote: remoteOf(
          latestRoundIndex: 3,
          roundGenerationCount: 6,
          contentUpdatedAt: '2026-01-01T00:00:00.000Z',
        ),
      );

      expect(result.unanimous, isFalse);
      expect(result.axes[0].outcome, SyncPkOutcome.tie);
      expect(result.explanation, contains('两边一样'));
    });

    test('云端旧版清单缺代数 / 轮次：按未知处理，不自动', () {
      final result = BackupPk.decideBook(
        local: localOf(
          latestRoundIndex: 3,
          roundGenerationCount: 4,
          updatedAt: DateTime.utc(2026, 3, 1),
        ),
        remote: remoteOf(),
      );

      expect(result.axes, hasLength(3));
      expect(result.axes[0].outcome, SyncPkOutcome.unknown);
      expect(result.axes[0].remoteText, '未知');
      expect(result.hasUnknown, isTrue);
      expect(result.unanimous, isFalse);
      expect(result.explanation, contains('缺少数据'));
    });

    test('本地指标缺失（文件读不出）：同样不自动', () {
      final result = BackupPk.decideBook(local: null, remote: remoteOf());
      expect(result.unanimous, isFalse);
      expect(result.axes.every((axis) => axis.localText == '未知'), isTrue);
    });

    test('轴文案：本地空书显示「暂无代次 / 暂无轮次」', () {
      final result = BackupPk.decideBook(
        local: localOf(updatedAt: DateTime.utc(2026, 1, 1)),
        remote: remoteOf(latestRoundIndex: 1, roundGenerationCount: 1),
      );
      expect(result.axes[0].localText, '暂无代次');
      expect(result.axes[1].localText, '暂无轮次');
      expect(result.axes[2].localText, isNotEmpty);
    });

    test('摘要算法版本不同：判定为冲突并不做指标比较', () {
      expect(
        BackupPk.digestVersionMismatch(remoteOf(digestVersion: 99)),
        isTrue,
      );
      final result = BackupPk.digestVersionConflict();
      expect(result.axes, isEmpty);
      expect(result.explanation, contains('摘要算法'));
    });
  });

  group('轮/代一致、仅时间更新（按时间裁决）', () {
    test('云端时间更近：自动采用云端，不需要用户决定', () {
      final result = BackupPk.decideBook(
        local: localOf(
          latestRoundIndex: 3,
          roundGenerationCount: 5,
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
        remote: remoteOf(
          latestRoundIndex: 3,
          roundGenerationCount: 5,
          contentUpdatedAt: '2026-02-01T00:00:00.000Z',
        ),
      );

      expect(result.axes, hasLength(3));
      expect(result.unanimous, isFalse, reason: '代数与轮次只是持平，不算三轴一致');
      expect(result.decidedByTimeOnly, isTrue);
      expect(result.autoDecision, SyncPkOutcome.remote);
      expect(result.winnerLabel, '云端');
      expect(result.explanation, contains('按时间采用云端'));
    });

    test('本地时间更近：自动保留本地', () {
      final result = BackupPk.decideBook(
        local: localOf(
          latestRoundIndex: 3,
          roundGenerationCount: 5,
          updatedAt: DateTime.utc(2026, 3, 1),
        ),
        remote: remoteOf(
          latestRoundIndex: 3,
          roundGenerationCount: 5,
          contentUpdatedAt: '2026-02-01T00:00:00.000Z',
        ),
      );

      expect(result.decidedByTimeOnly, isTrue);
      expect(result.autoDecision, SyncPkOutcome.local);
      expect(result.explanation, contains('按时间采用本地'));
    });

    test('轮/代一致、时间也持平：不自动，仍需用户选择', () {
      final result = BackupPk.decideBook(
        local: localOf(
          latestRoundIndex: 3,
          roundGenerationCount: 5,
          updatedAt: DateTime.utc(2026, 2, 1),
        ),
        remote: remoteOf(
          latestRoundIndex: 3,
          roundGenerationCount: 5,
          contentUpdatedAt: '2026-02-01T00:00:00.000Z',
        ),
      );

      expect(result.decidedByTimeOnly, isFalse);
      expect(result.autoDecision, isNull);
      expect(result.explanation, contains('两边一样'));
    });

    test('只有代数持平、轮次不同：不走时间裁决', () {
      final result = BackupPk.decideBook(
        local: localOf(
          latestRoundIndex: 4,
          roundGenerationCount: 5,
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
        remote: remoteOf(
          latestRoundIndex: 3,
          roundGenerationCount: 5,
          contentUpdatedAt: '2026-02-01T00:00:00.000Z',
        ),
      );

      expect(result.decidedByTimeOnly, isFalse);
      expect(result.autoDecision, isNull);
      expect(result.unanimous, isFalse);
    });

    test('轮/代一致但云端缺时间：未知轴不能拿来裁决', () {
      final result = BackupPk.decideBook(
        local: localOf(
          latestRoundIndex: 3,
          roundGenerationCount: 5,
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
        remote: remoteOf(
          latestRoundIndex: 3,
          roundGenerationCount: 5,
          contentUpdatedAt: '',
        ),
      );

      expect(result.decidedByTimeOnly, isFalse);
      expect(result.autoDecision, isNull);
      expect(result.hasUnknown, isTrue);
    });
  });

  group('Mod 逐项', () {
    ModsPk compareOf({
      required List<Map<String, Object?>> localRows,
      required List<Map<String, Object?>> remoteRows,
    }) => ModsPk.compare(localRows: localRows, remoteRows: remoteRows);

    test('逐项全部指向云端：autoDecision remote / unanimous', () {
      final comparison = compareOf(
        localRows: [
          modRow(
            uuid: 'm1',
            name: '云端较新',
            content: '旧',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        remoteRows: [
          modRow(
            uuid: 'm1',
            name: '云端较新',
            content: '新',
            updatedAt: DateTime.utc(2026, 2, 1),
          ),
          modRow(
            uuid: 'm2',
            name: '仅云端有',
            content: '云端独有',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      );
      expect(comparison.outcome, ModsPkOutcome.remote);

      final result = BackupPk.decideMods(
        // 整库时间反而本地更新：逐 Mod 明细生效后，不看整库时间。
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 3, 1)),
        remote: modsRemoteOf(contentUpdatedAt: '2026-02-01T00:00:00.000Z'),
        comparison: comparison,
      );

      expect(result.axes, isEmpty);
      expect(result.mods, isNotNull);
      expect(result.mods!.comparable, isTrue);
      expect(result.modsOutcome, SyncPkOutcome.remote);
      expect(result.unanimous, isTrue);
      expect(result.winner, SyncPkOutcome.remote);
      expect(result.autoDecision, SyncPkOutcome.remote);
      expect(result.winnerLabel, '云端');
      expect(result.explanation, contains('全部指向云端'));
    });

    test('逐项全部指向本地：autoDecision local / unanimous', () {
      final comparison = compareOf(
        localRows: [
          modRow(
            uuid: 'm1',
            name: '本地较新',
            content: '新',
            updatedAt: DateTime.utc(2026, 3, 1),
          ),
          modRow(
            uuid: 'm2',
            name: '仅本地有',
            content: '本地独有',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        remoteRows: [
          modRow(
            uuid: 'm1',
            name: '本地较新',
            content: '旧',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      );
      expect(comparison.outcome, ModsPkOutcome.local);

      final result = BackupPk.decideMods(
        // 云端整库时间更新也不影响逐项结论。
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 1, 1)),
        remote: modsRemoteOf(contentUpdatedAt: '2026-03-01T00:00:00.000Z'),
        comparison: comparison,
      );

      expect(result.axes, isEmpty);
      expect(result.mods, isNotNull);
      expect(result.modsOutcome, SyncPkOutcome.local);
      expect(result.unanimous, isTrue);
      expect(result.winner, SyncPkOutcome.local);
      expect(result.autoDecision, SyncPkOutcome.local);
      expect(result.winnerLabel, '本地');
      expect(result.explanation, contains('全部指向本地'));
    });

    test('方向不一致：autoDecision 为 null，明细留给页面逐项选择', () {
      final comparison = compareOf(
        localRows: [
          modRow(
            uuid: 'm-local',
            name: '本地较新',
            content: '本地',
            updatedAt: DateTime.utc(2026, 3, 1),
          ),
          modRow(
            uuid: 'm-remote',
            name: '云端较新',
            content: '本地',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        remoteRows: [
          modRow(
            uuid: 'm-local',
            name: '本地较新',
            content: '云端',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
          modRow(
            uuid: 'm-remote',
            name: '云端较新',
            content: '云端',
            updatedAt: DateTime.utc(2026, 3, 1),
          ),
        ],
      );

      final result = BackupPk.decideMods(
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 1, 1)),
        remote: modsRemoteOf(contentUpdatedAt: '2026-01-01T00:00:00.000Z'),
        comparison: comparison,
      );

      expect(result.axes, isEmpty, reason: '逐 Mod 明细替代整库时间轴');
      expect(result.mods, isNotNull);
      expect(result.mods!.outcome, ModsPkOutcome.unknown);
      expect(result.modsOutcome, SyncPkOutcome.unknown);
      expect(result.unanimous, isFalse);
      expect(result.winner, isNull);
      expect(result.autoDecision, isNull);
      expect(result.explanation, contains('需要你逐个选择'));
    });

    test('有任何一项判不了：不自动裁决', () {
      final comparison = compareOf(
        localRows: [
          modRow(
            uuid: 'm1',
            name: '云端较新',
            content: '旧',
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
          modRow(
            uuid: 'm2',
            name: '时间相同',
            content: '本地',
            updatedAt: DateTime.utc(2026, 2, 1),
          ),
        ],
        remoteRows: [
          modRow(
            uuid: 'm1',
            name: '云端较新',
            content: '新',
            updatedAt: DateTime.utc(2026, 2, 1),
          ),
          modRow(
            uuid: 'm2',
            name: '时间相同',
            content: '云端',
            updatedAt: DateTime.utc(2026, 2, 1),
          ),
        ],
      );

      final result = BackupPk.decideMods(
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 1, 1)),
        remote: modsRemoteOf(contentUpdatedAt: '2026-01-01T00:00:00.000Z'),
        comparison: comparison,
      );

      expect(result.modsOutcome, SyncPkOutcome.unknown);
      expect(result.autoDecision, isNull);
      expect(result.winner, isNull);
      expect(result.explanation, contains('时间相同或缺失 1 个'));
    });

    test('没有逐 Mod 明细：时间轴只作展示，结论强制 unknown', () {
      final result = BackupPk.decideMods(
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 3, 1)),
        remote: modsRemoteOf(contentUpdatedAt: '2026-02-01T00:00:00.000Z'),
      );

      expect(result.axes, hasLength(1));
      final axis = result.axes.single;
      expect(axis.axis, SyncPkAxis.updatedAt);
      expect(axis.outcome, SyncPkOutcome.unknown, reason: '本地整库时间更新也不自动裁决');
      expect(axis.localText, isNot('未知'));
      expect(result.hasUnknown, isTrue);
      expect(result.unanimous, isFalse);
      expect(result.winner, isNull);
      expect(result.autoDecision, isNull);
      expect(result.winnerLabel, isNull);
      expect(result.decidedByTimeOnly, isFalse);
      expect(result.mods, isNull);
      expect(result.modsOutcome, isNull);
      expect(result.explanation, contains('读不到两侧的逐 Mod 明细'));
    });

    test('逐 Mod 明细读不出来（unavailable）：展示原因，不自动裁决', () {
      const unavailable = ModsPk.unavailable('读不到云端 Mod 快照，需要你选择保留哪一侧。');
      final result = BackupPk.decideMods(
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 3, 1)),
        remote: modsRemoteOf(contentUpdatedAt: '2026-02-01T00:00:00.000Z'),
        comparison: unavailable,
      );

      expect(result.mods, isNotNull);
      expect(result.mods!.comparable, isFalse);
      expect(result.modsOutcome, isNull);
      expect(result.axes.single.outcome, SyncPkOutcome.unknown);
      expect(result.autoDecision, isNull);
      expect(result.explanation, '读不到云端 Mod 快照，需要你选择保留哪一侧。');
    });

    test('云端清单摘要版本不同：走 digestVersionConflict', () {
      final remote = modsRemoteOf(digestVersion: 99);
      expect(BackupPk.digestVersionMismatch(remote), isTrue);

      final result = BackupPk.digestVersionConflict();
      expect(result.axes, isEmpty);
      expect(result.mods, isNull);
      expect(result.autoDecision, isNull);
      expect(result.explanation, contains('摘要算法'));
    });
  });
}
