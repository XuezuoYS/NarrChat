import '../database/book_db_pool.dart';
import '../models/world_book_entry.dart';
import '../models/world_book_row.dart';
import '../utils/uuid_utils.dart';

/// 世界书仓储（R3）：条目随书库，身份是 uuid 而不是本地自增 id。
///
/// 对外仍返回 [WorldBookEntry]（界面一直用它），内部映射到 [WorldBookRow]。
class WorldBookRepository {
  WorldBookRepository({required this.books});

  final BookDbPool books;

  Future<List<WorldBookEntry>> list(String bookUuid) async {
    if (bookUuid.isEmpty) return const [];
    final db = await books.open(bookUuid);
    final rows = await db.worldBook.list();
    return [
      for (final row in rows)
        WorldBookEntry(
          uuid: row.uuid,
          bookUuid: bookUuid,
          keyword: row.keyword,
          content: row.content,
          isActive: row.isUsing,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
        ),
    ];
  }

  /// 新增或覆盖一条（uuid 为空 = 新条目，自动生成身份）。
  Future<WorldBookEntry> upsert(String bookUuid, WorldBookEntry entry) async {
    final uuid =
        entry.uuid.isEmpty ? UuidUtils.generateUuidV4() : entry.uuid;
    final db = await books.open(bookUuid);
    final now = DateTime.now().toUtc();
    await db.worldBook.upsert(WorldBookRow(
      uuid: uuid,
      keyword: entry.keyword,
      content: entry.content,
      isUsing: entry.isActive,
      createdAt: entry.createdAt ?? now,
      updatedAt: now,
    ));
    return entry.copyWith(uuid: uuid, updatedAt: now);
  }

  Future<void> delete(String bookUuid, String uuid) async {
    if (bookUuid.isEmpty || uuid.isEmpty) return;
    final db = await books.open(bookUuid);
    await db.worldBook.delete(uuid);
  }

  /// 整体替换（书籍设置保存 / 同步还原 / 导入用）。
  ///
  /// 设置页的草稿里，新条目没有 uuid（界面还不该关心身份）；这里统一补一个，
  /// 保证 `world_book_entries.uuid` 主键非空且多条新条目不会互相撞键。
  Future<void> replaceAll(String bookUuid, List<WorldBookEntry> entries) async {
    if (bookUuid.isEmpty) return;
    final db = await books.open(bookUuid);
    final now = DateTime.now().toUtc();
    await db.worldBook.replaceAll([
      for (final entry in entries)
        WorldBookRow(
          uuid: entry.uuid.isEmpty ? UuidUtils.generateUuidV4() : entry.uuid,
          keyword: entry.keyword,
          content: entry.content,
          isUsing: entry.isActive,
          createdAt: entry.createdAt ?? now,
          updatedAt: entry.updatedAt ?? now,
        ),
    ]);
  }
}
