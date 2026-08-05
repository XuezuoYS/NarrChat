import '../models/book.dart';
import 'database_helper.dart';

/// `books` 表的数据访问对象。
///
/// 所有方法均包含 try-catch，异常向上抛出，由 Provider 层捕获并暴露给 UI。
class BookDao {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  Future<List<Book>> getAllBooks() async {
    try {
      final db = await _helper.database;
      final rows = await db.query('books', orderBy: 'id ASC');
      return rows.map(Book.fromMap).toList();
    } catch (e) {
      rethrow;
    }
  }

  Future<Book?> getBookById(int id) async {
    try {
      final db = await _helper.database;
      final rows = await db.query('books', where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return null;
      return Book.fromMap(rows.first);
    } catch (e) {
      rethrow;
    }
  }

  Future<int> insertBook(Book book) async {
    try {
      final db = await _helper.database;
      final map = book.toMap()..remove('id');
      return db.insert('books', map);
    } catch (e) {
      rethrow;
    }
  }

  Future<int> updateBook(Book book) async {
    try {
      final db = await _helper.database;
      final map = book.toMap()..remove('id');
      return db.update('books', map, where: 'id = ?', whereArgs: [book.id]);
    } catch (e) {
      rethrow;
    }
  }

  /// 删除书籍及其全部轮次（事务保证原子性）。
  Future<void> deleteBook(int id) async {
    try {
      final db = await _helper.database;
      await db.transaction((txn) async {
        await txn.delete('rounds', where: 'book_id = ?', whereArgs: [id]);
        await txn.delete('books', where: 'id = ?', whereArgs: [id]);
      });
    } catch (e) {
      rethrow;
    }
  }
}
