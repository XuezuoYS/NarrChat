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
    final id = await db.insert('world_book_entries', map);
    await DatabaseHelper.touchBook(db, entry.bookId, settings: true);
    return id;
  }

  Future<int> updateEntry(WorldBookEntry entry) async {
    final db = await _helper.database;
    final map = entry.toMap()..remove('id');
    final count = await db.update(
      'world_book_entries',
      map,
      where: 'id = ?',
      whereArgs: [entry.id],
    );
    await DatabaseHelper.touchBook(db, entry.bookId, settings: true);
    return count;
  }

  Future<void> deleteEntry(int id) async {
    final db = await _helper.database;
    final rows = await db.query(
      'world_book_entries',
      columns: ['book_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    await db.delete('world_book_entries', where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty && rows.first['book_id'] is int) {
      await DatabaseHelper.touchBook(
        db,
        rows.first['book_id'] as int,
        settings: true,
      );
    }
  }

  Future<void> deleteEntriesByBook(int bookId) async {
    final db = await _helper.database;
    await db.delete('world_book_entries', where: 'book_id = ?', whereArgs: [bookId]);
    await DatabaseHelper.touchBook(db, bookId, settings: true);
  }
}
