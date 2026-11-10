import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/cloud_backup/backup_digest.dart';
import 'package:narrchat/services/cloud_backup/backup_manifest.dart';
import 'package:narrchat/services/cloud_backup/backup_metrics.dart';
import 'package:narrchat/services/cloud_backup/backup_planner.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';

/// 备份决策矩阵（纯逻辑，无 I/O）。
void main() {
  const unit = BackupUnit.library;

  BackupManifest remote({
    int generation = 1,
    String digest = 'R',
    int digestVersion = backupDigestVersion,
  }) {
    return BackupManifest(
      unitKey: unit.unitKey,
      kind: unit.kind,
      refUuid: '',
      generation: generation,
      digest: digest,
      digestVersion: digestVersion,
      snapshotName: unit.snapshotName(generation),
      savedAt: '2026-01-01T00:00:00.000Z',
    );
  }

  test('云端没有清单：首次备份 → push 第 1 代', () {
    final plan = BackupPlanner.plan(unit: unit, localDigest: 'L');
    expect(plan.action, BackupAction.push);
    expect(plan.nextGeneration, 1);
    expect(plan.reason, contains('首次'));
  });

  test('云端清单丢了但本机有历史：仍 push，且代数接着本机的走', () {
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'L',
      base: const BackupBase(generation: 7, baseDigest: 'L'),
    );
    expect(plan.action, BackupAction.push);
    expect(plan.nextGeneration, 8, reason: '不能退回第 1 代覆盖云端旧快照');
  });

  test('两边内容一致：什么都不做', () {
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'L',
      base: const BackupBase(generation: 3, baseDigest: 'L'),
      remote: remote(generation: 3, digest: 'L'),
    );
    expect(plan.action, BackupAction.upToDate);
  });

  test('云端前进、本地没改：拉取', () {
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'L',
      base: const BackupBase(generation: 2, baseDigest: 'L'),
      remote: remote(generation: 3, digest: 'R'),
    );
    expect(plan.action, BackupAction.pull);
    expect(plan.remote!.generation, 3);
  });

  test('云端前进、本地也改：冲突', () {
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'L2',
      base: const BackupBase(generation: 2, baseDigest: 'L'),
      remote: remote(generation: 3, digest: 'R'),
    );
    expect(plan.action, BackupAction.conflict);
  });

  test('云端没前进、本地改了：推送一代', () {
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'L2',
      base: const BackupBase(generation: 4, baseDigest: 'L'),
      remote: remote(generation: 4, digest: 'L'),
    );
    expect(plan.action, BackupAction.push);
    expect(plan.nextGeneration, 5);
  });

  test('云端被回滚（代数没前进但内容不同）、本地没改：跟随云端', () {
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'L',
      base: const BackupBase(generation: 4, baseDigest: 'L'),
      remote: remote(generation: 2, digest: 'Earliest'),
    );
    expect(plan.action, BackupAction.pull);
  });

  test('云端被回滚、本地也改过：以本地推新代，代数取两边较大值 +1', () {
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'L2',
      base: const BackupBase(generation: 6, baseDigest: 'L'),
      remote: remote(generation: 2, digest: 'Earliest'),
    );
    expect(plan.action, BackupAction.push);
    expect(plan.nextGeneration, 7);
  });

  test('摘要算法版本不同：不做摘要比对，按冲突处理', () {
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'L',
      base: const BackupBase(generation: 1, baseDigest: 'L'),
      remote: remote(generation: 1, digest: 'L', digestVersion: 99),
    );
    expect(plan.action, BackupAction.conflict);
    expect(plan.reason, contains('摘要算法'));
  });

  test('本地文件不存在：跳过（书被删了就不推）', () {
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: '',
      remote: remote(generation: 2),
      localMissingReason: '本地文件不存在',
    );
    expect(plan.action, BackupAction.skipped);
  });

  group('删除型云端变更（时间更新但轮/代减少）', () {
    final book = BackupUnit.book('b1');

    BackupManifest bookRemote({
      int generation = 3,
      int roundGenerationCount = 1,
      int latestRoundIndex = 1,
      String digest = 'R',
    }) {
      return BackupManifest(
        unitKey: book.unitKey,
        kind: book.kind,
        refUuid: 'b1',
        generation: generation,
        digest: digest,
        snapshotName: book.snapshotName(generation),
        savedAt: '2026-01-03T00:00:00.000Z',
        contentUpdatedAt: '2026-01-03T00:00:00.000Z',
        roundGenerationCount: roundGenerationCount,
        latestRoundIndex: latestRoundIndex,
      );
    }

    BackupUnitMetrics localMetrics({int rounds = 5, int generations = 8}) {
      return BackupUnitMetrics(
        roundGenerationCount: generations,
        latestRoundIndex: rounds,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
    }

    test('云端删了轮/代、本地没改：不静默跟随，转成冲突交给人', () {
      final plan = BackupPlanner.plan(
        unit: book,
        localDigest: 'L',
        localMetrics: localMetrics(),
        base: const BackupBase(generation: 2, baseDigest: 'L'),
        remote: bookRemote(),
      );

      expect(plan.action, BackupAction.conflict);
      expect(plan.reason, contains('云端删掉'));
      expect(
        BackupPlanner.isDeletionFromRemote(
          local: plan.localMetrics,
          remote: plan.remote,
        ),
        isTrue,
      );
    });

    test('云端只是正常前进（内容变多）：仍自动拉取', () {
      final plan = BackupPlanner.plan(
        unit: book,
        localDigest: 'L',
        localMetrics: localMetrics(rounds: 3, generations: 4),
        base: const BackupBase(generation: 2, baseDigest: 'L'),
        remote: bookRemote(roundGenerationCount: 6, latestRoundIndex: 5),
      );

      expect(plan.action, BackupAction.pull);
    });

    test('云端被回滚且更少：同样转冲突', () {
      final plan = BackupPlanner.plan(
        unit: book,
        localDigest: 'L',
        localMetrics: localMetrics(),
        base: const BackupBase(generation: 6, baseDigest: 'L'),
        remote: bookRemote(generation: 2),
      );

      expect(plan.action, BackupAction.conflict);
      expect(plan.reason, contains('需要你确认'));
    });

    test('旧版清单没带代数（0）：无法判断，维持跟随云端', () {
      final plan = BackupPlanner.plan(
        unit: book,
        localDigest: 'L',
        localMetrics: localMetrics(),
        base: const BackupBase(generation: 2, baseDigest: 'L'),
        remote: bookRemote(roundGenerationCount: 0, latestRoundIndex: 0),
      );

      expect(plan.action, BackupAction.pull, reason: '不凭猜测拦同步');
      expect(
        BackupPlanner.isDeletionFromRemote(
          local: localMetrics(),
          remote: bookRemote(roundGenerationCount: 0),
        ),
        isFalse,
      );
    });

    test('云端没清单 / 本地没指标：不判定为删除', () {
      expect(
        BackupPlanner.isDeletionFromRemote(local: null, remote: bookRemote()),
        isFalse,
      );
      expect(
        BackupPlanner.isDeletionFromRemote(local: localMetrics(), remote: null),
        isFalse,
      );
    });
  });
}
