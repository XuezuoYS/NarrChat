import 'backup_digest.dart';
import 'backup_manifest.dart';
import 'backup_metrics.dart';
import 'backup_unit.dart';

/// 本机记着的"上次成功同步到哪一代、内容摘要是什么"。
///
/// 由 `sync.db` 的 `sync_unit` 行提供；这里只取备份决策真正需要的两列，
/// 免得备份模块反向依赖数据库层。
class BackupBase {
  const BackupBase({this.generation = 0, this.baseDigest = ''});

  static const BackupBase none = BackupBase();

  /// 本机已知的云端代数（0 = 还没同步过）。
  final int generation;

  /// 上次同步完成后本地内容的摘要。
  final String baseDigest;
}

/// 一个单元这次要做什么。
enum BackupAction {
  /// 两边内容一致，什么都不用做。
  upToDate,

  /// 本地更新：推一代上去。
  push,

  /// 云端更新：拉下来替换本地（本机没有这个库/这本书时也走这里，补建文件）。
  pull,

  /// 两边都变了：交给用户整本二选一。
  conflict,

  /// 本地文件不在了（书被删/物理删除），跳过。
  skipped,
}

/// 决策结果（纯数据，便于 UI 展示与测试断言）。
class BackupPlan {
  const BackupPlan({
    required this.unit,
    required this.action,
    required this.base,
    required this.localDigest,
    this.localMetrics,
    this.remote,
    this.reason = '',
  });

  final BackupUnit unit;
  final BackupAction action;
  final BackupBase base;
  final String localDigest;

  /// 本地内容指标（代数 / 最新轮次 / 内容时间）：冲突 PK 与写清单共用。
  ///
  /// 本地文件不存在时为 null（例如「云端有、本机还没有」的库）。
  final BackupUnitMetrics? localMetrics;

  final BackupManifest? remote;
  final String reason;

  /// 推送时应写的代数。
  ///
  /// 取「云端当前代数」与「本机已知代数」的较大值 +1：云端被整体清空过、
  /// 或本地同步库被删过，都不会写出重复代数把旧快照覆盖掉。
  int get nextGeneration {
    final remoteGeneration = remote?.generation ?? 0;
    final known = base.generation > remoteGeneration
        ? base.generation
        : remoteGeneration;
    return known + 1;
  }
}

/// 备份决策（纯逻辑，无 I/O）。
///
/// 三方现状：本地当前摘要 [localDigest]、本机上次同步后的摘要 [base.baseDigest]、
/// 云端清单 [remote]。
class BackupPlanner {
  BackupPlanner._();

  static BackupPlan plan({
    required BackupUnit unit,
    required String localDigest,
    BackupUnitMetrics? localMetrics,
    BackupBase base = BackupBase.none,
    BackupManifest? remote,
    String? localMissingReason,
  }) {
    if (localMissingReason != null) {
      return BackupPlan(
        unit: unit,
        action: BackupAction.skipped,
        base: base,
        localDigest: localDigest,
        localMetrics: localMetrics,
        remote: remote,
        reason: localMissingReason,
      );
    }

    if (remote == null) {
      return BackupPlan(
        unit: unit,
        action: BackupAction.push,
        base: base,
        localDigest: localDigest,
        localMetrics: localMetrics,
        reason: base.generation == 0 ? '首次备份' : '云端清单缺失，重新推送',
      );
    }

    if (remote.digestVersion != backupDigestVersion) {
      return BackupPlan(
        unit: unit,
        action: BackupAction.conflict,
        base: base,
        localDigest: localDigest,
        localMetrics: localMetrics,
        remote: remote,
        reason: '摘要算法版本不同（云端 ${remote.digestVersion}，本地 $backupDigestVersion）',
      );
    }

    if (remote.digest == localDigest) {
      return BackupPlan(
        unit: unit,
        action: BackupAction.upToDate,
        base: base,
        localDigest: localDigest,
        localMetrics: localMetrics,
        remote: remote,
        reason: '内容一致',
      );
    }

    final localChanged = localDigest != base.baseDigest;
    final remoteAdvanced = remote.generation > base.generation;

    if (remoteAdvanced) {
      if (!localChanged) {
        // 云端更新、本地没动，通常直接跟随；但**云端变少**（删轮 / 删代）
        // 是破坏性变更："时间更新但轮次更少"不能静默跟随，交给 PK / 用户确认。
        if (isDeletionFromRemote(local: localMetrics, remote: remote)) {
          return BackupPlan(
            unit: unit,
            action: BackupAction.conflict,
            base: base,
            localDigest: localDigest,
            localMetrics: localMetrics,
            remote: remote,
            reason: '云端删掉了轮次或代（本地内容更多），需要你确认',
          );
        }
        return BackupPlan(
          unit: unit,
          action: BackupAction.pull,
          base: base,
          localDigest: localDigest,
          localMetrics: localMetrics,
          remote: remote,
          reason: '云端更新到第 ${remote.generation} 代',
        );
      }
      return BackupPlan(
        unit: unit,
        action: BackupAction.conflict,
        base: base,
        localDigest: localDigest,
        localMetrics: localMetrics,
        remote: remote,
        reason: '本地与云端都改过',
      );
    }

    // 云端代数没前进但内容不同（云端被回滚 / 换了目录 / 覆盖过）：
    // 本地没改就跟随云端，本地也改过就以本地为新代推上去。
    if (!localChanged) {
      if (isDeletionFromRemote(local: localMetrics, remote: remote)) {
        return BackupPlan(
          unit: unit,
          action: BackupAction.conflict,
          base: base,
          localDigest: localDigest,
          localMetrics: localMetrics,
          remote: remote,
          reason: '云端内容被换成更少的轮次或代，需要你确认',
        );
      }
      return BackupPlan(
        unit: unit,
        action: BackupAction.pull,
        base: base,
        localDigest: localDigest,
        localMetrics: localMetrics,
        remote: remote,
        reason: '云端内容被替换，跟随云端',
      );
    }
    return BackupPlan(
      unit: unit,
      action: BackupAction.push,
      base: base,
      localDigest: localDigest,
      localMetrics: localMetrics,
      remote: remote,
      reason: '本地有改动且云端未前进',
    );
  }

  /// 云端这一代是不是「变少」了（删轮 / 删代）。
  ///
  /// 只看云端清单带回来的指标：旧版清单没有代数（0）时无法判断，返回 false
  /// （维持原来的跟随逻辑，不凭猜测拦同步）。本地代数更多说明本地还有云端
  /// 已经删掉的内容，这种破坏性变更必须交给人决定，不能静默覆盖本地。
  static bool isDeletionFromRemote({
    required BackupUnitMetrics? local,
    required BackupManifest? remote,
  }) {
    if (local == null || remote == null) return false;
    if (remote.roundGenerationCount <= 0) return false;
    return local.roundGenerationCount > remote.roundGenerationCount;
  }
}
