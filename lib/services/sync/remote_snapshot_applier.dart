import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../database/book_dao.dart';
import '../../database/database_helper.dart';
import '../../database/mod_dao.dart';
import '../../database/round_dao.dart';
import '../../database/world_book_dao.dart';
import '../../models/book.dart';
import '../../models/mod.dart';
import '../../models/round.dart';
import '../../models/world_book_entry.dart';
import 'sync_action_planner.dart';
import 'sync_merge_planner.dart';

/// 把远端快照里的书籍 / Mod 变更，按「三向部件级决策」落地到本地库。
///
/// 远端快照是与本机同 schema 的库副本（`buildSnapshotBytes` 输出）。本类把快照
/// 作为只读 SQLite 打开，按 [SyncMergePlan] + [SyncAction] 应用：
/// - 书籍：本地无此书 → 整本复制（远端 uuid 原样入库，身份自此一致）；本地已有
///   → 部件级就地合并（`remoteOnly` 的部件用远端内容替换，`unchanged` /
///   `localOnly` 保持本地）；
/// - Mod：按 uuid upsert（命中 → 远端内容整体覆盖含时间戳；未命中 → 直接插入
///   远端原始行）。
///
/// 身份规则：**只有 uuid**。两侧每一行都以同一主键对齐，写子表时直接落远端的
/// `book_uuid` / `mod_uuid`——不做标题/名称回退匹配，也不存在「采用远端身份」
/// 的迁移步骤（同一 uuid 无需迁移）。
class RemoteSnapshotApplier {
  const RemoteSnapshotApplier();

  /// 应用一次远端变更。仅处理 [action.pullBookUuids] / [action.pullModUuids]
  /// 中的项（非冲突部件）。
  Future<void> apply({
    required SyncMergePlan mergePlan,
    required SyncAction action,
    required Uint8List snapshotBytes,
  }) async {
    if (action.pullBookUuids.isEmpty && action.pullModUuids.isEmpty) return;
    final dir = await Directory.systemTemp.createTemp('narrchat_pull_');
    try {
      final remotePath = '${dir.path}/remote.db';
      await File(remotePath).writeAsBytes(snapshotBytes, flush: true);
      final remote = await databaseFactoryFfi.openDatabase(
        remotePath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        final localDb = await DatabaseHelper.instance.database;
        final bookDao = BookDao();
        final roundDao = RoundDao();
        final wbDao = WorldBookDao();
        final modDao = ModDao();
        for (final bookUuid in action.pullBookUuids) {
          final decision = _decisionFor(mergePlan, bookUuid);
          if (decision == null) continue;
          await _applyBook(
            remote,
            localDb,
            decision,
            bookDao,
            roundDao,
            wbDao,
            modDao,
          );
        }
        // 远端独有 / 远端更新的独立 Mod（未被任何书引用）。
        for (final modUuid in action.pullModUuids) {
          await _upsertRemoteMod(remote, localDb, modUuid);
        }
      } finally {
        await remote.close();
      }
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 忽略清理失败。
      }
    }
  }

  static BookSyncDecision? _decisionFor(
    SyncMergePlan plan,
    String remoteUuid,
  ) {
    for (final d in plan.books) {
      if (d.remoteUuid == remoteUuid) return d;
    }
    return null;
  }

  Future<void> _applyBook(
    Database remote,
    Database localDb,
    BookSyncDecision decision,
    BookDao bookDao,
    RoundDao roundDao,
    WorldBookDao wbDao,
    ModDao modDao,
  ) async {
    final uuid = decision.remoteUuid ?? '';
    final remoteRows = uuid.isEmpty
        ? const <Map<String, Object?>>[]
        : await remote.query(
            'books',
            where: 'uuid = ? AND deleted_at IS NULL',
            whereArgs: [uuid],
            limit: 1,
          );
    if (remoteRows.isEmpty) return;
    final remoteRow = remoteRows.first;

    final localRows = await localDb.query(
      'books',
      where: 'uuid = ? AND deleted_at IS NULL',
      whereArgs: [uuid],
      limit: 1,
    );

    if (localRows.isEmpty) {
      await _insertWholeBook(
        remote,
        localDb,
        uuid,
        remoteRow,
        bookDao,
        roundDao,
        wbDao,
        modDao,
      );
      return;
    }

    final replaceAll = decision.presence == SyncBookPresence.remoteOnly;
    if (replaceAll || decision.settings == SyncPartStatus.remoteOnly) {
      await _updateSettings(localDb, uuid, remoteRow);
    }
    if (replaceAll || decision.rounds == SyncPartStatus.remoteOnly) {
      await _replaceRounds(
        remote,
        uuid,
        roundDao,
        remoteRow['rounds_updated_at'] as int?,
      );
    }
    if (replaceAll || decision.worldBook == SyncPartStatus.remoteOnly) {
      await _replaceWorldBooks(remote, uuid, wbDao);
    }
    if (replaceAll || decision.bookMods == SyncPartStatus.remoteOnly) {
      await _applyBookMods(remote, localDb, uuid, modDao);
    }
  }

  /// 整本复制远端书（书 / 轮次 / 世界书 / 书-Mod / 引用到的用户 Mod）。
  Future<void> _insertWholeBook(
    Database remote,
    Database localDb,
    String uuid,
    Map<String, Object?> row,
    BookDao bookDao,
    RoundDao roundDao,
    WorldBookDao wbDao,
    ModDao modDao,
  ) async {
    // 远端 uuid 随 [Book.fromMap] 原样入库：insertBook 返回的就是这个 uuid。
    await bookDao.insertBook(Book.fromMap(row));
    // Book 模型不含失败条目 / 写时间戳列，此处按远端原值补写。
    await _updateSettings(localDb, uuid, row);
    await _writeFailed(uuid, await _remoteFailed(remote, uuid));

    final rounds = await remote.query(
      'rounds',
      where: 'book_uuid = ?',
      whereArgs: [uuid],
      orderBy: 'round_index ASC',
    );
    for (final r in rounds) {
      await roundDao.insertRound(Round.fromMap(r));
    }
    await _touchBookTimes(
      localDb,
      uuid,
      roundsUpdatedAt: row['rounds_updated_at'] as int?,
    );

    final wbs = await remote.query(
      'world_book_entries',
      where: 'book_uuid = ?',
      whereArgs: [uuid],
      orderBy: 'id ASC',
    );
    for (final w in wbs) {
      await wbDao.insertEntry(WorldBookEntry.fromMap(w));
    }

    await _applyBookMods(remote, localDb, uuid, modDao);
  }

  /// 「设置部件」列（按远端原值覆盖）。
  static const List<String> _settingsColumns = [
    'title',
    'category',
    'base_setting',
    'writing_requirements',
    'writing_style',
    'global_pre_prompt',
    'global_post_prompt',
    'history_rounds',
    'role_hierarchy',
    'role_hierarchy_detail',
  ];

  static const List<String> _optionalColumns = [
    'settings_updated_at',
    'rounds_updated_at',
  ];

  Future<void> _updateSettings(
    Database localDb,
    String bookUuid,
    Map<String, Object?> remoteRow,
  ) async {
    final patch = <String, Object?>{};
    for (final c in [..._settingsColumns, ..._optionalColumns]) {
      if (remoteRow.containsKey(c)) patch[c] = remoteRow[c];
    }
    if (patch.isEmpty) return;
    await localDb.update(
      'books',
      patch,
      where: 'uuid = ?',
      whereArgs: [bookUuid],
    );
  }

  /// 部件替换后把写时间戳对齐远端（替换本地轮次经删除/插入会重置为 now）。
  Future<void> _touchBookTimes(
    Database localDb,
    String bookUuid, {
    int? settingsUpdatedAt,
    int? roundsUpdatedAt,
  }) async {
    final patch = <String, Object?>{
      'settings_updated_at': settingsUpdatedAt,
      'rounds_updated_at': roundsUpdatedAt,
    }..removeWhere((_, v) => v == null);
    if (patch.isEmpty) return;
    await localDb.update(
      'books',
      patch,
      where: 'uuid = ?',
      whereArgs: [bookUuid],
    );
  }

  Future<void> _syncRoundsUpdatedAt(
    String bookUuid,
    int? roundsUpdatedAt,
  ) async {
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'books',
      {
        'rounds_updated_at':
            roundsUpdatedAt ?? DateTime.now().millisecondsSinceEpoch,
      },
      where: 'uuid = ?',
      whereArgs: [bookUuid],
    );
  }

  Future<void> _replaceRounds(
    Database remote,
    String bookUuid,
    RoundDao roundDao,
    int? roundsUpdatedAt,
  ) async {
    await roundDao.deleteRoundsByBook(bookUuid);
    final rounds = await remote.query(
      'rounds',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'round_index ASC',
    );
    for (final r in rounds) {
      // 远端行的 book_uuid 就是本地这本书的 uuid（同一主键），身份无需改写。
      await roundDao.insertRound(Round.fromMap(r));
    }
    await _syncRoundsUpdatedAt(bookUuid, roundsUpdatedAt);
    // 失败条目与轮次同生命周期：随轮次部件一并替换（books 上的失败列）。
    await _writeFailed(bookUuid, await _remoteFailed(remote, bookUuid));
  }

  /// 读取远端书的失败条目（books 列）。
  Future<({String userInput, String errorMessage, String userImages})>
      _remoteFailed(Database remote, String bookUuid) async {
    final rows = await remote.query(
      'books',
      columns: [
        'failed_user_input',
        'failed_error_message',
        'failed_user_images',
      ],
      where: 'uuid = ?',
      whereArgs: [bookUuid],
      limit: 1,
    );
    if (rows.isEmpty) {
      return (userInput: '', errorMessage: '', userImages: '[]');
    }
    final r = rows.first;
    return (
      userInput: (r['failed_user_input'] as String?) ?? '',
      errorMessage: (r['failed_error_message'] as String?) ?? '',
      userImages: (r['failed_user_images'] as String?) ?? '[]',
    );
  }

  /// 落地失败条目列。
  Future<void> _writeFailed(
    String bookUuid,
    ({String userInput, String errorMessage, String userImages}) values,
  ) async {
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'books',
      {
        'failed_user_input': values.userInput,
        'failed_error_message': values.errorMessage,
        'failed_user_images': values.userImages,
      },
      where: 'uuid = ?',
      whereArgs: [bookUuid],
    );
  }

  Future<void> _replaceWorldBooks(
    Database remote,
    String bookUuid,
    WorldBookDao wbDao,
  ) async {
    await wbDao.deleteEntriesByBook(bookUuid);
    final wbs = await remote.query(
      'world_book_entries',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'id ASC',
    );
    for (final w in wbs) {
      await wbDao.insertEntry(WorldBookEntry.fromMap(w));
    }
  }

  /// 用远端内容替换本地这本书的「书-Mod 部件」，并 upsert 其引用的用户 Mod。
  Future<void> _applyBookMods(
    Database remote,
    Database localDb,
    String bookUuid,
    ModDao modDao,
  ) async {
    final bms = await remote.query(
      'book_mods',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'sort_order ASC, id ASC',
    );
    final configs = <BookModConfig>[];
    for (final bm in bms) {
      final modUuid = bm['mod_uuid'] as String?;
      if (modUuid != null && modUuid.isNotEmpty) {
        await _upsertRemoteMod(remote, localDb, modUuid);
      }
      configs.add(
        BookModConfig(
          bookUuid: bookUuid,
          presetKey: bm['preset_key'] as String?,
          modUuid: modUuid,
          isEnabled: ((bm['is_enabled'] as int?) ?? 1) == 1,
          sortOrder: (bm['sort_order'] as int?) ?? 0,
        ),
      );
    }
    await modDao.replaceBookMods(bookUuid, configs);
  }

  /// 按 uuid 把一个远端 Mod 落到本地（upsert；身份只有 uuid）：
  /// - 本地已有同 uuid 行 → 用远端内容整体覆盖（含 `created_at` / `updated_at` /
  ///   `deleted_at`），保证本地指纹与远端一致，否则下轮同步会误判为「本地独有」
  ///   来回推送；
  /// - 未命中 → 直接插入远端原始行（uuid 即主键，原样保留）。
  Future<void> _upsertRemoteMod(
    Database remote,
    Database localDb,
    String modUuid,
  ) async {
    if (modUuid.isEmpty) return;
    final rows = await remote.query(
      'mods',
      where: 'uuid = ?',
      whereArgs: [modUuid],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final remoteRow = rows.first;
    final existing = await localDb.query(
      'mods',
      columns: ['uuid'],
      where: 'uuid = ?',
      whereArgs: [modUuid],
      limit: 1,
    );
    if (existing.isEmpty) {
      await localDb.insert('mods', remoteRow);
      return;
    }
    final content = Map<String, Object?>.from(remoteRow)..remove('uuid');
    await localDb.update(
      'mods',
      content,
      where: 'uuid = ?',
      whereArgs: [modUuid],
    );
  }
}
