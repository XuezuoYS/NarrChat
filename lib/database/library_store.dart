import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/app_paths.dart';
import '../utils/timestamp_format.dart';
import '../utils/uuid_utils.dart';
import 'db_open.dart';
import 'db_schema.dart';

/// `library.books` 的一行：只有目录信息与墓碑，不含内容。
class LibraryBookRow {
  const LibraryBookRow({
    required this.bookUuid,
    required this.title,
    this.deletedAt,
  });

  final String bookUuid;

  /// 书名**副本**；信源在 `book_meta.title`，这里只用于兜底展示与同名匹配。
  final String title;

  /// 软删墓碑：非空表示这本书已被用户删除（云备份删除传播用）。
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  factory LibraryBookRow.fromRow(Map<String, Object?> row) {
    return LibraryBookRow(
      bookUuid: (row['book_uuid'] as String?) ?? '',
      title: (row['title'] as String?) ?? '',
      deletedAt: parseTimestamp(row['deleted_at']),
    );
  }

  Map<String, Object?> toRow() => {
        'book_uuid': bookUuid,
        'title': title,
        'deleted_at': deletedAt == null ? null : formatTimestamp(deletedAt!),
      };
}

/// 书籍目录库（`user_data/narrchat_library.db`）。
///
/// 职责边界：
/// - 本库**只**存书的身份与墓碑，不存分类 / 时间 / 轮次——那些在书库与缓存里；
/// - 列表页不查本库（避免每次列表都开一个库），页面数据来自 `library_cache.db`；
/// - 写本库的唯一入口就是本类，保证「书目录 + 书文件」不会各自漂移。
abstract class LibraryStore {
  /// 本套 user_data 的全局 UUID（几个库互相校验用）。
  Future<String> masterUuid();

  /// 镜像版本号，仅供调试页展示；判断版本请读 `PRAGMA user_version`。
  Future<int> databaseVersion();

  Future<List<LibraryBookRow>> books({bool includeDeleted = false});

  Future<LibraryBookRow?> book(String bookUuid);

  /// 新增或覆盖一行目录。
  Future<void> putBook(LibraryBookRow row);

  /// 只改书名副本（书库改名后回写）。
  Future<void> setTitle(String bookUuid, String title);

  /// 打上 / 清除墓碑。
  Future<void> setDeletedAt(String bookUuid, DateTime? deletedAt);

  /// 物理删除目录行（连墓碑一起清掉，用于彻底移除）。
  Future<void> removeBook(String bookUuid);

  Future<void> close();
}

/// SQLite 版 [LibraryStore]。
///
/// 生产环境用默认路径；测试传 [pathOverride] 指向临时文件（不触碰真实用户目录）。
class LibraryDb implements LibraryStore {
  LibraryDb({this.pathOverride, this.masterUuidOverride});

  final String? pathOverride;

  /// 迁移时显式指定 `master_uuid`，保证「建库 → 迁移 → 重跑」拿到同一个值。
  final String? masterUuidOverride;

  Database? _db;

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    final path = pathOverride ?? await AppPaths.libraryDatabasePath();
    final db = await openAppDatabase(
      path: path,
      version: userDataDbVersion,
      onCreate: (db) async {
        await createLibrarySchema(db);
        await _insertMeta(db, masterUuidOverride ?? UuidUtils.generateUuidV4());
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // R3 首次建库即 22，之后只做加法迁移；这里是以后加列的落点。
        await writeDatabaseVersion(db, 'meta', newVersion);
      },
    );
    _db = db;
    return db;
  }

  @override
  Future<String> masterUuid() async {
    final db = await _database;
    return _readMasterUuid(db);
  }

  @override
  Future<int> databaseVersion() async {
    final db = await _database;
    return readUserVersion(db);
  }

  @override
  Future<List<LibraryBookRow>> books({bool includeDeleted = false}) async {
    final db = await _database;
    final rows = await db.query(
      'books',
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy: 'book_uuid ASC',
    );
    return rows.map(LibraryBookRow.fromRow).toList();
  }

  @override
  Future<LibraryBookRow?> book(String bookUuid) async {
    if (bookUuid.isEmpty) return null;
    final db = await _database;
    final rows = await db.query(
      'books',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LibraryBookRow.fromRow(rows.first);
  }

  @override
  Future<void> putBook(LibraryBookRow row) async {
    final db = await _database;
    await db.insert(
      'books',
      row.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> setTitle(String bookUuid, String title) async {
    final db = await _database;
    await db.update(
      'books',
      {'title': title},
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
    );
  }

  @override
  Future<void> setDeletedAt(String bookUuid, DateTime? deletedAt) async {
    final db = await _database;
    await db.update(
      'books',
      {'deleted_at': deletedAt == null ? null : formatTimestamp(deletedAt)},
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
    );
  }

  @override
  Future<void> removeBook(String bookUuid) async {
    final db = await _database;
    await db.delete('books', where: 'book_uuid = ?', whereArgs: [bookUuid]);
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  static Future<void> _insertMeta(Database db, String masterUuid) async {
    await db.insert('meta', {
      'master_uuid': masterUuid,
      'database_version': userDataDbVersion,
    });
  }

  static Future<String> _readMasterUuid(DatabaseExecutor db) async {
    final rows = await db.query('meta', orderBy: 'rowid ASC', limit: 1);
    if (rows.isEmpty) return '';
    return (rows.first['master_uuid'] as String?) ?? '';
  }
}
