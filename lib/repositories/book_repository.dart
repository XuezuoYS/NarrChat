import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/book_db.dart';
import '../database/book_db_pool.dart';
import '../database/cache_store.dart';
import '../database/library_store.dart';
import '../models/book.dart';
import '../models/book_meta.dart';
import '../services/app_paths.dart';
import '../utils/constants.dart';
import '../utils/uuid_utils.dart';

/// 书籍的读写门面（R3）。
///
/// 一本书的事实分散在三个地方，本接口负责让上层看不见这个拆分：
/// - `library.books`：身份 + 墓碑（目录）；
/// - `books/narrbook_<uuid>.db` 的 `book_meta`：**书名与设置的信源**；
/// - `library_cache.book_index`：列表读的副本（含设置列，避免列出 N 本书就开 N 个库）。
abstract class BookRepository {
  /// 书籍列表（默认不含墓碑）。数据来自缓存副本，不打开书库。
  Future<List<Book>> listBooks({bool includeDeleted = false});

  /// 每本书最近一轮的时间（"最近对话"排序用）。
  Future<Map<String, DateTime>> lastRoundTimes();

  /// 打开一本完整书籍（信源读取），顺带校正缓存副本。
  Future<Book?> loadBook(String bookUuid);

  /// 新建书籍并落库，返回 uuid。
  Future<String> createBook(Book book);

  /// 保存设置（书名是信源，会一并回写目录与缓存副本）。
  Future<void> saveBook(Book book);

  /// 打墓碑（云备份删除传播用），并关闭该书连接。
  Future<void> softDeleteBook(String bookUuid);

  /// 清除墓碑（还原）。
  Future<void> restoreBook(String bookUuid);

  /// 物理删除：目录行 + 缓存行 + 书库文件。
  Future<void> purgeBook(String bookUuid);
}

/// SQLite 版 [BookRepository]。
class BookRepositorySqlite implements BookRepository {
  BookRepositorySqlite({
    required this.library,
    required this.cache,
    required this.books,
  });

  final LibraryStore library;
  final CacheStore cache;
  final BookDbPool books;

  /// 正在进行的索引自愈（避免并发 listBooks 重复重建同一批书）。
  Future<void>? _healing;

  @override
  Future<List<Book>> listBooks({bool includeDeleted = false}) async {
    final rows = await _indexRows();
    final visible = includeDeleted
        ? rows
        : rows.where((row) => !row.isDeleted);
    return visible.map(_bookFromIndex).toList(growable: false);
  }

  @override
  Future<Map<String, DateTime>> lastRoundTimes() async {
    final rows = await _indexRows();
    return {
      for (final row in rows)
        if (row.lastRoundAt != null) row.bookUuid: row.lastRoundAt!,
    };
  }

  /// 读缓存副本；发现「目录里有、缓存里没有」时先自愈再读。
  ///
  /// 成本：正常情况（无差异）只多一次 `library.books()` 查询，**不开任何书库**；
  /// 只有真缺行时才逐本打开补索引。
  ///
  /// 自愈本身失败（缓存库损坏等）不能让列表变空——退回缓存里已有的副本。
  Future<List<BookIndexRow>> _indexRows() async {
    var rows = await cache.allIndex(includeDeleted: true);
    try {
      if (await _healIndexIfNeeded(rows)) {
        rows = await cache.allIndex(includeDeleted: true);
      }
    } catch (_) {
      // 自愈是"锦上添花"，失败时宁可少几本书，也不能把整页打空。
    }
    return rows;
  }

  /// 目录里有、缓存里缺的书逐本重建索引行；返回是否发生过重建。
  Future<bool> _healIndexIfNeeded(List<BookIndexRow> cached) async {
    final directoryRows = await library.books(includeDeleted: true);
    if (directoryRows.isEmpty) return false;
    final known = {for (final row in cached) row.bookUuid};
    final missing = [
      for (final row in directoryRows)
        if (!known.contains(row.bookUuid)) row,
    ];
    if (missing.isEmpty) return false;

    // 并发调用只重建一次：两个 listBooks 同时进来时共用同一个 Future。
    final pending = _healing;
    if (pending != null) {
      await pending;
      return true;
    }
    final future = _rebuildIndex(missing);
    _healing = future;
    try {
      await future;
    } finally {
      _healing = null;
    }
    return true;
  }

  Future<void> _rebuildIndex(List<LibraryBookRow> missing) async {
    for (final row in missing) {
      // 文件根本不在：不造"幻影书"（点进去必然打不开），下轮还会再试。
      if (!await books.exists(row.bookUuid)) continue;
      try {
        final db = await books.open(row.bookUuid);
        final meta = await db.meta.read();
        await _writeIndex(meta, db);
      } catch (_) {
        // 文件在但读不出来（损坏 / 被占用）：用目录里的书名兜底，
        // 至少让用户还能看到这本书并处理，而不是整页空白。
        await _writeFallbackIndex(row);
      }
    }
  }

  /// 书库读不出来时的兜底索引行：只保证"能列出来"，其余字段留空。
  Future<void> _writeFallbackIndex(LibraryBookRow row) async {
    try {
      await cache.putIndex(BookIndexRow(
        bookUuid: row.bookUuid,
        title: row.title,
        deletedAt: row.deletedAt,
        dbMtimeMs: await _mtimeOf(row.bookUuid),
      ));
    } catch (_) {
      // 兜底也失败就真没办法了，不阻断其它书。
    }
  }

  @override
  Future<Book?> loadBook(String bookUuid) async {
    if (bookUuid.isEmpty) return null;
    final db = await books.tryOpen(bookUuid);
    if (db == null) return null;
    final meta = await db.meta.read();
    await _writeIndex(meta, db);
    return _bookFromMeta(meta);
  }

  @override
  Future<String> createBook(Book book) async {
    final uuid = book.uuid.isEmpty ? UuidUtils.generateUuidV4() : book.uuid;
    // 同一个 uuid 再建一次**不能**重建书库：`BookDb.create` 会覆盖文件，
    // 等于把这本书的轮次 / 世界书 / 分支全删光。现实里也没有「新建一本已存在的书」
    // 的需求，物理删除只走 [purgeBook]。这里直接返回，让调用方继续用已有数据。
    if (await books.exists(uuid)) return uuid;
    final now = DateTime.now().toUtc();
    final masterUuid = await library.masterUuid();
    final meta = BookMeta(
      bookUuid: uuid,
      masterUuid: masterUuid,
      title: book.title,
      category: book.category,
      createdAt: now,
      updatedAt: now,
      baseSetting: book.baseSetting,
      writingRequirements: book.writingRequirements,
      writingStyle: book.writingStyle,
      globalPrePrompt: book.globalPrePrompt,
      globalPostPrompt: book.globalPostPrompt,
      historyRounds: book.historyRounds,
      memorySummaryRounds: book.memorySummaryRounds,
      roleHierarchy: book.roleHierarchy,
      roleHierarchyDetail:
          Constants.encodeRoleCategories(book.roleCategories),
    );

    final db = await BookDb.create(meta: meta, pathOverride: _pathOf(uuid));
    await db.close();

    await library.putBook(LibraryBookRow(bookUuid: uuid, title: book.title));
    await cache.putIndex(BookIndexRow(
      bookUuid: uuid,
      title: meta.title,
      category: meta.category,
      createdAt: meta.createdAt,
      updatedAt: meta.updatedAt,
      dbMtimeMs: await _mtimeOf(uuid),
      baseSetting: meta.baseSetting,
      writingRequirements: meta.writingRequirements,
      writingStyle: meta.writingStyle,
      globalPrePrompt: meta.globalPrePrompt,
      globalPostPrompt: meta.globalPostPrompt,
      historyRounds: meta.historyRounds,
      memorySummaryRounds: meta.memorySummaryRounds,
      roleHierarchy: meta.roleHierarchy,
      roleHierarchyDetail: meta.roleHierarchyDetail,
    ));
    return uuid;
  }

  @override
  Future<void> saveBook(Book book) async {
    if (book.uuid.isEmpty) {
      throw ArgumentError('saveBook 需要非空 uuid（新书请先 createBook）');
    }
    final db = await books.open(book.uuid);
    final existing = await db.meta.read();
    final meta = BookMeta(
      bookUuid: book.uuid,
      masterUuid: existing.masterUuid,
      title: book.title,
      category: book.category,
      createdAt: existing.createdAt,
      // 信源里的 updated_at 由 store 在写入时刷新，这里只是过渡值。
      updatedAt: DateTime.now().toUtc(),
      baseSetting: book.baseSetting,
      writingRequirements: book.writingRequirements,
      writingStyle: book.writingStyle,
      globalPrePrompt: book.globalPrePrompt,
      globalPostPrompt: book.globalPostPrompt,
      historyRounds: book.historyRounds,
      memorySummaryRounds: book.memorySummaryRounds,
      roleHierarchy: book.roleHierarchy,
      roleHierarchyDetail:
          Constants.encodeRoleCategories(book.roleCategories),
    );
    await db.meta.writeSettings(meta);
    // 目录行只回写书名：不能整行覆盖，否则会把墓碑清掉。
    await library.setTitle(book.uuid, book.title);
    await _writeIndex(await db.meta.read(), db);
  }

  @override
  Future<void> softDeleteBook(String bookUuid) async {
    if (bookUuid.isEmpty) return;
    final now = DateTime.now().toUtc();
    await library.setDeletedAt(bookUuid, now);
    final existing = await cache.indexOf(bookUuid);
    if (existing != null) {
      await cache.putIndex(existing.copyWith(deletedAt: now));
    }
    await books.close(bookUuid);
  }

  @override
  Future<void> restoreBook(String bookUuid) async {
    if (bookUuid.isEmpty) return;
    await library.setDeletedAt(bookUuid, null);
    final existing = await cache.indexOf(bookUuid);
    if (existing != null) {
      await cache.putIndex(existing.copyWith(clearDeletedAt: true));
    }
  }

  @override
  Future<void> purgeBook(String bookUuid) async {
    if (bookUuid.isEmpty) return;
    await library.removeBook(bookUuid);
    await cache.removeIndex(bookUuid);
    await books.deleteFile(bookUuid);
  }

  /// 用信源校正缓存副本（打开书时顺手做，缓存不会长期漂移）。
  ///
  /// 墓碑从**目录库**取：缓存里那一列只是副本，单看它会把"删掉的书"写成活的。
  Future<void> _writeIndex(BookMeta meta, BookDb db) async {
    final directoryRow = await library.book(meta.bookUuid);
    final lastRoundAt = await db.rounds.lastRoundAt();
    await cache.putIndex(BookIndexRow(
      bookUuid: meta.bookUuid,
      title: meta.title,
      category: meta.category,
      createdAt: meta.createdAt,
      updatedAt: meta.updatedAt,
      lastRoundAt: lastRoundAt,
      deletedAt: directoryRow?.deletedAt,
      dbMtimeMs: await _mtimeOf(meta.bookUuid),
      baseSetting: meta.baseSetting,
      writingRequirements: meta.writingRequirements,
      writingStyle: meta.writingStyle,
      globalPrePrompt: meta.globalPrePrompt,
      globalPostPrompt: meta.globalPostPrompt,
      historyRounds: meta.historyRounds,
      memorySummaryRounds: meta.memorySummaryRounds,
      roleHierarchy: meta.roleHierarchy,
      roleHierarchyDetail: meta.roleHierarchyDetail,
    ));
  }

  Book _bookFromIndex(BookIndexRow row) {
    return Book(
      uuid: row.bookUuid,
      title: row.title,
      category: row.category,
      baseSetting: row.baseSetting,
      writingRequirements: row.writingRequirements,
      writingStyle: row.writingStyle,
      globalPrePrompt: row.globalPrePrompt,
      globalPostPrompt: row.globalPostPrompt,
      historyRounds: row.historyRounds,
      memorySummaryRounds: row.memorySummaryRounds,
      roleHierarchy: row.roleHierarchy,
      roleCategories: Constants.decodeRoleCategories(row.roleHierarchyDetail),
    );
  }

  Book _bookFromMeta(BookMeta meta) {
    return Book(
      uuid: meta.bookUuid,
      title: meta.title,
      category: meta.category,
      baseSetting: meta.baseSetting,
      writingRequirements: meta.writingRequirements,
      writingStyle: meta.writingStyle,
      globalPrePrompt: meta.globalPrePrompt,
      globalPostPrompt: meta.globalPostPrompt,
      historyRounds: meta.historyRounds,
      memorySummaryRounds: meta.memorySummaryRounds,
      roleHierarchy: meta.roleHierarchy,
      roleCategories: Constants.decodeRoleCategories(meta.roleHierarchyDetail),
    );
  }

  String _pathOf(String bookUuid) =>
      p.join(books.booksDir, AppPaths.bookDbFileName(bookUuid));

  Future<int> _mtimeOf(String bookUuid) async {
    try {
      final file = File(_pathOf(bookUuid));
      if (!await file.exists()) return 0;
      return (await file.stat()).modified.millisecondsSinceEpoch;
    } on ArgumentError {
      return 0;
    } on FileSystemException {
      return 0;
    }
  }
}
