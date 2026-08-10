import '../models/book.dart';
import '../models/failed_attempt.dart';
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

  /// 读取本书的「失败条目」（请求失败 / 用户中断的未完成尝试；无则返回空条目）。
  Future<FailedAttempt> getFailedAttempt(int bookId) async {
    final db = await _helper.database;
    final rows = await db.query(
      'books',
      columns: ['failed_user_input', 'failed_error_message'],
      where: 'id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    if (rows.isEmpty) return const FailedAttempt();
    final row = rows.first;
    return FailedAttempt(
      userInput: (row['failed_user_input'] as String?) ?? '',
      errorMessage: (row['failed_error_message'] as String?) ?? '',
    );
  }

  /// 写入本书的「失败条目」（空条目即清空）。
  ///
  /// 仅更新这两列，与 [Book] 内容列互不干扰：`insertBook` / `updateBook`
  /// 的写 map 不含失败列，因此书籍编辑保存不会覆盖失败条目。
  Future<void> setFailedAttempt(int bookId, FailedAttempt attempt) async {
    final db = await _helper.database;
    await db.update(
      'books',
      {
        'failed_user_input': attempt.userInput,
        'failed_error_message': attempt.errorMessage,
      },
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }
}
