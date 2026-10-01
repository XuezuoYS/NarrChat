import '../utils/memory_entry_format.dart';

/// 「记忆总结轮次合并」策略的**单一真源**（纯逻辑，无 Flutter 依赖）。
///
/// 档位 T = `Book.memorySummaryRounds`（0 = 不开启，5 / 10 = 每项包含的轮次）。
///
/// 【规则】记忆栏保持「一轮一条」，但当**未合并条目**（未被任何区间条目覆盖的
/// 单轮条目）达到 `2T` 时，把**最旧的 T 条**连续未合并条目压成一条合并条目
/// （[kMemoryMergedEntryFormat]），并重复该动作直到剩余未合并条目 `< 2T`
/// ——积压可在同一轮内补齐，不会出现「未合并条目超过两倍」的长期状态。
///
/// 例（T=5，已有合并条目 1-7，散条目 8/9/10）：
/// - 第 11~16 轮：未合并条目数（含本轮新增）< 10 → 不合并；
/// - 第 17 轮：`8..17` 共 10 条 → 合并 `8-12`，剩余 5 条 < 10 → 停止。
///
/// 【不变量】
/// - 已合并条目**永不改写**（冻结；只有用户显式要求才另说，属提示词层例外）；
/// - 合并只吃未合并条目，且**本轮新增的那条永不进入合并区间**
///   （区间个数 k 恒满足 `k*T <= count - T`）。
///
/// 落地口径：[planMemoryMerge] 在本轮**生成之前**调用（输入 = 上一轮落库的
/// 记忆总结全文），产出的动作随当轮指令下发给模型；生成后用
/// [isMemoryMergeApplied] 判定是否完成。
class MemoryMergeRange {
  /// 区间首轮 / 末轮（含两端），区间内共 `endRound - startRound + 1` 条未合并条目。
  final int startRound;
  final int endRound;

  /// 区间首条 / 末条目各自的「时间」段原文（填进合并行的时间区间）。
  final String startTime;
  final String endTime;

  const MemoryMergeRange({
    required this.startRound,
    required this.endRound,
    required this.startTime,
    required this.endTime,
  });

  /// 覆盖的轮次数。
  int get roundCount => endRound - startRound + 1;

  /// 区间徽标文案（如 `8-12`）。
  String get label => '$startRound-$endRound';

  @override
  String toString() => 'MemoryMergeRange($label)';
}

/// 本轮应执行的合并动作（[ranges] 为空 = 本轮无动作）。
class MemoryMergePlan {
  /// 档位（0 = 关闭；[ranges] 必为空）。
  final int tier;

  /// 本轮轮号 N。
  final int newRoundIndex;

  /// 并入本轮新增条目后的**未合并条目数**（诊断 / 文案用）。
  final int looseCount;

  /// 按时间顺序排列的待合并区间（可能多个：一轮内把积压补齐到 `< 2T`）。
  final List<MemoryMergeRange> ranges;

  const MemoryMergePlan({
    required this.tier,
    required this.newRoundIndex,
    required this.looseCount,
    required this.ranges,
  });

  bool get hasAction => ranges.isNotEmpty;

  /// 面向用户的常驻提示（同 `StateGap.uiText` 形态）。
  String get uiText => '记忆总结未按档位（$tier）合并：应合并 '
      '${ranges.map((r) => r.label).join('、')}';

  @override
  String toString() =>
      'MemoryMergePlan(tier=$tier, round=$newRoundIndex, ranges=$ranges)';
}

/// 计算本轮待执行的合并动作。
///
/// [memoryText] = 上一轮（第 [newRoundIndex] - 1 轮）落库的记忆总结全文；
/// [tier] = 本书档位。无动作时返回 `ranges` 为空的计划（档位 0、解析不出条目、
/// 尾部未合并片段末条不是上一轮、未合并条目不足 `2T` 都属此列）。
MemoryMergePlan planMemoryMerge({
  required String memoryText,
  required int tier,
  required int newRoundIndex,
}) {
  MemoryMergePlan none([int looseCount = 0]) => MemoryMergePlan(
        tier: tier,
        newRoundIndex: newRoundIndex,
        looseCount: looseCount,
        ranges: const [],
      );
  if (tier <= 0) return none();

  // 只吃**未合并**（单轮）条目；已合并条目一律不动。
  final loose = [
    for (final e in parseMemoryEntries(memoryText))
      if (!e.isMerged) e,
  ]..sort((a, b) => a.round.compareTo(b.round));
  if (loose.isEmpty) return none();

  // 尾部连续片段（升序、轮号逐 1 相接）；末条必须正好是上一轮，否则
  // 历史存在缺口 / 乱序，本轮不冒险合并。
  if (loose.last.round != newRoundIndex - 1) return none(loose.length);
  final run = <MemoryEntry>[loose.last];
  for (var i = loose.length - 2; i >= 0; i--) {
    if (loose[i].round != run.first.round - 1) break;
    run.insert(0, loose[i]);
  }

  // 本轮将新增一条 → 未合并条目数 + 1。
  final count = run.length + 1;
  final ranges = <MemoryMergeRange>[];
  for (var remaining = count; remaining >= 2 * tier; remaining -= tier) {
    final offset = ranges.length * tier;
    final slice = run.sublist(offset, offset + tier);
    ranges.add(
      MemoryMergeRange(
        startRound: slice.first.round,
        endRound: slice.last.round,
        startTime: slice.first.time,
        endTime: slice.last.time,
      ),
    );
  }
  return MemoryMergePlan(
    tier: tier,
    newRoundIndex: newRoundIndex,
    looseCount: count,
    ranges: ranges,
  );
}

/// [plan] 的全部区间是否都已落地：每个区间都存在**恰好覆盖它**的合并条目
/// （轮次两端一致；分隔符 / 全半角 / 转义由解析层归一）。
bool isMemoryMergeApplied(String memoryText, MemoryMergePlan plan) {
  if (!plan.hasAction) return true;
  final entries = parseMemoryEntries(memoryText);
  for (final range in plan.ranges) {
    final applied = entries.any(
      (e) => e.round == range.startRound && e.roundMax == range.endRound,
    );
    if (!applied) return false;
  }
  return true;
}
