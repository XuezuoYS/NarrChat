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

/// 本地一本书的同步记录：uuid 为跨设备身份，title 用于展示与首连/兼容回退。
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

    // 轮次：group by book → 聚合指纹。
    final roundsByBook = <int, List<Map<String, Object?>>>{};
    for (final r in await db.query('rounds')) {
      final bookId = r['book_id'] as int?;
      if (bookId == null) continue;
      (roundsByBook[bookId] ??= []).add(r);
    }

    // 世界书：group by book。
    final wbByBook = <int, List<Map<String, Object?>>>{};
    for (final r in await db.query('world_book_entries')) {
      final bookId = r['book_id'] as int?;
      if (bookId == null) continue;
      (wbByBook[bookId] ??= []).add(r);
    }

    // Mod 名 → id 映射（用于 book_mods 指纹归一化）；软删 Mod 不参与。
    final modRows = await db.query('mods', where: 'deleted_at IS NULL');
    final modIdToName = <int, String>{};
    final modIdToUuid = <int, String>{};
    final localMods = <String, SyncModRecord>{};
    for (final m in modRows) {
      final id = m['id'] as int?;
      final name = (m['name'] as String? ?? '').trim();
      if (id == null || name.isEmpty) continue;
      modIdToName[id] = name;
      final uuid = (m['uuid'] as String? ?? '').isEmpty
          ? 'legacy-mod:$id'
          : m['uuid'] as String;
      modIdToUuid[id] = uuid;
      localMods[uuid] = SyncModRecord(
        uuid: uuid,
        name: name,
        fingerprint: SyncFingerprint.mod(m),
      );
    }

    // 书-Mod：group by book。
    final bookModsByBook = <int, List<Map<String, Object?>>>{};
    for (final r in await db.query('book_mods')) {
      final bookId = r['book_id'] as int?;
      if (bookId == null) continue;
      (bookModsByBook[bookId] ??= []).add(r);
    }

    final books = <String, SyncBookRecord>{};
    final bookMeta = <String, SyncBookMeta>{};
    for (final r in bookRows) {
      final id = r['id'] as int?;
      final title = (r['title'] as String? ?? '').trim();
      if (id == null || title.isEmpty) continue;
      final rounds = [
        for (final rr in roundsByBook[id] ?? const <Map<String, Object?>>[]) rr,
      ];
      final wb = [
        for (final w in wbByBook[id] ?? const <Map<String, Object?>>[]) w,
      ];
      final bm = [
        for (final b in bookModsByBook[id] ?? const <Map<String, Object?>>[]) b,
      ];
      final uuid = (r['uuid'] as String? ?? '').isEmpty
          ? 'legacy-book:$id'
          : r['uuid'] as String;
      books[uuid] = SyncBookRecord(
        uuid: uuid,
        title: title,
        parts: SyncBookParts(
          deleted: r['deleted_at'] != null,
          settingsFp: SyncFingerprint.bookSettings(r),
          roundsFp: SyncFingerprint.roundsWithFailed(rounds, r),
          worldBookFp: SyncFingerprint.worldBooks(wb),
          bookModsFp: SyncFingerprint.bookMods(bm, modIdToName, modIdToUuid),
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
