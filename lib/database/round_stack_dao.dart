import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/round_stack.dart';
import 'database_helper.dart';

/// `round_stack`（修改还原的版本树）数据访问对象。
///
/// 约定：
/// - **写方法一律接收 [DatabaseExecutor]**：由服务层开启事务后传入，使
///   「stack 行 + 投影行（`rounds`）」落在同一事务里；
/// - 读方法走 [DatabaseHelper.instance]（远端快照等外部库请用带 `e` 的静态入口）；
/// - 本 DAO **不触碰** `books.rounds_updated_at`，由服务层在事务收尾统一
///   `DatabaseHelper.touchBook(..., rounds: true)`（一次操作一次触碰）。
class RoundStackDao {
  static const String table = 'round_stack';

  /// 元数据列（**不含正文**）：控件显隐 / 计数 / 归一化判定只读这些列。
  static const List<String> metaColumns = [
    'uuid',
    'book_uuid',
    'father_uuid',
    'round_index',
    'round_serial_num',
    'round_state',
    'round_created_at',
  ];

  final DatabaseHelper _helper = DatabaseHelper.instance;

  // ---------------------------------------------------------------------------
  // 读
  // ---------------------------------------------------------------------------

  /// 全量（含正文）：采纳 / 清理 / 指纹用。
  Future<List<RoundStackRow>> loadByBook(String bookUuid) async {
    final db = await _helper.database;
    return loadByBookFrom(db, bookUuid);
  }

  /// [loadByBook] 的显式执行器版本（远端快照 / 备份库同样适用）。
  static Future<List<RoundStackRow>> loadByBookFrom(
    DatabaseExecutor e,
    String bookUuid,
  ) async {
    final rows = await e.query(
      table,
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'round_index ASC, round_serial_num ASC',
    );
    return rows.map(RoundStackRow.fromMap).toList();
  }

  /// 仅元数据列（**绝不读正文**）。
  Future<List<RoundStackMeta>> loadMetaByBook(String bookUuid) async {
    final db = await _helper.database;
    return loadMetaByBookFrom(db, bookUuid);
  }

  /// [loadMetaByBook] 的显式执行器版本（事务内一致快照）。
  static Future<List<RoundStackMeta>> loadMetaByBookFrom(
    DatabaseExecutor e,
    String bookUuid,
  ) async {
    final rows = await e.query(
      table,
      columns: metaColumns,
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'round_index ASC, round_serial_num ASC',
    );
    return rows.map(RoundStackMeta.fromMap).toList();
  }

  Future<RoundStackRow?> getByUuid(String uuid) async {
    final db = await _helper.database;
    return getByUuidFrom(db, uuid);
  }

  static Future<RoundStackRow?> getByUuidFrom(
    DatabaseExecutor e,
    String uuid,
  ) async {
    if (uuid.isEmpty) return null;
    final rows = await e.query(
      table,
      where: 'uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return RoundStackRow.fromMap(rows.first);
  }

  Future<RoundStackMeta?> getMetaByUuid(String uuid) async {
    final db = await _helper.database;
    if (uuid.isEmpty) return null;
    final rows = await db.query(
      table,
      columns: metaColumns,
      where: 'uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return RoundStackMeta.fromMap(rows.first);
  }

  /// 某分组（`(book, round_index, father_uuid)`）的全部存活代，按序号升序。
  ///
  /// [fatherUuid] 为 `null` / 空串 = 根分组（`father_uuid IS NULL`）。
  Future<List<RoundStackMeta>> loadGroup(
    String bookUuid,
    int roundIndex,
    String? fatherUuid,
  ) async {
    final db = await _helper.database;
    return loadGroupFrom(db, bookUuid, roundIndex, fatherUuid);
  }

  static Future<List<RoundStackMeta>> loadGroupFrom(
    DatabaseExecutor e,
    String bookUuid,
    int roundIndex,
    String? fatherUuid,
  ) async {
    final father = RoundStackRow.normalizeFather(fatherUuid);
    final rows = await e.query(
      table,
      columns: metaColumns,
      where: 'book_uuid = ? AND round_index = ? AND ${_fatherCond(father)}',
      whereArgs: [bookUuid, roundIndex, ?father],
      orderBy: 'round_serial_num ASC',
    );
    return rows.map(RoundStackMeta.fromMap).toList();
  }

  /// 该分组下一个序号 = `max(round_serial_num) + 1`（须在事务内调用）。
  ///
  /// 序号表示「存活代次序」，物理删除后**允许复用**旧号；身份一律靠 uuid
  /// （故不引入分配器）。
  Future<int> nextSerial(
    DatabaseExecutor e,
    String bookUuid,
    int roundIndex,
    String? fatherUuid,
  ) async {
    final father = RoundStackRow.normalizeFather(fatherUuid);
    final rows = await e.rawQuery(
      'SELECT MAX(round_serial_num) AS m FROM $table '
      'WHERE book_uuid = ? AND round_index = ? AND ${_fatherCond(father)}',
      [bookUuid, roundIndex, ?father],
    );
    final maxSerial = rows.isEmpty ? null : rows.first['m'] as int?;
    return (maxSerial ?? 0) + 1;
  }

  // ---------------------------------------------------------------------------
  // 写
  // ---------------------------------------------------------------------------

  /// 新建一代（`insertGeneration`）：uuid 冲突即抛（uuid 是身份，撞号属于 bug）。
  Future<void> insertGeneration(DatabaseExecutor e, RoundStackRow row) async {
    await e.insert(table, row.toMap());
  }

  /// 原地修改某一代的内容列（**不动** uuid / 序号 / 父 / 状态 / 创建时间）。
  Future<void> updateContent(DatabaseExecutor e, RoundStackRow row) async {
    await e.update(
      table,
      {
        'user_input': row.userInput,
        'ai_narrative': row.aiNarrative,
        'world_state': row.worldState,
        'character_state': row.characterState,
        'memory_summary': row.memorySummary,
        'current_time': row.currentTime,
        'recommended_action': row.recommendedAction,
        'tokens_in': row.tokensIn,
        'tokens_out': row.tokensOut,
        'cached_tokens_in': row.cachedTokensIn,
        'model_name': row.modelName,
        'user_images': jsonEncode(row.userImages),
        'ai_images': jsonEncode(row.aiImages),
      },
      where: 'uuid = ?',
      whereArgs: [row.uuid],
    );
  }

  /// 改写某一行的分组内序号（归一化「重复序号」自愈用；不动 uuid / 内容）。
  Future<void> setSerial(
    DatabaseExecutor e,
    String uuid,
    int roundSerialNum,
  ) async {
    await e.update(
      table,
      {'round_serial_num': roundSerialNum},
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// 分组内 `use` 状态落库：`setUse` 置 `'use'`，`clearUse` 置 NULL。
  Future<void> setGroupUseState(
    DatabaseExecutor e, {
    List<String> setUse = const [],
    List<String> clearUse = const [],
  }) async {
    if (setUse.isNotEmpty) {
      await e.update(
        table,
        {'round_state': 'use'},
        where: _uuidInCond(setUse),
        whereArgs: setUse,
      );
    }
    if (clearUse.isNotEmpty) {
      await e.update(
        table,
        {'round_state': null},
        where: _uuidInCond(clearUse),
        whereArgs: clearUse,
      );
    }
  }

  /// 物理删除指定行（后代由调用方先算好；见服务层 `subtreeUuids`）。
  Future<void> deleteByUuids(DatabaseExecutor e, List<String> uuids) async {
    if (uuids.isEmpty) return;
    for (final chunk in _chunks(uuids)) {
      await e.delete(table, where: _uuidInCond(chunk), whereArgs: chunk);
    }
  }

  /// 物理删除该轮及之后的**全部行**（含跨分支的全部代）——用户删除 / 删书用。
  Future<void> deleteFromRound(
    DatabaseExecutor e,
    String bookUuid,
    int fromRoundIndex,
  ) async {
    await e.delete(
      table,
      where: 'book_uuid = ? AND round_index >= ?',
      whereArgs: [bookUuid, fromRoundIndex],
    );
  }

  /// 物理删除某一轮的**全部代（跨分支）**——用户「删除本轮」。
  Future<void> deleteRoundAt(
    DatabaseExecutor e,
    String bookUuid,
    int roundIndex,
  ) async {
    await e.delete(
      table,
      where: 'book_uuid = ? AND round_index = ?',
      whereArgs: [bookUuid, roundIndex],
    );
  }

  /// 物理删除某本书的全部代（删书收尾；外键级联的显式兜底）。
  Future<void> deleteByBookUuids(DatabaseExecutor e, String bookUuid) async {
    await e.delete(table, where: 'book_uuid = ?', whereArgs: [bookUuid]);
  }

  /// 下发 / 合并落行（`INSERT OR REPLACE`，uuid 即主键）。
  Future<void> upsertRow(DatabaseExecutor e, RoundStackRow row) async {
    await e.insert(
      table,
      row.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 整体替换某本书的版本树（先清后插）。
  ///
  /// 按 `round_index ASC` 插入：father 总在更早轮次 → 天然拓扑序（虽无自引用
  /// 外键，仍保证顺序便于排错与将来加约束）。
  Future<void> replaceBookStack(
    DatabaseExecutor e,
    String bookUuid,
    List<RoundStackRow> rows,
  ) async {
    await deleteByBookUuids(e, bookUuid);
    final sorted = [...rows]..sort((a, b) {
        final byIndex = a.roundIndex.compareTo(b.roundIndex);
        if (byIndex != 0) return byIndex;
        return a.roundSerialNum.compareTo(b.roundSerialNum);
      });
    for (final row in sorted) {
      await e.insert(table, row.toMap());
    }
  }

  // ---------------------------------------------------------------------------
  // 静态工具（外部库 / 旧 schema 守卫）
  // ---------------------------------------------------------------------------

  /// 该执行器上是否存在 `round_stack` 表。
  ///
  /// 远端快照 / 老备份库可能是 v18 schema（没有本表）：调用方据此跳过版本树
  /// 搬运、保留本地数据，交给采纳收敛。
  static Future<bool> hasTable(DatabaseExecutor e) async {
    final rows = await e.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }

  /// 只读「代次标签」（合并决策页展示用；任意库 / 备份库均可调用）：
  /// 取最末轮当前代所属分组 → `'第 x 代 / 最新第 y 代'`；无表 / 无锚点 → `''`。
  static Future<String> versionLabel(
    DatabaseExecutor e,
    String bookUuid,
  ) async {
    if (bookUuid.isEmpty || !await hasTable(e)) return '';
    final rounds = await e.query(
      'rounds',
      columns: ['round_index', 'use_stack_uuid'],
      where:
          "book_uuid = ? AND use_stack_uuid IS NOT NULL AND use_stack_uuid != ''",
      whereArgs: [bookUuid],
      orderBy: 'round_index DESC',
      limit: 1,
    );
    if (rounds.isEmpty) return '';
    final anchorUuid = (rounds.first['use_stack_uuid'] as String?) ?? '';
    final anchor = await getByUuidFrom(e, anchorUuid);
    if (anchor == null) return '';
    final group = await loadGroupFrom(
      e,
      bookUuid,
      anchor.roundIndex,
      anchor.fatherUuid,
    );
    if (group.isEmpty) return '';
    return '第 ${anchor.roundSerialNum} 代 / 最新第 ${group.last.roundSerialNum} 代';
  }

  /// 分组条件：根（[father] 为 null / 空串）走 `IS NULL OR = ''`，否则 `= ?`。
  ///
  /// **根是合法的可存活行**：`father_uuid IS NULL` 只表示「本代没有父」（链首），
  /// 不表示「父找不到」。孤儿规则只作用于**非空但查不到**的父亲
  /// （见 `RoundStackService.purgeOrphans`）。
  ///
  /// 同时把历史脏数据里的空串父亲（老客户端 / 手工写入）按根处理，
  /// 与内存侧 `RoundStackRow.normalizeFather` 的口径一致——否则同一行
  /// 在内存里算根、在 SQL 分组里被漏掉。
  static String _fatherCond(String? father) => father == null
      ? "(father_uuid IS NULL OR father_uuid = '')"
      : 'father_uuid = ?';

  static String _uuidInCond(List<String> uuids) =>
      'uuid IN (${List.filled(uuids.length, '?').join(', ')})';

  /// SQLite 变量上限（历史默认 999）：按 500 切块，避免大批量删除报错。
  static Iterable<List<T>> _chunks<T>(List<T> items, [int size = 500]) sync* {
    for (var i = 0; i < items.length; i += size) {
      yield items.sublist(i, i + size > items.length ? items.length : i + size);
    }
  }
}
