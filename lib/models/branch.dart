import '../utils/timestamp_format.dart';

/// 书籍分支（IF 线）。
///
/// 与「代」的区别：分支是一整条可查看、可命名、可独立管理和删除的轮次链，
/// 与其它分支共享书籍设定、不共享轮次。
///
/// - **默认分支不记表**：`branchUuid == ''` 即默认分支，不可删除、不可重命名。
/// - 本分支链首代的 `father_uuid = NULL`；父级信息记在 [fatherRow] /
///   [fatherBranch] 上，因此父代被删除也不影响分支本身。
/// - [fatherRowShot] 是父代内容的 JSON 快照，**只在父代已不存在时**兜底一轮，
///   之后不随父代编辑而更新（刻意的降级）。
class Branch {
  const Branch({
    required this.branchUuid,
    this.fatherRow = '',
    this.fatherRowIndex = 1,
    this.fatherBranch = '',
    required this.branchName,
    this.fatherRowShot = '',
    this.branchWorking = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 默认分支的 uuid（`''`）：不记表，也不可删改。
  static const String defaultBranchUuid = '';

  /// 默认分支的展示名。
  static const String defaultBranchName = '主线';

  final String branchUuid;

  /// 分叉点：父分支上某个**代**的 uuid（不是轮次）。
  final String fatherRow;

  /// 该代的轮号；父行被删后仍可用于展示「从第 x 轮分叉」。
  final int fatherRowIndex;

  /// 该代所在分支；`''` = 默认分支。
  final String fatherBranch;

  /// 分支名（用户命名）。
  final String branchName;

  /// 父代内容快照（JSON）；父代已删时兜底一轮。
  final String fatherRowShot;

  /// 本机当前激活的分支。全 0 = 默认分支激活。
  ///
  /// 这是**本机会话状态**：不进同步摘要、切换分支不触发云备份，
  /// 拉取远端整库后保留本机值。
  final bool branchWorking;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isDefault => branchUuid == defaultBranchUuid;

  /// 展示名：默认分支回落到「主线」。
  String get displayName => isDefault ? defaultBranchName : branchName;

  /// 默认分支的只读实例（不落库）。
  static Branch defaultBranch() {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return Branch(
      branchUuid: defaultBranchUuid,
      branchName: defaultBranchName,
      createdAt: epoch,
      updatedAt: epoch,
    );
  }

  factory Branch.fromRow(Map<String, Object?> row) {
    final now = DateTime.now().toUtc();
    return Branch(
      branchUuid: (row['branch_uuid'] as String?) ?? '',
      fatherRow: (row['father_row'] as String?) ?? '',
      fatherRowIndex: (row['father_row_index'] as int?) ?? 1,
      fatherBranch: (row['father_branch'] as String?) ?? '',
      branchName: (row['branch_name'] as String?) ?? '',
      fatherRowShot: (row['father_row_shot'] as String?) ?? '',
      branchWorking: ((row['branch_working'] as int?) ?? 0) != 0,
      createdAt: parseTimestampOr(row['created_at'], now),
      updatedAt: parseTimestampOr(row['updated_at'], now),
    );
  }

  Map<String, Object?> toRow() {
    return {
      'branch_uuid': branchUuid,
      'father_row': fatherRow,
      'father_row_index': fatherRowIndex,
      'father_branch': fatherBranch,
      'branch_name': branchName,
      'father_row_shot': fatherRowShot,
      'branch_working': branchWorking ? 1 : 0,
      'created_at': formatTimestamp(createdAt),
      'updated_at': formatTimestamp(updatedAt),
    };
  }

  Branch copyWith({
    String? fatherRow,
    int? fatherRowIndex,
    String? fatherBranch,
    String? branchName,
    String? fatherRowShot,
    bool? branchWorking,
    DateTime? updatedAt,
  }) {
    return Branch(
      branchUuid: branchUuid,
      fatherRow: fatherRow ?? this.fatherRow,
      fatherRowIndex: fatherRowIndex ?? this.fatherRowIndex,
      fatherBranch: fatherBranch ?? this.fatherBranch,
      branchName: branchName ?? this.branchName,
      fatherRowShot: fatherRowShot ?? this.fatherRowShot,
      branchWorking: branchWorking ?? this.branchWorking,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
