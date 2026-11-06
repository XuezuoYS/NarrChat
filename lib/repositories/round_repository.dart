import '../database/book_db.dart';
import '../database/book_db_pool.dart';
import '../models/branch.dart';
import '../models/round.dart';
import '../models/round_generation.dart';
import '../services/branch_rules.dart';
import '../services/round_tree.dart';
import '../utils/uuid_utils.dart';

/// 同一组（分支 + 轮号 + 父代）里存活的代数集合。
class GenerationSet {
  const GenerationSet({required this.generations, this.current});

  /// 组内全部存活代（按组内序号升序）。
  final List<RoundMeta> generations;

  /// 当前选中的那一代（可能为 null：脏数据 / 正在生成）。
  final RoundMeta? current;

  int get total => generations.length;

  bool get hasMultiple => total > 1;

  /// 当前是第几代（1-based；找不到时 1）。
  int get currentIndex {
    final target = current;
    if (target == null) return 1;
    final index = generations.indexWhere((g) => g.uuid == target.uuid);
    return index < 0 ? 1 : index + 1;
  }

  static GenerationSet from(List<RoundMeta> all, RoundMeta target) {
    final group = BranchRules.groupOf(all, target)
      ..sort((a, b) => a.roundSerialNum.compareTo(b.roundSerialNum));
    RoundMeta? current;
    if (target.isUsing) {
      current = target;
    } else {
      final using = group.where((g) => g.isUsing).toList();
      current = using.isEmpty ? null : RoundTree.pickWinner(using);
    }
    return GenerationSet(generations: group, current: current);
  }

  static const GenerationSet empty = GenerationSet(generations: []);
}

/// 一次读取得到的整本书状态：活动链 + 全书元信息 + 分支。
///
/// 元信息与正文分开：`allMeta` 用来算链 / 版本组 / 进度（轻），
/// `rounds` 只有活动链上的正文（界面要展示的那几十到几千轮）。
class RoundChain {
  const RoundChain({
    required this.rounds,
    required this.allMeta,
    required this.branches,
    required this.workingBranch,
  });

  final List<Round> rounds;
  final List<RoundMeta> allMeta;
  final List<Branch> branches;
  final String workingBranch;

  static const RoundChain empty = RoundChain(
    rounds: [],
    allMeta: [],
    branches: [],
    workingBranch: '',
  );

  Round? get tail => rounds.isEmpty ? null : rounds.last;

  /// 活动链的元信息（顺序与 [rounds] 一致）。
  List<RoundMeta> get chainMeta {
    final byUuid = {for (final meta in allMeta) meta.uuid: meta};
    return [
      for (final round in rounds)
        if (byUuid[round.uuid] != null) byUuid[round.uuid]!,
    ];
  }

  Branch? get currentBranch {
    for (final branch in branches) {
      if (branch.branchUuid == workingBranch) return branch;
    }
    return null;
  }

  /// 默认分支 + 各 IF 线的统一列表（默认分支永远第一个）。
  List<Branch> get allBranches => [Branch.defaultBranch(), ...branches];

  GenerationSet generationSetOf(String generationUuid) {
    final target = allMeta.where((m) => m.uuid == generationUuid).firstOrNull;
    if (target == null) return GenerationSet.empty;
    return GenerationSet.from(allMeta, target);
  }

  /// 下一轮的轮号（空分支按分叉点 +1）。
  int get nextRoundIndex => BranchRules.nextRoundIndex(
        chain: chainMeta,
        branch: currentBranch,
      );
}

/// 删除类操作的结果。
class RoundMutation {
  const RoundMutation({this.deleted = 0, this.refusal});

  final int deleted;

  /// 非空 = 被拒绝（例如唯一一代不允许单独删除）。
  final String? refusal;

  bool get isRefused => refusal != null;
}

/// 提示词拼合用的上文。
class PromptContext {
  const PromptContext({
    this.rounds = const [],
    this.fallback,
    this.truncated = false,
  });

  /// 按时间顺序（旧 → 新）的上文，已按 `history_rounds` 截断、已跳过 error 代。
  final List<Round> rounds;

  /// 父代已删时的一轮兜底快照。
  final RoundGeneration? fallback;

  /// 上溯是否因数据缺口中断。
  final bool truncated;
}

/// 当前分支之前的跨分支上文（请求拼装用）。
///
/// 与 [PromptContext] 的区别：**不含当前分支自己的轮次**、不做 error 过滤与最终
/// 截断——Provider 把这段前缀拼进本轮投影后，统一走既有的历史窗口逻辑。
class UpstreamContext {
  const UpstreamContext({
    this.rounds = const [],
    this.fallbackRound,
    this.truncated = false,
  });

  /// 父分支上的上溯代（旧 → 新），不含当前分支。
  final List<Round> rounds;

  /// 直接父代已被删除时，用 `father_row_shot` 解码出的一轮兜底。
  final Round? fallbackRound;

  /// 上溯是否因数据缺口中断。
  final bool truncated;
}

/// 轮次与分支的读写门面（R3）。
///
/// 这里只做"读写 + 规则调用"，不做 UI 状态：`RoundProvider` 持有它。
/// 所有会改内容的操作都会顺手刷新 `book_meta.updated_at`（由 store 保证）。
class RoundRepository {
  RoundRepository({required this.books});

  final BookDbPool books;

  /// 读整本书：活动链正文 + 全书元信息 + 分支。
  Future<RoundChain> loadChain(String bookUuid) async {
    if (bookUuid.isEmpty) return RoundChain.empty;
    final db = await books.open(bookUuid);
    final metas = await db.rounds.listMeta();
    final branches = await db.branches.list();

    Branch? working;
    for (final branch in branches) {
      if (branch.branchWorking) {
        working = branch;
        break;
      }
    }
    final workingUuid = working?.branchUuid ?? Branch.defaultBranchUuid;

    final chainMetas = RoundTree.planChain(metas, workingUuid);
    if (chainMetas.isEmpty) {
      return RoundChain(
        rounds: const [],
        allMeta: metas,
        branches: branches,
        workingBranch: workingUuid,
      );
    }

    final generations = await db.rounds.generations(
      chainMetas.map((m) => m.uuid),
    );
    final byUuid = {for (final generation in generations) generation.uuid: generation};
    final rounds = <Round>[];
    for (final meta in chainMetas) {
      final generation = byUuid[meta.uuid];
      if (generation == null) continue;
      rounds.add(Round.fromGeneration(generation, bookUuid: bookUuid));
    }

    return RoundChain(
      rounds: rounds,
      allMeta: metas,
      branches: branches,
      workingBranch: workingUuid,
    );
  }

  /// 插一代（生成新轮 / 重新生成 / 修改提问都用它）。
  Future<void> appendGeneration({
    required String bookUuid,
    required RoundGeneration generation,
  }) async {
    final db = await books.open(bookUuid);
    await db.rounds.insert(generation);
  }

  /// 切换组内选中（不触发云备份、不动 `updated_at`）。
  Future<void> switchGeneration({
    required String bookUuid,
    required String generationUuid,
  }) async {
    final db = await books.open(bookUuid);
    await db.rounds.setUsing(generationUuid);
  }

  /// 删除一代（连同它的后代子树），组内选中回落到相邻存活代。
  Future<RoundMutation> deleteGeneration({
    required String bookUuid,
    required String generationUuid,
  }) async {
    final db = await books.open(bookUuid);
    final metas = await db.rounds.listMeta();
    final target = metas.where((m) => m.uuid == generationUuid).firstOrNull;
    if (target == null) return const RoundMutation();

    final plan = BranchRules.planDeleteGeneration(target: target, all: metas);
    if (plan.isRefused) {
      return RoundMutation(refusal: plan.refusal);
    }
    await db.rounds.delete(plan.uuidsToDelete);
    // 只有被删的是"当前选中代"才需要回落，否则会莫名其妙换掉用户的视野。
    if (target.isUsing && plan.fallbackUuid != null) {
      await db.rounds.setUsing(plan.fallbackUuid!);
    }
    return RoundMutation(deleted: plan.uuidsToDelete.length);
  }

  /// 删除本轮及之后（本分支全部代 + 因此不可达的行）。
  Future<RoundMutation> deleteRoundAndFollowing({
    required String bookUuid,
    required int roundIndex,
  }) async {
    final db = await books.open(bookUuid);
    final metas = await db.rounds.listMeta();
    final branchUuid = await _workingBranchOf(db);
    final doomed = BranchRules.planDeleteRound(
      all: metas,
      branchUuid: branchUuid,
      fromRoundIndex: roundIndex,
    );
    if (doomed.isEmpty) return const RoundMutation();
    await db.rounds.delete(doomed);
    return RoundMutation(deleted: doomed.length);
  }

  /// 写正文列（重写 / 编辑）。
  Future<void> updateContent({
    required String bookUuid,
    required String generationUuid,
    required Map<String, Object?> fields,
  }) async {
    final db = await books.open(bookUuid);
    await db.rounds.updateContent(generationUuid, fields);
  }

  /// 写提示（关闭红条 / 写警告）。
  Future<void> updateMessage({
    required String bookUuid,
    required String generationUuid,
    required String status,
    required String message,
  }) async {
    final db = await books.open(bookUuid);
    await db.rounds.updateMeta(generationUuid, {
      'message_status': message.trim().isEmpty ? '' : status,
      'message': message,
    });
  }

  /// 从某一代分叉：建分支记录 + 设为当前分支（分支内此时还没有轮次）。
  Future<Branch> forkBranch({
    required String bookUuid,
    required String generationUuid,
    required String branchName,
  }) async {
    final db = await books.open(bookUuid);
    final generation = await db.rounds.generation(generationUuid);
    if (generation == null) {
      throw StateError('找不到要分叉的代：$generationUuid');
    }
    if (generation.meta.isError) {
      throw StateError('失败代不能分叉');
    }
    final branch = BranchRules.planFork(
      from: generation,
      branchUuid: UuidUtils.generateUuidV4(),
      branchName: branchName.trim().isEmpty ? '新分支' : branchName.trim(),
      now: DateTime.now().toUtc(),
    );
    await db.branches.upsert(branch);
    await db.branches.setWorking(branch.branchUuid);
    return branch;
  }

  /// 切换分支（不触发云备份）。
  Future<void> switchBranch({
    required String bookUuid,
    required String branchUuid,
  }) async {
    final db = await books.open(bookUuid);
    await db.branches.setWorking(branchUuid);
  }

  Future<void> renameBranch({
    required String bookUuid,
    required String branchUuid,
    required String name,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('分支名不能为空');
    final db = await books.open(bookUuid);
    final branch = await db.branches.get(branchUuid);
    if (branch == null) throw StateError('分支不存在：$branchUuid');
    await db.branches.upsert(
      branch.copyWith(branchName: trimmed, updatedAt: DateTime.now().toUtc()),
    );
  }

  /// 删除分支：删分支行 + 该分支全部轮次；子分支保留（父信息靠快照兜底）。
  Future<RoundMutation> deleteBranch({
    required String bookUuid,
    required String branchUuid,
  }) async {
    if (branchUuid.isEmpty) {
      return const RoundMutation(refusal: '默认分支不可删除');
    }
    final db = await books.open(bookUuid);
    final metas = await db.rounds.listMeta();
    final doomed = BranchRules.planDeleteBranch(
      all: metas,
      branchUuid: branchUuid,
    );
    // 先删轮次再删分支行：中途中断只会留下"有分支没轮次"的空分支，
    // 不会留下"找不到分支的轮次"（那种行会被孤儿规则清理，内容白丢）。
    // 两个 delete 各自带事务，这里不能再包一层（sqflite 不支持嵌套事务）。
    if (doomed.isNotEmpty) {
      await db.rounds.delete(doomed);
    }
    await db.branches.delete(branchUuid);
    return RoundMutation(deleted: doomed.length);
  }

  /// 拼合提示词上文：跨分支上溯 + 跳过 error 代 + 按历史轮数截断。
  Future<PromptContext> buildPromptContext({
    required String bookUuid,
    required RoundChain chain,
    required int historyRounds,
  }) async {
    if (chain.allMeta.isEmpty) return const PromptContext();

    final walk = RoundTree.buildContext(
      all: chain.allMeta,
      branches: chain.branches,
      branchUuid: chain.workingBranch,
      chain: chain.chainMeta,
    );
    // error 代没有 AI 内容，拼进上文只会污染上下文。
    final usable = walk.fullOldestFirst.where((m) => !m.isError).toList();
    final limit = historyRounds <= 0 ? 1 : historyRounds;
    final picked = usable.length <= limit
        ? usable
        : usable.sublist(usable.length - limit);
    if (picked.isEmpty) {
      return PromptContext(fallback: walk.fallback, truncated: walk.truncated);
    }

    final db = await books.open(bookUuid);
    final generations = await db.rounds.generations(picked.map((m) => m.uuid));
    final byUuid = {for (final generation in generations) generation.uuid: generation};
    final ordered = <Round>[];
    for (final meta in picked) {
      final generation = byUuid[meta.uuid];
      if (generation == null) continue;
      ordered.add(Round.fromGeneration(generation, bookUuid: bookUuid));
    }
    return PromptContext(
      rounds: ordered,
      fallback: walk.fallback,
      truncated: walk.truncated,
    );
  }

  /// 取当前分支之前的跨分支上文前缀（供请求拼装，不写库）。
  ///
  /// - 默认分支 / 空书 → 空前缀；
  /// - 只取最近 [limit] 条（至少 1 条），避免为一次发送读取整条祖先链；
  /// - 父代已删时 [UpstreamContext.fallbackRound] 给出一轮快照兜底；
  /// - [UpstreamContext.rounds] 为旧 → 新；fallback 更旧，调用方应把它排在前面。
  Future<UpstreamContext> loadUpstreamContext({
    required String bookUuid,
    required RoundChain chain,
    required int limit,
  }) async {
    if (chain.allMeta.isEmpty || chain.workingBranch.isEmpty) {
      return const UpstreamContext();
    }
    final walk = RoundTree.buildContext(
      all: chain.allMeta,
      branches: chain.branches,
      branchUuid: chain.workingBranch,
      chain: chain.chainMeta,
    );
    final take = limit < 1 ? 1 : limit;
    final metas = walk.upstream.length <= take
        ? walk.upstream
        : walk.upstream.sublist(walk.upstream.length - take);
    final rounds = <Round>[];
    if (metas.isNotEmpty) {
      final db = await books.open(bookUuid);
      final generations =
          await db.rounds.generations(metas.map((meta) => meta.uuid));
      final byUuid = {
        for (final generation in generations) generation.uuid: generation,
      };
      for (final meta in metas) {
        final generation = byUuid[meta.uuid];
        if (generation == null) continue;
        rounds.add(Round.fromGeneration(generation, bookUuid: bookUuid));
      }
    }
    final fallback = walk.fallback;
    return UpstreamContext(
      rounds: rounds,
      fallbackRound: fallback == null
          ? null
          : Round.fromGeneration(fallback, bookUuid: bookUuid),
      truncated: walk.truncated,
    );
  }

  static Future<String> _workingBranchOf(BookDb db) async {
    final branches = await db.branches.list();
    for (final branch in branches) {
      if (branch.branchWorking) return branch.branchUuid;
    }
    return Branch.defaultBranchUuid;
  }
}
