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

/// 「删除未启用的代」的计划。
///
/// 分组口径与 [RoundTree] 一致：`(branch_uuid, round_index, father_uuid)`。
/// 每组保留 `is_using = 1` 的全部代；一组一个都没有时保留 [RoundTree.pickWinner]
/// 选出的胜出者（与读取口径一致，避免脏数据把整组删空）。
///
/// 父代被删后后代不可达（见 `docs/database.md` 的 `father_uuid` 说明），
/// 因此被删代的整棵子树一并进 [cascaded]。
///
/// **不变式**：活动链永远不在删除集合里——活动链每一步取的都是组内胜出者，
/// 而胜出者一定被保留；链首是根，更不会被级联带走。
class DeleteUnusedGenerationsPlan {
  const DeleteUnusedGenerationsPlan({
    required this.totalGenerations,
    this.unused = const [],
    this.cascaded = const [],
  });

  /// 清理前全书代数（含所有分支）。
  final int totalGenerations;

  /// 未启用的代（每组保留当前选中代；组内无选中时保留胜出者）。
  final List<String> unused;

  /// 仅因父代在删除集合里而不可达的后代。
  final List<String> cascaded;

  /// 需要物理删除的全部代 uuid（先未启用，后级联）。
  List<String> get uuidsToDelete => [...unused, ...cascaded];

  int get unusedCount => unused.length;

  int get cascadedCount => cascaded.length;

  int get total => unused.length + cascaded.length;

  bool get isEmpty => total == 0;

  static const DeleteUnusedGenerationsPlan empty =
      DeleteUnusedGenerationsPlan(totalGenerations: 0);
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

  /// 从某一代「拷贝链」到新分支：计算待写入的 [Branch]。
  ///
  /// 与 [planFork] 的区别：拷贝分支的链里已经有内容（目标代 + 同分支后续各轮
  /// 的全部代，由调用方复制并重映射），所以分支的父级不是「目标代」而是
  /// **目标代的父代**：新分支里目标代是根代（`father_uuid = NULL`），
  /// 上下文靠分支表接回父代；目标代同轮的兄弟代不会复制。
  ///
  /// 父级取值优先级：
  /// 1. [father] 非空 = 目标代在同一分支里的直接父代（正常路径）；
  /// 2. 目标代是链首（没有直接父代）→ 原样沿用 [sourceBranch] 的父级四列，
  ///    这样新分支与源分支拥有完全相同的上文；
  /// 3. 都没有（默认分支第 1 轮）→ 根分支，`father_row` 为空。
  ///
  /// 父代快照只在父代已删时兜底一轮，语义与 [planFork] 一致。
  static Branch planCopyBranch({
    required String branchUuid,
    required String branchName,
    required RoundGeneration? father,
    required Branch? sourceBranch,
    required DateTime now,
    bool working = false,
  }) {
    if (branchUuid.isEmpty) {
      throw ArgumentError('拷贝链需要新的分支 uuid');
    }
    final String fatherRow;
    final int fatherRowIndex;
    final String fatherBranch;
    final String fatherRowShot;
    if (father != null) {
      fatherRow = father.uuid;
      fatherRowIndex = father.roundIndex;
      fatherBranch = father.branchUuid;
      fatherRowShot = BranchFatherSnapshot.encode(father);
    } else if (sourceBranch != null && sourceBranch.fatherRow.isNotEmpty) {
      fatherRow = sourceBranch.fatherRow;
      fatherRowIndex = sourceBranch.fatherRowIndex;
      fatherBranch = sourceBranch.fatherBranch;
      fatherRowShot = sourceBranch.fatherRowShot;
    } else {
      fatherRow = '';
      fatherRowIndex = 1;
      fatherBranch = '';
      fatherRowShot = '';
    }
    return Branch(
      branchUuid: branchUuid,
      fatherRow: fatherRow,
      fatherRowIndex: fatherRowIndex,
      fatherBranch: fatherBranch,
      branchName: branchName,
      fatherRowShot: fatherRowShot,
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

  /// 「删除未启用的代」：按组保留当前选中的代，其余旧代连同因此不可达的
  /// 后代一起删除。
  ///
  /// 纯函数，不碰数据库；规则细节见 [DeleteUnusedGenerationsPlan]。
  static DeleteUnusedGenerationsPlan planDeleteUnusedGenerations({
    required List<RoundMeta> all,
  }) {
    if (all.isEmpty) return DeleteUnusedGenerationsPlan.empty;

    // 1) 按组求保底存活代。
    final groups = <String, List<RoundMeta>>{};
    for (final row in all) {
      final key =
          '${row.branchUuid}\u0000${row.roundIndex}\u0000${row.fatherUuid ?? ''}';
      (groups[key] ??= <RoundMeta>[]).add(row);
    }
    final keep = <String>{};
    for (final group in groups.values) {
      final using = group.where((row) => row.isUsing).toList(growable: false);
      if (using.isEmpty) {
        final winner = RoundTree.pickWinner(group);
        if (winner != null) keep.add(winner.uuid);
      } else {
        keep.addAll(using.map((row) => row.uuid));
      }
    }

    // 2) 组内非存活者都是未启用代。
    final unused = <String>[
      for (final row in all)
        if (!keep.contains(row.uuid)) row.uuid,
    ];
    final unusedSet = unused.toSet();
    if (unusedSet.isEmpty) {
      return DeleteUnusedGenerationsPlan(totalGenerations: all.length);
    }

    // 3) 父代被删 → 后代不可达：一次 BFS 收全子树，避免 O(n²) 扫表。
    final children = RoundTree.childrenIndex(all);
    final doomed = <String>{...unusedSet};
    final queue = <String>[...unusedSet];
    while (queue.isNotEmpty) {
      final kids = children[queue.removeLast()];
      if (kids == null) continue;
      for (final kid in kids) {
        if (doomed.add(kid.uuid)) queue.add(kid.uuid);
      }
    }
    // 输入顺序稳定，便于测试与调试（未启用在前，级联在后）。
    final cascaded = <String>[
      for (final row in all)
        if (doomed.contains(row.uuid) && !unusedSet.contains(row.uuid))
          row.uuid,
    ];
    return DeleteUnusedGenerationsPlan(
      totalGenerations: all.length,
      unused: unused,
      cascaded: cascaded,
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
  ///
  /// 遍历规则与顺序统一由 [RoundTree.subtreeMetas] 提供（父代在前、可防环）：
  /// 「删除此代」只关心集合，拷贝链还需要这个顺序来重映射 `father_uuid`。
  static List<String> subtreeOf(RoundMeta target, List<RoundMeta> all) {
    return RoundTree.subtreeMetas(all: all, root: target)
        .map((row) => row.uuid)
        .toList(growable: false);
  }
}
