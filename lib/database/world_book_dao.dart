import '../models/world_book_entry.dart';
import 'database_helper.dart';

/// `world_book_entries` 表的数据访问对象。
///
/// 所有方法均包含 try-catch，异常向上抛出，由 Provider 层捕获并暴露给 UI。
class WorldBookDao {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  Future<List<WorldBookEntry>> getEntriesByBook(int bookId) async {
    try {
      final db = await _helper.database;
      final rows = await db.query(
        'world_book_entries',
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'id ASC',
      );
      return rows.map(WorldBookEntry.fromMap).toList();
    } catch (e) {
      rethrow;
    }
  }

  Future<int> insertEntry(WorldBookEntry entry) async {
    try {
      final db = await _helper.database;
      final map = entry.toMap()..remove('id');
      return db.insert('world_book_entries', map);
    } catch (e) {
      rethrow;
    }
  }

  Future<int> updateEntry(WorldBookEntry entry) async {
    try {
      final db = await _helper.database;
      final map = entry.toMap()..remove('id');
      return db.update(
        'world_book_entries',
        map,
        where: 'id = ?',
        whereArgs: [entry.id],
      );
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteEntry(int id) async {
    try {
      final db = await _helper.database;
      await db.delete('world_book_entries', where: 'id = ?', whereArgs: [id]);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteEntriesByBook(int bookId) async {
    try {
      final db = await _helper.database;
      await db.delete('world_book_entries', where: 'book_id = ?', whereArgs: [bookId]);
    } catch (e) {
      rethrow;
    }
  }
}
