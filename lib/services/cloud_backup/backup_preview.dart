import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../database/book_db_pool.dart';
import '../../database/library_store.dart';
import '../../database/mods_store.dart';
import '../../database/sqflite_desktop.dart';
import '../../models/preset_mods.dart';
import '../../models/round_generation.dart';
import '../../utils/timestamp_format.dart';
import '../sync/sync_conflict.dart';
import 'backup_manifest.dart';
import 'backup_mods_conflict.dart';
import 'backup_remote.dart';
import 'backup_unit.dart';

/// 冲突决策页的「单侧预览」读取器。
///
/// 本地一侧直接读各 store（书库是活数据，没必要再复制一份）；云端一侧把那一代
/// 快照下载到临时文件，用**只读连接**读概览，读完立刻关连接、删临时目录：
/// 绝不改动云端快照，也不长期占磁盘。临时文件还顺带避免了 Windows 上「同一文件
/// 被两个连接打开」的锁问题。
class BackupPreviewReader {
  BackupPreviewReader({
    required this.remoteFactory,
    required this.locator,
    required this.books,
    required this.mods,
    required this.library,
    this.openDatabase,
  });

  /// 云端读写（每次读取结束由本类 close）。
  final BackupRemote Function() remoteFactory;

  /// 本地库路径定位（Mod 库 / 书架直接读文件，和云端走同一套 SQL）。
  final BackupLocator locator;

  final BookDbPool books;
  final ModsStore mods;
  final LibraryStore library;

  /// 打开只读连接的替身（测试注入；缺省用 sqflite 工厂）。
  final Future<Database> Function(String path)? openDatabase;

  /// 读取某一侧的预览数据。
  Future<SyncSidePreview> read(
    SyncConflict conflict,
    SyncPreviewSide side,
  ) async {
    final remote = remoteFactory();
    try {
      return switch (conflict.unit.kind) {
        BackupUnitKind.book => await _readBook(conflict, side, remote),
        BackupUnitKind.mods => await _readMods(conflict, side, remote),
        BackupUnitKind.library => await _readLibrary(conflict, side, remote),
      };
    } finally {
      remote.close();
    }
  }

  /// 释放资源（每次读取已自行收尾，方法保留给调用方统一收口）。
  void close() {}

  // --- 书籍 -------------------------------------------------------------------

  Future<SyncSidePreview> _readBook(
    SyncConflict conflict,
    SyncPreviewSide side,
    BackupRemote remote,
  ) async {
    final book = side == SyncPreviewSide.local
        ? await _readLocalBook(conflict.unit.refUuid)
        : await _withRemoteSnapshot(
            remote,
            _snapshotNameOf(conflict),
            _readBookFromDatabase,
          );
    return SyncSidePreview(side: side, book: book);
  }

  Future<BookSidePreview> _readLocalBook(String bookUuid) async {
    final db = await books.open(bookUuid);
    final meta = await db.meta.read();
    final worldBook = await db.worldBook.list();
    final useMods = await db.useMods.list();
    final metas = await db.rounds.listMeta();

    var latestIndex = 0;
    for (final item in metas) {
      if (item.roundIndex > latestIndex) latestIndex = item.roundIndex;
    }
    RoundMeta? latestMeta;
    for (final item in metas) {
      if (item.roundIndex != latestIndex) continue;
      if (latestMeta == null || (item.isUsing && !latestMeta.isUsing)) {
        latestMeta = item;
      }
    }
    var userInput = '';
    var narrative = '';
    if (latestMeta != null) {
      final generations = await db.rounds.listGenerations(
        firstRoundIndex: latestIndex,
        lastRoundIndex: latestIndex,
      );
      for (final generation in generations) {
        if (generation.meta.uuid != latestMeta.uuid) continue;
        userInput = generation.userInput;
        narrative = generation.aiNarrative;
        break;
      }
    }

    return BookSidePreview(
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
      worldBookCount: worldBook.length,
      worldBookKeywords: [
        for (final entry in worldBook)
          if (entry.keyword.trim().isNotEmpty) entry.keyword,
      ],
      modNames: await _modNames([for (final row in useMods) row.modUuid]),
      roundGenerationCount: metas.length,
      latestRoundIndex: latestIndex,
      latestRoundAt: latestMeta?.operatedAt,
      latestUserInput: userInput,
      latestNarrative: narrative,
    );
  }

  /// 从任意一个「书库结构」的数据库连接读书籍预览（云端快照用）。
  Future<BookSidePreview> _readBookFromDatabase(DatabaseExecutor db) async {
    final metaRows = await db.query('book_meta', limit: 1);
    final meta = metaRows.isEmpty ? const <String, Object?>{} : metaRows.first;
    final worldRows = await db.rawQuery(
      'SELECT "keyword" FROM "world_book_entries" ORDER BY "created_at" ASC',
    );
    final useModRows = await db.rawQuery(
      'SELECT "mod_uuid" FROM "use_mods" ORDER BY "sort_order" ASC',
    );
    final roundRows = await db.rawQuery(
      'SELECT COUNT(*) AS "total", MAX("round_index") AS "latest" '
      'FROM "round_stack"',
    );
    final total = _intOf(roundRows, 'total');
    final latestIndex = _intOf(roundRows, 'latest');
    var userInput = '';
    var narrative = '';
    var latestAt = '';
    if (latestIndex > 0) {
      final rows = await db.rawQuery(
        'SELECT "user_input", "ai_narrative", "operated_at" FROM "round_stack" '
        'WHERE "round_index" = ? '
        'ORDER BY "is_using" DESC, "operated_at" DESC LIMIT 1',
        [latestIndex],
      );
      if (rows.isNotEmpty) {
        userInput = (rows.first['user_input'] as String?) ?? '';
        narrative = (rows.first['ai_narrative'] as String?) ?? '';
        latestAt = (rows.first['operated_at'] as String?) ?? '';
      }
    }

    return BookSidePreview(
      title: _textOf(meta, 'title'),
      category: _textOf(meta, 'category'),
      baseSetting: _textOf(meta, 'base_setting'),
      writingRequirements: _textOf(meta, 'writing_requirements'),
      writingStyle: _textOf(meta, 'writing_style'),
      globalPrePrompt: _textOf(meta, 'global_pre_prompt'),
      globalPostPrompt: _textOf(meta, 'global_post_prompt'),
      historyRounds: (meta['history_rounds'] as num?)?.toInt() ?? 0,
      memorySummaryRounds:
          (meta['memory_summary_rounds'] as num?)?.toInt() ?? 0,
      roleHierarchy: _textOf(meta, 'role_hierarchy'),
      worldBookCount: worldRows.length,
      worldBookKeywords: [
        for (final row in worldRows)
          if (((row['keyword'] as String?) ?? '').trim().isNotEmpty)
            (row['keyword'] as String).trim(),
      ],
      modNames: await _modNames([
        for (final row in useModRows) ((row['mod_uuid'] as String?) ?? ''),
      ]),
      roundGenerationCount: total,
      latestRoundIndex: latestIndex,
      latestRoundAt: parseTimestamp(latestAt),
      latestUserInput: userInput,
      latestNarrative: narrative,
    );
  }

  // --- Mod 库 -----------------------------------------------------------------

  Future<SyncSidePreview> _readMods(
    SyncConflict conflict,
    SyncPreviewSide side,
    BackupRemote remote,
  ) async {
    final modsPreview = side == SyncPreviewSide.local
        ? await _readLocalModsFile()
        : await _withRemoteSnapshot(
            remote,
            _snapshotNameOf(conflict),
            _readModsFromDatabase,
          );
    return SyncSidePreview(side: side, mods: modsPreview);
  }

  /// 读本地 Mod 库的全部行（含墓碑）；库文件不存在时返回空列表。
  ///
  /// 逐 Mod PK 与合并都复用这一份读取：与预览同一条只读连接，不碰写连接。
  Future<List<Map<String, Object?>>> readLocalModRows() async {
    final path = locator.localPathOf(BackupUnit.mods);
    if (!await File(path).exists()) return const [];
    return _withDatabase(path, readModRowsFromDatabase);
  }

  /// 读云端某一代快照的 Mod 行（含墓碑），读不到时抛错由调用方兜底。
  Future<List<Map<String, Object?>>> readRemoteModRows(
    BackupManifest manifest,
  ) async {
    final remote = remoteFactory();
    try {
      return await readRemoteModRowsWith(remote, manifest);
    } finally {
      remote.close();
    }
  }

  /// 用调用方已有的远端连接读快照：逐 Mod 合并时复用同一次同步的 client。
  Future<List<Map<String, Object?>>> readRemoteModRowsWith(
    BackupRemote remote,
    BackupManifest manifest,
  ) {
    return _withRemoteSnapshot(
      remote,
      manifest.snapshotName,
      readModRowsFromDatabase,
    );
  }

  Future<ModsSidePreview> _readLocalModsFile() async {
    final rows = await readLocalModRows();
    return ModsSidePreview(mods: [for (final row in rows) _modPreviewOf(row)]);
  }

  Future<ModsSidePreview> _readModsFromDatabase(DatabaseExecutor db) async {
    final rows = await readModRowsFromDatabase(db);
    return ModsSidePreview(mods: [for (final row in rows) _modPreviewOf(row)]);
  }

  /// 原始行 → 单条预览（内容指纹与逐 Mod PK 共用同一算法）。
  static ModEntryPreview _modPreviewOf(Map<String, Object?> row) {
    return ModEntryPreview(
      uuid: _textOf(row, 'mod_uuid'),
      name: _textOf(row, 'name'),
      description: _textOf(row, 'description'),
      prePrompt: _textOf(row, 'pre_prompt'),
      postPrompt: _textOf(row, 'post_prompt'),
      systemPrompt: _textOf(row, 'system_prompt'),
      worldBookCount: _worldBookCountOf(_textOf(row, 'world_book')),
      updatedAt: parseTimestamp(row['updated_at']),
      deleted: row['deleted_at'] != null,
      contentDigest: ModContentDigest.ofRow(row),
    );
  }

  // --- 书架 -------------------------------------------------------------------

  Future<SyncSidePreview> _readLibrary(
    SyncConflict conflict,
    SyncPreviewSide side,
    BackupRemote remote,
  ) async {
    final preview = side == SyncPreviewSide.local
        ? await _readLocalLibraryFile()
        : await _withRemoteSnapshot(
            remote,
            _snapshotNameOf(conflict),
            _readLibraryFromDatabase,
          );
    return SyncSidePreview(side: side, library: preview);
  }

  Future<LibrarySidePreview> _readLocalLibraryFile() async {
    final path = locator.localPathOf(BackupUnit.library);
    if (!await File(path).exists()) {
      return const LibrarySidePreview();
    }
    return _withDatabase(path, _readLibraryFromDatabase);
  }

  Future<LibrarySidePreview> _readLibraryFromDatabase(
    DatabaseExecutor db,
  ) async {
    final rows = await db.rawQuery(
      'SELECT * FROM "books" ORDER BY "book_uuid" ASC',
    );
    final parsed = rows.map((row) {
      return LibraryBookPreview(
        bookUuid: _textOf(row, 'book_uuid'),
        title: _textOf(row, 'title'),
        deletedAt: parseTimestamp(row['deleted_at']),
        deletedRoundIndex: (row['deleted_round_index'] as num?)?.toInt(),
      );
    }).toList()..sort(_compareLibraryRows);
    return LibrarySidePreview(
      alive: [
        for (final row in parsed)
          if (!row.isDeleted) row,
      ],
      deleted: [
        for (final row in parsed)
          if (row.isDeleted) row,
      ],
    );
  }

  static int _compareLibraryRows(LibraryBookPreview a, LibraryBookPreview b) {
    final ta = a.title.trim();
    final tb = b.title.trim();
    if (ta.isEmpty != tb.isEmpty) return ta.isEmpty ? 1 : -1;
    return ta.compareTo(tb);
  }

  // --- 工具 -------------------------------------------------------------------

  /// 云端快照名：取冲突清单里那一代；清单缺失直接报错（页面显示可重试的失败态）。
  static String _snapshotNameOf(SyncConflict conflict) {
    final name = conflict.plan.remote?.snapshotName ?? '';
    if (name.isEmpty) {
      throw const BackupRemoteException('缺少云端清单，无法读取预览');
    }
    return name;
  }

  Future<T> _withRemoteSnapshot<T>(
    BackupRemote remote,
    String snapshotName,
    Future<T> Function(DatabaseExecutor db) action,
  ) async {
    final bytes = await remote.read(snapshotName);
    final dir = await Directory.systemTemp.createTemp('narrchat_preview_');
    final path = p.join(dir.path, 'snapshot.db');
    try {
      await File(path).writeAsBytes(bytes, flush: true);
      return await _withDatabase(path, action);
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响预览结果。
      }
    }
  }

  Future<T> _withDatabase<T>(
    String path,
    Future<T> Function(DatabaseExecutor db) action,
  ) async {
    final opener = openDatabase ?? _openReadOnly;
    final db = await opener(path);
    try {
      return await action(db);
    } finally {
      await db.close();
    }
  }

  static Future<Database> _openReadOnly(String path) async {
    ensureDesktopSqfliteFactory();
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
  }

  /// 把启用清单里的引用翻成名字：`preset::<key>` 查内置，其余查 Mod 库。
  Future<List<String>> _modNames(Iterable<String> refs) async {
    final names = <String>[];
    for (final ref in refs) {
      if (ref.isEmpty) continue;
      const presetPrefix = 'preset::';
      if (ref.startsWith(presetPrefix)) {
        final preset = PresetMods.byKey(ref.substring(presetPrefix.length));
        names.add(preset?.name ?? ref.substring(presetPrefix.length));
        continue;
      }
      try {
        final mod = await mods.get(ref);
        names.add(mod?.name ?? _shortUuid(ref));
      } catch (_) {
        names.add(_shortUuid(ref));
      }
    }
    return names;
  }

  static int _worldBookCountOf(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return 0;
    try {
      final decoded = jsonDecode(text);
      return decoded is List ? decoded.length : 0;
    } catch (_) {
      return 0;
    }
  }

  static String _textOf(Map<String, Object?> row, String column) =>
      (row[column] as String?) ?? '';

  static int _intOf(List<Map<String, Object?>> rows, String column) {
    if (rows.isEmpty) return 0;
    return (rows.first[column] as num?)?.toInt() ?? 0;
  }

  static String _shortUuid(String uuid) =>
      uuid.length <= 8 ? uuid : uuid.substring(0, 8);
}
