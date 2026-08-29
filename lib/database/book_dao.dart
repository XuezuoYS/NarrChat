import 'dart:convert';

import '../models/book.dart';
import '../models/failed_attempt.dart';
import '../utils/uuid_utils.dart';
import 'database_helper.dart';

/// `books` 表的数据访问对象（主键即 uuid，无第二个 id）。
class BookDao {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  Future<List<Book>> getAllBooks({bool includeDeleted = false}) async {
    final db = await _helper.database;
    final rows = await db.query(
      'books',
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy: 'uuid ASC',
    );
    return rows.map(Book.fromMap).toList();
  }

  /// 按 uuid（主键）取书；[uuid] 为空直接返回 null（不存在第二种 id 可回退）。
  Future<Book?> getBookByUuid(String uuid, {bool includeDeleted = false}) async {
    if (uuid.isEmpty) return null;
    final db = await _helper.database;
    final rows = await db.query(
      'books',
      where: 'uuid = ?${includeDeleted ? '' : ' AND deleted_at IS NULL'}',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Book.fromMap(rows.first);
  }

  /// 软删除书籍：仅打上删除墓碑（UI 立即隐藏，行暂留用于同步删除传播）。
  ///
  /// 与 [deleteBook]（硬删）区分：硬删用于旁路/清理路径；软删供云同步删除传播。
  Future<void> softDeleteBook(String uuid) async {
    if (uuid.isEmpty) return;
    final db = await _helper.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'books',
      {
        'deleted_at': now,
        'settings_updated_at': now,
        'rounds_updated_at': now,
      },
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// 每本书最近一轮对话的创建时间（按「最近对话时间」排序用）。
  ///
  /// 仅包含有轮次记录的书籍；无轮次的书不在结果中，由调用方决定其排序位置。
  Future<Map<String, DateTime>> getLastRoundTimes() async {
    final db = await _helper.database;
    final rows = await db.rawQuery(
      'SELECT book_uuid, MAX(created_at) AS last_time '
      'FROM rounds WHERE created_at IS NOT NULL GROUP BY book_uuid',
    );
    final result = <String, DateTime>{};
    for (final row in rows) {
      final bookUuid = row['book_uuid'] as String?;
      final lastTime = row['last_time'] as String?;
      if (bookUuid == null || bookUuid.isEmpty || lastTime == null) continue;
      final time = DateTime.tryParse(lastTime);
      if (time != null) result[bookUuid] = time;
    }
    return result;
  }

  /// 插入新书并返回其 uuid（= 主键）；[Book.uuid] 为空时生成 v4。
  Future<String> insertBook(Book book) async {
    final db = await _helper.database;
    final map = book.toMap();
    var uuid = map['uuid'] as String? ?? '';
    if (uuid.isEmpty) {
      uuid = UuidUtils.generateUuidV4();
      map['uuid'] = uuid;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    map['settings_updated_at'] = now;
    map['rounds_updated_at'] = now;
    await db.insert('books', map);
    return uuid;
  }

  /// 按 uuid 更新书籍内容列（uuid 自身不参与写集合）。
  Future<int> updateBook(Book book) async {
    if (book.uuid.isEmpty) {
      throw StateError('updateBook 需要非空 uuid（未落库草稿请先 insertBook）');
    }
    final db = await _helper.database;
    final map = book.toMap()..remove('uuid');
    map['settings_updated_at'] = DateTime.now().millisecondsSinceEpoch;
    return db.update('books', map, where: 'uuid = ?', whereArgs: [book.uuid]);
  }

  /// 删除书籍及其全部轮次（事务保证原子性）。
  Future<void> deleteBook(String uuid) async {
    if (uuid.isEmpty) return;
    final db = await _helper.database;
    await db.transaction((txn) async {
      await txn.delete('rounds', where: 'book_uuid = ?', whereArgs: [uuid]);
      await txn.delete('books', where: 'uuid = ?', whereArgs: [uuid]);
    });
  }

  /// 读取本书的「失败条目」（请求失败 / 用户中断的未完成尝试；无则返回空条目）。
  Future<FailedAttempt> getFailedAttempt(String bookUuid) async {
    final db = await _helper.database;
    final rows = await db.query(
      'books',
      columns: [
        'failed_user_input',
        'failed_error_message',
        'failed_user_images',
      ],
      where: 'uuid = ?',
      whereArgs: [bookUuid],
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
  /// 失败条目与生成内容（轮次）同生命周期：成功生成会新增轮次并清空失败条目，
  /// 作为同一「轮次部件」变化同步——因此随写触碰 `rounds_updated_at`。
  /// 仅更新这三列，与 [Book] 内容列互不干扰：`insertBook` / `updateBook`
  /// 的写 map 不含失败列，因此书籍编辑保存不会覆盖失败条目。
  Future<void> setFailedAttempt(String bookUuid, FailedAttempt attempt) async {
    final db = await _helper.database;
    await db.update(
      'books',
      {
        'failed_user_input': attempt.userInput,
        'failed_error_message': attempt.errorMessage,
        'failed_user_images': jsonEncode(attempt.userImages),
      },
      where: 'uuid = ?',
      whereArgs: [bookUuid],
    );
    await DatabaseHelper.touchBook(db, bookUuid, rounds: true);
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