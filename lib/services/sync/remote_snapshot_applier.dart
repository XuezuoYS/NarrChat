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
/// 远端快照是 `buildSnapshotBytes` 输出的本地库一致副本（同 schema）。本类把
/// 快照作为只读 SQLite 打开，按 [SyncMergePlan] + [SyncAction] 应用：
/// - 书籍：`remoteOnly`（本地不存在该书）整本复制；`both` 按部件状态就地合并到
///   本地同名书（settings / rounds / worldBook / bookMods 中 `remoteOnly` 的部件
///   用远端内容替换，`unchanged` / `localOnly` 保持本地）；
/// - 独立 Mod（未被任何书引用、仅 manifest 出现的 `pullModUuids`）：按 uuid（回退
///   名称）新增到本地（保留 `created_at` / `updated_at`），同名已存在则整体采用
///   远端内容（指纹与远端一致，避免 Mod 跨设备冲突）。
///
/// 身份规则：**uuid 优先**。决策携带远端 uuid（manifest format=1 的 legacy 键
/// `legacy:<name>` 按名称定位）；本地书先按 uuid 匹配，未命中再按 title 回退，
/// 回退命中时会**采用远端 uuid**（身份迁移，两侧此后以同一 uuid 对齐）。
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
        for (final pullUuid in action.pullBookUuids) {
          final decision = _decisionFor(mergePlan, pullUuid);
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
        for (final pullUuid in action.pullModUuids) {
          await _applyStandaloneMod(remote, localDb, pullUuid);
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

  static BookSyncDecision? _decisionFor(SyncMergePlan plan, String remoteUuid) {
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
    final rows = await _queryRemoteBook(remote, decision.remoteUuid ?? '', decision.title);
    if (rows.isEmpty) return;
    final remoteRow = rows.first;
    final remoteBookId = remoteRow['id'] as int?;
    if (remoteBookId == null) return;

    final localRows = await _queryLocalBook(localDb, decision.remoteUuid ?? '', decision.title);

    // 本地无此书 → 整本复制（含远程 uuid，身份自此一致）。
    if (localRows.isEmpty) {
      await _insertWholeBook(
        remote,
        localDb,
        remoteBookId,
        decision.title,
        bookDao,
        roundDao,
        wbDao,
        modDao,
      );
      return;
    }

    // 本地同名书存在 → 部件级就地合并：
    // - `remoteOnly`：整体采用远端（含身份迁移）；
    // - `both`：仅替换 remoteOnly 部件，unchanged / localOnly 部件保持本地。
    final replaceAll = decision.presence == SyncBookPresence.remoteOnly;
    final localBookId = localRows.first['id'] as int;
    if (replaceAll || decision.settings == SyncPartStatus.remoteOnly) {
      await _updateSettings(localDb, localBookId, remoteRow);
    }
    if (replaceAll || decision.rounds == SyncPartStatus.remoteOnly) {
      await _replaceRounds(
        remote,
        remoteBookId,
        localBookId,
        roundDao,
        remoteRow['rounds_updated_at'] as int?,
      );
    }
    if (replaceAll || decision.worldBook == SyncPartStatus.remoteOnly) {
      await _replaceWorldBooks(remote, remoteBookId, localBookId, wbDao);
    }
    if (replaceAll || decision.bookMods == SyncPartStatus.remoteOnly) {
      await _replaceBookMods(remote, remoteBookId, localBookId, modDao, localDb);
    }
    // 回退匹配（本地 uuid 与远端不同）→ 采用远端 uuid，两侧身份收敛。
    await _adoptRemoteIdentity(localDb, localBookId, remoteRow);
  }

  /// 按 uuid 查询远端书；legacy 键（uuid==""）按 title 回退。
  Future<List<Map<String, Object?>>> _queryRemoteBook(
    Database remote,
    String remoteUuid,
    String title,
  ) async {
    if (remoteUuid.isNotEmpty && !remoteUuid.startsWith('legacy:')) {
      final rows = await remote.query(
        'books',
        where: 'uuid = ? AND (deleted_at IS NULL)',
        whereArgs: [remoteUuid],
        limit: 1,
      );
      if (rows.isNotEmpty) return rows;
    }
    return remote.query(
      'books',
      where: 'title = ? AND (deleted_at IS NULL)',
      whereArgs: [title],
      orderBy: 'id ASC',
      limit: 1,
    );
  }

  /// 按 uuid 查询本地书；未命中按 title 回退（回退命中 → 身份迁移）。
  Future<List<Map<String, Object?>>> _queryLocalBook(
    Database localDb,
    String remoteUuid,
    String title,
  ) async {
    if (remoteUuid.isNotEmpty && !remoteUuid.startsWith('legacy:')) {
      final rows = await localDb.query(
        'books',
        where: 'uuid = ? AND (deleted_at IS NULL)',
        whereArgs: [remoteUuid],
        orderBy: 'id ASC',
        limit: 1,
      );
      if (rows.isNotEmpty) return rows;
    }
    return localDb.query(
      'books',
      where: 'title = ? AND (deleted_at IS NULL)',
      whereArgs: [title],
      orderBy: 'id ASC',
      limit: 1,
    );
  }

  /// 整本复制远端书（书/轮次/世界书/书-Mod/引用到的用户 Mod）。
  Future<void> _insertWholeBook(
    Database remote,
    Database localDb,
    int remoteBookId,
    String title,
    BookDao bookDao,
    RoundDao roundDao,
    WorldBookDao wbDao,
    ModDao modDao,
  ) async {
    final rows = await remote.query(
      'books',
      where: 'id = ?',
      whereArgs: [remoteBookId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;

    final localBookId = await bookDao.insertBook(Book.fromMap(row));
    // Book 模型不含失败条目/写时间戳列，此处补写（指纹以完整列为准）。
    await _updateSettings(localDb, localBookId, row);
    await _writeFailed(localBookId, (
      userInput: (row['failed_user_input'] as String?) ?? '',
      errorMessage: (row['failed_error_message'] as String?) ?? '',
      userImages: (row['failed_user_images'] as String?) ?? '[]',
    ));

    final rounds = await remote.query(
      'rounds',
      where: 'book_id = ?',
      whereArgs: [remoteBookId],
      orderBy: 'round_index ASC',
    );
    for (final r in rounds) {
      await roundDao.insertRound(Round.fromMap(r).copyWith(bookId: localBookId));
    }
    await _touchBookTimes(
      localDb,
      localBookId,
      roundsUpdatedAt: row['rounds_updated_at'] as int?,
    );

    final wbs = await remote.query(
      'world_book_entries',
      where: 'book_id = ?',
      whereArgs: [remoteBookId],
      orderBy: 'id ASC',
    );
    for (final w in wbs) {
      await wbDao.insertEntry(WorldBookEntry.fromMap(w).copyWith(bookId: localBookId));
    }

    await _applyBookMods(remote, remoteBookId, localBookId, modDao, localDb);
  }

  /// 用远端内容替换本地同名书的「设置部件」字段（含写时间戳；失败条目不在此列，
  /// 随轮次部件替换）。
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
    int localBookId,
    Map<String, Object?> remoteRow,
  ) async {
    final patch = <String, Object?>{};
    for (final c in [..._settingsColumns, ..._optionalColumns]) {
      if (remoteRow.containsKey(c)) patch[c] = remoteRow[c];
    }
    if (patch.isEmpty) return;
    await localDb.update('books', patch, where: 'id = ?', whereArgs: [localBookId]);
  }

  /// 回退匹配命中时把本地书的 uuid 收敛为远端 uuid（身份迁移）。
  Future<void> _adoptRemoteIdentity(
    Database localDb,
    int localBookId,
    Map<String, Object?> remoteRow,
  ) async {
    final remoteUuid = remoteRow['uuid'] as String? ?? '';
    if (remoteUuid.isEmpty) return;
    final localRows = await localDb.query(
      'books',
      columns: ['uuid'],
      where: 'id = ?',
      whereArgs: [localBookId],
      limit: 1,
    );
    if (localRows.isEmpty) return;
    final localUuid = localRows.first['uuid'] as String? ?? '';
    if (localUuid == remoteUuid) return;
    await localDb.update(
      'books',
      {'uuid': remoteUuid},
      where: 'id = ?',
      whereArgs: [localBookId],
    );
  }

  /// 把远端书的部件写时间戳写到本地书（供 base 元信息与合并建议对齐）。
  Future<void> _touchBookTimes(
    Database localDb,
    int localBookId, {
    int? settingsUpdatedAt,
    int? roundsUpdatedAt,
  }) async {
    final patch = <String, Object?>{
      'settings_updated_at': settingsUpdatedAt,
      'rounds_updated_at': roundsUpdatedAt,
    }..removeWhere((_, v) => v == null);
    if (patch.isEmpty) return;
    await localDb.update('books', patch, where: 'id = ?', whereArgs: [localBookId]);
  }

  /// 部件替换后把写时间戳对齐远端（替换本地轮次经删除/插入会重置为 now）。
  Future<void> _syncRoundsUpdatedAt(
    int localBookId,
    int? roundsUpdatedAt,
  ) async {
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'books',
      {
        'rounds_updated_at':
            roundsUpdatedAt ?? DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [localBookId],
    );
  }

  Future<void> _replaceRounds(
    Database remote,
    int remoteBookId,
    int localBookId,
    RoundDao roundDao,
    int? roundsUpdatedAt,
  ) async {
    await roundDao.deleteRoundsByBook(localBookId);
    final rounds = await remote.query(
      'rounds',
      where: 'book_id = ?',
      whereArgs: [remoteBookId],
      orderBy: 'round_index ASC',
    );
    for (final r in rounds) {
      await roundDao.insertRound(Round.fromMap(r).copyWith(bookId: localBookId));
    }
    await _syncRoundsUpdatedAt(localBookId, roundsUpdatedAt);
    // 失败条目与轮次同生命周期：随轮次部件一并替换（books 上的失败列）。
    await _writeFailed(
      localBookId,
      await _remoteFailed(remote, remoteBookId),
    );
  }

  /// 读取远端书的失败条目（books 列）。
  Future<({String userInput, String errorMessage, String userImages})>
      _remoteFailed(Database remote, int remoteBookId) async {
    final rows = await remote.query(
      'books',
      columns: ['failed_user_input', 'failed_error_message', 'failed_user_images'],
      where: 'id = ?',
      whereArgs: [remoteBookId],
      limit: 1,
    );
    if (rows.isEmpty) return (userInput: '', errorMessage: '', userImages: '[]');
    final r = rows.first;
    return (
      userInput: (r['failed_user_input'] as String?) ?? '',
      errorMessage: (r['failed_error_message'] as String?) ?? '',
      userImages: (r['failed_user_images'] as String?) ?? '[]',
    );
  }

  /// 落地失败条目列。
  Future<void> _writeFailed(
    int localBookId,
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
      where: 'id = ?',
      whereArgs: [localBookId],
    );
  }

  Future<void> _replaceWorldBooks(
    Database remote,
    int remoteBookId,
    int localBookId,
    WorldBookDao wbDao,
  ) async {
    await wbDao.deleteEntriesByBook(localBookId);
    final wbs = await remote.query(
      'world_book_entries',
      where: 'book_id = ?',
      whereArgs: [remoteBookId],
      orderBy: 'id ASC',
    );
    for (final w in wbs) {
      await wbDao.insertEntry(WorldBookEntry.fromMap(w).copyWith(bookId: localBookId));
    }
  }

  /// 用远端内容替换本地同名书的「书-Mod 部件」（按 uuid/名称复用用户 Mod）。
  Future<void> _replaceBookMods(
    Database remote,
    int remoteBookId,
    int localBookId,
    ModDao modDao,
    Database localDb,
  ) async {
    await _applyBookMods(remote, remoteBookId, localBookId, modDao, localDb);
  }

  Future<void> _applyBookMods(
    Database remote,
    int remoteBookId,
    int localBookId,
    ModDao modDao,
    Database localDb,
  ) async {
    final bms = await remote.query(
      'book_mods',
      where: 'book_id = ?',
      whereArgs: [remoteBookId],
      orderBy: 'sort_order ASC, id ASC',
    );
    final configs = <BookModConfig>[];
    for (final bm in bms) {
      final presetKey = bm['preset_key'] as String?;
      final remoteModId = bm['mod_id'] as int?;
      int? localModId;
      if (remoteModId != null) {
        localModId = await _findOrCopyMod(remote, remoteModId, localDb);
      }
      configs.add(
        BookModConfig(
          bookId: localBookId,
          presetKey: presetKey,
          modId: localModId,
          isEnabled: ((bm['is_enabled'] as int?) ?? 1) == 1,
          sortOrder: (bm['sort_order'] as int?) ?? 0,
        ),
      );
    }
    await modDao.replaceBookMods(localBookId, configs);
  }

  /// 把远端某用户 Mod 落到本地：按 uuid 优先复用已有 Mod（跨设备身份稳定），
  /// 未命中按名称复用（首连/旧清单回退），仍未命中则按远端原始行复制
  /// （保留 `created_at` / `updated_at`，避免 fp 漂移）。
  Future<int?> _findOrCopyMod(
    Database remote,
    int remoteModId,
    Database localDb,
  ) async {
    final rows = await remote.query(
      'mods',
      where: 'id = ?',
      whereArgs: [remoteModId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final uuid = (row['uuid'] as String? ?? '').trim();
    final name = (row['name'] as String? ?? '').trim();
    if (uuid.isNotEmpty) {
      final existing = await localDb.query(
        'mods',
        where: 'TRIM(uuid) = ? AND deleted_at IS NULL',
        whereArgs: [uuid],
        limit: 1,
      );
      if (existing.isNotEmpty) return existing.first['id'] as int;
    }
    if (name.isNotEmpty) {
      final existing = await localDb.query(
        'mods',
        where: 'TRIM(name) = ? AND deleted_at IS NULL',
        whereArgs: [name],
        limit: 1,
      );
      if (existing.isNotEmpty) return existing.first['id'] as int;
    }
    final map = Map<String, Object?>.from(row)..remove('id');
    return localDb.insert('mods', map);
  }

  /// 应用一个「独立 Mod」的远端变更（未被任何书引用，仅 manifest 记录）。
  ///
  /// - 本地没有该 uuid（回退：名称）的 Mod → 按远端原始行新增（保留时间戳）；
  /// - 本地已有同 uuid Mod（远端更新了内容）→ 整体采用远端内容（含时间戳），
  ///   保证本地指纹与远端一致（否则下轮同步会误判为「本地独有」来回推送）。
  Future<void> _applyStandaloneMod(
    Database remote,
    Database localDb,
    String pullUuid,
  ) async {
    final List<Map<String, Object?>> rows;
    if (pullUuid.startsWith('legacy:')) {
      final nameOf = pullUuid.substring('legacy:'.length);
      rows = await remote.query(
        'mods',
        where: 'TRIM(name) = ? AND deleted_at IS NULL',
        whereArgs: [nameOf],
        limit: 1,
      );
    } else {
      rows = await remote.query(
        'mods',
        where: 'uuid = ? AND deleted_at IS NULL',
        whereArgs: [pullUuid],
        limit: 1,
      );
    }
    if (rows.isEmpty) return;
    final remoteRow = rows.first;
    final remoteUuid = (remoteRow['uuid'] as String? ?? '').trim();
    final remoteName = (remoteRow['name'] as String? ?? '').trim();
    final content = Map<String, Object?>.from(remoteRow)..remove('id');

    List<Map<String, Object?>> existing = const [];
    if (remoteUuid.isNotEmpty) {
      existing = await localDb.query(
        'mods',
        where: 'TRIM(uuid) = ? AND deleted_at IS NULL',
        whereArgs: [remoteUuid],
        limit: 1,
      );
    }
    if (existing.isEmpty && remoteName.isNotEmpty) {
      existing = await localDb.query(
        'mods',
        where: 'TRIM(name) = ? AND deleted_at IS NULL',
        whereArgs: [remoteName],
        limit: 1,
      );
    }
    if (existing.isEmpty) {
      await localDb.insert('mods', content);
      return;
    }
    final localId = existing.first['id'] as int;
    await localDb.update('mods', content, where: 'id = ?', whereArgs: [localId]);
  }
}
