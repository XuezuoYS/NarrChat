import '../../utils/formats.dart';
import '../../utils/timestamp_format.dart';
import 'backup_digest.dart';
import 'backup_manifest.dart';
import 'backup_metrics.dart';

/// PK 的三条轴（书籍）。
///
/// 用户口径：**代数 = `round_stack` 的行数**（一行就是一代），轮次 = 全书最新
/// 轮号，更新时间 = `book_meta.updated_at`；云端一侧都取自云端清单。
enum SyncPkAxis { generationCount, latestRound, updatedAt }

extension SyncPkAxisLabel on SyncPkAxis {
  /// 轴名（PK 对比表第一列）。
  String get label => switch (this) {
    SyncPkAxis.generationCount => '代数',
    SyncPkAxis.latestRound => '最新轮次',
    SyncPkAxis.updatedAt => '更新时间',
  };

  /// 轴的含义（悬停提示 / 规则说明）。
  String get hint => switch (this) {
    SyncPkAxis.generationCount => 'round_stack 里的代（版本）行数，一行一代',
    SyncPkAxis.latestRound => '全书最大轮号',
    SyncPkAxis.updatedAt => '最近一次内容修改时间',
  };
}

/// 一条轴的比较结果。
enum SyncPkOutcome {
  /// 本地更新。
  local,

  /// 云端更新。
  remote,

  /// 两边一样。
  tie,

  /// 缺少数据，无法比较（旧版云端清单 / 读不出来）。
  unknown,
}

/// 一条轴的比较明细（UI 直接渲染，测试直接断言）。
class SyncPkAxisResult {
  const SyncPkAxisResult({
    required this.axis,
    required this.outcome,
    required this.localText,
    required this.remoteText,
  });

  final SyncPkAxis axis;
  final SyncPkOutcome outcome;

  /// 本地一侧的展示文案。
  final String localText;

  /// 云端（导入端）一侧的展示文案。
  final String remoteText;

  bool get favorsLocal => outcome == SyncPkOutcome.local;
  bool get favorsRemote => outcome == SyncPkOutcome.remote;
}

/// 一次 PK 的完整结果。
class SyncPkResult {
  const SyncPkResult({required this.axes, required this.explanation});

  const SyncPkResult.unavailable(this.explanation)
    : axes = const <SyncPkAxisResult>[];

  /// 逐轴结果（书架冲突时为空：它不做 PK，直接自动合并）。
  final List<SyncPkAxisResult> axes;

  /// 为什么需要 / 不需要用户介入（面向用户的一句话）。
  final String explanation;

  bool get isEmpty => axes.isEmpty;

  /// 三轴是否**全部**指向同一侧（只有本地 / 云端两种算「一致」）。
  bool get unanimous => winner != null;

  /// 一致时的胜者；不一致 / 有未知 / 没有轴时为 null。
  SyncPkOutcome? get winner {
    if (axes.isEmpty) return null;
    final first = axes.first.outcome;
    if (first != SyncPkOutcome.local && first != SyncPkOutcome.remote) {
      return null;
    }
    for (final axis in axes) {
      if (axis.outcome != first) return null;
    }
    return first;
  }

  /// 是否有轴因为缺数据而无法比较。
  bool get hasUnknown =>
      axes.any((axis) => axis.outcome == SyncPkOutcome.unknown);

  /// 胜者文案（没有一致结果时为 null）。
  String? get winnerLabel => switch (winner) {
    SyncPkOutcome.local => '本地',
    SyncPkOutcome.remote => '云端',
    _ => null,
  };
}

/// 冲突 PK：**纯逻辑、无 I/O**。
///
/// 书籍三条轴、Mod 库一条轴；只有「全部轴一致」才算自动裁决，其余一律交回
/// 上层（弹对话框 / 冲突决策页）。书架不做 PK（见 `LibraryMerger`）。
class BackupPk {
  BackupPk._();

  /// 书籍：代数 / 最新轮次 / 更新时间三轴。
  static SyncPkResult decideBook({
    required BackupUnitMetrics? local,
    required BackupManifest? remote,
  }) {
    final axes = <SyncPkAxisResult>[
      _compareNumbers(
        axis: SyncPkAxis.generationCount,
        local: local?.roundGenerationCount,
        remote: remote?.roundGenerationCount,
        localText: (value) => value > 0 ? '$value 代' : '暂无代次',
        remoteText: (value) => value > 0 ? '$value 代' : '未知',
        unknownLocalText: '未知',
      ),
      _compareNumbers(
        axis: SyncPkAxis.latestRound,
        local: local?.latestRoundIndex,
        remote: remote?.latestRoundIndex,
        localText: (value) => value > 0 ? '第 $value 轮' : '暂无轮次',
        remoteText: (value) => value > 0 ? '第 $value 轮' : '未知',
        unknownLocalText: '未知',
      ),
      _compareTimes(
        axis: SyncPkAxis.updatedAt,
        local: local?.updatedAt,
        remote: _parse(remote?.contentUpdatedAt),
      ),
    ];
    return _result(axes);
  }

  /// Mod 库：只有「更新时间」一轴（新者居上）。
  static SyncPkResult decideMods({
    required BackupUnitMetrics? local,
    required BackupManifest? remote,
  }) {
    return _result([
      _compareTimes(
        axis: SyncPkAxis.updatedAt,
        local: local?.updatedAt,
        remote: _parse(remote?.contentUpdatedAt),
      ),
    ]);
  }

  /// 云端清单与本地摘要算法版本不同：内容不可比，直接交给人。
  static bool digestVersionMismatch(BackupManifest? remote) =>
      remote != null && remote.digestVersion != backupDigestVersion;

  static SyncPkResult digestVersionConflict() => const SyncPkResult.unavailable(
    '云端备份与当前版本的内容摘要算法不同，无法自动比较，'
    '请选择保留本地或采用云端。',
  );

  static SyncPkResult _result(List<SyncPkAxisResult> axes) {
    return SyncPkResult(axes: axes, explanation: _explain(axes));
  }

  static SyncPkAxisResult _compareNumbers({
    required SyncPkAxis axis,
    required int? local,
    required int? remote,
    required String Function(int value) localText,
    required String Function(int value) remoteText,
    required String unknownLocalText,
  }) {
    // 云端 0 只可能来自旧版清单（真实空书的同一份数据会同时带着时间），
    // 因此按「未知」处理；本地 0 是真实值（空书），照常参与比较。
    final localKnown = local != null;
    final remoteKnown = remote != null && remote > 0;
    final outcome = _outcomeOf(
      localKnown: localKnown,
      remoteKnown: remoteKnown,
      comparison: (local ?? 0).compareTo(remote ?? 0),
    );
    return SyncPkAxisResult(
      axis: axis,
      outcome: outcome,
      localText: localKnown ? localText(local) : unknownLocalText,
      remoteText: remoteKnown ? remoteText(remote) : '未知',
    );
  }

  static SyncPkAxisResult _compareTimes({
    required SyncPkAxis axis,
    required DateTime? local,
    required DateTime? remote,
  }) {
    final comparison = local == null || remote == null
        ? 0
        : local.toUtc().compareTo(remote.toUtc());
    final outcome = _outcomeOf(
      localKnown: local != null,
      remoteKnown: remote != null,
      comparison: comparison,
    );
    return SyncPkAxisResult(
      axis: axis,
      outcome: outcome,
      localText: local == null ? '未知' : Formats.formatDateTime(local),
      remoteText: remote == null ? '未知' : Formats.formatDateTime(remote),
    );
  }

  static SyncPkOutcome _outcomeOf({
    required bool localKnown,
    required bool remoteKnown,
    required int comparison,
  }) {
    if (!localKnown || !remoteKnown) return SyncPkOutcome.unknown;
    if (comparison == 0) return SyncPkOutcome.tie;
    return comparison > 0 ? SyncPkOutcome.local : SyncPkOutcome.remote;
  }

  static DateTime? _parse(String? raw) => parseTimestamp(raw);

  /// 拼一句人话解释：`代数指向本地，最新轮次与更新时间指向云端` / `三项都指向云端`。
  static String _explain(List<SyncPkAxisResult> axes) {
    if (axes.isEmpty) return '无法比较两侧内容，请选择保留哪一侧。';
    final labels = <SyncPkOutcome, List<String>>{};
    for (final axis in axes) {
      labels.putIfAbsent(axis.outcome, () => <String>[]).add(axis.axis.label);
    }
    final winner = _winnerOf(axes);
    if (winner != null) {
      final side = winner == SyncPkOutcome.local ? '本地' : '云端';
      return '三项都指向$side：$side更新，可自动采用。';
    }
    final parts = <String>[
      for (final entry in labels.entries)
        if (entry.key == SyncPkOutcome.local)
          '${entry.value.join('、')}指向本地'
        else if (entry.key == SyncPkOutcome.remote)
          '${entry.value.join('、')}指向云端'
        else if (entry.key == SyncPkOutcome.tie)
          '${entry.value.join('、')}两边一样'
        else
          '${entry.value.join('、')}缺少数据',
    ];
    return '${parts.join('，')}，无法自动判定，需要你选择。';
  }

  static SyncPkOutcome? _winnerOf(List<SyncPkAxisResult> axes) {
    final first = axes.first.outcome;
    if (first != SyncPkOutcome.local && first != SyncPkOutcome.remote) {
      return null;
    }
    return axes.every((axis) => axis.outcome == first) ? first : null;
  }
}
