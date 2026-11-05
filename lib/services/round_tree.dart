import '../models/branch.dart';
import '../models/branch_father_snapshot.dart';
import '../models/round_generation.dart';

/// 活动链解析结果：当前分支能看到的轮次，加上跨分支上溯到的上文。
///
/// [chain] 是界面真正展示的那条链；[upstream] 只给模型拼合用，不显示。
class ContextWalk {
  const ContextWalk({
    required this.chain,
    this.upstream = const [],
    this.fallback,
    this.truncated = false,
  });

  /// 当前分支的活动链（旧 → 新）。
  final List<RoundMeta> chain;

  /// 分支头之前、跨分支上溯到的代（旧 → 新）。
  final List<RoundMeta> upstream;

  /// 父代已删除时的兜底快照（最多补一轮）。
  final RoundGeneration? fallback;

  /// 上溯是否因数据缺口而中断（提示词可能缺上文）。
  final bool truncated;

  /// 拼合用的完整序列（旧 → 新）。
  List<RoundMeta> get fullOldestFirst => [...upstream, ...chain];

  bool get isEmpty => chain.isEmpty && upstream.isEmpty && fallback == null;
}

/// 轮次树的**纯函数**规则。
///
/// 这里不碰任何 I/O：输入是全书轻量索引（[RoundMeta] 列表）与分支表，
/// 输出是链 / 计划。好处是同输入同输出，多设备、多次读取结果一致，
/// 也便于把「分支、版本、删除回落」这些容易写歪的规则全部单测住。
///
/// 数据模型：`branch -> round(逻辑分层) -> 代(row)`。
/// 分代只靠 `father_uuid`，**不靠轮号排序**——轮号允许断裂，
/// 跟着父指针走才不会被断裂的轮号带偏。
class RoundTree {
  RoundTree._();

  /// 环保险丝：正常数据远小于这个数，真的绕成环也能停下来。
  static const int _maxWalk = 200000;

  /// 建索引：父代 uuid → 直接子代列表（根不入表）。
  static Map<String, List<RoundMeta>> childrenIndex(List<RoundMeta> all) {
    final index = <String, List<RoundMeta>>{};
    for (final row in all) {
      final father = row.fatherUuid;
      if (father == null || father.isEmpty) continue;
      (index[father] ??= <RoundMeta>[]).add(row);
    }
    return index;
  }

  /// 组的胜出者：优先 `is_using`，否则序号最大者；并列时 uuid 字典序最小。
  ///
  /// 同一组出现多个 `is_using` 属脏数据（同步可能带来），这里也按同一口径
  /// 选出一个，调用方可用 [usingConflicts] 找出需要自愈的组。
  static RoundMeta? pickWinner(List<RoundMeta> group) {
    if (group.isEmpty) return null;
    final using = group.where((g) => g.isUsing).toList();
    final pool = using.isNotEmpty ? using : group;
    RoundMeta best = pool.first;
    for (final row in pool.skip(1)) {
      if (row.roundSerialNum > best.roundSerialNum) {
        best = row;
      } else if (row.roundSerialNum == best.roundSerialNum &&
          row.uuid.compareTo(best.uuid) < 0) {
        best = row;
      }
    }
    return best;
  }

  /// 某分支的链首（该分支内 `father_uuid` 为空的代）。
  ///
  /// 正常数据每组只有一个链首；脏数据有多个时按 [pickWinner] 的口径挑一个，
  /// 保证解析确定。
  static RoundMeta? headOf(List<RoundMeta> all, String branchUuid) {
    final roots = all
        .where((r) => r.branchUuid == branchUuid && r.isRoot)
        .toList(growable: false);
    if (roots.isEmpty) return null;
    return pickWinner(roots);
  }

  /// 解析当前分支的活动链（旧 → 新）。
  ///
  /// 规则：从链首出发，每一步在「父代 = 当前代」的组里取胜出者；
  /// 组里没有代则链结束（后续内容仍在库里，切回原父就回来）。
  static List<RoundMeta> planChain(List<RoundMeta> all, String branchUuid) {
    final head = headOf(all, branchUuid);
    if (head == null) return const [];
    final byFather = childrenIndex(all);
    final chain = <RoundMeta>[head];
    final visited = <String>{head.uuid};
    var current = head;
    for (var step = 0; step < _maxWalk; step++) {
      final kids = byFather[current.uuid];
      if (kids == null || kids.isEmpty) break;
      final sameBranch = kids.where((k) => k.branchUuid == branchUuid).toList();
      if (sameBranch.isEmpty) break;
      final next = pickWinner(sameBranch);
      if (next == null || !visited.add(next.uuid)) break;
      chain.add(next);
      current = next;
    }
    return chain;
  }

  /// 链尾（最新一轮）；空链返回 null。
  static RoundMeta? chainTail(List<RoundMeta> chain) =>
      chain.isEmpty ? null : chain.last;

  /// 下一轮的轮号：链尾 +1；空链默认从第 1 轮开始。
  static int nextRoundIndex(List<RoundMeta> chain) =>
      chain.isEmpty ? 1 : chain.last.roundIndex + 1;

  /// 找出「同组多个 is_using」的脏数据组，供自愈使用。
  ///
  /// 返回每组：第一个是应当保留的代，其余是需要清 0 的代。
  static List<List<RoundMeta>> usingConflicts(List<RoundMeta> all) {
    final groups = <String, List<RoundMeta>>{};
    for (final row in all) {
      final key =
          '${row.branchUuid}\u0000${row.roundIndex}\u0000${row.fatherUuid ?? ''}';
      (groups[key] ??= <RoundMeta>[]).add(row);
    }
    final conflicts = <List<RoundMeta>>[];
    for (final group in groups.values) {
      final using = group.where((g) => g.isUsing).toList();
      if (using.length <= 1) continue;
      final keeper = pickWinner(using)!;
      conflicts.add([
        keeper,
        ...using.where((g) => g.uuid != keeper.uuid),
      ]);
    }
    return conflicts;
  }

  /// 跨分支上溯：当前分支的链 + 分支头之前的上文（只给模型拼合用）。
  ///
  /// 走法：沿 `father_uuid` 往上；到链首时按 `branches.father_row` 跳到父分支
  /// 的那一代继续往上。父代已被删除时，用该分支的 `father_row_shot` 兜底**一轮**
  /// 并停止（刻意的降级：上文可能不完整）。
  static ContextWalk buildContext({
    required List<RoundMeta> all,
    required List<Branch> branches,
    required String branchUuid,
    List<RoundMeta>? chain,
  }) {
    final activeChain = chain ?? planChain(all, branchUuid);
    if (activeChain.isEmpty) {
      return const ContextWalk(chain: []);
    }

    final byUuid = <String, RoundMeta>{for (final row in all) row.uuid: row};
    final byBranch = <String, Branch>{
      for (final branch in branches) branch.branchUuid: branch,
    };

    final upstream = <RoundMeta>[];
    final visited = <String>{for (final row in activeChain) row.uuid};
    var current = activeChain.first;
    var currentBranch = current.branchUuid;
    RoundGeneration? fallback;
    var truncated = false;

    for (var step = 0; step < _maxWalk; step++) {
      final father = current.fatherUuid;
      if (father != null && father.isNotEmpty) {
        final parent = byUuid[father];
        if (parent == null) {
          // 父代已不存在：本代不可达，上溯到此为止。
          truncated = true;
          break;
        }
        if (!visited.add(parent.uuid)) break;
        upstream.insert(0, parent);
        current = parent;
        currentBranch = parent.branchUuid;
        continue;
      }

      // 已到本分支的链首：按分支表跳到父分支的那一代。
      final branch = byBranch[currentBranch];
      if (branch == null || branch.fatherRow.isEmpty) break;
      final parent = byUuid[branch.fatherRow];
      if (parent == null) {
        fallback = BranchFatherSnapshot.decode(branch.fatherRowShot);
        if (fallback == null) truncated = true;
        break;
      }
      if (!visited.add(parent.uuid)) break;
      upstream.insert(0, parent);
      current = parent;
      currentBranch = parent.branchUuid;
    }

    return ContextWalk(
      chain: activeChain,
      upstream: upstream,
      fallback: fallback,
      truncated: truncated,
    );
  }
}
