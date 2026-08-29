import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_fingerprint.dart';
import 'sync_merge_planner.dart';

/// 某本书在本地库中用于同步的部件指纹与写时间戳。
class SyncBookMeta {
  final int settingsUpdatedAt;
  final int roundsUpdatedAt;

  const SyncBookMeta({
    this.settingsUpdatedAt = 0,
    this.roundsUpdatedAt = 0,
  });
}

/// 本地一本书的同步记录：uuid 为唯一身份（同时是库主键），title 仅展示。
class SyncBookRecord {
  final String uuid;
  final String title;
  final SyncBookParts parts;

  const SyncBookRecord({
    required this.uuid,
    required this.title,
    required this.parts,
  });
}

/// 本地一个 Mod 的同步记录。
class SyncModRecord {
  final String uuid;
  final String name;
  final String fingerprint;

  const SyncModRecord({
    required this.uuid,
    required this.name,
    required this.fingerprint,
  });
}

/// 从本地库一次性读出"同步所需的部件级快照"，供 `SyncMergePlanner` 使用。
///
/// 只读业务表，不改写；返回的是纯数据。全部以 **uuid** 为键（跨设备身份），
/// title / name 作为附带字段供展示与回退匹配：
/// - [books]：uuid → 书的部件指纹 + 删除标记（软删书 `deleted=true`）；
/// - [bookMeta]：uuid → 设置/轮次写时间戳（写入 `sync_book_base` 用）；
/// - [mods]：uuid → 尚未删除的 Mod 指纹 + 名称。
class SyncLocalSnapshot {
  final Map<String, SyncBookRecord> books;
  final Map<String, SyncBookMeta> bookMeta;
  final Map<String, SyncModRecord> mods;

  const SyncLocalSnapshot({
    required this.books,
    required this.bookMeta,
    required this.mods,
  });

  static Future<SyncLocalSnapshot> build(Database db) async {
    final bookRows = await db.query('books');

    // 子表一律按 book_uuid 分组（uuid 即父表主键，无需任何 id 中转）。
    final roundsByBook = <String, List<Map<String, Object?>>>{};
    for (final r in await db.query('rounds')) {
      final bookUuid = (r['book_uuid'] as String? ?? '').trim();
      if (bookUuid.isEmpty) continue;
      (roundsByBook[bookUuid] ??= []).add(r);
    }
    final wbByBook = <String, List<Map<String, Object?>>>{};
    for (final r in await db.query('world_book_entries')) {
      final bookUuid = (r['book_uuid'] as String? ?? '').trim();
      if (bookUuid.isEmpty) continue;
      (wbByBook[bookUuid] ??= []).add(r);
    }
    final bookModsByBook = <String, List<Map<String, Object?>>>{};
    for (final r in await db.query('book_mods')) {
      final bookUuid = (r['book_uuid'] as String? ?? '').trim();
      if (bookUuid.isEmpty) continue;
      (bookModsByBook[bookUuid] ??= []).add(r);
    }

    // uuid → 名称（书-Mod 指纹按名称归一化：名称是内容，uuid 是身份）。
    // 软删 Mod 不参与。
    final modNameByUuid = <String, String>{};
    final localMods = <String, SyncModRecord>{};
    for (final m in await db.query('mods', where: 'deleted_at IS NULL')) {
      final uuid = (m['uuid'] as String? ?? '').trim();
      final name = (m['name'] as String? ?? '').trim();
      if (uuid.isEmpty || name.isEmpty) continue;
      modNameByUuid[uuid] = name;
      localMods[uuid] = SyncModRecord(
        uuid: uuid,
        name: name,
        fingerprint: SyncFingerprint.mod(m),
      );
    }

    final books = <String, SyncBookRecord>{};
    final bookMeta = <String, SyncBookMeta>{};
    for (final r in bookRows) {
      final uuid = (r['uuid'] as String? ?? '').trim();
      final title = (r['title'] as String? ?? '').trim();
      if (uuid.isEmpty || title.isEmpty) continue;
      books[uuid] = SyncBookRecord(
        uuid: uuid,
        title: title,
        parts: SyncBookParts(
          deleted: r['deleted_at'] != null,
          settingsFp: SyncFingerprint.bookSettings(r),
          roundsFp: SyncFingerprint.roundsWithFailed(
            [...roundsByBook[uuid] ?? const []],
            r,
          ),
          worldBookFp: SyncFingerprint.worldBooks(
            [...wbByBook[uuid] ?? const []],
          ),
          bookModsFp: SyncFingerprint.bookMods(
            [...bookModsByBook[uuid] ?? const []],
            modNameByUuid,
          ),
        ),
      );
      bookMeta[uuid] = SyncBookMeta(
        settingsUpdatedAt: (r['settings_updated_at'] as int?) ?? 0,
        roundsUpdatedAt: (r['rounds_updated_at'] as int?) ?? 0,
      );
    }

    return SyncLocalSnapshot(books: books, bookMeta: bookMeta, mods: localMods);
  }
}
