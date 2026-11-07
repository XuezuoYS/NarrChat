import 'branch.dart';

/// 「从此代拷贝链至新的分支」的结果。
///
/// 只描述**这一次拷贝**产出了什么，不持有任何可修改状态：
/// - [branch] 是新建的分支行（尚未激活，`branchWorking = false`）；
/// - [generationCount] 是拷过去的代数（目标代 + 它的整棵子代树）；
/// - [firstRoundIndex] / [lastRoundIndex] 是这些代覆盖的轮号范围（给完成提示用）。
///
/// 对话框、Provider 与界面都直接读它，避免三处各自再算一遍计数 / 范围。
class BranchCopyResult {
  const BranchCopyResult({
    required this.branch,
    required this.generationCount,
    required this.firstRoundIndex,
    required this.lastRoundIndex,
  });

  /// 新建的分支（`branch_working = false`，等用户点「点击跳转」才切换）。
  final Branch branch;

  /// 拷贝了多少代（目标代 + 全部子代，含同轮的其它历史代）。
  final int generationCount;

  /// 拷贝内容覆盖的最小轮号。
  final int firstRoundIndex;

  /// 拷贝内容覆盖的最大轮号。
  final int lastRoundIndex;

  /// 分支名（完成提示直接展示）。
  String get branchName => branch.branchName;
}
