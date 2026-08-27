import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/database_merge_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/merge_db.dart';

void main() {
  group('DatabaseMergeService.buildPlan', () {
    test('同名书轮次内容不同 → 冲突', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokId = await _addBook(local, 'A', category: '本地');
        await _addRound(local, lokId, 1, userInput: '本地');
        final bakId = await _addBook(backup, 'A', category: '备份');
        await _addRound(backup, bakId, 1, userInput: '备份');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final entry = plan.entries.single;
        expect(entry.status, MergeBookStatus.conflict);
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('书籍设置字段不同 → 冲突', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokId = await _addBook(local, 'A', category: '旧');
        await _addRound(local, lokId, 1, userInput: '正文');
        final bakId = await _addBook(backup, 'A', category: '新');
        await _addRound(backup, bakId, 1, userInput: '正文');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(plan.entries.single.status, MergeBookStatus.conflict);
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('两侧完全一致 → 两者全一致', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokId = await _addBook(local, 'A', category: '同');
        await _addRound(local, lokId, 1, userInput: '正文');
        final bakId = await _addBook(backup, 'A', category: '同');
        await _addRound(backup, bakId, 1, userInput: '正文');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(plan.entries.single.status, MergeBookStatus.identical);
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('仅导入有 / 仅本地有', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await _addBook(backup, '云端书');
        await _addBook(local, '本地书');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(plan.importOnlyCount, 1);
        expect(plan.localOnlyCount, 1);
        expect(
          plan.entries.firstWhere((e) => e.title == '云端书').status,
          MergeBookStatus.importOnly,
        );
        expect(
          plan.entries.firstWhere((e) => e.title == '本地书').status,
          MergeBookStatus.localOnly,
        );
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('元数据：轮次数与最后时间正确，无轮次为空', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final id = await _addBook(backup, 'B');
        await _addRound(
          backup,
          id,
          1,
          createdAt: DateTime(2026, 1, 1, 8),
        );
        await _addRound(
          backup,
          id,
          2,
          createdAt: DateTime(2026, 1, 2, 20),
        );

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final side = plan.entries.single.imported!;
        expect(side.roundsCount, 2);
        expect(side.lastTime, DateTime(2026, 1, 2, 20));
        expect(side.rounds.map((r) => r.roundIndex), [1, 2]);
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('建议决策：默认保留最后更新较新的一侧', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokId = await _addBook(local, 'A');
        await _addRound(local, lokId, 1, createdAt: DateTime(2026, 1, 1));
        final bakId = await _addBook(backup, 'A');
        await _addRound(backup, bakId, 1, createdAt: DateTime(2026, 2, 1));

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(
          plan.entries.single.suggestedDecision,
          MergeBookDecision.keepImported,
        );
        // 内容部件按"最后更新较新的一侧"建议导入；设置部件默认保留本地。
        expect(plan.entries.single.suggestedContent, MergePartChoice.import);
        expect(plan.entries.single.suggestedSettings, MergePartChoice.keepLocal);
        expect(plan.entries.single.contentConflict, isTrue);
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('建议决策：时间相同/未知默认采用导入（轮次比对相等时优先导入）', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        // 制造真冲突但轮次时间相同、数量相同的书（轮次内容不同）。
        final lokId = await _addBook(local, 'A');
        await _addRound(local, lokId, 1, userInput: '本地', createdAt: DateTime(2026, 1, 1));
        final bakId = await _addBook(backup, 'A');
        await _addRound(backup, bakId, 1, userInput: '备份', createdAt: DateTime(2026, 1, 1));

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(
          plan.entries.single.suggestedDecision,
          MergeBookDecision.keepLocal,
        );
        expect(plan.entries.single.suggestedContent, MergePartChoice.import,
            reason: '轮次时间/数量相同 → 内容部件优先采用导入');
        expect(plan.entries.single.suggestedSettings, MergePartChoice.keepLocal);
      } finally {
        await local.close();
        await backup.close();
      }
    });
  });

  group('DatabaseMergeService.applyPlan（部件级）', () {
    test('冲突书双部件采用导入 → 就地替换设置与内容（保留本地行 id）', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokId = await _addBook(local, 'A', category: '旧');
        await _addRound(local, lokId, 1, userInput: '本地');
        await local.insert('mods', {'name': '本地Mod'});

        final bakId = await _addBook(backup, 'A', category: '新');
        await _addRound(backup, bakId, 1, userInput: '备份');
        await backup.insert('world_book_entries', {
          'book_id': bakId,
          'keyword': 'k1',
          'content': '云端词条',
        });
        final backupModId = await backup.insert('mods', {'name': '云端Mod'});
        await backup.insert('book_mods', {
          'book_id': bakId,
          'mod_id': backupModId,
          'preset_key': 'p1',
          'sort_order': 0,
          'is_enabled': 1,
        });

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final result = await DatabaseMergeService.applyPlan(
          local,
          plan,
          {plan.entries.single.title: const BookPartDecisions(settings: MergePartChoice.import, content: MergePartChoice.import)},
          const {},
        );

        expect(result.booksReplaced, 1);
        expect(result.booksAdded, 0, reason: '部件级就地更新，不删除重建');
        expect(result.roundsAdded, 1);
        expect(result.worldBookAdded, 1);
        expect(result.bookModsAdded, 1);

        final books = await local.query('books');
        expect(books, hasLength(1));
        expect(books.single['category'], '新');
        final rounds = await local.query('rounds');
        expect(rounds, hasLength(1));
        expect(rounds.single['user_input'], '备份');
        final wb = await local.query('world_book_entries');
        expect(wb, hasLength(1));
        expect(wb.single['keyword'], 'k1');
        final mods = await local.query('mods');
        expect(mods, hasLength(2));
        final cloudMod = mods.firstWhere((m) => m['name'] == '云端Mod');
        final bookMods = await local.query('book_mods');
        expect(bookMods, hasLength(1));
        expect(bookMods.single['mod_id'], cloudMod['id']);
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('冲突书保留本地 → 本地不变', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokId = await _addBook(local, 'A');
        await _addRound(local, lokId, 1, userInput: '本地');
        await _addBook(backup, 'A');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final result = await DatabaseMergeService.applyPlan(
          local,
          plan,
          {plan.entries.single.title: const BookPartDecisions(settings: MergePartChoice.keepLocal, content: MergePartChoice.keepLocal)},
          const {},
        );

        expect(result.isEmpty, isTrue);
        expect(result.booksSkipped, 1);
        final rounds = await local.query('rounds');
        expect(rounds.single['user_input'], '本地');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('仅导入有：始终导入，不提供取消', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final id = await _addBook(backup, '新书');
        await _addRound(backup, id, 1, userInput: '云端正文');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final entry = plan.entries.single;
        expect(entry.status, MergeBookStatus.importOnly);
        expect(entry.suggestedDecision, MergeBookDecision.keepImported);

        await DatabaseMergeService.applyPlan(
          local,
          plan,
          {entry.title: const BookPartDecisions(settings: MergePartChoice.import, content: MergePartChoice.import)},
          const {},
        );
        final localBooks = await local.query('books');
        expect(localBooks, hasLength(1));
        final localRounds = await local.query('rounds');
        expect(localRounds.single['user_input'], '云端正文');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('仅本地有 / 全一致：保持不变', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await _addBook(local, '仅本地书');
        // 全一致：两侧相同。
        final lokId = await _addBook(local, '一致书', category: '同');
        await _addRound(local, lokId, 1, userInput: '正文');
        final bakId = await _addBook(backup, '一致书', category: '同');
        await _addRound(backup, bakId, 1, userInput: '正文');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final result = await DatabaseMergeService.applyPlan(
          local,
          plan,
          {
            for (final e in plan.entries) e.title: BookPartDecisions(settings: e.suggestedSettings, content: e.suggestedContent),
          },
          const {},
        );
        expect(result.isEmpty, isTrue);
        expect(await local.query('books'), hasLength(2));
      } finally {
        await local.close();
        await backup.close();
      }
    });
  });

  group('DatabaseMergeService.buildPlan（Mod）', () {
    test('Mod 分类：冲突 / 仅导入有 / 仅本地有 / 两者全一致', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await local.insert('mods', {'name': 'M', 'description': '本地'});
        await backup.insert('mods', {'name': 'M', 'description': '云端'});
        await backup.insert('mods', {'name': '云Mod'});
        await local.insert('mods', {'name': '本地Mod'});
        await local.insert('mods', {'name': '同', 'description': 'x'});
        await backup.insert('mods', {'name': '同', 'description': 'x'});

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(plan.modConflictCount, 1);
        expect(plan.modImportOnlyCount, 1);
        expect(plan.modLocalOnlyCount, 1);
        expect(plan.modIdenticalCount, 1);
        final byName = {for (final m in plan.modEntries) m.name: m.status};
        expect(byName['M'], ModMergeStatus.conflict);
        expect(byName['云Mod'], ModMergeStatus.importOnly);
        expect(byName['本地Mod'], ModMergeStatus.localOnly);
        expect(byName['同'], ModMergeStatus.identical);
        // Mod 无时间可对比，冲突默认保留导入。
        expect(
          plan.modEntries.firstWhere((m) => m.name == 'M').defaultDecision,
          ModMergeDecision.import,
        );
      } finally {
        await local.close();
        await backup.close();
      }
    });
  });

  group('DatabaseMergeService.applyPlan（Mod）', () {
    test('冲突 Mod 默认导入：用导入内容覆盖本地同名 Mod', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await local.insert('mods', {'name': 'M', 'description': '本地描述'});
        await backup.insert('mods', {'name': 'M', 'description': '云端描述'});

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final result = await DatabaseMergeService.applyPlan(
          local,
          plan,
          const {},
          const {},
        );

        expect(result.modsReplaced, 1);
        final mods = await local.query('mods');
        expect(mods, hasLength(1));
        expect(mods.single['description'], '云端描述');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('冲突 Mod 重命名：另存为「{原名} - 导入」，本地同名 Mod 保留', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await local.insert('mods', {'name': 'M', 'description': '本地'});
        await backup.insert('mods', {'name': 'M', 'description': '云端'});

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final result = await DatabaseMergeService.applyPlan(
          local,
          plan,
          const {},
          {'M': ModMergeDecision.rename},
        );

        expect(result.modsRenamed, 1);
        final mods = await local.query('mods');
        expect(mods, hasLength(2));
        expect(mods.map((m) => m['name']).toSet(), {'M', 'M - 导入'});
        final renamed = mods.firstWhere((m) => m['name'] == 'M - 导入');
        expect(renamed['description'], '云端');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('冲突 Mod 保留本地：本地不变', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await local.insert('mods', {'name': 'M', 'description': '本地'});
        await backup.insert('mods', {'name': 'M', 'description': '云端'});

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final result = await DatabaseMergeService.applyPlan(
          local,
          plan,
          const {},
          {'M': ModMergeDecision.keepLocal},
        );

        expect(result.isEmpty, isTrue);
        final mods = await local.query('mods');
        expect(mods.single['description'], '本地');
      } finally {
        await local.close();
        await backup.close();
      }
    });
  });
}

Future<int> _addBook(
  Database db,
  String title, {
  String category = '',
  String baseSetting = '',
}) {
  return db.insert('books', {
    'title': title,
    'category': category,
    'base_setting': baseSetting,
  });
}

Future<int> _addRound(
  Database db,
  int bookId,
  int roundIndex, {
  String userInput = '',
  String aiNarrative = '',
  DateTime? createdAt,
}) {
  return db.insert('rounds', {
    'book_id': bookId,
    'round_index': roundIndex,
    'user_input': userInput,
    'ai_narrative': aiNarrative,
    'created_at': createdAt?.toIso8601String(),
  });
}
