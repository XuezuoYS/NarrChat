import '../models/round.dart';
import 'database_helper.dart';

/// `rounds` 表的数据访问对象。
///
/// 所有方法均包含 try-catch，异常向上抛出，由 Provider 层捕获并暴露给 UI。
class RoundDao {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  Future<List<Round>> getRoundsByBook(int bookId) async {
    try {
      final db = await _helper.database;
      final rows = await db.query(
        'rounds',
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'round_index ASC',
      );
      return rows.map(Round.fromMap).toList();
    } catch (e) {
      rethrow;
    }
  }

  Future<Round?> getRoundById(int id) async {
    try {
      final db = await _helper.database;
      final rows = await db.query('rounds', where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return null;
      return Round.fromMap(rows.first);
    } catch (e) {
      rethrow;
    }
  }

  Future<int> insertRound(Round round) async {
    try {
      final db = await _helper.database;
      final map = round.toMap()..remove('id');
      return db.insert('rounds', map);
    } catch (e) {
      rethrow;
    }
  }

  Future<int> updateRound(Round round) async {
    try {
      final db = await _helper.database;
      final map = round.toMap()..remove('id');
      return db.update('rounds', map, where: 'id = ?', whereArgs: [round.id]);
    } catch (e) {
      rethrow;
    }
  }

  /// 仅更新指定字段（用于侧边栏“保存快照”）。
  Future<int> updateRoundFields(int roundId, Map<String, Object?> fields) async {
    try {
      final db = await _helper.database;
      return db.update('rounds', fields, where: 'id = ?', whereArgs: [roundId]);
    } catch (e) {
      rethrow;
    }
  }

  /// 删除轮次。
  ///
  /// - [deleteFollowing] 为 false：仅删除本轮；
  /// - [deleteFollowing] 为 true：删除本轮及该轮之后的所有轮次。
  Future<void> deleteRound(int roundId, {bool deleteFollowing = false}) async {
    try {
      final db = await _helper.database;
      final round = await getRoundById(roundId);
      if (round == null) return;
      if (deleteFollowing) {
        await db.delete(
          'rounds',
          where: 'book_id = ? AND round_index >= ?',
          whereArgs: [round.bookId, round.roundIndex],
        );
      } else {
        await db.delete('rounds', where: 'id = ?', whereArgs: [roundId]);
      }
    } catch (e) {
      rethrow;
    }
  }

  /// 删除某本书的全部轮次（书籍删除时使用）。
  Future<void> deleteRoundsByBook(int bookId) async {
    try {
      final db = await _helper.database;
      await db.delete('rounds', where: 'book_id = ?', whereArgs: [bookId]);
    } catch (e) {
      rethrow;
    }
  }
}
