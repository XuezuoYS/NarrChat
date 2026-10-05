import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/database_merge_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/merge_db.dart';

void main() {
  group('DatabaseMergeService.buildPlan', () {
    test('同名书轮次内容不同 → 冲突', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokUuid = await _addBook(local, 'lok-a', 'A', category: '本地');
        await _addRound(local, lokUuid, 1, userInput: '本地');
        final bakUuid = await _addBook(backup, 'bak-a', 'A', category: '备份');
        await _addRound(backup, bakUuid, 1, userInput: '备份');

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
        final lokUuid = await _addBook(local, 'lok-a', 'A', category: '旧');
        await _addRound(local, lokUuid, 1, userInput: '正文');
        final bakUuid = await _addBook(backup, 'bak-a', 'A', category: '新');
        await _addRound(backup, bakUuid, 1, userInput: '正文');

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
        final lokUuid = await _addBook(local, 'lok-a', 'A', category: '同');
        await _addRound(local, lokUuid, 1, userInput: '正文');
        final bakUuid = await _addBook(backup, 'bak-a', 'A', category: '同');
        await _addRound(backup, bakUuid, 1, userInput: '正文');

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
        await _addBook(backup, 'bak-cloud', '云端书');
        await _addBook(local, 'lok-local', '本地书');

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
        final uuid = await _addBook(backup, 'bak-b', 'B');
        await _addRound(
          backup,
          uuid,
          1,
          createdAt: DateTime(2026, 1, 1, 8),
        );
        await _addRound(
          backup,
          uuid,
          2,
          createdAt: DateTime(2026, 1, 2, 20),
        );

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final side = plan.entries.single.imported!;
        expect(side.roundsCount, 2);
        expect(side.lastTime, DateTime(2026, 1, 2, 20));
        expect(side.rounds.map((r) => r.roundIndex), [1, 2]);
        expect(side.dbUuid, 'bak-b', reason: '快照直接携带书籍 uuid（不再有本地行号）');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('元数据：设置/内容写时间戳从书籍行解析，未设置为 0', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await _addBook(backup, 'bak-t', 'T',
            settingsUpdatedAt: 1111, roundsUpdatedAt: 2222);
        await _addBook(backup, 'bak-u', 'U');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final sideT = plan.entries.firstWhere((e) => e.title == 'T').imported!;
        expect(sideT.settingsUpdatedAt, 1111);
        expect(sideT.roundsUpdatedAt, 2222);
        final sideU = plan.entries.firstWhere((e) => e.title == 'U').imported!;
        expect(sideU.settingsUpdatedAt, 0,
            reason: '未写入时间戳列 → 按未记录处理（0）');
        expect(sideU.roundsUpdatedAt, 0);
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('建议决策：默认保留最后更新较新的一侧', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokUuid = await _addBook(local, 'lok-a', 'A');
        await _addRound(local, lokUuid, 1, createdAt: DateTime(2026, 1, 1));
        final bakUuid = await _addBook(backup, 'bak-a', 'A');
        await _addRound(backup, bakUuid, 1, createdAt: DateTime(2026, 2, 1));

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(
          plan.entries.single.suggestedDecision,
          MergeBookDecision.keepImported,
        );
        // 内容部件按"最后更新较新的一侧"建议导入；设置部件两侧时间均为 0
        // （持平/未记录）→ 同样默认采用导入。
        expect(plan.entries.single.suggestedContent, MergePartChoice.import);
        expect(plan.entries.single.suggestedSettings, MergePartChoice.import);
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
        final lokUuid = await _addBook(local, 'lok-a', 'A');
        await _addRound(local, lokUuid, 1, userInput: '本地', createdAt: DateTime(2026, 1, 1));
        final bakUuid = await _addBook(backup, 'bak-a', 'A');
        await _addRound(backup, bakUuid, 1, userInput: '备份', createdAt: DateTime(2026, 1, 1));

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(
          plan.entries.single.suggestedDecision,
          MergeBookDecision.keepImported,
          reason: '两侧轮次时间相同（持平）→ 整书默认采用导入',
        );
        expect(plan.entries.single.suggestedContent, MergePartChoice.import,
            reason: '轮次时间/数量相同 → 内容部件优先采用导入');
        expect(plan.entries.single.suggestedSettings, MergePartChoice.import,
            reason: '设置时间均为 0（持平/未记录）→ 设置部件优先采用导入');
      } finally {
        await local.close();
        await backup.close();
      }
    });
  });

  group('DatabaseMergeService.applyPlan（部件级）', () {
    test('冲突书双部件采用导入 → 就地替换设置与内容（保留本地书 uuid）', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokUuid = await _addBook(local, 'lok-a', 'A', category: '旧');
        await _addRound(local, lokUuid, 1, userInput: '本地');
        await _addMod(local, 'lok-m', '本地Mod');

        final bakUuid = await _addBook(backup, 'bak-a', 'A', category: '新');
        await _addRound(backup, bakUuid, 1, userInput: '备份');
        await backup.insert('world_book_entries', {
          'book_uuid': bakUuid,
          'keyword': 'k1',
          'content': '云端词条',
        });
        final backupModUuid = await _addMod(backup, 'bak-m', '云端Mod');
        await backup.insert('book_mods', {
          'book_uuid': bakUuid,
          'mod_uuid': backupModUuid,
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
        expect(books.single['uuid'], lokUuid, reason: '同名书合并保留本地 uuid（uuid 即身份）');
        expect(books.single['category'], '新');
        final rounds = await local.query('rounds');
        expect(rounds, hasLength(1));
        expect(rounds.single['user_input'], '备份');
        expect(rounds.single['book_uuid'], lokUuid, reason: '导入轮次挂到本地书 uuid 下');
        final wb = await local.query('world_book_entries');
        expect(wb, hasLength(1));
        expect(wb.single['keyword'], 'k1');
        expect(wb.single['book_uuid'], lokUuid);
        final mods = await local.query('mods');
        expect(mods, hasLength(2));
        final cloudMod = mods.firstWhere((m) => m['name'] == '云端Mod');
        expect(cloudMod['uuid'], backupModUuid,
            reason: '本地无同 uuid 行 → 导入 Mod 沿用自身 uuid（身份随行迁移）');
        final bookMods = await local.query('book_mods');
        expect(bookMods, hasLength(1));
        expect(bookMods.single['book_uuid'], lokUuid);
        expect(bookMods.single['mod_uuid'], cloudMod['uuid'],
            reason: '书-Mod 关联按 uuid 落地');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('冲突书保留本地 → 本地不变', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokUuid = await _addBook(local, 'lok-a', 'A');
        await _addRound(local, lokUuid, 1, userInput: '本地');
        await _addBook(backup, 'bak-a', 'A');

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

    test('冲突书设置部件采用导入 → 本地 books.settings_updated_at 对齐导入侧', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokUuid = await _addBook(local, 'lok-a', 'A',
            category: '旧', settingsUpdatedAt: 1000);
        await _addRound(local, lokUuid, 1, userInput: '本地');
        final bakUuid = await _addBook(backup, 'bak-a', 'A',
            category: '新', settingsUpdatedAt: 5000);
        await _addRound(backup, bakUuid, 1, userInput: '备份');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        await DatabaseMergeService.applyPlan(
          local,
          plan,
          {plan.entries.single.title: const BookPartDecisions(settings: MergePartChoice.import, content: MergePartChoice.keepLocal)},
          const {},
        );

        final book = (await local.query('books')).single;
        expect(book['settings_updated_at'], 5000,
            reason: '采用导入侧设置 → 时间戳一并对齐导入侧');
        expect(book['rounds_updated_at'], 0,
            reason: '内容未采用导入 → 保持本地原值（0）');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('冲突书内容部件采用导入 → 本地 books.rounds_updated_at 对齐导入侧', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokUuid = await _addBook(local, 'lok-a', 'A',
            category: '旧', roundsUpdatedAt: 1000);
        await _addRound(local, lokUuid, 1, userInput: '本地');
        final bakUuid = await _addBook(backup, 'bak-a', 'A',
            category: '新', roundsUpdatedAt: 7000);
        await _addRound(backup, bakUuid, 1, userInput: '备份');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        await DatabaseMergeService.applyPlan(
          local,
          plan,
          {plan.entries.single.title: const BookPartDecisions(settings: MergePartChoice.keepLocal, content: MergePartChoice.import)},
          const {},
        );

        final book = (await local.query('books')).single;
        expect(book['rounds_updated_at'], 7000,
            reason: '采用导入侧轮次内容 → 时间戳一并对齐导入侧');
        expect(book['settings_updated_at'], 0,
            reason: '设置未采用导入 → 保持本地原值（0）');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('导入侧时间戳未记录（0）时保持本地原值，不降级覆盖', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokUuid = await _addBook(local, 'lok-a', 'A',
            category: '旧', settingsUpdatedAt: 1000, roundsUpdatedAt: 1000);
        await _addRound(local, lokUuid, 1, userInput: '本地');
        // 备份侧未记录任何时间戳（旧备份 / 迁移数据）。
        final bakUuid = await _addBook(backup, 'bak-a', 'A', category: '新');
        await _addRound(backup, bakUuid, 1, userInput: '备份');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        await DatabaseMergeService.applyPlan(
          local,
          plan,
          {plan.entries.single.title: const BookPartDecisions(settings: MergePartChoice.import, content: MergePartChoice.import)},
          const {},
        );

        final book = (await local.query('books')).single;
        expect(book['settings_updated_at'], 1000,
            reason: '导入侧为 0（未记录）时保持本地值，不得降级为 0');
        expect(book['rounds_updated_at'], 1000);
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('仅导入有：始终导入，不提供取消', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final uuid = await _addBook(backup, 'bak-new', '新书');
        await _addRound(backup, uuid, 1, userInput: '云端正文');

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
        expect(localBooks.single['uuid'], 'bak-new',
            reason: '身份不冲突时原样沿用导入侧 uuid');
        final localRounds = await local.query('rounds');
        expect(localRounds.single['user_input'], '云端正文');
        expect(localRounds.single['book_uuid'], 'bak-new');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('仅导入有但 uuid 撞本地既有行 → 副本另发新 uuid，本地行不被覆盖', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        // 书名不同、uuid 相同（旧数据/手工拷贝造出的身份撞车）。
        final lokUuid = await _addBook(local, 'same-uuid', '本地书', category: '本地');
        await _addRound(local, lokUuid, 1, userInput: '本地正文');
        final bakUuid = await _addBook(backup, 'same-uuid', '云端书', category: '云端');
        await _addRound(backup, bakUuid, 1, userInput: '云端正文');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(plan.localOnlyCount, 1);
        expect(plan.importOnlyCount, 1);

        await DatabaseMergeService.applyPlan(local, plan, const {}, const {});

        final books = await local.query('books');
        expect(books, hasLength(2), reason: '两本书各自独立，互不覆盖');
        expect(books.map((b) => b['uuid']).toSet(), hasLength(2),
            reason: 'uuid 唯一身份：副本必须另发新值');
        final kept = books.firstWhere((b) => b['title'] == '本地书');
        expect(kept['uuid'], lokUuid);
        expect(kept['category'], '本地', reason: '本地行原样保留');
        final copy = books.firstWhere((b) => b['title'] == '云端书');
        expect(copy['uuid'], isNot(lokUuid));
        expect(copy['category'], '云端');

        final rounds = await local.query('rounds');
        expect(rounds, hasLength(2));
        expect(
          rounds.firstWhere((r) => r['user_input'] == '本地正文')['book_uuid'],
          lokUuid,
        );
        expect(
          rounds.firstWhere((r) => r['user_input'] == '云端正文')['book_uuid'],
          copy['uuid'],
          reason: '导入轮次挂到副本自己的 uuid 下',
        );
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('仅本地有 / 全一致：保持不变', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await _addBook(local, 'lok-only', '仅本地书');
        // 全一致：两侧内容 / 设置相同（uuid 各自独立，不参与判同）。
        final lokUuid = await _addBook(local, 'lok-same', '一致书', category: '同');
        await _addRound(local, lokUuid, 1, userInput: '正文');
        final bakUuid = await _addBook(backup, 'bak-same', '一致书', category: '同');
        await _addRound(backup, bakUuid, 1, userInput: '正文');

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

  group('DatabaseMergeService 版本树（SY-8）', () {
    test('SY-8 内容部件采用导入 → 版本树随内容部件搬运（计数 + 落到本地书 uuid）', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokUuid = await _addBook(local, 'lok-a', 'A', category: '同');
        await _addRound(local, lokUuid, 1, userInput: '本地');
        await _addStackRow(local, lokUuid, 'lok-g1', serial: 1);
        final bakUuid = await _addBook(backup, 'bak-a', 'A', category: '同');
        await _addRound(backup, bakUuid, 1, userInput: '备份');
        await _addStackRow(backup, bakUuid, 'bak-g1', serial: 1, aiNarrative: '备份一代');
        await _addStackRow(backup, bakUuid, 'bak-g2', serial: 2, aiNarrative: '备份二代');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final entry = plan.entries.single;
        expect(entry.status, MergeBookStatus.conflict, reason: '轮次内容不同 → 内容部件冲突');
        expect(entry.imported!.hasRoundStack, isTrue);
        expect(entry.local!.hasRoundStack, isTrue);
        expect(entry.imported!.stackRows, hasLength(2));

        final result = await DatabaseMergeService.applyPlan(
          local,
          plan,
          {
            entry.title: const BookPartDecisions(
              settings: MergePartChoice.keepLocal,
              content: MergePartChoice.import,
            ),
          },
          const {},
        );

        expect(result.stackRowsAdded, 2, reason: '版本树行数随「内容部件采用导入」计数');
        expect(result.roundsAdded, 1);
        final stack = await local.query('round_stack', orderBy: 'round_serial_num ASC');
        expect(stack.map((r) => r['book_uuid']).toSet(), {lokUuid},
            reason: '导入的版本树挂到本地书 uuid（同名书就地合并，身份不变）');
        expect(stack.map((r) => r['uuid']).toSet(), {'bak-g1', 'bak-g2'});
        expect(stack.map((r) => r['ai_narrative']).toList(), ['备份一代', '备份二代']);
        expect(
          await local.query('round_stack',
              where: 'book_uuid = ?', whereArgs: ['lok-g1']),
          isEmpty,
          reason: '版本树整体替换：本地旧代被清掉（不是叠加）',
        );
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('SY-8 整本导入（仅导入有）→ 版本树随书搬运，本地他书版本树不受影响', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final keptUuid = await _addBook(local, 'lok-keep', '本地书');
        await _addRound(local, keptUuid, 1, userInput: '本地正文');
        await _addStackRow(local, keptUuid, 'keep-g1');

        final bakUuid = await _addBook(backup, 'bak-new', '新书');
        await _addRound(backup, bakUuid, 1, userInput: '云端正文');
        await _addStackRow(backup, bakUuid, 'new-g1', aiNarrative: '云端一代');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        expect(plan.importOnlyCount, 1);
        final result = await DatabaseMergeService.applyPlan(
          local,
          plan,
          const {},
          const {},
        );

        expect(result.booksAdded, 1);
        expect(result.stackRowsAdded, 1, reason: '整本导入同样搬运版本树并计数');
        final stack = await local.query('round_stack', orderBy: 'uuid ASC');
        expect(stack, hasLength(2));
        expect(
          stack.firstWhere((r) => r['uuid'] == 'new-g1')['book_uuid'],
          'bak-new',
          reason: '身份不冲突：沿用导入侧 uuid',
        );
        expect(
          stack.firstWhere((r) => r['uuid'] == 'keep-g1')['book_uuid'],
          keptUuid,
          reason: '本地其它书的版本树不被触碰',
        );
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('SY-8 老备份库无 round_stack 表 → 保留本地版本树（不搬运、不报错）', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb(withRoundStack: false);
      try {
        final lokUuid = await _addBook(local, 'lok-a', 'A', category: '同');
        await _addRound(local, lokUuid, 1, userInput: '本地');
        await _addStackRow(local, lokUuid, 'lok-keep', aiNarrative: '本地仅存的一代');
        final bakUuid = await _addBook(backup, 'bak-a', 'A', category: '同');
        await _addRound(backup, bakUuid, 1, userInput: '备份');

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final entry = plan.entries.single;
        expect(entry.imported!.hasRoundStack, isFalse, reason: 'v18 老备份没有该表');
        expect(entry.imported!.stackRows, isEmpty);

        final result = await DatabaseMergeService.applyPlan(
          local,
          plan,
          {
            entry.title: const BookPartDecisions(
              settings: MergePartChoice.import,
              content: MergePartChoice.import,
            ),
          },
          const {},
        );

        expect(result.roundsAdded, 1, reason: '轮次照常导入');
        expect(result.stackRowsAdded, 0, reason: '备份无该表 → 不搬运');
        final stack = await local.query('round_stack');
        expect(stack, hasLength(1), reason: '保留本地版本树，交给采纳按 rounds 收敛');
        expect(stack.single['uuid'], 'lok-keep');
        expect(stack.single['ai_narrative'], '本地仅存的一代');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('版本树代次标签：有锚点轮 → 当前代 / 最新代；无表或无锚点 → 空', () async {
      final local = await createMergeDb();
      final path = await createMergeFileDb(title: 'A', uuid: 'bak-anchor');
      final dir = Directory(p.dirname(path));
      Database? backup;
      try {
        backup = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await _addRound(backup, 'bak-anchor', 1, userInput: '导入正文');
        await _addRound(
          backup,
          'bak-anchor',
          2,
          userInput: '导入正文二',
          useStackUuid: 'anchor',
        );
        // 同一分组两代：当前代 2、最新代 5 → '第 2 代 / 最新第 5 代'。
        await _addStackRow(backup, 'bak-anchor', 'anchor', serial: 2);
        await _addStackRow(backup, 'bak-anchor', 'newest', serial: 5);

        final plan = await DatabaseMergeService.buildPlan(backup, local);
        final entry = plan.entries.single;
        expect(entry.status, MergeBookStatus.importOnly);
        expect(
          entry.imported!.versionLabel,
          '第 2 代 / 最新第 5 代',
          reason: '只读代次标签 = 最末有锚点轮的当前代 / 分组内最新代',
        );
        expect(entry.local, isNull, reason: '本地无同名书');

        // 老备份库（v18，无 round_stack 表）→ 标签为空，不报错。
        final oldPath = await createMergeFileDb(
          title: 'B',
          uuid: 'bak-old',
          withRoundStack: false,
        );
        final oldDir = Directory(p.dirname(oldPath));
        Database? oldBackup;
        try {
          oldBackup = await databaseFactoryFfi.openDatabase(
            oldPath,
            options: OpenDatabaseOptions(singleInstance: false),
          );
          await _addRound(oldBackup, 'bak-old', 1, userInput: '旧正文');
          final oldPlan = await DatabaseMergeService.buildPlan(oldBackup, local);
          final oldEntry =
              oldPlan.entries.firstWhere((e) => e.imported?.dbUuid == 'bak-old');
          expect(oldEntry.imported!.hasRoundStack, isFalse);
          expect(oldEntry.imported!.versionLabel, isEmpty,
              reason: '无版本树表 → 不显示代次，且不因缺表报错');
        } finally {
          await oldBackup?.close();
          try {
            oldDir.deleteSync(recursive: true);
          } catch (_) {
            // 忽略清理失败。
          }
        }
      } finally {
        await backup?.close();
        await local.close();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {
          // 忽略清理失败。
        }
      }
    });
  });

  group('DatabaseMergeService.buildPlan（Mod）', () {
    test('Mod 分类：冲突 / 仅导入有 / 仅本地有 / 两者全一致', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await _addMod(local, 'lok-m', 'M', description: '本地');
        await _addMod(backup, 'bak-m', 'M', description: '云端');
        await _addMod(backup, 'bak-cloud', '云Mod');
        await _addMod(local, 'lok-only', '本地Mod');
        await _addMod(local, 'lok-same', '同', description: 'x');
        await _addMod(backup, 'bak-same', '同', description: 'x');

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
        final lokModUuid = await _addMod(local, 'lok-m', 'M', description: '本地描述');
        await _addMod(backup, 'bak-m', 'M', description: '云端描述');

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
        expect(mods.single['uuid'], lokModUuid,
            reason: '同名 Mod 就地覆盖内容，身份仍是本地那个 uuid');
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('冲突 Mod 重命名：另存为「{原名} - 导入」，本地同名 Mod 保留', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        final lokModUuid = await _addMod(local, 'lok-m', 'M', description: '本地');
        final bakModUuid = await _addMod(backup, 'bak-m', 'M', description: '云端');

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
        expect(mods.map((m) => m['uuid']).toSet(), hasLength(2),
            reason: '重命名副本是独立实体，不得与本地 Mod 共用 uuid');
        final kept = mods.firstWhere((m) => m['name'] == 'M');
        expect(kept['uuid'], lokModUuid);
        expect(kept['description'], '本地', reason: '本地同名 Mod 不被覆盖');
        final renamed = mods.firstWhere((m) => m['name'] == 'M - 导入');
        expect(renamed['description'], '云端');
        expect(renamed['uuid'], bakModUuid);
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('冲突 Mod 保留本地：本地不变', () async {
      final local = await createMergeDb();
      final backup = await createMergeDb();
      try {
        await _addMod(local, 'lok-m', 'M', description: '本地');
        await _addMod(backup, 'bak-m', 'M', description: '云端');

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
        expect(mods.single['uuid'], 'lok-m');
      } finally {
        await local.close();
        await backup.close();
      }
    });
  });
}

/// 写入一本书：v16 起 uuid 即主键（无自增 id），故显式给定 uuid，返回它。
///
/// [settingsUpdatedAt] / [roundsUpdatedAt] 为同步写时间戳（books 列，epoch 毫秒），
/// 未传时不写（交列 DEFAULT 0），用于构造「设置 / 内容部件修改时间」可比较的用例。
Future<String> _addBook(
  Database db,
  String uuid,
  String title, {
  String category = '',
  String baseSetting = '',
  int? settingsUpdatedAt,
  int? roundsUpdatedAt,
}) async {
  await db.insert('books', {
    'uuid': uuid,
    'title': title,
    'category': category,
    'base_setting': baseSetting,
    'settings_updated_at': ?settingsUpdatedAt,
    'rounds_updated_at': ?roundsUpdatedAt,
  });
  return uuid;
}

/// 写入一个 Mod：同样以 uuid 为唯一身份，返回该 uuid。
Future<String> _addMod(
  Database db,
  String uuid,
  String name, {
  String description = '',
}) async {
  await db.insert('mods', {
    'uuid': uuid,
    'name': name,
    'description': description,
  });
  return uuid;
}

/// 为某本书追加一轮：轮次仍有自己的自增 id（返回它），但父书按 uuid 引用。
Future<int> _addRound(
  Database db,
  String bookUuid,
  int roundIndex, {
  String userInput = '',
  String aiNarrative = '',
  DateTime? createdAt,
  String? useStackUuid,
}) {
  return db.insert('rounds', {
    'book_uuid': bookUuid,
    'round_index': roundIndex,
    'user_input': userInput,
    'ai_narrative': aiNarrative,
    'created_at': createdAt?.toIso8601String(),
    'use_stack_uuid': useStackUuid,
  });
}

/// 为某本书追加一代版本树（`round_stack`，v19）。
///
/// [serial] = 分组内序号（同 `(book, round_index, father)` 分组内唯一）；
/// [roundIndex] 默认 1（= 最末轮，供 [RoundStackDao.versionLabel] 的锚点查找）。
Future<void> _addStackRow(
  Database db,
  String bookUuid,
  String uuid, {
  int roundIndex = 1,
  int serial = 1,
  String? fatherUuid,
  String roundState = 'use',
  String userInput = '',
  String aiNarrative = '',
}) async {
  await db.insert('round_stack', {
    'uuid': uuid,
    'book_uuid': bookUuid,
    'father_uuid': fatherUuid,
    'round_index': roundIndex,
    'round_serial_num': serial,
    'round_state': roundState,
    'round_created_at': 1000,
    'user_input': userInput,
    'ai_narrative': aiNarrative,
    'user_images': '[]',
    'ai_images': '[]',
  });
}
