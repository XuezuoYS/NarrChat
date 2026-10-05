import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';
import '../database/round_dao.dart';
import '../database/round_stack_dao.dart';
import '../models/round.dart';
import '../models/round_stack.dart';
import '../utils/uuid_utils.dart';

/// 只读版本索引：把一本书的全部存活代按「分组」组织好，供 UI **同步**查询。
///
/// 一次 `loadMetaByBook`（只读元数据列，**绝不读正文**）建好索引后，
/// 对话页每个气泡 footer 的代次控件 `O(分组大小)` 同步取用，不做任何异步查询
/// （避免 FutureBuilder 闪烁与逐轮查询）。缓存失效由 `versionsRevision` 驱动。
class RoundStackIndex {
  final Map<String, List<RoundStackMeta>> _byGroup;

  RoundStackIndex._(this._byGroup);

  /// 空索引（尚未加载 / 目标书无版本树）。
  RoundStackIndex.empty() : _byGroup = const {};

  factory RoundStackIndex.fromMetas(List<RoundStackMeta> metas) {
    final byGroup = <String, List<RoundStackMeta>>{};
    for (final meta in metas) {
      (byGroup[RoundStackService.groupKey(meta.roundIndex, meta.fatherUuid)] ??=
              <RoundStackMeta>[])
          .add(meta);
    }
    for (final group in byGroup.values) {
      group.sort(_bySerial);
    }
    return RoundStackIndex._(byGroup);
  }

  bool get isEmpty => _byGroup.isEmpty;

  /// 该轮的可切换信息；`null` = 不显示控件（该分组没有存活代）。
  ///
  /// [fatherUuid]：本轮的父锚点（= 上一轮当前代的 uuid；第零轮 / 缺口为 null）。
  /// [currentUuid]：投影行当前指向的代号（失败态 / 无投影行传 null）。
  ///
  /// 失败态（[currentUuid] 为 null 或指向本分组外的行）时 `currentSerial` 为
  /// null、`prevUuid` = 本分组序号最大的存活代 —— 即「还原上一代」的落点。
  RoundVersionInfo? infoFor(
    int roundIndex, {
    required String? fatherUuid,
    required String? currentUuid,
  }) {
    final group = _byGroup[RoundStackService.groupKey(roundIndex, fatherUuid)];
    if (group == null || group.isEmpty) return null;
    RoundStackMeta? current;
    if (currentUuid != null && currentUuid.isNotEmpty) {
      for (final meta in group) {
        if (meta.uuid == currentUuid) {
          current = meta;
          break;
        }
      }
    }
    String? prevUuid;
    String? nextUuid;
    int? prevSerial;
    int? nextSerial;
    if (current == null) {
      // 临时代（失败态 / 待采纳）：回落目标 = 分组内「选中记忆」（无则序号最大者），
      // 即「还原上一代」要还原成用户此前看到的那一代。
      final target = group.firstWhere(
        (meta) => meta.isUse,
        orElse: () => group.last,
      );
      prevUuid = target.uuid;
      prevSerial = target.roundSerialNum;
    } else {
      for (final meta in group) {
        if (meta.roundSerialNum < current.roundSerialNum) {
          prevUuid = meta.uuid;
          prevSerial = meta.roundSerialNum;
        }
      }
      for (final meta in group) {
        if (meta.roundSerialNum > current.roundSerialNum) {
          nextUuid = meta.uuid;
          nextSerial = meta.roundSerialNum;
          break;
        }
      }
    }
    return RoundVersionInfo(
      currentSerial: current?.roundSerialNum,
      latestSerial: group.map((m) => m.roundSerialNum).reduce(math.max),
      aliveCount: group.length,
      currentUuid: current?.uuid,
      prevUuid: prevUuid,
      nextUuid: nextUuid,
      prevSerial: prevSerial,
      nextSerial: nextSerial,
    );
  }

  static int _bySerial(RoundStackMeta a, RoundStackMeta b) {
    final bySerial = a.roundSerialNum.compareTo(b.roundSerialNum);
    if (bySerial != 0) return bySerial;
    final at = a.roundCreatedAt?.millisecondsSinceEpoch ?? 0;
    final bt = b.roundCreatedAt?.millisecondsSinceEpoch ?? 0;
    if (at != bt) return at.compareTo(bt);
    return a.uuid.compareTo(b.uuid);
  }
}

/// 修改还原（版本树）领域服务：承载 `round_stack` 的全部语义。
///
/// 「读权威在 `rounds`」：投影行（`rounds`）永远是读取路径的唯一来源；
/// `round_stack` 是历史与分支库，只在切换 / 采纳 / 元数据查询时参与。
///
/// 事务边界：所有写操作各自开一个事务，把「stack 行 + 投影行 + touchBook」
/// 原子提交；归一化只允许发生在**采纳末尾 / 切换开始前的单分组 / 删除收尾**
/// 三处，绝不进 build 或流式帧。
class RoundStackService {
  RoundStackService({RoundStackDao? stackDao, RoundDao? roundDao})
      : _stack = stackDao ?? RoundStackDao(),
        _rounds = roundDao ?? RoundDao();

  final RoundStackDao _stack;
  final RoundDao _rounds;

  // ---------------------------------------------------------------------------
  // 只读
  // ---------------------------------------------------------------------------

  /// 建该书版本索引（一次元数据查询；UI 同步查询靠它）。
  Future<RoundStackIndex> loadIndex(String bookUuid) async {
    if (bookUuid.isEmpty) return RoundStackIndex.empty();
    final metas = await _stack.loadMetaByBook(bookUuid);
    return RoundStackIndex.fromMetas(metas);
  }

  // ---------------------------------------------------------------------------
  // 写：生成 / 原地修改
  // ---------------------------------------------------------------------------

  /// 生成新一轮（或重写某轮时新增一代）：同分组内新建 `state='use'` 的一代，
  /// 清同组旧 `use`，并把投影行指向它。返回新投影行 id（RAW 缓存归属用）。
  ///
  /// [fatherUuid]：上一轮**当前代**的 uuid（第零轮 / 无前轮传 null）。重写第 i
  /// 轮时应先删该轮起的投影行（见 [deleteProjectionFrom]）再调用，
  /// 旧代**保留**为同父兄弟代，供 `← / →` 切回。
  Future<int> attachNewGeneration({
    required String bookUuid,
    required Round round,
    String? fatherUuid,
  }) async {
    final father = RoundStackRow.normalizeFather(fatherUuid);
    return _inTxn((txn) async {
      final group = await RoundStackDao.loadGroupFrom(
        txn,
        bookUuid,
        round.roundIndex,
        father,
      );
      final row = RoundStackRow.fromRound(
        round,
        uuid: UuidUtils.generateUuidV4(),
        fatherUuid: father,
        roundSerialNum: _nextSerial(group.map((m) => m.roundSerialNum)),
        roundState: 'use',
      );
      await _stack.insertGeneration(txn, row);
      await _stack.setGroupUseState(
        txn,
        clearUse: [
          for (final meta in group)
            if (meta.isUse) meta.uuid,
        ],
      );
      final id = await _rounds.upsertProjectionRow(txn, round, row.uuid);
      await DatabaseHelper.touchBook(txn, bookUuid, rounds: true);
      return id;
    });
  }

  /// 原地修改（不发请求）：同一事务内改「当前代」内容 + 投影行内容。
  ///
  /// 不改 uuid / 序号 / 父 / 状态 / 本代创建时间；投影行刷新 `updated_at`。
  /// 老库（尚未采纳、锚点为空）只改投影行，下次采纳按内容重建代。
  Future<void> applyInPlaceEdit({required Round round}) async {
    final id = round.id;
    if (id == null) return;
    await _inTxn((txn) async {
      if (round.useStackUuid.isNotEmpty) {
        final anchor = await RoundStackDao.getByUuidFrom(txn, round.useStackUuid);
        if (anchor != null) {
          await _stack.updateContent(
            txn,
            RoundStackRow.fromRound(
              round,
              uuid: anchor.uuid,
              fatherUuid: anchor.fatherUuid,
              roundSerialNum: anchor.roundSerialNum,
              roundState: anchor.roundState,
            ),
          );
        }
      }
      await _rounds.updateProjectionFields(txn, id, round.contentMap());
      await DatabaseHelper.touchBook(txn, round.bookUuid, rounds: true);
    });
  }

  /// 删除该轮起的投影行（重写某轮 / 切换前的清理；**不动** `round_stack`）。
  Future<void> deleteProjectionFrom(String bookUuid, int fromRoundIndex) async {
    await _inTxn((txn) async {
      await _rounds.deleteRoundsFrom(txn, bookUuid, fromRoundIndex);
      await DatabaseHelper.touchBook(txn, bookUuid, rounds: true);
    });
  }

  // ---------------------------------------------------------------------------
  // 写：切换
  // ---------------------------------------------------------------------------

  /// 切换到 [targetUuid] 那一代（`← / →`）。
  ///
  /// 步骤 0（防覆盖）：投影行与当前代内容不一致（老客户端 / 外部改动）时先采纳，
  /// 避免把陈旧 stack 内容写回 `rounds`、无声覆盖修改。
  /// 步骤 1（单事务）：归一化该分组 → 置 `use` → 以目标为锚点重算活动链 →
  /// 重建该轮起的投影行 → `touchBook(rounds)`。
  ///
  /// 返回是否真的执行了切换（目标不存在 / 不属于该书 → false）。
  Future<bool> switchTo({
    required String bookUuid,
    required int roundIndex,
    required String targetUuid,
  }) async {
    if (bookUuid.isEmpty || targetUuid.isEmpty) return false;
    if (!await _singleRoundConsistent(bookUuid, roundIndex)) {
      await adoptIfNeeded(bookUuid, force: true);
    }
    return _inTxn((txn) async {
      final target = await RoundStackDao.getByUuidFrom(txn, targetUuid);
      if (target == null || target.bookUuid != bookUuid) return false;
      await _normalizeGroupInTxn(txn, bookUuid, roundIndex, target.fatherUuid);
      final group = await RoundStackDao.loadGroupFrom(
        txn,
        bookUuid,
        roundIndex,
        target.fatherUuid,
      );
      await _stack.setGroupUseState(
        txn,
        setUse: [targetUuid],
        clearUse: [
          for (final meta in group)
            if (meta.isUse && meta.uuid != targetUuid) meta.uuid,
        ],
      );
      final rows = await RoundStackDao.loadByBookFrom(txn, bookUuid);
      final anchor = rows.where((r) => r.uuid == targetUuid).firstOrNull;
      if (anchor == null) return false;
      final chain = planChain(anchor: anchor, byGroup: groupRows(rows));
      await _rounds.replaceProjectionFrom(
        txn,
        bookUuid,
        roundIndex,
        [for (final row in chain) row.toRound()],
      );
      await DatabaseHelper.touchBook(txn, bookUuid, rounds: true);
      return true;
    });
  }

  // ---------------------------------------------------------------------------
  // 写：删除
  // ---------------------------------------------------------------------------

  /// 用户删除轮次。
  ///
  /// - [deleteFollowing] = true：删该轮及之后（投影 + **跨分支全部代**）；
  /// - [deleteFollowing] = false：只删该轮（投影 + 该轮全部代），后续轮次保留，
  ///   其父链断裂 → 随即采纳为「链重启」，历史代随孤儿清理移除。
  ///
  /// 收尾做孤儿清理（[deleteFollowing] 为 false 时由采纳一并完成）。
  Future<void> deleteFrom({
    required String bookUuid,
    required int fromRoundIndex,
    required bool deleteFollowing,
  }) async {
    await _inTxn((txn) async {
      if (deleteFollowing) {
        await _rounds.deleteRoundsFrom(txn, bookUuid, fromRoundIndex);
        await _stack.deleteFromRound(txn, bookUuid, fromRoundIndex);
      } else {
        await _rounds.deleteRoundAt(txn, bookUuid, fromRoundIndex);
        await _stack.deleteRoundAt(txn, bookUuid, fromRoundIndex);
      }
      await DatabaseHelper.touchBook(txn, bookUuid, rounds: true);
    });
    if (deleteFollowing) {
      await purgeOrphans(bookUuid);
    } else {
      await adoptIfNeeded(bookUuid, force: true);
    }
  }

  // ---------------------------------------------------------------------------
  // 写：采纳（`rounds` 为准）
  // ---------------------------------------------------------------------------

  /// 以投影行（`rounds`）为准收敛版本树。
  ///
  /// 触发点只有三处：① 联网同步；② 导入 db 文件；③ 启动时库指纹变化
  /// （这三处传 [force] = true）。[force] = false 时走廉价路径：只在
  /// 「存在空锚点 / 悬空锚点」时才真正工作（`loadRounds` 每次都调，故必须廉价）。
  ///
  /// 返回 null = 无需采纳或没有任何变化（幂等）。
  Future<RoundStackAdoptionReport?> adoptIfNeeded(
    String bookUuid, {
    bool force = false,
  }) async {
    if (bookUuid.isEmpty) return null;
    final db = await DatabaseHelper.instance.database;
    if (!force && await _pointersHealthy(db, bookUuid)) return null;
    final report = await db.transaction((txn) => _adoptInTxn(txn, bookUuid));
    if (report != null && report.hasChanges) {
      await DatabaseHelper.touchBook(db, bookUuid, rounds: true);
    }
    return report;
  }

  /// 全量采纳（启动指纹变化 / 维护入口）：逐书采纳，返回发生变化的本数。
  Future<int> adoptAllBooks({bool force = true}) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('SELECT DISTINCT book_uuid FROM rounds');
    var changed = 0;
    for (final row in rows) {
      final uuid = (row['book_uuid'] as String? ?? '').trim();
      if (uuid.isEmpty) continue;
      final report = await adoptIfNeeded(uuid, force: force);
      if (report != null && report.hasChanges) changed++;
    }
    return changed;
  }

  // ---------------------------------------------------------------------------
  // 写：归一化 / 孤儿清理（自愈）
  // ---------------------------------------------------------------------------

  /// 归一化某分组（切换开始前 / 采纳末尾 / 删除收尾使用）。
  ///
  /// - 分组内多个 `use` → 保留序号最大者，其余置 NULL；
  /// - 无 `use` → 取存活代中序号最大者置 `use`（不新增行）；
  /// - 重复序号 → 保留 `round_created_at` 最新者，其余顺移到最大序号之后。
  ///
  /// 必须「同输入同输出」，否则两台设备各自归一化会互相推送抖动。
  Future<void> normalizeGroup(
    String bookUuid,
    int roundIndex,
    String? fatherUuid,
  ) async {
    await _inTxn((txn) async {
      await _normalizeGroupInTxn(txn, bookUuid, roundIndex, fatherUuid);
    });
  }

  /// 归一化整本书的全部存活代分组。
  Future<void> normalizeBook(String bookUuid) async {
    await _inTxn((txn) async {
      await _normalizeBookInTxn(txn, bookUuid);
    });
  }

  /// 孤儿清理：`father_uuid` **非空但找不到对应行** = 不可达（视为已删除），物理删除。
  ///
  /// **根（`father_uuid IS NULL` / 空串）不算孤儿**：它表示「本代没有父」（链首），
  /// 是合法的可存活行；清理只针对「父查不到」的非空父引用。
  /// 幂等（迭代到不动点）；返回删除行数。
  Future<int> purgeOrphans(String bookUuid) async {
    return _inTxn((txn) => _purgeOrphansInTxn(txn, bookUuid));
  }

  // ---------------------------------------------------------------------------
  // 纯函数（可独立单测，不碰 DB）
  // ---------------------------------------------------------------------------

  /// 分组键：`roundIndex|fatherUuid`（根为 `roundIndex|`）。
  static String groupKey(int roundIndex, String? fatherUuid) =>
      '$roundIndex|${RoundStackRow.normalizeFather(fatherUuid) ?? ''}';

  /// 按 `(round_index, father_uuid)` 分组。
  static Map<String, List<RoundStackRow>> groupRows(List<RoundStackRow> rows) {
    final byGroup = <String, List<RoundStackRow>>{};
    for (final row in rows) {
      (byGroup[groupKey(row.roundIndex, row.fatherUuid)] ??= <RoundStackRow>[])
          .add(row);
    }
    return byGroup;
  }

  /// 按「父 uuid」分组（后代检索用；根行不入表）。
  static Map<String, List<RoundStackRow>> childRows(List<RoundStackRow> rows) {
    final byChildren = <String, List<RoundStackRow>>{};
    for (final row in rows) {
      final father = row.fatherUuid;
      if (father == null) continue;
      (byChildren[father] ??= <RoundStackRow>[]).add(row);
    }
    return byChildren;
  }

  /// 活动链重算：从 [anchor] 起**逐轮向下**选择——
  /// ① 分组内 `state='use'` 的行；② 无 `use` → 序号最大者；
  /// ③ 找不到「以现任 uuid 为父」的更大轮号分组（含**轮号断裂**处）→ 链在此结束。
  ///
  /// 轮号可断裂（用户删掉中间某一轮、老客户端留空洞）：此处**跳过空洞**向后找
  /// 最近一个以现任 uuid 为父的分组，因此 `1,2,50` 这种轮号序列在切换到第 2 轮
  /// 的某一代时，第 50 轮仍会随父一起出现。
  static List<RoundStackRow> planChain({
    required RoundStackRow anchor,
    required Map<String, List<RoundStackRow>> byGroup,
  }) {
    final chain = <RoundStackRow>[anchor];
    final seen = <String>{anchor.uuid};
    final indexes = groupRoundIndexes(byGroup);
    var current = anchor;
    while (true) {
      int? next;
      for (final j in indexes) {
        if (j <= current.roundIndex) continue;
        final group = byGroup[groupKey(j, current.uuid)];
        if (group != null && group.isNotEmpty) {
          next = j;
          break;
        }
      }
      if (next == null) break;
      final selected = _pickInGroup(byGroup[groupKey(next, current.uuid)]!);
      if (!seen.add(selected.uuid)) break; // 脏数据成环时兜底
      chain.add(selected);
      current = selected;
    }
    return chain;
  }

  /// [byGroup] 中出现的全部轮号（升序）：活动链跳空洞时用来找「下一个存在的轮号」。
  static List<int> groupRoundIndexes(
    Map<String, List<RoundStackRow>> byGroup,
  ) {
    final indexes = <int>{};
    for (final key in byGroup.keys) {
      final sep = key.indexOf('|');
      if (sep <= 0) continue;
      final index = int.tryParse(key.substring(0, sep));
      if (index != null) indexes.add(index);
    }
    return indexes.toList()..sort();
  }

  /// 轮号断裂时的「父锚点」：**自动上溯**到最近存在的更早一轮的当前代 uuid
  /// （更早一轮都不存在才返回 `null` = 根）。
  ///
  /// 例：轮号 `1,2,50` 的第 50 轮，父锚点 = 第 2 轮的当前代——断裂处若不上溯，
  /// 第 50 轮会变成一条独立的根，切换第 2 轮的版本时它会被整条丢掉。
  static String? nearestEarlierAnchor(
    Map<int, String?> anchorByRoundIndex,
    int roundIndex,
  ) {
    for (var j = roundIndex - 1; j >= 0; j--) {
      final anchor = anchorByRoundIndex[j];
      if (anchor != null) return anchor;
    }
    return null;
  }

  /// [root] 及其全部后代（含自身）的 uuid，按字典序（确定性输出）。
  static List<String> subtreeUuids(
    RoundStackRow root,
    Map<String, List<RoundStackRow>> byChildren,
  ) {
    final visited = <String>{};
    final queue = <RoundStackRow>[root];
    while (queue.isNotEmpty) {
      final node = queue.removeLast();
      if (!visited.add(node.uuid)) continue;
      final children = byChildren[node.uuid];
      if (children != null) queue.addAll(children);
    }
    return visited.toList()..sort();
  }

  /// 一代的内容指纹（时间戳 **不**参与：创建 / 更新时间会随保存刷新）。
  static String contentFpOfStack(RoundStackRow row) => _fp([
        row.userInput,
        row.aiNarrative,
        row.worldState,
        row.characterState,
        row.memorySummary,
        row.currentTime,
        row.recommendedAction,
        row.tokensIn,
        row.tokensOut,
        row.cachedTokensIn,
        row.modelName,
        jsonEncode(row.userImages),
        jsonEncode(row.aiImages),
      ]);

  /// 投影行的内容指纹（与 [contentFpOfStack] 同一字段集与顺序：复用同一实现）。
  static String contentFpOfRound(Round round) => contentFpOfStack(
        RoundStackRow.fromRound(round, uuid: '', roundSerialNum: 0),
      );

  static String _fp(List<Object?> values) => jsonEncode(values);

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  Future<T> _inTxn<T>(Future<T> Function(DatabaseExecutor txn) action) async {
    final db = await DatabaseHelper.instance.database;
    return db.transaction(action);
  }

  /// 廉价健康检查：全部投影行都有非空锚点且锚点行存在（不读正文）。
  Future<bool> _pointersHealthy(DatabaseExecutor e, String bookUuid) async {
    final rounds = await RoundDao.getRoundsByBookFrom(e, bookUuid);
    if (rounds.isEmpty) return true;
    final metas = await RoundStackDao.loadMetaByBookFrom(e, bookUuid);
    final alive = {for (final meta in metas) meta.uuid};
    for (final round in rounds) {
      if (round.useStackUuid.isEmpty || !alive.contains(round.useStackUuid)) {
        return false;
      }
    }
    return true;
  }

  /// 单轮一致性：投影行与它指向的代内容是否一致（切换步骤 0）。
  Future<bool> _singleRoundConsistent(String bookUuid, int roundIndex) async {
    final db = await DatabaseHelper.instance.database;
    final round = await RoundDao.getRoundByIndexFrom(db, bookUuid, roundIndex);
    if (round == null) return true; // 失败态 / 无投影行：无需防覆盖
    if (round.useStackUuid.isEmpty) return false;
    final anchor = await RoundStackDao.getByUuidFrom(db, round.useStackUuid);
    if (anchor == null) return false;
    return contentFpOfStack(anchor) == contentFpOfRound(round);
  }

  Future<RoundStackAdoptionReport?> _adoptInTxn(
    DatabaseExecutor e,
    String bookUuid,
  ) async {
    final rounds = await RoundDao.getRoundsByBookFrom(e, bookUuid);
    if (rounds.isEmpty) return null;
    final rows = await RoundStackDao.loadByBookFrom(e, bookUuid);
    final byUuid = {for (final row in rows) row.uuid: row};
    final byGroup = groupRows(rows);
    final anchorByIndex = <int, String?>{};
    var reused = 0;
    var created = 0;

    for (final round in rounds) {
      final fp = contentFpOfRound(round);
      final current = byUuid[round.useStackUuid];
      if (current != null && contentFpOfStack(current) == fp) {
        anchorByIndex[round.roundIndex] = current.uuid;
        continue;
      }
      // 父锚点：**最近存在的更早一轮**的当前代（本条循环里若刚新建 / 复用，取其
      // 新值）。轮号断裂（如 1,2,50）时自动上溯到第 2 轮，而不是落成 NULL 根。
      final father = nearestEarlierAnchor(anchorByIndex, round.roundIndex);
      final group =
          byGroup[groupKey(round.roundIndex, father)] ?? const <RoundStackRow>[];
      RoundStackRow? hit;
      for (final candidate in group) {
        if (contentFpOfStack(candidate) == fp) {
          hit = candidate;
          break;
        }
      }
      final String anchor;
      if (hit != null) {
        // 内容相同的代**复用**：防止「老客户端每次编辑都长一代」。
        reused++;
        anchor = hit.uuid;
      } else {
        created++;
        final row = RoundStackRow.fromRound(
          round,
          uuid: UuidUtils.generateUuidV4(),
          fatherUuid: father,
          roundSerialNum: _nextSerial(group.map((r) => r.roundSerialNum)),
          roundState: 'use',
        );
        await _stack.insertGeneration(e, row);
        byUuid[row.uuid] = row;
        (byGroup[groupKey(row.roundIndex, row.fatherUuid)] ??= <RoundStackRow>[])
            .add(row);
        anchor = row.uuid;
      }
      await _stack.setGroupUseState(
        e,
        setUse: [anchor],
        clearUse: [
          for (final candidate in group)
            if (candidate.isUse && candidate.uuid != anchor) candidate.uuid,
        ],
      );
      anchorByIndex[round.roundIndex] = anchor;
      final id = round.id;
      if (id != null && round.useStackUuid != anchor) {
        await _rounds.updateProjectionFields(e, id, {'use_stack_uuid': anchor});
      }
    }

    // `rounds` 缺口（含「删除本轮」留下的空洞）：删除**匹配到的父**之下的子树，
    // 父不匹配的其它分支保留。
    //
    // 扫描上限取「投影行与版本树行的最大轮号」：老客户端删掉末尾轮次时
    // `rounds` 里已看不到该轮，但它的代仍在库里（必须按缺口处理）。
    var removedSubtree = 0;
    final fresh = await RoundStackDao.loadByBookFrom(e, bookUuid);
    final maxIndex = [
      rounds.last.roundIndex,
      ...fresh.map((row) => row.roundIndex),
    ].reduce(math.max);
    final present = {for (final round in rounds) round.roundIndex};
    final byChildren = childRows(fresh);
    final doomed = <String>{};
    for (var i = 0; i <= maxIndex; i++) {
      if (present.contains(i)) continue;
      // 缺口处的「活动父」同样自动上溯（与采纳主循环同一口径）。
      final father = nearestEarlierAnchor(anchorByIndex, i);
      final roots = [
        for (final row in fresh)
          if (row.roundIndex == i && row.fatherUuid == father) row,
      ];
      if (roots.isEmpty) continue;
      removedSubtree++;
      for (final root in roots) {
        doomed.addAll(subtreeUuids(root, byChildren));
      }
    }
    if (doomed.isNotEmpty) {
      await _stack.deleteByUuids(e, doomed.toList());
    }

    final purged = await _purgeOrphansInTxn(e, bookUuid);
    final normalized = await _normalizeBookInTxn(e, bookUuid);
    return RoundStackAdoptionReport(
      reused: reused,
      created: created,
      removedSubtree: removedSubtree,
      purgedOrphans: purged,
      normalized: normalized,
    );
  }

  Future<int> _purgeOrphansInTxn(DatabaseExecutor e, String bookUuid) async {
    var purged = 0;
    while (true) {
      final metas = await RoundStackDao.loadMetaByBookFrom(e, bookUuid);
      final alive = {for (final meta in metas) meta.uuid};
      // 关键：`fatherUuid != null` 是根守卫——根（无父行）永远不是孤儿。
      final orphans = [
        for (final meta in metas)
          if (meta.fatherUuid != null && !alive.contains(meta.fatherUuid))
            meta.uuid,
      ];
      if (orphans.isEmpty) return purged;
      await _stack.deleteByUuids(e, orphans);
      purged += orphans.length;
    }
  }

  Future<int> _normalizeBookInTxn(DatabaseExecutor e, String bookUuid) async {
    final metas = await RoundStackDao.loadMetaByBookFrom(e, bookUuid);
    final groups = <String, List<RoundStackMeta>>{};
    for (final meta in metas) {
      (groups[groupKey(meta.roundIndex, meta.fatherUuid)] ??=
              <RoundStackMeta>[])
          .add(meta);
    }
    var changes = 0;
    for (final group in groups.values) {
      changes += await _normalizeGroupInTxn(
        e,
        bookUuid,
        group.first.roundIndex,
        group.first.fatherUuid,
      );
    }
    return changes;
  }

  Future<int> _normalizeGroupInTxn(
    DatabaseExecutor e,
    String bookUuid,
    int roundIndex,
    String? fatherUuid,
  ) async {
    var metas = await RoundStackDao.loadGroupFrom(
      e,
      bookUuid,
      roundIndex,
      fatherUuid,
    );
    if (metas.isEmpty) return 0;
    var changes = 0;

    // 重复序号：保留「创建时间最新者」，同刻按 uuid 定序，其余顺移到末尾。
    final bySerial = <int, List<RoundStackMeta>>{};
    for (final meta in metas) {
      (bySerial[meta.roundSerialNum] ??= <RoundStackMeta>[]).add(meta);
    }
    var maxSerial = metas.map((m) => m.roundSerialNum).reduce(math.max);
    for (final entry in bySerial.entries) {
      if (entry.value.length < 2) continue;
      final ordered = [...entry.value]..sort(_byNewestFirst);
      final losers = ordered.sublist(1)..sort(_byUuid);
      for (final loser in losers) {
        await _stack.setSerial(e, loser.uuid, ++maxSerial);
        changes++;
      }
    }
    if (changes > 0) {
      metas = await RoundStackDao.loadGroupFrom(
        e,
        bookUuid,
        roundIndex,
        fatherUuid,
      );
    }

    // use 归一化：多个 use → 序号最大者；无 use → 存活代中序号最大者。
    final ordered = [...metas]..sort(_byOldestFirst);
    final uses = [
      for (final meta in ordered)
        if (meta.isUse) meta,
    ];
    final winner = uses.isEmpty ? ordered.last : uses.last;
    final clearUse = [
      for (final meta in metas)
        if (meta.isUse && meta.uuid != winner.uuid) meta.uuid,
    ];
    if (clearUse.isEmpty && winner.isUse) return changes;
    await _stack.setGroupUseState(
      e,
      setUse: [winner.uuid],
      clearUse: clearUse,
    );
    return changes + 1 + clearUse.length;
  }

  /// 分组内选中的活着代：优先 `use`，否则序号最大者。
  static RoundStackRow _pickInGroup(List<RoundStackRow> group) {
    for (final row in group) {
      if (row.isUse) return row;
    }
    var best = group.first;
    for (final row in group) {
      if (_byOldestFirstRow(row, best) > 0) best = row;
    }
    return best;
  }

  static int _nextSerial(Iterable<int> serials) =>
      serials.isEmpty ? 1 : serials.reduce(math.max) + 1;

  /// 序号 → 创建时间 → uuid（同输入同输出，跨设备一致）。
  static int _byOldestFirst(RoundStackMeta a, RoundStackMeta b) {
    final bySerial = a.roundSerialNum.compareTo(b.roundSerialNum);
    if (bySerial != 0) return bySerial;
    final at = a.roundCreatedAt?.millisecondsSinceEpoch ?? 0;
    final bt = b.roundCreatedAt?.millisecondsSinceEpoch ?? 0;
    if (at != bt) return at.compareTo(bt);
    return a.uuid.compareTo(b.uuid);
  }

  static int _byNewestFirst(RoundStackMeta a, RoundStackMeta b) =>
      _byOldestFirst(b, a);

  static int _byUuid(RoundStackMeta a, RoundStackMeta b) =>
      a.uuid.compareTo(b.uuid);

  static int _byOldestFirstRow(RoundStackRow a, RoundStackRow b) {
    final bySerial = a.roundSerialNum.compareTo(b.roundSerialNum);
    if (bySerial != 0) return bySerial;
    final at = a.roundCreatedAt?.millisecondsSinceEpoch ?? 0;
    final bt = b.roundCreatedAt?.millisecondsSinceEpoch ?? 0;
    if (at != bt) return at.compareTo(bt);
    return a.uuid.compareTo(b.uuid);
  }
}
