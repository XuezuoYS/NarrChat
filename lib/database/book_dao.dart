import '../models/book.dart';
import 'database_helper.dart';

/// `books` 表的数据访问对象。
class BookDao {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  Future<List<Book>> getAllBooks() async {
    final db = await _helper.database;
    final rows = await db.query('books', orderBy: 'id ASC');
    return rows.map(Book.fromMap).toList();
  }

  Future<Book?> getBookById(int id) async {
    final db = await _helper.database;
    final rows = await db.query('books', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Book.fromMap(rows.first);
  }

  Future<int> insertBook(Book book) async {
    final db = await _helper.database;
    final map = book.toMap()..remove('id');
    return db.insert('books', map);
  }

  Future<int> updateBook(Book book) async {
    final db = await _helper.database;
    final map = book.toMap()..remove('id');
    return db.update('books', map, where: 'id = ?', whereArgs: [book.id]);
  }

  /// 删除书籍及其全部轮次（事务保证原子性）。
  Future<void> deleteBook(int id) async {
    final db = await _helper.database;
    await db.transaction((txn) async {
      await txn.delete('rounds', where: 'book_id = ?', whereArgs: [id]);
      await txn.delete('books', where: 'id = ?', whereArgs: [id]);
    });
  }
}
