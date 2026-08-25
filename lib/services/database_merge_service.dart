import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';
import '../models/book.dart';
import '../models/round.dart';

/// 合并结果统计。
class DatabaseMergeResult {
  int booksAdded = 0;
  int modsAdded = 0;
  int roundsAdded = 0;
  int worldBookAdded = 0;
  int bookModsAdded = 0;

  /// 冲突书「保留导入侧」导致的整本替换（删除本地同名书并写入导入侧副本）。
  int booksReplaced = 0;

  /// 因用户选择或既有状态而跳过的书籍数（保留本地/取消导入）。
  int booksSkipped = 0;

  bool get isEmpty =>
      booksAdded == 0 &&
      modsAdded == 0 &&
      roundsAdded == 0 &&
      worldBookAdded == 0 &&
      bookModsAdded == 0 &&
      booksReplaced == 0;
}

/// 数据库合并服务：把一份备份库（`narrchat.db` 副本）以合并决策页的形式导入本地用户库。
///
/// 采用「人工逐书决策」而非自动并集：
/// - [buildPlanFromBackup] / [buildPlan]：比对两侧库，按书名（去首尾空白）判同，对同名书
///   按内容指纹区分为「冲突」或「两者全一致」，并给出保留较新侧的默认决策；
/// - [applyPlanIntoLocal] / [applyPlan]：按用户在合并决策页的逐书选择落地——冲突书
///   「保留导入」整本替换、「保留本地」不动；仅导入有的书始终导入；仅本地有 / 两者全一致保持本地。
class DatabaseMergeService {
  DatabaseMergeService._();

  // ---------------------------------------------------------------------------
  // 合并决策（人工逐书选择）——计划构建 / 落地
  // ---------------------------------------------------------------------------

  /// 从 [backupPath] 指向的备份库构建合并决策计划（只读打开备份，完成后即关闭）。
  static Future<DatabaseMergePlan> buildPlanFromBackup(
    String backupPath,
  ) async {
    final backup = await _openBackup(backupPath);
    try {
      final local = await DatabaseHelper.instance.database;
      return await buildPlan(backup, local);
    } finally {
      await backup.close();
    }
  }

  /// 构建合并决策计划：比对备份库与本地库，按标题判同并分类。
  ///
  /// 独立于文件路径与本地库单例，便于单元测试注入内存数据库。
  @visibleForTesting
  static Future<DatabaseMergePlan> buildPlan(
    Database backup,
    Database local,
  ) async {
    // 一次性读入两侧全量数据，便于分书分组与计算指纹（规模同现有并集合并）。
    final backupBooks = await backup.query('books', orderBy: 'id ASC');
    final localBooks = await local.query('books', orderBy: 'id ASC');
    final backupRounds = await backup.query('rounds', orderBy: 'round_index ASC');
    final localRounds = await local.query('rounds', orderBy: 'round_index ASC');
    final backupWb = await backup.query('world_book_entries');
    final localWb = await local.query('world_book_entries');
    final backupMods = await backup.query('mods');
    final localMods = await local.query('mods');
    final backupBookMods = await backup.query('book_mods');
    final localBookMods = await local.query('book_mods');

    final backupRoundsByBook = _groupByBookId(backupRounds);
    final localRoundsByBook = _groupByBookId(localRounds);
    final backupWbByBook = _groupByBookId(backupWb);
    final localWbByBook = _groupByBookId(localWb);
    final backupBookModsByBook = _groupByBookId(backupBookMods);
    final localBookModsByBook = _groupByBookId(localBookMods);
    final backupModsById = <int, Map<String, Object?>>{
      for (final m in backupMods)
        if (m['id'] != null) m['id'] as int: m,
    };
    final localModsById = <int, Map<String, Object?>>{
      for (final m in localMods)
        if (m['id'] != null) m['id'] as int: m,
    };

    final backupByTitle = _indexByTitle(backupBooks);
    final localByTitle = _indexByTitle(localBooks);

    final allTitles = <String>{...backupByTitle.keys, ...localByTitle.keys};
    final entries = <BookMergeEntry>[];
    for (final title in allTitles) {
      final backupRow = backupByTitle[title];
      final localRow = localByTitle[title];

      final imported = backupRow == null
          ? null
          : _buildSide(
              backupRow: backupRow,
              rounds: backupRoundsByBook[backupRow['id']] ?? const [],
              worldBooks: backupWbByBook[backupRow['id']] ?? const [],
              bookMods: backupBookModsByBook[backupRow['id']] ?? const [],
              modsById: backupModsById,
            );
      final localSide = localRow == null
          ? null
          : _buildSide(
              backupRow: localRow,
              rounds: localRoundsByBook[localRow['id']] ?? const [],
              worldBooks: localWbByBook[localRow['id']] ?? const [],
              bookMods: localBookModsByBook[localRow['id']] ?? const [],
              modsById: localModsById,
            );

      final MergeBookStatus status;
      if (imported != null && localSide != null) {
        status = imported.fingerprint == localSide.fingerprint
            ? MergeBookStatus.identical
            : MergeBookStatus.conflict;
      } else if (imported != null) {
        status = MergeBookStatus.importOnly;
      } else {
        status = MergeBookStatus.localOnly;
      }

      entries.add(
        BookMergeEntry(
          title: title,
          status: status,
          imported: imported,
          local: localSide,
          suggestedDecision: _suggestDecision(status, imported, localSide),
        ),
      );
    }

    // 需用户决策的项优先（冲突 → 仅导入有），随后按标题排序，保证列表稳定。
    final rank = {
      MergeBookStatus.conflict: 0,
      MergeBookStatus.importOnly: 1,
      MergeBookStatus.localOnly: 2,
      MergeBookStatus.identical: 3,
    };
    entries.sort((a, b) {
      final byRank = (rank[a.status]!).compareTo(rank[b.status]!);
      if (byRank != 0) return byRank;
      return a.title.compareTo(b.title);
    });

    return DatabaseMergePlan(entries: entries);
  }

  /// 按用户的逐书决策把 [plan] 落地进 [local]（整本替换语义）。
  @visibleForTesting
  static Future<DatabaseMergeResult> applyPlan(
    Database local,
    DatabaseMergePlan plan,
    Map<String, MergeBookDecision> decisions,
  ) async {
    final result = DatabaseMergeResult();
    await local.transaction((txn) async {
      // 1. 汇总所有会被导入的书侧，先对 Mod 按名称并集，建立 oldModId → localModId。
      final localModRows = await txn.query('mods');
      final modNameToId = <String, int>{
        for (final m in localModRows)
          if ((m['name'] as String? ?? '').trim().isNotEmpty)
            (m['name'] as String? ?? '').trim(): m['id'] as int,
      };
      final modIdMap = <int, int>{};

      for (final entry in plan.entries) {
        final imported = entry.imported;
        if (imported == null) continue;
        final decision = decisions[entry.title] ?? entry.suggestedDecision;
        if (_shouldImport(entry.status, decision)) {
          for (final mod in imported.mods.values) {
            final name = (mod['name'] as String? ?? '').trim();
            if (name.isEmpty) continue;
            final oldModId = mod['id'] as int?;
            if (oldModId == null) continue;
            if (modNameToId.containsKey(name)) {
              modIdMap[oldModId] = modNameToId[name]!;
            } else if (!modIdMap.containsKey(oldModId)) {
              final newId = await txn.insert(
                'mods',
                Map<String, Object?>.from(mod)..remove('id'),
              );
              modNameToId[name] = newId;
              modIdMap[oldModId] = newId;
              result.modsAdded++;
            }
          }
        }
      }

      // 2. 逐书落地。
      for (final entry in plan.entries) {
        final status = entry.status;
        if (status == MergeBookStatus.localOnly ||
            status == MergeBookStatus.identical) {
          continue;
        }
        final decision = decisions[entry.title] ?? entry.suggestedDecision;

        if (status == MergeBookStatus.importOnly) {
          // 仅导入有的书始终导入，不支持取消。
          await _insertImportedBook(
            txn,
            entry.imported!,
            modIdMap,
            result,
          );
          continue;
        }

        // conflict
        if (decision == MergeBookDecision.keepLocal) {
          result.booksSkipped++;
          continue;
        }
        await _deleteLocalBookByTitle(txn, entry.title);
        await _insertImportedBook(txn, entry.imported!, modIdMap, result);
        result.booksReplaced++;
      }
    });
    return result;
  }

  /// 把 [plan] 按决策落地进应用本地库（[DatabaseHelper]）。
  static Future<DatabaseMergeResult> applyPlanIntoLocal(
    DatabaseMergePlan plan,
    Map<String, MergeBookDecision> decisions,
  ) async {
    final local = await DatabaseHelper.instance.database;
    return applyPlan(local, plan, decisions);
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  static bool _shouldImport(MergeBookStatus status, MergeBookDecision decision) {
    if (status == MergeBookStatus.localOnly ||
        status == MergeBookStatus.identical) {
      return false;
    }
    // 仅导入有的书始终导入。
    if (status == MergeBookStatus.importOnly) {
      return true;
    }
    return decision == MergeBookDecision.keepImported;
  }

  /// 删除本地库中与 [title]（去首尾空白判同）匹配的书籍及其整棵子树。
  ///
  /// 显式删除 rounds / world_book_entries / book_mods 再删 books，
  /// 不依赖 FK 级联，兼容任何历史库是否开启 `PRAGMA foreign_keys`。
  static Future<void> _deleteLocalBookByTitle(
    DatabaseExecutor txn,
    String title,
  ) async {
    final rows = await txn.query(
      'books',
      where: 'title = ?',
      whereArgs: [title],
    );
    // 标题可能携带首尾空白而索引已归一化，此处再按归一化匹配兜底。
    final normalized = title.trim();
    final match = rows.firstWhere(
      (r) => (r['title'] as String? ?? '').trim() == normalized,
      orElse: () => const <String, Object?>{},
    );
    final id = match['id'] as int?;
    if (id == null) return;
    await txn.delete('rounds', where: 'book_id = ?', whereArgs: [id]);
    await txn.delete('world_book_entries', where: 'book_id = ?', whereArgs: [id]);
    await txn.delete('book_mods', where: 'book_id = ?', whereArgs: [id]);
    await txn.delete('books', where: 'id = ?', whereArgs: [id]);
  }

  /// 整本插入导入侧书籍快照（设置字段 + 轮次 + 世界书 + 书-Mod 配置）。
  static Future<void> _insertImportedBook(
    DatabaseExecutor txn,
    BookMergeSide side,
    Map<int, int> modIdMap,
    DatabaseMergeResult result,
  ) async {
    final bookMap = side.book.toMap()..remove('id');
    final newBookId = await txn.insert('books', bookMap);
    result.booksAdded++;

    for (final round in side.rounds) {
      await txn.insert(
        'rounds',
        round.toMap()
          ..remove('id')
          ..['book_id'] = newBookId,
      );
      result.roundsAdded++;
    }

    for (final wb in side.worldBooks) {
      await txn.insert(
        'world_book_entries',
        Map<String, Object?>.from(wb)
          ..remove('id')
          ..remove('book_id')
          ..['book_id'] = newBookId,
      );
      result.worldBookAdded++;
    }

    for (final bm in side.bookMods) {
      await txn.insert('book_mods', {
        'book_id': newBookId,
        'preset_key': bm.presetKey,
        'mod_id': bm.modId != null ? modIdMap[bm.modId] : null,
        'sort_order': bm.sortOrder,
        'is_enabled': bm.isEnabled,
      });
      result.bookModsAdded++;
    }
  }

  /// 由一侧书籍行与其关联数据构建快照。
  static BookMergeSide _buildSide({
    required Map<String, Object?> backupRow,
    required List<Map<String, Object?>> rounds,
    required List<Map<String, Object?>> worldBooks,
    required List<Map<String, Object?>> bookMods,
    required Map<int, Map<String, Object?>> modsById,
  }) {
    final roundModels = [
      for (final r in rounds) Round.fromMap(r),
    ]..sort((a, b) => a.roundIndex.compareTo(b.roundIndex));
    final worldBooksCopy =
        List<Map<String, Object?>>.from(worldBooks)
          ..sort((a, b) {
            final ak = (a['keyword'] as String? ?? '');
            final bk = (b['keyword'] as String? ?? '');
            return ak.compareTo(bk);
          });
    final assignments = [
      for (final bm in bookMods)
        BookModAssign(
          presetKey: bm['preset_key'] as String?,
          modId: bm['mod_id'] as int?,
          sortOrder: (bm['sort_order'] as int?) ?? 0,
          isEnabled: (bm['is_enabled'] as int?) ?? 1,
        ),
    ]..sort((a, b) {
        final an = _modName(a.modId, modsById);
        final bn = _modName(b.modId, modsById);
        final byName = an.compareTo(bn);
        if (byName != 0) return byName;
        return (a.presetKey ?? '').compareTo(b.presetKey ?? '');
      });
    final referencedMods = <int, Map<String, Object?>>{
      for (final bm in assignments)
        if (bm.modId != null && modsById.containsKey(bm.modId))
          bm.modId!: modsById[bm.modId]!,
    };

    DateTime? lastTime;
    for (final r in roundModels) {
      final t = r.createdAt;
      if (t != null && (lastTime == null || t.isAfter(lastTime))) {
        lastTime = t;
      }
    }

    final book = Book.fromMap(backupRow);

    return BookMergeSide(
      book: book,
      rounds: roundModels,
      worldBooks: worldBooksCopy,
      bookMods: assignments,
      mods: referencedMods,
      dbId: backupRow['id'] as int?,
      roundsCount: roundModels.length,
      lastTime: lastTime,
      fingerprint: _fingerprint(
        book.toMap(),
        roundModels,
        worldBooksCopy,
        assignments,
        referencedMods,
      ),
    );
  }

  static String _modName(
    int? modId,
    Map<int, Map<String, Object?>> modsById,
  ) {
    if (modId == null) return '';
    return (modsById[modId]?['name'] as String? ?? '').trim();
  }

  /// 与行 id 无关的书籍内容指纹：任一字段不同则指纹不同。
  static String _fingerprint(
    Map<String, Object?> bookRow,
    List<Round> rounds,
    List<Map<String, Object?>> worldBooks,
    List<BookModAssign> bookMods,
    Map<int, Map<String, Object?>> modsById,
  ) {
    final settings = Map<String, Object?>.from(bookRow)..remove('id');
    final roundsJson = [
      for (final r in rounds)
        [
          r.roundIndex,
          r.userInput,
          r.aiNarrative,
          r.worldState,
          r.characterState,
          r.memorySummary,
          r.currentTime,
          r.recommendedAction,
          r.tokensIn,
          r.tokensOut,
          r.modelName,
          r.userImages,
          r.aiImages,
          r.createdAt?.toIso8601String(),
        ],
    ];
    final worldBooksJson = [
      for (final w in worldBooks)
        [
          w['keyword'],
          w['content'],
          w['is_active'],
          w['created_at'],
        ],
    ];
    final bookModsJson = [
      for (final bm in bookMods)
        [
          _modName(bm.modId, modsById),
          bm.presetKey,
          bm.sortOrder,
          bm.isEnabled,
        ],
    ];
    return jsonEncode([settings, roundsJson, worldBooksJson, bookModsJson]);
  }

  /// 默认决策：冲突书「保留最后更新时间较新的一侧」（时间相同/未知默认保留本地）。
  static MergeBookDecision _suggestDecision(
    MergeBookStatus status,
    BookMergeSide? imported,
    BookMergeSide? local,
  ) {
    switch (status) {
      case MergeBookStatus.conflict:
        final i = imported?.lastTime;
        final l = local?.lastTime;
        if (i != null && (l == null || i.isAfter(l))) {
          return MergeBookDecision.keepImported;
        }
        if (l != null && (i == null || l.isAfter(i))) {
          return MergeBookDecision.keepLocal;
        }
        return MergeBookDecision.keepLocal;
      case MergeBookStatus.importOnly:
        return MergeBookDecision.keepImported;
      case MergeBookStatus.localOnly:
      case MergeBookStatus.identical:
        return MergeBookDecision.keepLocal;
    }
  }

  static Map<int, List<Map<String, Object?>>> _groupByBookId(
    List<Map<String, Object?>> rows,
  ) {
    final map = <int, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final id = row['book_id'] as int?;
      if (id == null) continue;
      (map[id] ??= []).add(row);
    }
    return map;
  }

  static Map<String, Map<String, Object?>> _indexByTitle(
    List<Map<String, Object?>> books,
  ) {
    final map = <String, Map<String, Object?>>{};
    for (final b in books) {
      final t = (b['title'] as String? ?? '').trim();
      if (t.isEmpty) continue; // 无名书籍不参与合并。
      map[t] = b;
    }
    return map;
  }

  /// 以只读方式打开备份库（不传 version，跳过 onCreate/onUpgrade 迁移逻辑）。
  static Future<Database> _openBackup(String path) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    return openDatabase(path, readOnly: true);
  }
}

/// 合并决策计划：逐书冲突分类与建议决策。
class DatabaseMergePlan {
  final List<BookMergeEntry> entries;

  const DatabaseMergePlan({required this.entries});

  int get conflictCount =>
      entries.where((e) => e.status == MergeBookStatus.conflict).length;
  int get importOnlyCount =>
      entries.where((e) => e.status == MergeBookStatus.importOnly).length;
  int get localOnlyCount =>
      entries.where((e) => e.status == MergeBookStatus.localOnly).length;
  int get identicalCount =>
      entries.where((e) => e.status == MergeBookStatus.identical).length;

  /// 依据决策表统计最终会发生的动作，用于合并确认摘要。
  Map<String, int> summarize(Map<String, MergeBookDecision> decisions) {
    var toImport = 0;
    var toReplace = 0;
    var toSkip = 0;
    for (final e in entries) {
      final d = decisions[e.title] ?? e.suggestedDecision;
      switch (e.status) {
        case MergeBookStatus.conflict:
          if (d == MergeBookDecision.keepImported) {
            toReplace++;
          } else {
            toSkip++;
          }
          break;
        case MergeBookStatus.importOnly:
          // 仅导入有的书始终导入。
          toImport++;
          break;
        case MergeBookStatus.localOnly:
        case MergeBookStatus.identical:
          // 保留本地，不计入变更。
          break;
      }
    }
    return {'import': toImport, 'replace': toReplace, 'skip': toSkip};
  }
}

/// 单本书的合并条目。
class BookMergeEntry {
  final String title;
  final MergeBookStatus status;
  final BookMergeSide? imported;
  final BookMergeSide? local;
  final MergeBookDecision suggestedDecision;

  const BookMergeEntry({
    required this.title,
    required this.status,
    this.imported,
    this.local,
    required this.suggestedDecision,
  });
}

/// 单书在某侧数据库中的完整快照（列表元数据 + 预览/落地所需内容）。
class BookMergeSide {
  final Book book;
  final List<Round> rounds;
  final List<Map<String, Object?>> worldBooks;
  final List<BookModAssign> bookMods;

  /// 被本书引用的 Mod 行（按 oldModId），用于并集重建与 id 映射。
  final Map<int, Map<String, Object?>> mods;

  /// 本书在该库中的行 id（落地时用于关联映射）。
  final int? dbId;
  final int roundsCount;
  final DateTime? lastTime;

  /// 与行 id 无关的内容指纹（冲突判定）。
  final String fingerprint;

  const BookMergeSide({
    required this.book,
    required this.rounds,
    required this.worldBooks,
    required this.bookMods,
    required this.mods,
    this.dbId,
    required this.roundsCount,
    this.lastTime,
    required this.fingerprint,
  });
}

/// 书-Mod 配置项（`book_mods` 行）。
class BookModAssign {
  final String? presetKey;
  final int? modId;
  final int sortOrder;
  final int isEnabled;

  const BookModAssign({
    this.presetKey,
    this.modId,
    this.sortOrder = 0,
    this.isEnabled = 1,
  });
}

/// 书籍合并状态。
enum MergeBookStatus { conflict, importOnly, localOnly, identical }

/// 单书的合并决策。
enum MergeBookDecision { keepImported, keepLocal }
