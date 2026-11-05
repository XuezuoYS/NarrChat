import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/book_meta.dart';
import '../../models/mod.dart';
import '../../models/round_generation.dart';
import '../../models/world_book_row.dart';
import '../../services/branch_rules.dart';
import '../../services/round_tree.dart';
import '../../utils/timestamp_format.dart';
import '../../utils/uuid_utils.dart';
import '../book_db.dart';
import '../book_store.dart';
import '../cache_store.dart';
import '../database_helper.dart';
import '../db_open.dart';
import '../library_store.dart';
import '../sqflite_desktop.dart';
import '../mods_store.dart';
import 'migration_paths.dart';
import 'migration_state.dart';

/// 一次迁移的结果。
class MigrationReport {
  const MigrationReport({
    this.alreadyDone = false,
    this.freshInstall = false,
    this.migratedBooks = 0,
    this.skippedBooks = 0,
    this.failedBooks = const {},
    this.masterUuid = '',
  });

  /// 之前已经迁移完成，本次什么都没做。
  final bool alreadyDone;

  /// 没有旧库（全新安装 / 已被清理），只写了完成标记。
  final bool freshInstall;

  final int migratedBooks;
  final int skippedBooks;

  /// 迁移失败的书 uuid → 原因。用户可以重试。
  final Map<String, String> failedBooks;

  final String masterUuid;

  bool get hasFailures => failedBooks.isNotEmpty;
}

/// R2（单库 `narrchat.db`）→ R3（library + mods + 每书一库 + 缓存库）迁移。
///
/// 设计要点：
/// - **幂等**：进度写 `migration_state.json`，每成功一本就落盘；重跑时已迁移的书跳过。
/// - **可中断**：任何时刻杀掉进程都不会留下"半个状态"——状态文件原子写，
///   书库先写临时名再改名（见 [BookDb.create]：同路径重建）。
/// - **不毁旧数据**：旧库原件改名成 `narrchat.db.r2.bak` 留着，迁移只读它。
/// - **单本失败不影响其它书**：失败记账，其余继续，结束时统一提示。
///
/// 内容基准取 R2 的 `rounds`（读权威），身份（uuid / 父代 / 序号 / 提示）取
/// `round_stack`；对不上的重建一代，保证迁移后的树是完整可走的。
class R2ToR3Migrator {
  R2ToR3Migrator({required this.paths, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final MigrationPaths paths;

  /// 注入时钟，测试里固定时间好断言。
  final DateTime Function() _clock;

  DateTime get _now => _clock().toUtc();

  /// 执行迁移（或续跑）。
  Future<MigrationReport> run() async {
    ensureDesktopSqfliteFactory();

    final stateFile = File(paths.statePath);
    final existing = await MigrationState.read(stateFile);
    if (existing != null && existing.done) {
      return MigrationReport(alreadyDone: true, masterUuid: existing.masterUuid);
    }
    var state = existing ?? const MigrationState();

    final source = await _resolveLegacySource();
    if (source == null) {
      // 全新安装，或旧库已经被清理过：各库首次打开时自建，这里只落完成标记。
      state = state.copyWith(done: true, updatedAt: nowTimestamp());
      await MigrationState.write(stateFile, state);
      return MigrationReport(freshInstall: true, masterUuid: state.masterUuid);
    }

    final masterUuid =
        state.masterUuid.isEmpty ? UuidUtils.generateUuidV4() : state.masterUuid;
    state = state.copyWith(masterUuid: masterUuid, updatedAt: nowTimestamp());
    await MigrationState.write(stateFile, state);

    Database? legacy;
    LibraryDb? library;
    ModsDb? mods;
    CacheDb? cache;
    try {
      legacy = await _openLegacy(source);

      library = LibraryDb(
        pathOverride: paths.libraryDbPath,
        masterUuidOverride: masterUuid,
      );
      await library.masterUuid();
      await _migrateLibrary(legacy, library);

      mods = ModsDb(
        pathOverride: paths.modsDbPath,
        masterUuidOverride: masterUuid,
      );
      await mods.putMasterUuid(masterUuid);
      await _migrateMods(legacy, mods);

      cache = CacheDb(pathOverride: paths.cacheDbPath);
      await cache.allIndex();

      final bookRows = await legacy.query('books', orderBy: 'uuid ASC');
      final failed = Map<String, String>.from(state.failedBooks);
      var migrated = 0;
      var skipped = 0;

      for (final row in bookRows) {
        final bookUuid = _str(row['uuid']);
        if (bookUuid.isEmpty) continue;
        try {
          final dbFile = File(paths.bookDbPath(bookUuid));
          if (state.migratedBooks.contains(bookUuid) && await dbFile.exists()) {
            skipped++;
            continue;
          }
          await _migrateBook(legacy, row, masterUuid);
          failed.remove(bookUuid);
          state = state.copyWith(
            migratedBooks: {...state.migratedBooks, bookUuid},
            failedBooks: Map<String, String>.from(failed),
            updatedAt: nowTimestamp(),
          );
          migrated++;
        } catch (error) {
          failed[bookUuid] = error.toString();
          state = state.copyWith(
            failedBooks: Map<String, String>.from(failed),
            updatedAt: nowTimestamp(),
          );
        }
        await MigrationState.write(stateFile, state);
      }

      await _rebuildCache(legacy, cache, bookRows);

      // R2 的本地同步库格式完全不同（三向部件共基），新格式下无意义，直接丢弃。
      final oldSync = File(paths.legacySyncDbPath);
      if (await oldSync.exists()) {
        try {
          await oldSync.delete();
        } catch (_) {
          // 删不掉也不影响迁移结论。
        }
      }

      state = state.copyWith(
        done: true,
        failedBooks: Map<String, String>.from(failed),
        updatedAt: nowTimestamp(),
      );
      await MigrationState.write(stateFile, state);

      return MigrationReport(
        migratedBooks: migrated,
        skippedBooks: skipped,
        failedBooks: failed,
        masterUuid: masterUuid,
      );
    } finally {
      await legacy?.close();
      await library?.close();
      await mods?.close();
      await cache?.close();
    }
  }

  // ---------------------------------------------------------------------------
  // 旧库定位与打开
  // ---------------------------------------------------------------------------

  /// 找到要迁移的旧库，并按文档规定的改名规则整理文件。
  ///
  /// | 情况 | 处理 |
  /// | --- | --- |
  /// | 有 `narrchat.db`、无 `.r2.bak` | 改名成 `.r2.bak` |
  /// | 两者都有 | `narrchat.db` 是降级期间旧版本写的 → 改名 `after-downgrade.bak` |
  /// | 只有 `.r2.bak` | 直接用它（上次中断） |
  Future<File?> _resolveLegacySource() async {
    final legacy = File(paths.legacyDbPath);
    final backup = File(paths.backupPath);

    if (await legacy.exists()) {
      if (await backup.exists()) {
        await legacy.rename(await _uniquePath(paths.downgradePath));
      } else {
        await legacy.rename(paths.backupPath);
      }
    }

    final source = File(paths.backupPath);
    return await source.exists() ? source : null;
  }

  /// 目标已存在时依次尝试 `-2` `-3`…… 不覆盖任何已有文件。
  Future<String> _uniquePath(String path) async {
    if (!await File(path).exists()) return path;
    for (var i = 2; i < 1000; i++) {
      final candidate = '$path.$i';
      if (!await File(candidate).exists()) return candidate;
    }
    return '$path.${_now.millisecondsSinceEpoch}';
  }

  /// 打开旧库，必要时跑 R2 的迁移链补到 v21。
  Future<Database> _openLegacy(File source) async {
    final version = await _peekUserVersion(source.path);
    if (version > DatabaseHelper.currentDbVersion) {
      throw StateError(
        '旧库版本 $version 高于本版本能处理的 ${DatabaseHelper.currentDbVersion}，已拒绝迁移',
      );
    }
    return DatabaseHelper.openAt(source.path);
  }

  /// 先读 `user_version` 再决定是否打开：避免 sqflite 对"更高版本"静默降级。
  Future<int> _peekUserVersion(String path) async {
    final db = await databaseFactory.openDatabase(path);
    try {
      return await readUserVersion(db);
    } finally {
      await db.close();
    }
  }

  // ---------------------------------------------------------------------------
  // 目录库 / Mod 库
  // ---------------------------------------------------------------------------

  Future<void> _migrateLibrary(Database legacy, LibraryDb library) async {
    final rows = await legacy.query('books', orderBy: 'uuid ASC');
    for (final row in rows) {
      final bookUuid = _str(row['uuid']);
      if (bookUuid.isEmpty) continue;
      await library.putBook(LibraryBookRow(
        bookUuid: bookUuid,
        title: _str(row['title']),
        deletedAt: _dateTime(row['deleted_at']),
      ));
    }
  }

  Future<void> _migrateMods(Database legacy, ModsDb mods) async {
    final rows = await legacy.query('mods', orderBy: 'uuid ASC');
    for (final row in rows) {
      final uuid = _str(row['uuid']);
      if (uuid.isEmpty) continue;
      await mods.upsert(Mod(
        uuid: uuid,
        name: _str(row['name']),
        description: _str(row['description']),
        prePrompt: _str(row['pre_prompt']),
        postPrompt: _str(row['post_prompt']),
        systemPrompt: _str(row['system_prompt']),
        worldBookEntries: ModWorldBookEntry.decodeList(
          row['world_book'] as String?,
        ),
        createdAt: _dateTimeFromIso(row['created_at']),
        updatedAt: _dateTimeFromIso(row['updated_at']) ?? _now,
      ));
      final deletedAt = _dateTime(row['deleted_at']);
      if (deletedAt != null) {
        await mods.setDeletedAt(uuid, deletedAt);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 单本书
  // ---------------------------------------------------------------------------

  Future<void> _migrateBook(
    Database legacy,
    Map<String, Object?> bookRow,
    String masterUuid,
  ) async {
    final bookUuid = _str(bookRow['uuid']);

    final worldBookRows = await legacy.query(
      'world_book_entries',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'id ASC',
    );
    final modRows = await legacy.query(
      'book_mods',
      where: 'book_uuid = ? AND is_enabled = 1',
      whereArgs: [bookUuid],
      orderBy: 'sort_order ASC, id ASC',
    );
    final roundRows = await legacy.query(
      'rounds',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'round_index ASC, id ASC',
    );
    final stackRows = await legacy.query(
      'round_stack',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'round_index ASC, round_serial_num ASC',
    );

    final generations = buildGenerationsFromLegacy(
      bookUuid: bookUuid,
      roundRows: roundRows,
      stackRows: stackRows,
      bookRow: bookRow,
      now: _now,
    );

    final createdAt = _bookCreatedAt(roundRows, bookRow) ?? _now;
    final meta = BookMeta(
      bookUuid: bookUuid,
      masterUuid: masterUuid,
      title: _str(bookRow['title']),
      category: _str(bookRow['category']),
      createdAt: createdAt,
      updatedAt: _now,
      baseSetting: _str(bookRow['base_setting']),
      writingRequirements: _str(bookRow['writing_requirements']),
      writingStyle: _str(bookRow['writing_style']),
      globalPrePrompt: _str(bookRow['global_pre_prompt']),
      globalPostPrompt: _str(bookRow['global_post_prompt']),
      historyRounds: _int(bookRow['history_rounds']) ?? 1,
      memorySummaryRounds: _int(bookRow['memory_summary_rounds']) ?? 0,
      roleHierarchy: _str(bookRow['role_hierarchy']),
      roleHierarchyDetail: _str(bookRow['role_hierarchy_detail']),
    );

    final book = await BookDb.create(
      meta: meta,
      pathOverride: paths.bookDbPath(bookUuid),
    );
    try {
      await book.worldBook.replaceAll([
        for (final row in worldBookRows)
          WorldBookRow(
            uuid: UuidUtils.deterministicUuidV5(
              '$bookUuid:world_book_entries:${_int(row['id']) ?? 0}',
            ),
            keyword: _str(row['keyword']),
            content: _str(row['content']),
            isUsing: (_int(row['is_active']) ?? 1) != 0,
            createdAt: _dateTimeFromIso(row['created_at']) ?? _now,
            updatedAt: _dateTime(row['updated_at']) ?? _now,
          ),
      ]);
      await book.useMods.replaceAll(_legacyUseMods(modRows));
      await book.rounds.importAll(generations);

      // 自愈：同组多个 is_using（旧库脏数据 / 合成代撞车）只留一个。
      final metas = await book.rounds.listMeta();
      for (final conflict in RoundTree.usingConflicts(metas)) {
        for (final extra in conflict.skip(1)) {
          await book.rounds.setUsing(extra.uuid, isUsing: false);
        }
      }
      final orphans = BranchRules.planPurgeOrphans(metas);
      if (orphans.isNotEmpty) {
        await book.rounds.delete(orphans);
      }
    } finally {
      await book.close();
    }
  }

  /// 书籍创建时间：R2 的 `books` 没有这一列，用最早一轮的时间兜底。
  DateTime? _bookCreatedAt(
    List<Map<String, Object?>> roundRows,
    Map<String, Object?> bookRow,
  ) {
    DateTime? earliest;
    for (final row in roundRows) {
      final time = _dateTimeFromIso(row['created_at']);
      if (time == null) continue;
      if (earliest == null || time.isBefore(earliest)) earliest = time;
    }
    if (earliest != null) return earliest;
    final settingsAt = _dateTime(bookRow['settings_updated_at']);
    if (settingsAt != null) return settingsAt;
    return null;
  }

  /// `book_mods` → `use_mods`：只留已启用的，预置 Mod 统一成 `preset::<id>`。
  List<UseModRow> _legacyUseMods(List<Map<String, Object?>> rows) {
    final result = <UseModRow>[];
    final seen = <String>{};
    var order = 0;
    for (final row in rows) {
      final modUuid = _str(row['mod_uuid']);
      final presetKey = _str(row['preset_key']);
      final key = modUuid.isNotEmpty
          ? modUuid
          : (presetKey.isNotEmpty ? 'preset::$presetKey' : '');
      if (key.isEmpty || !seen.add(key)) continue;
      result.add(UseModRow(modUuid: key, sortOrder: order));
      order++;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 缓存库
  // ---------------------------------------------------------------------------

  Future<void> _rebuildCache(
    Database legacy,
    CacheDb cache,
    List<Map<String, Object?>> bookRows,
  ) async {
    final indexRows = <BookIndexRow>[];
    for (final row in bookRows) {
      final bookUuid = _str(row['uuid']);
      if (bookUuid.isEmpty) continue;

      DateTime? firstRoundAt;
      DateTime? lastRoundAt;
      final times = await legacy.query(
        'rounds',
        columns: const ['created_at'],
        where: 'book_uuid = ? AND created_at IS NOT NULL',
        whereArgs: [bookUuid],
      );
      for (final timeRow in times) {
        final time = _dateTimeFromIso(timeRow['created_at']);
        if (time == null) continue;
        if (firstRoundAt == null || time.isBefore(firstRoundAt)) {
          firstRoundAt = time;
        }
        if (lastRoundAt == null || time.isAfter(lastRoundAt)) {
          lastRoundAt = time;
        }
      }

      // uuid 非法（迁移已记为失败）时没有对应的书库文件，缓存行照样建，
      // 只是 mtime 记 0 —— 让用户还能在列表里看到它并处理。
      String? bookPath;
      try {
        bookPath = paths.bookDbPath(bookUuid);
      } catch (_) {
        bookPath = null;
      }
      final file = bookPath == null ? null : File(bookPath);
      final mtime = (file != null && await file.exists())
          ? (await file.stat()).modified
          : null;
      indexRows.add(BookIndexRow(
        bookUuid: bookUuid,
        title: _str(row['title']),
        category: _str(row['category']),
        createdAt: firstRoundAt ?? _dateTime(row['settings_updated_at']),
        updatedAt: _now,
        lastRoundAt: lastRoundAt,
        deletedAt: _dateTime(row['deleted_at']),
        dbMtimeMs: mtime?.millisecondsSinceEpoch ?? 0,
      ));

      await cache.replaceImageRefs(bookUuid, await _imageRefs(legacy, bookUuid));
    }
    await cache.replaceAllIndex(indexRows);
  }

  /// 一本书的图片引用统计。
  ///
  /// 当前代同时存在于 `rounds`（读权威）与 `round_stack`（版本树），两边都数会翻倍。
  /// 因此按「`rounds` 的全部行 + `round_stack` 里没被 `rounds` 锚定的行」统计：
  /// 既不会重复计数，也不会因为某一边内容为空而漏掉。
  Future<List<ImageRefRow>> _imageRefs(Database legacy, String bookUuid) async {
    final counts = <String, int>{};
    final rows = <Map<String, Object?>>[
      ...await legacy.rawQuery(
        'SELECT user_images, ai_images FROM rounds WHERE book_uuid = ?',
        [bookUuid],
      ),
      ...await legacy.rawQuery(
        'SELECT user_images, ai_images FROM round_stack WHERE book_uuid = ? '
        'AND uuid NOT IN ('
        '  SELECT use_stack_uuid FROM rounds '
        "  WHERE book_uuid = ? AND use_stack_uuid IS NOT NULL AND use_stack_uuid <> ''"
        ')',
        [bookUuid, bookUuid],
      ),
    ];
    for (final row in rows) {
      final paths = <String>[
        ...decodeImageList(row['user_images']),
        ...decodeImageList(row['ai_images']),
      ];
      for (final path in paths) {
        counts[path] = (counts[path] ?? 0) + 1;
      }
    }
    return [
      for (final entry in counts.entries)
        ImageRefRow(
          imagePath: entry.key,
          bookUuid: bookUuid,
          refCount: entry.value,
        ),
    ];
  }
}

// -----------------------------------------------------------------------------
// 旧库行 → 代（纯函数，便于单测）
// -----------------------------------------------------------------------------

/// 把 R2 的 `rounds`（读权威）+ `round_stack`（版本树）合成 R3 的代数列表。
///
/// 规则：
/// 1. 每一行 `rounds` 产出一代 `is_using = true`，内容是 `rounds` 的（读权威）；
///    身份（uuid / 父代 / 序号 / 提示）取它锚定的 stack 行。
/// 2. 锚点缺失或悬空 → 合成一代，父代接上一轮，序号取组内最大 +1。
/// 3. 未被任何 `rounds` 行锚定的 stack 行也照样迁过来（`is_using = false`），
///    版本历史不能丢。
/// 4. `round_state = 'failed'` 的占位代 → `message_status = 'error'` 的正常代；
///    用户输入与图片从 `books.failed_*` 补回（占位代内容列本来就是空的）。
/// 5. 只剩 `books.failed_*` 没有占位代时，补一代 error，轮号 = 最后一轮 +1。
///
/// 结果按轮号、序号排序，调用方直接整批写入。
List<RoundGeneration> buildGenerationsFromLegacy({
  required String bookUuid,
  required List<Map<String, Object?>> roundRows,
  required List<Map<String, Object?>> stackRows,
  required Map<String, Object?> bookRow,
  required DateTime now,
}) {
  final stackByUuid = <String, Map<String, Object?>>{};
  for (final row in stackRows) {
    final uuid = _str(row['uuid']);
    if (uuid.isNotEmpty) stackByUuid[uuid] = row;
  }

  final roundsIndexes = <int>{
    for (final row in roundRows) _int(row['round_index']) ?? 0,
  };

  final maxSerial = <String, int>{};
  String groupKey(int roundIndex, String? father) =>
      '$roundIndex\u0000${father ?? ''}';
  for (final row in stackRows) {
    final key = groupKey(
      _int(row['round_index']) ?? 0,
      _father(row['father_uuid']),
    );
    final serial = _int(row['round_serial_num']) ?? 0;
    if (serial > (maxSerial[key] ?? 0)) maxSerial[key] = serial;
  }

  final produced = <String>{};
  final result = <RoundGeneration>[];
  String? previousChosen;

  // 1) 正常轮次
  for (final row in roundRows) {
    final roundIndex = _int(row['round_index']) ?? 0;
    final anchor = _str(row['use_stack_uuid']);
    final anchorRow = stackByUuid[anchor];
    final anchorUsable = anchorRow != null &&
        _str(anchorRow['round_state']) != 'failed' &&
        !produced.contains(anchor);

    String uuid;
    String? father;
    int serial;
    DateTime operatedAt;
    String message = '';
    String messageStatus = '';

    if (anchorUsable) {
      uuid = anchor;
      father = _father(anchorRow['father_uuid']);
      serial = _int(anchorRow['round_serial_num']) ?? 1;
      operatedAt = _stackTime(anchorRow, row, now);
      message = _str(anchorRow['message']);
      messageStatus = _str(anchorRow['message_status']);
    } else {
      father = previousChosen;
      final key = groupKey(roundIndex, father);
      serial = (maxSerial[key] ?? 0) + 1;
      maxSerial[key] = serial;
      uuid = UuidUtils.deterministicUuidV5(
        '$bookUuid:round:$roundIndex:$serial',
      );
      operatedAt = _dateTimeFromIso(row['created_at']) ?? now;
    }

    produced.add(uuid);
    previousChosen = uuid;
    result.add(_fromRoundRow(
      row: row,
      uuid: uuid,
      father: father,
      roundIndex: roundIndex,
      serial: serial,
      operatedAt: operatedAt,
      message: message,
      messageStatus: messageStatus,
    ));
  }

  // 2) 未被锚定的历史代
  for (final row in stackRows) {
    final uuid = _str(row['uuid']);
    if (uuid.isEmpty || produced.contains(uuid)) continue;
    if (_str(row['round_state']) == 'failed') continue;
    produced.add(uuid);
    result.add(_fromStackRow(row: row, now: now, using: false));
  }

  // 3) 失败占位代 → error 代（只在其轮号没有正常轮次时保留）
  final failedInput = _str(bookRow['failed_user_input']);
  final failedImages = _str(bookRow['failed_user_images']);
  final failedMessage = _str(bookRow['failed_error_message']);
  Map<String, Object?>? lastFailedRow;
  for (final row in stackRows) {
    if (_str(row['round_state']) != 'failed') continue;
    final roundIndex = _int(row['round_index']) ?? 0;
    if (roundsIndexes.contains(roundIndex)) continue;
    final uuid = _str(row['uuid']);
    if (uuid.isEmpty || produced.contains(uuid)) continue;
    produced.add(uuid);
    lastFailedRow = row;
    result.add(_fromStackRow(
      row: row,
      now: now,
      using: true,
      forceStatus: RoundMessageStatus.error,
      fallbackMessage: '已中断',
    ));
  }

  // 4) 只有 books.failed_* 的失败（老库 / 尚未写占位代）
  if (lastFailedRow != null) {
    // 占位代内容列是空的：把用户输入与图片补回来（只补最近一次失败）。
    if (failedInput.isNotEmpty) {
      final targetUuid = _str(lastFailedRow['uuid']);
      final index = result.indexWhere((g) => g.uuid == targetUuid);
      if (index >= 0) {
        result[index] = result[index].copyWith(
          userInput: failedInput,
          userImages: decodeImageList(failedImages),
          meta: result[index].meta.copyWith(
            message: result[index].meta.message.isEmpty
                ? (failedMessage.isEmpty ? '已中断' : failedMessage)
                : result[index].meta.message,
          ),
        );
      }
    }
  } else if (failedInput.isNotEmpty || failedMessage.isNotEmpty) {
    var maxIndex = 0;
    for (final gen in result) {
      if (gen.roundIndex > maxIndex) maxIndex = gen.roundIndex;
    }
    final roundIndex = maxIndex + 1;
    final uuid = UuidUtils.deterministicUuidV5('$bookUuid:failed');
    if (produced.add(uuid)) {
      result.add(RoundGeneration(
        meta: RoundMeta(
          uuid: uuid,
          fatherUuid: previousChosen,
          roundIndex: roundIndex,
          roundSerialNum: 1,
          isUsing: true,
          operatedAt: now,
          messageStatus: RoundMessageStatus.error,
          message: failedMessage.isEmpty ? '已中断' : failedMessage,
          hasImages: failedImages.isNotEmpty && failedImages != '[]',
        ),
        userInput: failedInput,
        userImages: decodeImageList(failedImages),
      ));
    }
  }

  result.sort((a, b) {
    final byIndex = a.roundIndex.compareTo(b.roundIndex);
    if (byIndex != 0) return byIndex;
    final bySerial = a.roundSerialNum.compareTo(b.roundSerialNum);
    if (bySerial != 0) return bySerial;
    return a.uuid.compareTo(b.uuid);
  });
  return result;
}

RoundGeneration _fromRoundRow({
  required Map<String, Object?> row,
  required String uuid,
  required String? father,
  required int roundIndex,
  required int serial,
  required DateTime operatedAt,
  required String message,
  required String messageStatus,
}) {
  return RoundGeneration(
    meta: RoundMeta(
      uuid: uuid,
      fatherUuid: father,
      roundIndex: roundIndex,
      roundSerialNum: serial,
      isUsing: true,
      operatedAt: operatedAt,
      messageStatus: messageStatus,
      message: message,
    ),
    modelName: _str(row['model_name']),
    tokensIn: _int(row['tokens_in']),
    tokensCachedIn: _int(row['cached_tokens_in']),
    tokensOut: _int(row['tokens_out']),
    userInput: _str(row['user_input']),
    aiNarrative: _str(row['ai_narrative']),
    worldState: _str(row['world_state']),
    characterState: _str(row['character_state']),
    memorySummary: _str(row['memory_summary']),
    currentTime: _str(row['current_time']),
    recommendedAction: _str(row['recommended_action']),
    userImages: decodeImageList(row['user_images']),
    aiImages: decodeImageList(row['ai_images']),
  );
}

RoundGeneration _fromStackRow({
  required Map<String, Object?> row,
  required DateTime now,
  required bool using,
  String? forceStatus,
  String fallbackMessage = '',
}) {
  var message = _str(row['message']);
  if (message.isEmpty && fallbackMessage.isNotEmpty) message = fallbackMessage;
  final status = forceStatus ?? _str(row['message_status']);
  return RoundGeneration(
    meta: RoundMeta(
      uuid: _str(row['uuid']),
      fatherUuid: _father(row['father_uuid']),
      roundIndex: _int(row['round_index']) ?? 0,
      roundSerialNum: _int(row['round_serial_num']) ?? 1,
      isUsing: using,
      operatedAt: _millisToDateTime(_int(row['round_created_at'])) ?? now,
      messageStatus: status,
      message: message,
    ),
    modelName: _str(row['model_name']),
    tokensIn: _int(row['tokens_in']),
    tokensCachedIn: _int(row['cached_tokens_in']),
    tokensOut: _int(row['tokens_out']),
    userInput: _str(row['user_input']),
    aiNarrative: _str(row['ai_narrative']),
    worldState: _str(row['world_state']),
    characterState: _str(row['character_state']),
    memorySummary: _str(row['memory_summary']),
    currentTime: _str(row['current_time']),
    recommendedAction: _str(row['recommended_action']),
    userImages: decodeImageList(row['user_images']),
    aiImages: decodeImageList(row['ai_images']),
  );
}

DateTime _stackTime(
  Map<String, Object?> stackRow,
  Map<String, Object?> roundRow,
  DateTime now,
) {
  final ms = _int(stackRow['round_created_at']);
  final fromMillis = ms == null ? null : _millisToDateTime(ms);
  if (fromMillis != null) return fromMillis;
  return _dateTimeFromIso(roundRow['created_at']) ?? now;
}

// -----------------------------------------------------------------------------
// 行取值小工具（旧库列类型不统一，统一在这里收敛）
// -----------------------------------------------------------------------------

String _str(Object? value) => value is String ? value : '';

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _father(Object? value) {
  final text = _str(value);
  return text.isEmpty ? null : text;
}

/// epoch 毫秒（R2 的时间戳列）→ DateTime。
DateTime? _millisToDateTime(int? value) {
  if (value == null || value <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}

/// R2 里可能是 epoch 毫秒（`deleted_at` / `*_updated_at`）也可能是 ISO 文本。
DateTime? _dateTime(Object? value) {
  if (value is int) return _millisToDateTime(value);
  if (value is String) {
    return _dateTimeFromIso(value) ?? _millisToDateTime(int.tryParse(value));
  }
  return null;
}

DateTime? _dateTimeFromIso(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}
