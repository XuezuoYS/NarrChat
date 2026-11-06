import '../models/branch.dart';
import '../models/branch_father_snapshot.dart';
import '../models/round_generation.dart';
import 'round_tree.dart';

/// 单代删除的计划。
class DeleteGenerationPlan {
  const DeleteGenerationPlan({
    required this.uuidsToDelete,
    this.fallbackUuid,
    this.refusal,
  });

  /// 要物理删除的代（含目标代自身与它的后代子树）。
  final List<String> uuidsToDelete;

  /// 删除后应回落到的那一代（`null` = 不需要回落，通常是拒绝删除）。
  final String? fallbackUuid;

  /// 拒绝原因；非空时 [uuidsToDelete] 为空。
  final String? refusal;

  bool get isRefused => refusal != null;
}

/// 分支分叉点（父代）的展示信息。
///
/// 父代可能已经删除：此时 [alive] 为 false，代序号从 `branches.father_row_shot`
/// 快照里取（快照是建分支时抓下的一代内容，含 `round_serial_num`）。
class BranchForkPoint {
  const BranchForkPoint({
    required this.fatherUuid,
    required this.roundIndex,
    required this.alive,
    this.generationSerial,
  });

  /// 父代 uuid（= `branches.father_row`）。
  final String fatherUuid;

  /// 父代的轮号（= `branches.father_row_index`）。
  final int roundIndex;

  /// 父代是否仍在库里；false = 已被删除，只能按快照展示。
  final bool alive;

  /// 父代的版本序号（`round_serial_num`）；连快照都没有时是 null。
  final int? generationSerial;
}

/// 分支的创建 / 删除 / 改名规则（纯函数）。
///
/// 只算"该写什么"，不碰数据库；真正落库由 `BranchService` 调用 store 完成。
class BranchRules {
  BranchRules._();

  /// 解析 [branch] 的分叉点；默认分支 / 缺父代数据返回 null。
  ///
  /// 序号优先取**库里还活着的父代**；父代已删时退回快照里的序号，
  /// 这样链首卡片仍能说清「起始自第几轮第几代」。
  static BranchForkPoint? forkPointOf(Branch branch, List<RoundMeta> all) {
    if (branch.isDefault || branch.fatherRow.isEmpty) return null;
    RoundMeta? father;
    for (final meta in all) {
      if (meta.uuid == branch.fatherRow) {
        father = meta;
        break;
      }
    }
    final serial = father?.roundSerialNum ??
        BranchFatherSnapshot.decode(branch.fatherRowShot)?.roundSerialNum;
    return BranchForkPoint(
      fatherUuid: branch.fatherRow,
      roundIndex: branch.fatherRowIndex,
      alive: father != null,
      generationSerial: serial,
    );
  }

  /// 同一组的成员（分支 + 轮号 + 父代）。
  static List<RoundMeta> groupOf(List<RoundMeta> all, RoundMeta target) {
    return all
        .where((r) =>
            r.branchUuid == target.branchUuid &&
            r.roundIndex == target.roundIndex &&
            (r.fatherUuid ?? '') == (target.fatherUuid ?? ''))
        .toList(growable: false);
  }

  /// 下一轮的轮号。
  ///
  /// - 当前分支已有轮次 → 链尾 +1；
  /// - 空分支（刚分叉，还没生成过）→ 分叉点轮号 +1；
  /// - 默认分支空链 → 1（第 0 轮是书籍初始状态，不在 `round_stack` 里）。
  static int nextRoundIndex({
    required List<RoundMeta> chain,
    Branch? branch,
  }) {
    if (chain.isNotEmpty) return chain.last.roundIndex + 1;
    if (branch != null && !branch.isDefault) return branch.fatherRowIndex + 1;
    return 1;
  }

  /// 从某一代分叉：生成待写入的 [Branch]。
  ///
  /// 分支内此刻**没有任何轮次**——用户第一次输入时才会写入链首代
  /// （`father_uuid = NULL`、`round_index = fatherRowIndex + 1`）。
  static Branch planFork({
    required RoundGeneration from,
    required String branchUuid,
    required String branchName,
    required DateTime now,
    bool working = true,
  }) {
    if (branchUuid.isEmpty) {
      throw ArgumentError('分叉需要新的分支 uuid');
    }
    return Branch(
      branchUuid: branchUuid,
      fatherRow: from.uuid,
      fatherRowIndex: from.roundIndex,
      fatherBranch: from.branchUuid,
      branchName: branchName,
      fatherRowShot: BranchFatherSnapshot.encode(from),
      branchWorking: working,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 新一代的元信息骨架（生成 / 重新生成 / 修改提问共用）。
  ///
  /// - [father] 为空 = 链首代；
  /// - [roundIndex] 由调用方按 [nextRoundIndex] 或目标轮号给出；
  /// - [serial] 由调用方按组内最大号 +1 给出。
  static RoundMeta planNewMeta({
    required String uuid,
    required String branchUuid,
    required RoundMeta? father,
    required int roundIndex,
    required int serial,
    required DateTime now,
    bool using = true,
  }) {
    return RoundMeta(
      uuid: uuid,
      fatherUuid: father?.uuid,
      branchUuid: branchUuid,
      roundIndex: roundIndex,
      roundSerialNum: serial,
      isUsing: using,
      operatedAt: now,
    );
  }

  /// 在 [target] 所在组新增一代（重新生成 / 修改提问）。
  ///
  /// 序号取组内最大号 +1；物理删除后允许复用旧号，身份一律靠 uuid。
  static RoundMeta planVersionOf({
    required RoundMeta target,
    required List<RoundMeta> all,
    required String uuid,
    required DateTime now,
  }) {
    final group = groupOf(all, target);
    var maxSerial = 0;
    for (final row in group) {
      if (row.roundSerialNum > maxSerial) maxSerial = row.roundSerialNum;
    }
    return RoundMeta(
      uuid: uuid,
      fatherUuid: target.fatherUuid,
      branchUuid: target.branchUuid,
      roundIndex: target.roundIndex,
      roundSerialNum: maxSerial + 1,
      isUsing: true,
      operatedAt: now,
    );
  }

  /// 「删除此代」：删该代 **及其后代子树**，并把组内选中回落到相邻存活代。
  ///
  /// 回落规则（与 R2 一致）：前一代优先（序号更小的最大者），
  /// 第一代被删才取后一代（序号更大的最小者）；组内只剩它一个则**拒绝删除**，
  /// 提示改用「删除本轮」。
  static DeleteGenerationPlan planDeleteGeneration({
    required RoundMeta target,
    required List<RoundMeta> all,
  }) {
    final survivors = groupOf(all, target)
        .where((r) => r.uuid != target.uuid)
        .toList(growable: false);
    if (survivors.isEmpty) {
      return const DeleteGenerationPlan(
        uuidsToDelete: [],
        refusal: '这是本轮唯一的一代，不能单独删除；如需删除请改用「删除本轮」',
      );
    }

    RoundMeta? previous;
    RoundMeta? next;
    for (final row in survivors) {
      if (row.roundSerialNum < target.roundSerialNum) {
        if (previous == null ||
            row.roundSerialNum > previous.roundSerialNum) {
          previous = row;
        }
      } else if (row.roundSerialNum > target.roundSerialNum) {
        if (next == null || row.roundSerialNum < next.roundSerialNum) {
          next = row;
        }
      }
    }
    final fallback = previous ?? next;

    return DeleteGenerationPlan(
      uuidsToDelete: subtreeOf(target, all),
      fallbackUuid: fallback?.uuid,
    );
  }

  /// 「删除本轮」：删本分支该轮及之后**全部代**，并清理由此不可达的孤儿。
  static List<String> planDeleteRound({
    required List<RoundMeta> all,
    required String branchUuid,
    required int fromRoundIndex,
  }) {
    final doomed = <String>{
      for (final row in all)
        if (row.branchUuid == branchUuid && row.roundIndex >= fromRoundIndex)
          row.uuid,
    };
    if (doomed.isEmpty) return const [];

    // 父在删除集合里的代一律不可达 —— 连后代子树一起带走。
    var changed = true;
    while (changed) {
      changed = false;
      for (final row in all) {
        if (doomed.contains(row.uuid)) continue;
        final father = row.fatherUuid;
        if (father != null && father.isNotEmpty && doomed.contains(father)) {
          doomed.add(row.uuid);
          changed = true;
        }
      }
    }
    return doomed.toList(growable: false);
  }

  /// 「删除分支」：删该分支在轮次表里的全部行；子分支不受影响
  /// （它们的链首是根，父信息靠 `father_row_shot` 兜底）。
  static List<String> planDeleteBranch({
    required List<RoundMeta> all,
    required String branchUuid,
  }) {
    if (branchUuid.isEmpty) {
      throw ArgumentError('默认分支不可删除');
    }
    return all
        .where((r) => r.branchUuid == branchUuid)
        .map((r) => r.uuid)
        .toList(growable: false);
  }

  /// 清理不可达行：父代非空但已不存在 → 本代不可达 → 物理删除。
  ///
  /// 根（`father_uuid` 为空）永远不在此列。
  static List<String> planPurgeOrphans(List<RoundMeta> all) {
    final present = {for (final row in all) row.uuid};
    return all
        .where((row) {
          final father = row.fatherUuid;
          return father != null && father.isNotEmpty && !present.contains(father);
        })
        .map((row) => row.uuid)
        .toList(growable: false);
  }

  /// [target] 及其后代子树的全部 uuid（含自身）。
  static List<String> subtreeOf(RoundMeta target, List<RoundMeta> all) {
    final byFather = RoundTree.childrenIndex(all);
    final result = <String>[target.uuid];
    final visited = <String>{target.uuid};
    final queue = <String>[target.uuid];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      final kids = byFather[current];
      if (kids == null) continue;
      for (final kid in kids) {
        if (!visited.add(kid.uuid)) continue;
        result.add(kid.uuid);
        queue.add(kid.uuid);
      }
    }
    return result;
  }
}
