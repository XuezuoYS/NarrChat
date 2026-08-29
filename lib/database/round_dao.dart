import '../models/round.dart';
import 'database_helper.dart';

/// `rounds` 表的数据访问对象。
class RoundDao {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  Future<List<Round>> getRoundsByBook(String bookUuid) async {
    final db = await _helper.database;
    final rows = await db.query(
      'rounds',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'round_index ASC',
    );
    return rows.map(Round.fromMap).toList();
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

  /// 仅更新指定字段（用于侧边栏“保存快照”）。
  Future<int> updateRoundFields(int roundId, Map<String, Object?> fields) async {
    final db = await _helper.database;
    final round = await getRoundById(roundId);
    final count = await db.update('rounds', fields, where: 'id = ?', whereArgs: [roundId]);
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
}
