import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/app_paths.dart';
import 'book_db.dart';
import 'db_open.dart';

/// 单本书库的连接登记表。
///
/// 为什么需要它：`BookDb` 的读写入口必须**同一个实例**——`book_meta.updated_at`
/// 的刷新、同组 `is_using` 的归一化都在实例里收口，两个实例各开一条连接会让
/// 事务互相等待。同时 sqflite 对同一路径默认复用同一个 `Database`，重复 open
/// 再 close 会把别人正在用的连接顺手关掉。
///
/// 职责边界：
/// - 同一本书并发 `open` 只真正打开一次（共用同一个 Future）；
/// - `close` 只关自己登记过的连接；
/// - **不做自动淘汰**：什么时候关由调用方决定（离开书籍 / 换书）。
///   列表页不打开任何书库，所以同时打开的数量天然很小。
class BookDbPool {
  BookDbPool({required this.booksDir});

  /// `user_data/books/` 绝对路径。
  final String booksDir;

  final Map<String, BookDb> _open = {};
  final Map<String, Future<BookDb>> _pending = {};

  /// 当前已打开的书数（调试 / 测试断言用）。
  int get openCount => _open.length;

  bool isOpen(String bookUuid) => _open.containsKey(bookUuid);

  /// 打开一本书（已打开则直接返回同一实例）。
  Future<BookDb> open(String bookUuid) async {
    final existing = _open[bookUuid];
    if (existing != null) return existing;
    final pending = _pending[bookUuid];
    if (pending != null) return pending;

    final future = _openNow(bookUuid);
    _pending[bookUuid] = future;
    try {
      return await future;
    } finally {
      _pending.remove(bookUuid);
    }
  }

  Future<BookDb> _openNow(String bookUuid) async {
    final path = p.join(booksDir, AppPaths.bookDbFileName(bookUuid));
    final db = await BookDb.open(bookUuid: bookUuid, pathOverride: path);
    _open[bookUuid] = db;
    return db;
  }

  /// 关闭某本书的连接；没打开过也无所谓。
  Future<void> close(String bookUuid) async {
    final db = _open.remove(bookUuid);
    if (db == null) return;
    try {
      await db.close();
    } catch (_) {
      // 关不掉不影响后续（下次 open 会重新建立连接）。
    }
  }

  /// 关闭全部连接（切书 / 退出 / 还原前）。
  Future<void> closeAll() async {
    final books = _open.keys.toList();
    for (final uuid in books) {
      await close(uuid);
    }
  }

  /// 书被物理删除后，把残留文件也清掉（连接先关）。
  Future<void> deleteFile(String bookUuid) async {
    await close(bookUuid);
    final file = File(p.join(booksDir, AppPaths.bookDbFileName(bookUuid)));
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 书库文件是否真的在磁盘上（迁移 / 还原后校验用）。
  Future<bool> exists(String bookUuid) async {
    try {
      return await File(
        p.join(booksDir, AppPaths.bookDbFileName(bookUuid)),
      ).exists();
    } on ArgumentError {
      // uuid 非法时没有合法文件。
      return false;
    }
  }

  /// 便于上层统一处理"打开失败"（缺文件 / 身份不符）。
  Future<BookDb?> tryOpen(String bookUuid) async {
    try {
      return await open(bookUuid);
    } on DbIntegrityException {
      return null;
    } on FileSystemException {
      return null;
    }
  }
}
