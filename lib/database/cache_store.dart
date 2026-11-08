import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/app_paths.dart';
import '../utils/image_path_utils.dart';
import '../utils/timestamp_format.dart';
import 'db_open.dart';
import 'db_schema.dart';

/// `book_index` 的一行：一本书在列表页需要的全部字段。
///
/// 全部是**副本**：信源在书库，这里只为"不打开 N 个库"。
/// 设置列也一并缓存——否则列表要拼出完整的 `Book` 就得把每本书各开一次。
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
    this.baseSetting = '',
    this.writingRequirements = '',
    this.writingStyle = '',
    this.globalPrePrompt = '',
    this.globalPostPrompt = '',
    this.historyRounds = 1,
    this.memorySummaryRounds = 0,
    this.roleHierarchy = '',
    this.roleHierarchyDetail = '',
    this.bookCoverImg,
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

  final String baseSetting;
  final String writingRequirements;
  final String writingStyle;
  final String globalPrePrompt;
  final String globalPostPrompt;
  final int historyRounds;
  final int memorySummaryRounds;
  final String roleHierarchy;
  final String roleHierarchyDetail;

  /// 自定义封面的图片相对路径（书库 `book_meta.book_cover_img` 的副本）。
  final String? bookCoverImg;

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
      baseSetting: (row['base_setting'] as String?) ?? '',
      writingRequirements: (row['writing_requirements'] as String?) ?? '',
      writingStyle: (row['writing_style'] as String?) ?? '',
      globalPrePrompt: (row['global_pre_prompt'] as String?) ?? '',
      globalPostPrompt: (row['global_post_prompt'] as String?) ?? '',
      historyRounds: (row['history_rounds'] as int?) ?? 1,
      memorySummaryRounds: (row['memory_summary_rounds'] as int?) ?? 0,
      roleHierarchy: (row['role_hierarchy'] as String?) ?? '',
      roleHierarchyDetail: (row['role_hierarchy_detail'] as String?) ?? '',
      bookCoverImg: cleanImagePath(row['book_cover_img']),
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
      'base_setting': baseSetting,
      'writing_requirements': writingRequirements,
      'writing_style': writingStyle,
      'global_pre_prompt': globalPrePrompt,
      'global_post_prompt': globalPostPrompt,
      'history_rounds': historyRounds,
      'memory_summary_rounds': memorySummaryRounds,
      'role_hierarchy': roleHierarchy,
      'role_hierarchy_detail': roleHierarchyDetail,
      'book_cover_img': bookCoverImg,
    };
  }

  BookIndexRow copyWith({
    String? title,
    String? category,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastRoundAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? dbMtimeMs,
    String? baseSetting,
    String? writingRequirements,
    String? writingStyle,
    String? globalPrePrompt,
    String? globalPostPrompt,
    int? historyRounds,
    int? memorySummaryRounds,
    String? roleHierarchy,
    String? roleHierarchyDetail,
    String? bookCoverImg,
    bool clearBookCoverImg = false,
  }) {
    return BookIndexRow(
      bookUuid: bookUuid,
      title: title ?? this.title,
      category: category ?? this.category,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastRoundAt: lastRoundAt ?? this.lastRoundAt,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      dbMtimeMs: dbMtimeMs ?? this.dbMtimeMs,
      baseSetting: baseSetting ?? this.baseSetting,
      writingRequirements: writingRequirements ?? this.writingRequirements,
      writingStyle: writingStyle ?? this.writingStyle,
      globalPrePrompt: globalPrePrompt ?? this.globalPrePrompt,
      globalPostPrompt: globalPostPrompt ?? this.globalPostPrompt,
      historyRounds: historyRounds ?? this.historyRounds,
      memorySummaryRounds: memorySummaryRounds ?? this.memorySummaryRounds,
      roleHierarchy: roleHierarchy ?? this.roleHierarchy,
      roleHierarchyDetail: roleHierarchyDetail ?? this.roleHierarchyDetail,
      bookCoverImg: clearBookCoverImg
          ? null
          : (bookCoverImg ?? this.bookCoverImg),
    );
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

  /// 清掉一本书的全部图片引用（删书时调用）。
  Future<void> clearImageRefs(String bookUuid);

  /// 某一档（列宽档 + 字号档）下这本书各条目的实测高度。
  ///
  /// 返回 `item_key → height`。档位见 `ChatHeightBucket`：跨档不复用，
  /// 否则改窗口宽度 / 换字号后高度全错。
  Future<Map<String, double>> heightsOf(
    String bookUuid, {
    required int widthBucket,
    required int typeScaleBucket,
  });

  /// 批量写入某一档的实测高度（同 key 覆盖旧值）。
  Future<void> putHeights(
    String bookUuid,
    Map<String, double> heights, {
    required int widthBucket,
    required int typeScaleBucket,
  });

  /// 清掉这本书**所有档**的高度缓存（删书时调用）。
  Future<void> clearHeights(String bookUuid);

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
  Future<void> clearImageRefs(String bookUuid) async {
    final db = await _database;
    await db.delete(
      'image_refs',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
    );
  }

  @override
  Future<Map<String, double>> heightsOf(
    String bookUuid, {
    required int widthBucket,
    required int typeScaleBucket,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'chat_heights',
      columns: const ['item_key', 'height'],
      where: 'book_uuid = ? AND width_bucket = ? AND type_scale_bucket = ?',
      whereArgs: [bookUuid, widthBucket, typeScaleBucket],
    );
    return {
      for (final row in rows)
        row['item_key']! as String: (row['height']! as num).toDouble(),
    };
  }

  @override
  Future<void> putHeights(
    String bookUuid,
    Map<String, double> heights, {
    required int widthBucket,
    required int typeScaleBucket,
  }) async {
    if (heights.isEmpty) return;
    final db = await _database;
    final now = nowTimestamp();
    await db.transaction((txn) async {
      final batch = txn.batch();
      heights.forEach((key, height) {
        batch.insert(
          'chat_heights',
          {
            'book_uuid': bookUuid,
            'item_key': key,
            'width_bucket': widthBucket,
            'type_scale_bucket': typeScaleBucket,
            'height': height,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<void> clearHeights(String bookUuid) async {
    final db = await _database;
    await db.delete(
      'chat_heights',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
    );
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
