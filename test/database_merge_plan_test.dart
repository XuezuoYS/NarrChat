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

        var plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(
          plan.entries.single.suggestedDecision,
          MergeBookDecision.keepImported,
        );
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('建议决策：时间相同/未知默认保留本地', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await _addBook(local, 'A');
        await _addBook(backup, 'A');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(
          plan.entries.single.suggestedDecision,
          MergeBookDecision.keepLocal,
        );
      } finally {
        await local.close();
        await backup.close();
      }
    });
  });

  group('DatabaseMergeService.applyPlan', () {
    test('冲突书保留导入 → 整本替换（设置/轮次/世界书/Mod 并集映射）', () async {
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
          {plan.entries.single.title: MergeBookDecision.keepImported},
        );

        expect(result.booksReplaced, 1);
        expect(result.booksAdded, 1);
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
          {plan.entries.single.title: MergeBookDecision.keepLocal},
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
          {entry.title: MergeBookDecision.keepImported},
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
            for (final e in plan.entries) e.title: e.suggestedDecision,
          },
        );
        expect(result.isEmpty, isTrue);
        expect(await local.query('books'), hasLength(2));
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
