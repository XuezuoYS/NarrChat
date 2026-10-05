import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/round.dart';
import 'database_helper.dart';

/// `rounds` 表的数据访问对象。
///
/// v19（修改还原）后本表是**读权威**：所有读取路径只依赖 `rounds`；
/// `round_stack` 只是历史与分支库，二者的投影重建见
/// [replaceProjectionFrom] / [upsertProjectionRow] / [deleteRoundsFrom]。
class RoundDao {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  Future<List<Round>> getRoundsByBook(String bookUuid) async {
    final db = await _helper.database;
    return getRoundsByBookFrom(db, bookUuid);
  }

  /// [getRoundsByBook] 的显式执行器版本（事务内读取一致快照 / 备份库分析）。
  static Future<List<Round>> getRoundsByBookFrom(
    DatabaseExecutor e,
    String bookUuid,
  ) async {
    final rows = await e.query(
      'rounds',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'round_index ASC',
    );
    return rows.map(Round.fromMap).toList();
  }

  /// 取某书某一轮的投影行（版本树校验 / 切换前的单轮比对用）。
  static Future<Round?> getRoundByIndexFrom(
    DatabaseExecutor e,
    String bookUuid,
    int roundIndex,
  ) async {
    final rows = await e.query(
      'rounds',
      where: 'book_uuid = ? AND round_index = ?',
      whereArgs: [bookUuid, roundIndex],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Round.fromMap(rows.first);
  }

  Future<Round?> getRoundById(int id) async {
    final db = await _helper.database;
    final rows = await db.query('rounds', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Round.fromMap(rows.first);
  }

  Future<int> insertRound(Round round) async {
    final db = await _helper.database;
    final map = round.toMap()..remove('id');
    final id = await db.insert('rounds', map);
    await DatabaseHelper.touchBook(db, round.bookUuid, rounds: true);
    return id;
  }

  Future<int> updateRound(Round round) async {
    final db = await _helper.database;
    final map = round.toMap()..remove('id');
    final count = await db.update('rounds', map, where: 'id = ?', whereArgs: [round.id]);
    await DatabaseHelper.touchBook(db, round.bookUuid, rounds: true);
    return count;
  }

  /// 仅更新指定字段（用于侧边栏「保存快照」、编辑 AI 正文 / 用户输入），
  /// 同时刷新本轮 `updated_at`（epoch 毫秒）并触碰书籍 `rounds_updated_at`，
  /// 使编辑后的轮次带有准确的更新时间并可被云同步识别为「本地较新」。
  Future<int> updateRoundFields(int roundId, Map<String, Object?> fields) async {
    final db = await _helper.database;
    final round = await getRoundById(roundId);
    final count = await db.update(
      'rounds',
      {...fields, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [roundId],
    );
    if (round != null) {
      await DatabaseHelper.touchBook(db, round.bookUuid, rounds: true);
    }
    return count;
  }

  /// 删除轮次。
  ///
  /// - [deleteFollowing] 为 false：仅删除本轮；
  /// - [deleteFollowing] 为 true：删除本轮及该轮之后的所有轮次。
  Future<void> deleteRound(int roundId, {bool deleteFollowing = false}) async {
    final db = await _helper.database;
    final round = await getRoundById(roundId);
    if (round == null) return;
    if (deleteFollowing) {
      await db.delete(
        'rounds',
        where: 'book_uuid = ? AND round_index >= ?',
        whereArgs: [round.bookUuid, round.roundIndex],
      );
    } else {
      await db.delete('rounds', where: 'id = ?', whereArgs: [roundId]);
    }
    await DatabaseHelper.touchBook(db, round.bookUuid, rounds: true);
  }

  /// 删除某本书的全部轮次（书籍删除时使用）。
  Future<void> deleteRoundsByBook(String bookUuid) async {
    final db = await _helper.database;
    await db.delete('rounds', where: 'book_uuid = ?', whereArgs: [bookUuid]);
    await DatabaseHelper.touchBook(db, bookUuid, rounds: true);
  }

  // ---------------------------------------------------------------------------
  // 投影重建（v19：`round_stack` 版本树 ↔ `rounds` 投影）
  //
  // 以下方法一律接收事务执行器，且**不**自行 touchBook：由服务层在同一事务
  // 收尾统一 `DatabaseHelper.touchBook(..., rounds: true)`。
  // ---------------------------------------------------------------------------

  /// 删除该轮起的全部投影行（投影重建的清理步骤）。
  Future<void> deleteRoundsFrom(
    DatabaseExecutor e,
    String bookUuid,
    int fromRoundIndex,
  ) async {
    await e.delete(
      'rounds',
      where: 'book_uuid = ? AND round_index >= ?',
      whereArgs: [bookUuid, fromRoundIndex],
    );
  }

  /// 只删某一轮的投影行（用户「删除本轮」；后续轮次保留、允许父链断裂）。
  Future<void> deleteRoundAt(
    DatabaseExecutor e,
    String bookUuid,
    int roundIndex,
  ) async {
    await e.delete(
      'rounds',
      where: 'book_uuid = ? AND round_index = ?',
      whereArgs: [bookUuid, roundIndex],
    );
  }

  /// 投影重建：删该轮起的 `rounds` 行 → 按 [rows] 顺序插入。
  ///
  /// 内容取 `round_stack` 行、`use_stack_uuid` = 该行 uuid、
  /// `created_at` = `round_created_at`、`updated_at` = now（见设计 §2.4）。
  Future<void> replaceProjectionFrom(
    DatabaseExecutor e,
    String bookUuid,
    int fromRoundIndex,
    List<Round> rows,
  ) async {
    await deleteRoundsFrom(e, bookUuid, fromRoundIndex);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in rows) {
      final map = row.toMap()
        ..remove('id')
        ..['updated_at'] = now;
      await e.insert('rounds', map);
    }
  }

  /// 单行投影（生成 / 原地修改用）：该轮只保留一行，并写 [useStackUuid]。
  ///
  /// 先按 `(book_uuid, round_index)` 清行再插入：保证「一轮一行」不变量，
  /// 代价是 `rounds.id` 会变（调用方须清该书的 RAW 缓存）。返回新行 id。
  Future<int> upsertProjectionRow(
    DatabaseExecutor e,
    Round round,
    String useStackUuid,
  ) async {
    await e.delete(
      'rounds',
      where: 'book_uuid = ? AND round_index = ?',
      whereArgs: [round.bookUuid, round.roundIndex],
    );
    final map = round.toMap()
      ..remove('id')
      ..['use_stack_uuid'] = useStackUuid
      ..['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    return e.insert('rounds', map);
  }

  /// 原地修改投影行的指定字段（白名单字段由调用方保证）并刷新 `updated_at`。
  Future<void> updateProjectionFields(
    DatabaseExecutor e,
    int roundId,
    Map<String, Object?> fields,
  ) async {
    await e.update(
      'rounds',
      {...fields, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [roundId],
    );
  }
}
