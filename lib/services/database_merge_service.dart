import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';
import '../models/book.dart';
import '../models/round.dart';
import '../utils/uuid_utils.dart';

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

  /// 冲突 mod「保留导入」覆盖本地同名 mod 的次数。
  int modsReplaced = 0;

  /// 冲突 mod「重命名为 {原名} - 导入」另存新 mod 的次数。
  int modsRenamed = 0;

  bool get isEmpty =>
      booksAdded == 0 &&
      modsAdded == 0 &&
      roundsAdded == 0 &&
      worldBookAdded == 0 &&
      bookModsAdded == 0 &&
      booksReplaced == 0 &&
      modsReplaced == 0 &&
      modsRenamed == 0;
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
      final bool settingsConflict;
      final bool contentConflict;
      if (imported != null && localSide != null) {
        settingsConflict =
            imported.settingsFp != localSide.settingsFp;
        contentConflict = imported.contentFp != localSide.contentFp;
        status = (settingsConflict || contentConflict)
            ? MergeBookStatus.conflict
            : MergeBookStatus.identical;
      } else {
        settingsConflict = false;
        contentConflict = false;
        status = imported != null
            ? MergeBookStatus.importOnly
            : MergeBookStatus.localOnly;
      }

      // 各部件默认：内容按"保留最后更新时间较新的一侧"；设置默认保留本地。
      final suggestedContent = status != MergeBookStatus.conflict
          ? MergePartChoice.keepLocal
          : (_suggestContentImport(imported, localSide)
              ? MergePartChoice.import
              : MergePartChoice.keepLocal);

      entries.add(
        BookMergeEntry(
          title: title,
          status: status,
          settingsConflict: settingsConflict,
          contentConflict: contentConflict,
          imported: imported,
          local: localSide,
          suggestedDecision: _suggestDecision(status, imported, localSide),
          suggestedSettings: MergePartChoice.keepLocal,
          suggestedContent: suggestedContent,
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

    // 合并计划同样包含 Mod：与书一致，按名称判同（Mod 不记录修改时间，
    // 无自动对比，默认保留导入；仅在「全本地/全导入」批量选项下变化）。
    final backupModByName = _indexModsByName(backupMods);
    final localModByName = _indexModsByName(localMods);
    final allModNames = <String>{
      ...backupModByName.keys,
      ...localModByName.keys,
    };
    final modEntries = <ModMergeEntry>[];
    for (final name in allModNames) {
      final backupMod = backupModByName[name];
      final localMod = localModByName[name];
      final imported = backupMod == null ? null : _buildModSide(backupMod);
      final local = localMod == null ? null : _buildModSide(localMod);

      final ModMergeStatus status;
      if (imported != null && local != null) {
        status = imported.fingerprint == local.fingerprint
            ? ModMergeStatus.identical
            : ModMergeStatus.conflict;
      } else if (imported != null) {
        status = ModMergeStatus.importOnly;
      } else {
        status = ModMergeStatus.localOnly;
      }

      modEntries.add(
        ModMergeEntry(
          name: name,
          status: status,
          imported: imported,
          local: local,
          defaultDecision: _modDefaultDecision(status),
        ),
      );
    }
    final modRank = {
      ModMergeStatus.conflict: 0,
      ModMergeStatus.importOnly: 1,
      ModMergeStatus.localOnly: 2,
      ModMergeStatus.identical: 3,
    };
    modEntries.sort((a, b) {
      final byRank = (modRank[a.status]!).compareTo(modRank[b.status]!);
      if (byRank != 0) return byRank;
      return a.name.compareTo(b.name);
    });

    return DatabaseMergePlan(entries: entries, modEntries: modEntries);
  }

  /// 按用户的逐书（部件级） / 逐 Mod 决策把 [plan] 落地进 [local]。
  ///
  /// 冲突书按「设置部件 / 内容部件」独立选择（[BookPartDecisions]）：
  /// - 设置部件导入 → books 设置列 + 世界书 + 书‑Mod 配置采用导入侧；
  /// - 内容部件导入 → 轮次 + 失败条目采用导入侧；
  /// 同名书就地更新（不删除重建，保留本地行 id 与共基身份）。
  @visibleForTesting
  static Future<DatabaseMergeResult> applyPlan(
    Database local,
    DatabaseMergePlan plan,
    Map<String, BookPartDecisions> bookDecisions,
    Map<String, ModMergeDecision> modDecisions,
  ) async {
    final result = DatabaseMergeResult();
    await local.transaction((txn) async {
      // 1. 先落地 Mod 决策，得到「导入 Mod 名 → 本地 Mod id」映射，
      //    供导入书时解析其 book_mods 引用。
      final importModNameToId = await _applyModDecisions(
        txn,
        plan,
        modDecisions,
        result,
      );

      // 2. 逐书落地。
      for (final entry in plan.entries) {
        final status = entry.status;
        if (status == MergeBookStatus.localOnly ||
            status == MergeBookStatus.identical) {
          continue;
        }
        final decision = bookDecisions[entry.title] ?? BookPartDecisions(
              settings: entry.suggestedSettings,
              content: entry.suggestedContent,
            );

        if (status == MergeBookStatus.importOnly) {
          // 仅导入有的书始终导入，不支持取消。
          await _insertImportedBook(
            txn,
            entry.imported!,
            importModNameToId,
            result,
          );
          continue;
        }

        // conflict：按部件独立落地（就地更新，不删除重建）。
        final localId = await _localBookIdByTitle(txn, entry.title);
        if (localId == null) {
          // 极端情形：本地书已不存在（如被删除）→ 整本保留导入。
          await _insertImportedBook(
            txn,
            entry.imported!,
            importModNameToId,
            result,
          );
          continue;
        }
        var applied = false;
        if (decision.settings == MergePartChoice.import) {
          await _applySettingsPart(
            txn,
            entry.imported!,
            localId,
            importModNameToId,
            result,
          );
          applied = true;
        }
        if (decision.content == MergePartChoice.import) {
          await _applyContentPart(txn, entry.imported!, localId, result);
          applied = true;
        }
        if (applied) {
          result.booksReplaced++;
        } else {
          result.booksSkipped++;
        }
      }
    });
    return result;
  }

  /// 按书名（去首尾空白）查找本地书 id。
  static Future<int?> _localBookIdByTitle(
    DatabaseExecutor txn,
    String title,
  ) async {
    final normalized = title.trim();
    final rows = await txn.query('books', where: 'title = ?', whereArgs: [title]);
    for (final r in rows) {
      if ((r['title'] as String? ?? '').trim() == normalized) {
        return r['id'] as int?;
      }
    }
    return null;
  }

  /// 落地「设置部件」：books 设置列（不含 title，避免改名扰乱匹配）+
  /// 世界书整体替换 + 书‑Mod 配置整体替换。
  static Future<void> _applySettingsPart(
    DatabaseExecutor txn,
    BookMergeSide imported,
    int localId,
    Map<String, int> importModNameToId,
    DatabaseMergeResult result,
  ) async {
    final settings = imported.book.toMap()
      ..remove('id')
      ..remove('title')
      ..remove('uuid');
    await txn.update('books', settings, where: 'id = ?', whereArgs: [localId]);

    await txn.delete('world_book_entries', where: 'book_id = ?', whereArgs: [localId]);
    for (final w in imported.worldBooks) {
      await txn.insert(
        'world_book_entries',
        Map<String, Object?>.from(w)
          ..remove('id')
          ..remove('book_id')
          ..['book_id'] = localId,
      );
      result.worldBookAdded++;
    }

    await txn.delete('book_mods', where: 'book_id = ?', whereArgs: [localId]);
    for (final bm in imported.bookMods) {
      final modName = (imported.mods[bm.modId]?['name'] as String? ?? '').trim();
      final modId = modName.isEmpty ? null : importModNameToId[modName];
      await txn.insert('book_mods', {
        'book_id': localId,
        'preset_key': bm.presetKey,
        'mod_id': modId,
        'sort_order': bm.sortOrder,
        'is_enabled': bm.isEnabled,
      });
      result.bookModsAdded++;
    }
  }

  /// 落地「内容部件」：轮次整体替换 + 失败条目列一并替换。
  static Future<void> _applyContentPart(
    DatabaseExecutor txn,
    BookMergeSide imported,
    int localId,
    DatabaseMergeResult result,
  ) async {
    await txn.delete('rounds', where: 'book_id = ?', whereArgs: [localId]);
    for (final r in imported.rounds) {
      await txn.insert(
        'rounds',
        r.toMap()
          ..remove('id')
          ..['book_id'] = localId,
      );
      result.roundsAdded++;
    }
    await txn.update(
      'books',
      {
        'failed_user_input': imported.failedUserInput,
        'failed_error_message': imported.failedErrorMessage,
        'failed_user_images': imported.failedUserImages,
      },
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  /// 把 [plan] 按决策落地进应用本地库（[DatabaseHelper]）。
  static Future<DatabaseMergeResult> applyPlanIntoLocal(
    DatabaseMergePlan plan,
    Map<String, BookPartDecisions> bookDecisions,
    Map<String, ModMergeDecision> modDecisions,
  ) async {
    final local = await DatabaseHelper.instance.database;
    return applyPlan(local, plan, bookDecisions, modDecisions);
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  /// 落地 Mod 决策，返回「导入 Mod 名 → 本地 Mod id」映射（供导入书解析 book_mods）。
  static Future<Map<String, int>> _applyModDecisions(
    DatabaseExecutor txn,
    DatabaseMergePlan plan,
    Map<String, ModMergeDecision> modDecisions,
    DatabaseMergeResult result,
  ) async {
    final importNameToId = <String, int>{};
    final localModRows = await txn.query('mods');
    final localNameToId = <String, int>{
      for (final m in localModRows)
        if ((m['name'] as String? ?? '').trim().isNotEmpty)
          (m['name'] as String? ?? '').trim(): m['id'] as int,
    };

    for (final e in plan.modEntries) {
      final defaultDecision = e.defaultDecision;
      final decision = modDecisions[e.name] ?? defaultDecision;
      switch (e.status) {
        case ModMergeStatus.localOnly:
        case ModMergeStatus.identical:
          final lid = localNameToId[e.name];
          if (lid != null) importNameToId[e.name] = lid;
          break;
        case ModMergeStatus.importOnly:
          // 仅导入有的 Mod 始终导入。
          final row = e.imported!.mod;
          final newId = await txn.insert(
            'mods',
            _ensureUuid(Map<String, Object?>.from(row)..remove('id')),
          );
          localNameToId[e.name] = newId;
          importNameToId[e.name] = newId;
          result.modsAdded++;
          break;
        case ModMergeStatus.conflict:
          switch (decision) {
            case ModMergeDecision.keepLocal:
              final lid = localNameToId[e.name];
              if (lid != null) importNameToId[e.name] = lid;
              break;
            case ModMergeDecision.import:
              // 用导入内容覆盖本地同名 Mod（就地更新，id 不变，引用不失效）。
              // 本地 uuid 保留（同步身份以本地为准，内容变更随推送传播）；
              // 导入行 uuid 缺失时补齐（旧备份 schema 无该列）。
              final row = e.imported!.mod;
              final lid = localNameToId[e.name];
              int modId;
              if (lid != null) {
                await txn.update(
                  'mods',
                  Map<String, Object?>.from(row)
                    ..remove('id')
                    ..remove('uuid'),
                  where: 'id = ?',
                  whereArgs: [lid],
                );
                modId = lid;
              } else {
                modId = await txn.insert(
                  'mods',
                  _ensureUuid(Map<String, Object?>.from(row)..remove('id')),
                );
                localNameToId[e.name] = modId;
                result.modsAdded++;
              }
              importNameToId[e.name] = modId;
              result.modsReplaced++;
              break;
            case ModMergeDecision.rename:
              // 重命名为「{原名} - 导入」另存为新 Mod，本地同名 Mod 保留。
              final renamed = '${e.name} - 导入';
              final row = e.imported!.mod;
              final newId = await txn.insert(
                'mods',
                _ensureUuid(
                  Map<String, Object?>.from(row)
                    ..remove('id')
                    ..['name'] = renamed,
                ),
              );
              localNameToId[renamed] = newId;
              importNameToId[e.name] = newId;
              result.modsRenamed++;
              break;
          }
          break;
      }
    }
    return importNameToId;
  }

  /// 导入行 uuid 缺失（旧备份 schema）时补生成，保证落地后的行具备同步身份。
  static Map<String, Object?> _ensureUuid(Map<String, Object?> row) {
    if ((row['uuid'] as String? ?? '').isNotEmpty) return row;
    return {...row, 'uuid': UuidUtils.generateUuidV4()};
  }

  /// 整本插入导入侧书籍快照（设置字段 + 轮次 + 世界书 + 书-Mod 配置）。
  ///
  /// [importModNameToId]：导入 Mod 名 → 本地 Mod id（由 [applyPlan] 先落地 Mod 决策得到）。
  static Future<void> _insertImportedBook(
    DatabaseExecutor txn,
    BookMergeSide side,
    Map<String, int> importModNameToId,
    DatabaseMergeResult result,
  ) async {
    final bookMap = _ensureUuid(side.book.toMap()..remove('id'));
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
      final modName = (side.mods[bm.modId]?['name'] as String? ?? '').trim();
      final modId = modName.isEmpty ? null : importModNameToId[modName];
      await txn.insert('book_mods', {
        'book_id': newBookId,
        'preset_key': bm.presetKey,
        'mod_id': modId,
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
      settingsFp: _settingsPartFingerprint(
        backupRow,
        worldBooksCopy,
        assignments,
        modsById,
      ),
      contentFp: _contentPartFingerprint(backupRow, roundModels),
      failedUserInput: (backupRow['failed_user_input'] as String?) ?? '',
      failedErrorMessage: (backupRow['failed_error_message'] as String?) ?? '',
      failedUserImages: (backupRow['failed_user_images'] as String?) ?? '[]',
    );
  }

  /// 设置部件指纹：books 设置列 + 世界书 + 书‑Mod 配置。
  static String _settingsPartFingerprint(
    Map<String, Object?> row,
    List<Map<String, Object?>> worldBooks,
    List<BookModAssign> bookMods,
    Map<int, Map<String, Object?>> modsById,
  ) {
    final worldBooksJson = [
      for (final w in worldBooks)
        [w['keyword'], w['content'], w['is_active']],
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
    return jsonEncode([
      row['title'],
      row['category'],
      row['base_setting'],
      row['writing_requirements'],
      row['writing_style'],
      row['global_pre_prompt'],
      row['global_post_prompt'],
      row['history_rounds'],
      row['role_hierarchy'],
      row['role_hierarchy_detail'],
      worldBooksJson,
      bookModsJson,
    ]);
  }

  /// 内容部件指纹：轮次（按 round_index）+ 失败条目列。
  static String _contentPartFingerprint(
    Map<String, Object?> row,
    List<Round> rounds,
  ) {
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
    return jsonEncode([
      roundsJson,
      row['failed_user_input'],
      row['failed_error_message'],
      row['failed_user_images'],
    ]);
  }

  static String _modName(
    int? modId,
    Map<int, Map<String, Object?>> modsById,
  ) {
    if (modId == null) return '';
    return (modsById[modId]?['name'] as String? ?? '').trim();
  }

  /// 与行 id 无关的书籍内容指纹：任一字段不同则指纹不同。
  /// 排除同步身份（uuid）与时间戳/墓碑列：这些字段不参与"内容一致"判定。
  static String _fingerprint(
    Map<String, Object?> bookRow,
    List<Round> rounds,
    List<Map<String, Object?>> worldBooks,
    List<BookModAssign> bookMods,
    Map<int, Map<String, Object?>> modsById,
  ) {
    final settings = Map<String, Object?>.from(bookRow)
      ..remove('id')
      ..remove('uuid')
      ..remove('settings_updated_at')
      ..remove('rounds_updated_at')
      ..remove('deleted_at');
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

  /// 内容部件默认：导入侧最后更新时间较新、或时间相同/未知 → 采用导入。
  static bool _suggestContentImport(
    BookMergeSide? imported,
    BookMergeSide? local,
  ) {
    final i = imported?.lastTime;
    final l = local?.lastTime;
    if (i != null && (l == null || !l.isAfter(i))) return true;
    return false;
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

  static Map<String, Map<String, Object?>> _indexModsByName(
    List<Map<String, Object?>> rows,
  ) {
    final map = <String, Map<String, Object?>>{};
    for (final m in rows) {
      final name = (m['name'] as String? ?? '').trim();
      if (name.isEmpty) continue; // 无名 Mod 不参与合并。
      map[name] = m;
    }
    return map;
  }

  static ModMergeSide _buildModSide(Map<String, Object?> row) {
    return ModMergeSide(
      mod: Map<String, Object?>.from(row),
      dbId: row['id'] as int?,
      fingerprint: _modFingerprint(row),
    );
  }

  /// 与行 id 无关的 Mod 内容指纹（任一字段不同则指纹不同）。
  static String _modFingerprint(Map<String, Object?> row) {
    return jsonEncode([
      (row['name'] as String? ?? '').trim(),
      row['description'],
      row['pre_prompt'],
      row['post_prompt'],
      row['system_prompt'],
      row['world_book'],
      row['created_at'],
      row['updated_at'],
    ]);
  }

  /// Mod 默认决策：无时间可对比，冲突 / 仅导入有默认保留导入；
  /// 仅本地有 / 两者全一致保留本地。
  static ModMergeDecision _modDefaultDecision(ModMergeStatus status) {
    return switch (status) {
      ModMergeStatus.conflict || ModMergeStatus.importOnly =>
        ModMergeDecision.import,
      ModMergeStatus.localOnly || ModMergeStatus.identical =>
        ModMergeDecision.keepLocal,
    };
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

/// 合并决策计划：逐书 / 逐 Mod 冲突分类与建议决策。
class DatabaseMergePlan {
  final List<BookMergeEntry> entries;
  final List<ModMergeEntry> modEntries;

  const DatabaseMergePlan({
    required this.entries,
    this.modEntries = const [],
  });

  int get conflictCount =>
      entries.where((e) => e.status == MergeBookStatus.conflict).length;
  int get importOnlyCount =>
      entries.where((e) => e.status == MergeBookStatus.importOnly).length;
  int get localOnlyCount =>
      entries.where((e) => e.status == MergeBookStatus.localOnly).length;
  int get identicalCount =>
      entries.where((e) => e.status == MergeBookStatus.identical).length;

  int get modConflictCount =>
      modEntries.where((e) => e.status == ModMergeStatus.conflict).length;
  int get modImportOnlyCount =>
      modEntries.where((e) => e.status == ModMergeStatus.importOnly).length;
  int get modLocalOnlyCount =>
      modEntries.where((e) => e.status == ModMergeStatus.localOnly).length;
  int get modIdenticalCount =>
      modEntries.where((e) => e.status == ModMergeStatus.identical).length;

  /// 依据决策表统计最终会发生的动作，用于合并确认摘要。
  ///
  /// [decisions] 为逐书部件决策（设置部件 / 内容部件独立计数）。
  Map<String, int> summarize(Map<String, BookPartDecisions> decisions) {
    var toImport = 0;
    var toReplace = 0;
    var toSkip = 0;
    var toReplaceSettings = 0;
    var toReplaceContent = 0;
    for (final e in entries) {
      final d = decisions[e.title] ??
          BookPartDecisions(
            settings: e.suggestedSettings,
            content: e.suggestedContent,
          );
      switch (e.status) {
        case MergeBookStatus.conflict:
          if (d.allLocal) {
            toSkip++;
          } else {
            toReplace++;
          }
          if (d.settings == MergePartChoice.import) toReplaceSettings++;
          if (d.content == MergePartChoice.import) toReplaceContent++;
        case MergeBookStatus.importOnly:
          // 仅导入有的书始终导入。
          toImport++;
        case MergeBookStatus.localOnly:
        case MergeBookStatus.identical:
          // 保留本地，不计入变更。
          break;
      }
    }
    return {
      'import': toImport,
      'replace': toReplace,
      'skip': toSkip,
      'replaceSettings': toReplaceSettings,
      'replaceContent': toReplaceContent,
    };
  }

  /// 依据 Mod 决策统计最终动作，用于合并确认摘要。
  Map<String, int> summarizeMods(Map<String, ModMergeDecision> decisions) {
    var toImport = 0;
    var toRename = 0;
    var toReplace = 0;
    var toKeep = 0;
    for (final e in modEntries) {
      final d = decisions[e.name] ?? e.defaultDecision;
      switch (e.status) {
        case ModMergeStatus.conflict:
          switch (d) {
            case ModMergeDecision.import:
              toReplace++;
            case ModMergeDecision.rename:
              toRename++;
            case ModMergeDecision.keepLocal:
              toKeep++;
          }
          break;
        case ModMergeStatus.importOnly:
          toImport++;
          break;
        case ModMergeStatus.localOnly:
        case ModMergeStatus.identical:
          toKeep++;
          break;
      }
    }
    return {
      'import': toImport,
      'rename': toRename,
      'replace': toReplace,
      'keep': toKeep,
    };
  }
}

/// 单本书的合并条目。
///
/// 冲突判定细分为两个部件（对应同步层的"设置部件 / 内容部件"）：
/// - 设置部件：书名/分类/设定/文笔/前后置词/历史轮数/角色（books 设置列）+ 世界书 + 书‑Mod 配置；
/// - 内容部件：轮次 + 失败条目（生成内容，失败条目随轮次同步）。
class BookMergeEntry {
  final String title;
  final MergeBookStatus status;

  /// 设置部件是否冲突（两侧设置/世界书/书‑Mod 任一不同）。
  final bool settingsConflict;

  /// 内容部件是否冲突（两侧轮次/失败条目任一不同）。
  final bool contentConflict;

  final BookMergeSide? imported;
  final BookMergeSide? local;
  final MergeBookDecision suggestedDecision;

  /// 各部件默认选择（内容部件按"保留轮次较新侧"建议；设置部件默认保留本地）。
  final MergePartChoice suggestedSettings;
  final MergePartChoice suggestedContent;

  const BookMergeEntry({
    required this.title,
    required this.status,
    required this.settingsConflict,
    required this.contentConflict,
    this.imported,
    this.local,
    required this.suggestedDecision,
    required this.suggestedSettings,
    required this.suggestedContent,
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

  /// 设置部件指纹（books 设置列 + 世界书 + 书‑Mod 配置）。
  final String settingsFp;

  /// 内容部件指纹（轮次 + 失败条目）。
  final String contentFp;

  /// 失败条目（books 列；随内容部件落地）。
  final String failedUserInput;
  final String failedErrorMessage;
  final String failedUserImages;

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
    required this.settingsFp,
    required this.contentFp,
    this.failedUserInput = '',
    this.failedErrorMessage = '',
    this.failedUserImages = '[]',
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

/// 单个部件的合并选择（冲突书按部件独立选择）。
enum MergePartChoice { keepLocal, import }

/// 一本书的两个部件决策（设置部件 / 内容部件）。
class BookPartDecisions {
  final MergePartChoice settings;
  final MergePartChoice content;

  const BookPartDecisions({
    required this.settings,
    required this.content,
  });

  bool get allLocal => settings == MergePartChoice.keepLocal &&
      content == MergePartChoice.keepLocal;

  bool get allImport => settings == MergePartChoice.import &&
      content == MergePartChoice.import;
}

/// Mod 合并状态。
enum ModMergeStatus { conflict, importOnly, localOnly, identical }

/// 单个 Mod 的合并决策（冲突）：
/// - [import]：用导入内容覆盖本地同名 Mod；
/// - [rename]：把导入 Mod 重命名为「{原名} - 导入」另存（本地同名 Mod 保留）；
/// - [keepLocal]：保留本地 Mod。
enum ModMergeDecision { import, rename, keepLocal }

/// 单 Mod 在某侧数据库中的完整快照（content 落地所需）。
class ModMergeSide {
  /// 完整 mod 行（含 name/description/pre_prompt/post_prompt/system_prompt/world_book 等）。
  final Map<String, Object?> mod;

  /// 该书在该库中的行 id（落地时用于关联映射）。
  final int? dbId;

  /// 与行 id 无关的内容指纹（冲突判定）。
  final String fingerprint;

  const ModMergeSide({
    required this.mod,
    this.dbId,
    required this.fingerprint,
  });
}

/// 单个 Mod 的合并条目。
class ModMergeEntry {
  final String name;
  final ModMergeStatus status;
  final ModMergeSide? imported;
  final ModMergeSide? local;
  final ModMergeDecision defaultDecision;

  const ModMergeEntry({
    required this.name,
    required this.status,
    this.imported,
    this.local,
    required this.defaultDecision,
  });
}
