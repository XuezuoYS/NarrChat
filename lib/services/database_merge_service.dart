import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';

/// 合并结果统计。
class DatabaseMergeResult {
  int booksAdded = 0;
  int modsAdded = 0;
  int roundsAdded = 0;
  int worldBookAdded = 0;
  int bookModsAdded = 0;

  bool get isEmpty =>
      booksAdded == 0 &&
      modsAdded == 0 &&
      roundsAdded == 0 &&
      worldBookAdded == 0 &&
      bookModsAdded == 0;
}

/// 数据库合并服务：把一份备份库（`narrchat.db` 副本）合并进本地用户库。
///
/// 合并语义（取并集、不丢失任何一端数据、冲突以本地为准）：
/// - books：按书名（去首尾空白）判重，同名视为同一本书，保留本地版本；
/// - mods：按名称判重；
/// - rounds：按（书, 轮次序号）判重，本地缺失的轮次补入；
/// - world_book_entries：按（书, 关键词）判重；
/// - book_mods：仅为「本次新增的书籍」补入其 Mod 配置（已存在书籍的
///   Mod 配置以本地为准，避免覆盖用户在本地的调整）。
class DatabaseMergeService {
  DatabaseMergeService._();

  /// 将 [backupPath] 指向的备份库合并进本地用户库，返回统计结果。
  static Future<DatabaseMergeResult> mergeBackupIntoLocal(
    String backupPath,
  ) async {
    final backup = await _openBackup(backupPath);
    try {
      final local = await DatabaseHelper.instance.database;
      return await mergeDatabases(backup, local);
    } finally {
      await backup.close();
    }
  }

  /// 核心合并逻辑：把 [backup] 中的数据合并进 [local]。
  ///
  /// 独立于文件路径与本地库单例，便于单元测试注入内存数据库。
  @visibleForTesting
  static Future<DatabaseMergeResult> mergeDatabases(
    Database backup,
    Database local,
  ) async {
    final result = DatabaseMergeResult();
    final backupBooks = await backup.query('books', orderBy: 'id ASC');
    final backupMods = await backup.query('mods', orderBy: 'id ASC');
    final backupRounds = await backup.query('rounds', orderBy: 'id ASC');
    final backupWorldBooks = await backup.query(
      'world_book_entries',
      orderBy: 'id ASC',
    );
    final backupBookMods = await backup.query('book_mods', orderBy: 'id ASC');

    await local.transaction((txn) async {
      // 1. 合并书籍（按书名判重）。
      final localBooks = await txn.query('books');
      final bookIdMap = <int, int>{};
      final newBookOldIds = <int>{};
      final localTitleSet = <String>{
        for (final b in localBooks) (b['title'] as String? ?? '').trim(),
      };
      for (final b in backupBooks) {
        final oldId = b['id'] as int?;
        if (oldId == null) continue;
        final title = (b['title'] as String? ?? '').trim();
        if (title.isEmpty) continue; // 无名书籍不合并
        if (localTitleSet.contains(title)) {
          final match = localBooks.firstWhere(
            (lb) => (lb['title'] as String? ?? '').trim() == title,
          );
          bookIdMap[oldId] = match['id'] as int;
        } else {
          final map = Map<String, Object?>.from(b)..remove('id');
          final newId = await txn.insert('books', map);
          bookIdMap[oldId] = newId;
          localTitleSet.add(title);
          newBookOldIds.add(oldId);
          result.booksAdded++;
        }
      }

      // 2. 合并 Mod（按名称判重）。
      final localMods = await txn.query('mods');
      final modIdMap = <int, int>{};
      final localModNameSet = <String>{
        for (final m in localMods) (m['name'] as String? ?? '').trim(),
      };
      for (final m in backupMods) {
        final oldId = m['id'] as int?;
        if (oldId == null) continue;
        final name = (m['name'] as String? ?? '').trim();
        if (name.isEmpty) continue;
        if (localModNameSet.contains(name)) {
          final match = localMods.firstWhere(
            (lm) => (lm['name'] as String? ?? '').trim() == name,
          );
          modIdMap[oldId] = match['id'] as int;
        } else {
          final map = Map<String, Object?>.from(m)..remove('id');
          final newId = await txn.insert('mods', map);
          modIdMap[oldId] = newId;
          localModNameSet.add(name);
          result.modsAdded++;
        }
      }

      // 3. 合并轮次（按 书 + 轮次序号）。
      final localRounds = await txn.query('rounds');
      final roundKeys = <String>{
        for (final r in localRounds) '${r['book_id']}:${r['round_index']}',
      };
      for (final r in backupRounds) {
        final oldBookId = r['book_id'] as int?;
        final localBookId = bookIdMap[oldBookId];
        if (localBookId == null) continue;
        final key = '$localBookId:${r['round_index']}';
        if (roundKeys.contains(key)) continue;
        final map = Map<String, Object?>.from(r)
          ..remove('id')
          ..['book_id'] = localBookId;
        await txn.insert('rounds', map);
        roundKeys.add(key);
        result.roundsAdded++;
      }

      // 4. 合并世界书（按 书 + 关键词）。
      final localWorldBooks = await txn.query('world_book_entries');
      final wbeKeys = <String>{
        for (final w in localWorldBooks) '${w['book_id']}:${w['keyword']}',
      };
      for (final w in backupWorldBooks) {
        final oldBookId = w['book_id'] as int?;
        final localBookId = bookIdMap[oldBookId];
        if (localBookId == null) continue;
        final key = '$localBookId:${w['keyword']}';
        if (wbeKeys.contains(key)) continue;
        final map = Map<String, Object?>.from(w)
          ..remove('id')
          ..['book_id'] = localBookId;
        await txn.insert('world_book_entries', map);
        wbeKeys.add(key);
        result.worldBookAdded++;
      }

      // 5. 仅为「本次新增的书籍」补入 Mod 配置。
      for (final bm in backupBookMods) {
        final oldBookId = bm['book_id'] as int?;
        if (oldBookId == null || !newBookOldIds.contains(oldBookId)) {
          continue;
        }
        final localBookId = bookIdMap[oldBookId];
        if (localBookId == null) continue;
        final modId = bm['mod_id'] as int?;
        await txn.insert('book_mods', {
          'book_id': localBookId,
          'preset_key': bm['preset_key'],
          'mod_id': modId != null ? modIdMap[modId] : null,
          'sort_order': bm['sort_order'] ?? 0,
          'is_enabled': bm['is_enabled'] ?? 1,
        });
        result.bookModsAdded++;
      }
    });
    return result;
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
