import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/app_paths.dart';
import '../utils/timestamp_format.dart';
import 'db_open.dart';
import 'db_schema.dart';

/// `book_index` 的一行：一本书在列表页需要的全部字段。
///
/// 全部是**副本**：信源在书库，这里只为"不打开 N 个库"。
class BookIndexRow {
  const BookIndexRow({
    required this.bookUuid,
    this.title = '',
    this.category = '',
    this.createdAt,
    this.updatedAt,
    this.lastRoundAt,
    this.deletedAt,
    this.dbMtimeMs = 0,
  });

  final String bookUuid;
  final String title;
  final String category;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 最近一条轮次的时间（列表"最近对话"排序用）。
  final DateTime? lastRoundAt;
  final DateTime? deletedAt;

  /// 书库文件的修改时间（毫秒）：变了就说明缓存行该刷新。
  final int dbMtimeMs;

  bool get isDeleted => deletedAt != null;

  factory BookIndexRow.fromRow(Map<String, Object?> row) {
    return BookIndexRow(
      bookUuid: (row['book_uuid'] as String?) ?? '',
      title: (row['title'] as String?) ?? '',
      category: (row['category'] as String?) ?? '',
      createdAt: parseTimestamp(row['created_at']),
      updatedAt: parseTimestamp(row['updated_at']),
      lastRoundAt: parseTimestamp(row['last_round_at']),
      deletedAt: parseTimestamp(row['deleted_at']),
      dbMtimeMs: (row['db_mtime_ms'] as int?) ?? 0,
    );
  }

  Map<String, Object?> toRow() {
    return {
      'book_uuid': bookUuid,
      'title': title,
      'category': category,
      'created_at': _format(createdAt),
      'updated_at': _format(updatedAt),
      'last_round_at': _format(lastRoundAt),
      // 墓碑必须是真正的 NULL：列表查询靠 `deleted_at IS NULL` 过滤。
      'deleted_at': deletedAt == null ? null : formatTimestamp(deletedAt!),
      'db_mtime_ms': dbMtimeMs,
    };
  }

  static String _format(DateTime? value) =>
      value == null ? '' : formatTimestamp(value);
}

/// `image_refs` 的一行：某张图被某本书引用了几次。
///
/// 只用于「图片库展示引用关系 / 删除前提示影响范围」，
/// **不做引用保护**：用户点删除就删，剧情里显示为缺失。
class ImageRefRow {
  const ImageRefRow({
    required this.imagePath,
    required this.bookUuid,
    this.refCount = 0,
  });

  /// 相对路径 `img/<sha256>.<ext>`。
  final String imagePath;
  final String bookUuid;
  final int refCount;

  factory ImageRefRow.fromRow(Map<String, Object?> row) {
    return ImageRefRow(
      imagePath: (row['image_path'] as String?) ?? '',
      bookUuid: (row['book_uuid'] as String?) ?? '',
      refCount: (row['ref_count'] as int?) ?? 0,
    );
  }

  Map<String, Object?> toRow() => {
        'image_path': imagePath,
        'book_uuid': bookUuid,
        'ref_count': refCount,
      };
}

/// 本地缓存库（`local_config/local_db/library_cache.db`）。
///
/// 纯派生数据、随时可重建，任何情况下都不得把这里的值当信源写回书库。
abstract class CacheStore {
  Future<BookIndexRow?> indexOf(String bookUuid);

  Future<List<BookIndexRow>> allIndex({bool includeDeleted = false});

  /// 写入 / 覆盖一本书的索引行。
  Future<void> putIndex(BookIndexRow row);

  Future<void> removeIndex(String bookUuid);

  /// 全量重建书籍索引（后台重建任务用，一次事务写完）。
  Future<void> replaceAllIndex(List<BookIndexRow> rows);

  Future<List<ImageRefRow>> imageRefsOf(String bookUuid);

  /// 整体替换一本书的图片引用。
  Future<void> replaceImageRefs(String bookUuid, List<ImageRefRow> refs);

  Future<void> close();
}

/// SQLite 版 [CacheStore]。
class CacheDb implements CacheStore {
  CacheDb({this.pathOverride});

  final String? pathOverride;

  Database? _db;

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    final path = pathOverride ?? await AppPaths.libraryCacheDatabasePath();
    final db = await openAppDatabase(
      path: path,
      version: localCacheDbVersion,
      onCreate: createCacheSchema,
      onUpgrade: (db, oldVersion, newVersion) async {
        // 缓存库是纯派生数据：升级即整体重建，不写逐版本迁移。
        for (final table in const ['book_index', 'image_refs', 'chat_heights']) {
          await db.execute('DROP TABLE IF EXISTS $table');
        }
        await createCacheSchema(db);
      },
    );
    _db = db;
    return db;
  }

  @override
  Future<BookIndexRow?> indexOf(String bookUuid) async {
    if (bookUuid.isEmpty) return null;
    final db = await _database;
    final rows = await db.query(
      'book_index',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return BookIndexRow.fromRow(rows.first);
  }

  @override
  Future<List<BookIndexRow>> allIndex({bool includeDeleted = false}) async {
    final db = await _database;
    final rows = await db.query(
      'book_index',
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy: 'updated_at DESC, book_uuid ASC',
    );
    return rows.map(BookIndexRow.fromRow).toList();
  }

  @override
  Future<void> putIndex(BookIndexRow row) async {
    final db = await _database;
    await db.insert(
      'book_index',
      row.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> removeIndex(String bookUuid) async {
    final db = await _database;
    await db.delete(
      'book_index',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
    );
  }

  @override
  Future<void> replaceAllIndex(List<BookIndexRow> rows) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('book_index');
      for (final row in rows) {
        await txn.insert(
          'book_index',
          row.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  @override
  Future<List<ImageRefRow>> imageRefsOf(String bookUuid) async {
    final db = await _database;
    final rows = await db.query(
      'image_refs',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'image_path ASC',
    );
    return rows.map(ImageRefRow.fromRow).toList();
  }

  @override
  Future<void> replaceImageRefs(String bookUuid, List<ImageRefRow> refs) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(
        'image_refs',
        where: 'book_uuid = ?',
        whereArgs: [bookUuid],
      );
      for (final row in refs) {
        await txn.insert(
          'image_refs',
          {...row.toRow(), 'book_uuid': bookUuid},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
