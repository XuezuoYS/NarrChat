import '../models/world_book_entry.dart';
import 'database_helper.dart';

/// `world_book_entries` 表的数据访问对象。
class WorldBookDao {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  Future<List<WorldBookEntry>> getEntriesByBook(int bookId) async {
    final db = await _helper.database;
    final rows = await db.query(
      'world_book_entries',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'id ASC',
    );
    return rows.map(WorldBookEntry.fromMap).toList();
  }

  Future<int> insertEntry(WorldBookEntry entry) async {
    final db = await _helper.database;
    final map = entry.toMap()..remove('id');
    return db.insert('world_book_entries', map);
  }

  Future<int> updateEntry(WorldBookEntry entry) async {
    final db = await _helper.database;
    final map = entry.toMap()..remove('id');
    return db.update(
      'world_book_entries',
      map,
      where: 'id = ?',
      whereArgs: [entry.id],
    );
  }

  Future<void> deleteEntry(int id) async {
    final db = await _helper.database;
    await db.delete('world_book_entries', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteEntriesByBook(int bookId) async {
    final db = await _helper.database;
    await db.delete('world_book_entries', where: 'book_id = ?', whereArgs: [bookId]);
  }
}
