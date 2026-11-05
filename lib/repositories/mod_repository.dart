import '../database/book_db_pool.dart';
import '../database/book_store.dart';
import '../database/mods_store.dart';
import '../models/mod.dart';
import '../utils/uuid_utils.dart';

/// Mod 仓储（R3）：Mod 本体在 `narrchat_mods.db`，某本书启用哪些在书库的 `use_mods`。
///
/// 「启用」是两处数据：本接口把"取启用清单"与"整体替换启用清单"合在一起，
/// 保证顺序（`sort_order`）与去重只在一个地方处理。
class ModRepository {
  ModRepository({required this.mods, required this.books});

  final ModsStore mods;
  final BookDbPool books;

  Future<List<Mod>> listMods({bool includeDeleted = false}) =>
      mods.list(includeDeleted: includeDeleted);

  Future<Mod?> getMod(String uuid) => mods.get(uuid);

  /// 新建 Mod，返回 uuid。
  Future<String> createMod(Mod mod) async {
    final uuid = mod.uuid.isEmpty ? UuidUtils.generateUuidV4() : mod.uuid;
    await mods.upsert(mod.copyWith(uuid: uuid));
    return uuid;
  }

  Future<void> updateMod(Mod mod) async {
    if (mod.uuid.isEmpty) throw ArgumentError('updateMod 需要非空 uuid');
    await mods.upsert(mod);
  }

  /// 软删（整库同步下墓碑只影响展示，不做删除传播）。
  Future<void> deleteMod(String uuid) async {
    if (uuid.isEmpty) return;
    await mods.setDeletedAt(uuid, DateTime.now().toUtc());
  }

  /// 某本书启用的 Mod uuid 列表（按启用顺序）。
  Future<List<String>> useModUuids(String bookUuid) async {
    if (bookUuid.isEmpty) return const [];
    final db = await books.open(bookUuid);
    final rows = await db.useMods.list();
    return [for (final row in rows) row.modUuid];
  }

  /// 整体替换启用清单：去重、按传入顺序重编号。
  Future<void> setUseModUuids(String bookUuid, List<String> uuids) async {
    if (bookUuid.isEmpty) return;
    final seen = <String>{};
    final rows = <UseModRow>[];
    for (final uuid in uuids) {
      if (uuid.isEmpty || !seen.add(uuid)) continue;
      rows.add(UseModRow(modUuid: uuid, sortOrder: rows.length));
    }
    final db = await books.open(bookUuid);
    await db.useMods.replaceAll(rows);
  }
}
