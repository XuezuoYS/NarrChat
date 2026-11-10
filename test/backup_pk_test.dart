import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/cloud_backup/backup_manifest.dart';
import 'package:narrchat/services/cloud_backup/backup_metrics.dart';
import 'package:narrchat/services/cloud_backup/backup_pk.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';

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

    test('Mod 单轴不受时间裁决影响', () {
      final result = BackupPk.decideMods(
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 1, 1)),
        remote: remoteOf(contentUpdatedAt: '2026-02-01T00:00:00.000Z'),
      );
      expect(result.decidedByTimeOnly, isFalse);
      expect(result.autoDecision, SyncPkOutcome.remote);
    });
  });

  group('Mod 单轴', () {
    test('云端修改时间更新：自动采用云端', () {
      final result = BackupPk.decideMods(
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 1, 1)),
        remote: remoteOf(contentUpdatedAt: '2026-02-01T00:00:00.000Z'),
      );
      expect(result.axes, hasLength(1));
      expect(result.unanimous, isTrue);
      expect(result.winner, SyncPkOutcome.remote);
    });

    test('本地修改时间更新：自动保留本地', () {
      final result = BackupPk.decideMods(
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 3, 1)),
        remote: remoteOf(contentUpdatedAt: '2026-02-01T00:00:00.000Z'),
      );
      expect(result.unanimous, isTrue);
      expect(result.winner, SyncPkOutcome.local);
    });

    test('时间持平或缺失：不自动，交给用户', () {
      final tie = BackupPk.decideMods(
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 2, 1)),
        remote: remoteOf(contentUpdatedAt: '2026-02-01T00:00:00.000Z'),
      );
      expect(tie.unanimous, isFalse);
      expect(tie.axes.single.outcome, SyncPkOutcome.tie);

      final unknown = BackupPk.decideMods(
        local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 2, 1)),
        remote: remoteOf(contentUpdatedAt: ''),
      );
      expect(unknown.unanimous, isFalse);
      expect(unknown.axes.single.outcome, SyncPkOutcome.unknown);
    });
  });
}
