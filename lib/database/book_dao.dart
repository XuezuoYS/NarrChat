import 'dart:convert';

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

  /// 每本书最近一轮对话的创建时间（按「最近对话时间」排序用）。
  ///
  /// 仅包含有轮次记录的书籍；无轮次的书不在结果中，由调用方决定其排序位置。
  Future<Map<int, DateTime>> getLastRoundTimes() async {
    final db = await _helper.database;
    final rows = await db.rawQuery(
      'SELECT book_id, MAX(created_at) AS last_time '
      'FROM rounds WHERE created_at IS NOT NULL GROUP BY book_id',
    );
    final result = <int, DateTime>{};
    for (final row in rows) {
      final bookId = row['book_id'] as int?;
      final lastTime = row['last_time'] as String?;
      if (bookId == null || lastTime == null) continue;
      final time = DateTime.tryParse(lastTime);
      if (time != null) result[bookId] = time;
    }
    return result;
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
      columns: [
        'failed_user_input',
        'failed_error_message',
        'failed_user_images',
      ],
      where: 'id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    if (rows.isEmpty) return const FailedAttempt();
    final row = rows.first;
    return FailedAttempt(
      userInput: (row['failed_user_input'] as String?) ?? '',
      errorMessage: (row['failed_error_message'] as String?) ?? '',
      userImages: _decodeImages(row['failed_user_images']),
    );
  }

  /// 写入本书的「失败条目」（空条目即清空）。
  ///
  /// 仅更新这三列，与 [Book] 内容列互不干扰：`insertBook` / `updateBook`
  /// 的写 map 不含失败列，因此书籍编辑保存不会覆盖失败条目。
  Future<void> setFailedAttempt(int bookId, FailedAttempt attempt) async {
    final db = await _helper.database;
    await db.update(
      'books',
      {
        'failed_user_input': attempt.userInput,
        'failed_error_message': attempt.errorMessage,
        'failed_user_images': jsonEncode(attempt.userImages),
      },
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// 解析 JSON 数组字符串（相对路径列表）；非法 / 空视为无图片。
  static List<String> _decodeImages(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // 非法 JSON 视为空。
    }
    return const [];
  }
}
