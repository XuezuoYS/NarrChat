import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_db.dart';
import 'package:narrchat/database/cache_store.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/database/library_store.dart';
import 'package:narrchat/database/migration/migration_paths.dart';
import 'package:narrchat/database/migration/migration_state.dart';
import 'package:narrchat/database/migration/r2_to_v3.dart';
import 'package:narrchat/database/mods_store.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/services/round_tree.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// R2 → R3 迁移回归测试。
///
/// 旧库直接用真实 R2 DDL（`DatabaseHelper.openAt` 建出新装 v21 库）造数据，
/// 再跑迁移器，断言新库结构、数据与进度文件；不触碰真实用户目录。
void main() {
  final tempDirs = <Directory>[];

  late MigrationPaths paths;

  MigrationPaths makePaths() {
    final userData = Directory.systemTemp.createTempSync('v3_migrate_user_');
    final localConfig = Directory.systemTemp.createTempSync('v3_migrate_cfg_');
    tempDirs.addAll([userData, localConfig]);
    return MigrationPaths(
      userDataDir: userData.path,
      localConfigDir: localConfig.path,
    );
  }

  final fixedNow = DateTime.utc(2026, 6, 1, 12);

  setUp(() {
    paths = makePaths();
  });

  tearDownAll(() async {
    for (final dir in tempDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 清理失败不影响结论。
      }
    }
    tempDirs.clear();
  });

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 在旧库路径造一份 R2 数据。
  Future<void> seedR2({
    required List<Map<String, Object?>> books,
    List<Map<String, Object?>> mods = const [],
    List<Map<String, Object?>> rounds = const [],
    List<Map<String, Object?>> stack = const [],
    List<Map<String, Object?>> worldBook = const [],
    List<Map<String, Object?>> bookMods = const [],
  }) async {
    final db = await DatabaseHelper.openAt(paths.legacyDbPath);
    for (final row in books) {
      await db.insert('books', row);
    }
    for (final row in mods) {
      await db.insert('mods', row);
    }
    for (final row in rounds) {
      await db.insert('rounds', row);
    }
    for (final row in stack) {
      await db.insert('round_stack', row);
    }
    for (final row in worldBook) {
      await db.insert('world_book_entries', row);
    }
    for (final row in bookMods) {
      await db.insert('book_mods', row);
    }
    await db.close();
  }

  Map<String, Object?> bookRow(
    String uuid, {
    String title = '书',
    String? failedInput,
    String? failedMessage,
  }) {
    return {
      'uuid': uuid,
      'title': title,
      'category': '分类',
      'base_setting': '设定',
      'history_rounds': 4,
      'memory_summary_rounds': 2,
      'settings_updated_at': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      'rounds_updated_at': DateTime.utc(2026, 1, 2).millisecondsSinceEpoch,
      'failed_user_input': failedInput ?? '',
      'failed_error_message': failedMessage ?? '',
      'failed_user_images': '[]',
    };
  }

  Map<String, Object?> roundRow(
    String bookUuid,
    int index, {
    String input = '',
    String narrative = '',
    String useStackUuid = '',
    String? createdAt,
    String userImages = '[]',
  }) {
    return {
      'book_uuid': bookUuid,
      'round_index': index,
      'user_input': input,
      'ai_narrative': narrative,
      'user_images': userImages,
      'ai_images': '[]',
      'cached_tokens_in': 7,
      'created_at': createdAt ?? '2026-01-0${index.clamp(1, 9)}T00:00:00.000Z',
      'use_stack_uuid': useStackUuid,
    };
  }

  Map<String, Object?> stackRow(
    String uuid,
    String bookUuid,
    int index, {
    String? father,
    int serial = 1,
    String? state,
    String? message,
    String? messageStatus,
  }) {
    return {
      'uuid': uuid,
      'book_uuid': bookUuid,
      'father_uuid': father,
      'round_index': index,
      'round_serial_num': serial,
      'round_state': state,
      'round_created_at': DateTime.utc(2026, 1, index).millisecondsSinceEpoch,
      'user_input': '输入-$uuid',
      'ai_narrative': '正文-$uuid',
      'message': message ?? '',
      'message_status': messageStatus ?? '',
    };
  }

  test('完整迁移：目录 / Mod / 轮次树 / 世界书 / 启用 Mod / 缓存 / 进度', () async {
    await seedR2(
      books: [bookRow('b1', title: '测试书')],
      mods: [
        {
          'uuid': 'm1',
          'name': '自定义 Mod',
          'description': '说明',
          'pre_prompt': '前置',
          'post_prompt': '后置',
          'system_prompt': '系统',
          'world_book': '[]',
          'created_at': '2026-01-01T00:00:00.000Z',
          'updated_at': '2026-01-02T00:00:00.000Z',
        },
      ],
      rounds: [
        roundRow('b1', 1, input: '问一', narrative: '答一', useStackUuid: 'g1'),
        roundRow(
          'b1',
          2,
          input: '问二',
          narrative: '答二',
          useStackUuid: 'g2',
          userImages: '["img/a.png"]',
        ),
      ],
      stack: [
        stackRow('g1', 'b1', 1),
        stackRow('g2', 'b1', 2, father: 'g1'),
        stackRow('g2b', 'b1', 2, father: 'g1', serial: 2),
        stackRow('g2c', 'b1', 2, father: 'g1', serial: 3),
      ],
      worldBook: [
        {
          'book_uuid': 'b1',
          'keyword': '龙、蛇',
          'content': '爬行类',
          'is_active': 1,
          'created_at': '2026-01-01T00:00:00.000Z',
          'updated_at': 0,
        },
        {
          'book_uuid': 'b1',
          'keyword': '凤',
          'content': '鸟类',
          'is_active': 0,
          'created_at': '2026-01-02T00:00:00.000Z',
          'updated_at': 0,
        },
      ],
      bookMods: [
        {
          'book_uuid': 'b1',
          'preset_key': 'wuxia',
          'mod_uuid': null,
          'sort_order': 0,
          'is_enabled': 1,
        },
        {
          'book_uuid': 'b1',
          'preset_key': null,
          'mod_uuid': 'm1',
          'sort_order': 1,
          'is_enabled': 1,
        },
        {
          'book_uuid': 'b1',
          'preset_key': null,
          'mod_uuid': 'm1',
          'sort_order': 2,
          'is_enabled': 0,
        },
      ],
    );

    final report = await R2ToR3Migrator(paths: paths, clock: () => fixedNow).run();

    expect(report.alreadyDone, isFalse);
    expect(report.freshInstall, isFalse);
    expect(report.migratedBooks, 1);
    expect(report.failedBooks, isEmpty);
    expect(report.masterUuid, isNotEmpty);

    // 旧库改名留档，原文件消失
    expect(await File(paths.legacyDbPath).exists(), isFalse);
    expect(await File(paths.backupPath).exists(), isTrue);

    // 目录库
    final library = LibraryDb(pathOverride: paths.libraryDbPath);
    final libraryBooks = await library.books();
    expect(libraryBooks.single.bookUuid, 'b1');
    expect(libraryBooks.single.title, '测试书');
    expect(await library.masterUuid(), report.masterUuid);
    await library.close();

    // Mod 库
    final mods = ModsDb(pathOverride: paths.modsDbPath);
    final mod = (await mods.list()).single;
    expect(mod.uuid, 'm1');
    expect(mod.name, '自定义 Mod');
    expect(mod.prePrompt, '前置');
    expect(await mods.masterUuid(), report.masterUuid);
    await mods.close();

    // 书库
    final book = await BookDb.open(
      bookUuid: 'b1',
      pathOverride: paths.bookDbPath('b1'),
    );
    final meta = await book.meta.read();
    expect(meta.title, '测试书');
    expect(meta.category, '分类');
    expect(meta.baseSetting, '设定');
    expect(meta.historyRounds, 4);
    expect(meta.memorySummaryRounds, 2);
    expect(meta.masterUuid, report.masterUuid);
    expect(meta.createdAt, DateTime.utc(2026, 1, 1));

    final metas = await book.rounds.listMeta();
    final chain = RoundTree.planChain(metas, '');
    expect(chain.map((e) => e.uuid), ['g1', 'g2'], reason: '活动链跟着 is_using 走');
    expect(chain.map((e) => e.roundIndex), [1, 2]);

    // 第 2 轮一共 3 代，其它两代是历史
    expect(metas.where((m) => m.roundIndex == 2).length, 3);
    expect(metas.where((m) => m.isUsing).map((m) => m.uuid).toSet(), {'g1', 'g2'});

    // 内容取 rounds（读权威），不是 round_stack
    final gen2 = (await book.rounds.generation('g2'))!;
    expect(gen2.userInput, '问二');
    expect(gen2.aiNarrative, '答二');
    expect(gen2.tokensCachedIn, 7);
    expect(gen2.userImages, ['img/a.png']);

    // 历史代的内容取自身
    final history = (await book.rounds.generation('g2b'))!;
    expect(history.aiNarrative, '正文-g2b');
    expect(history.fatherUuid, 'g1');

    // 世界书：uuid 由旧 id 确定性推导，启用状态保留
    final worldBook = await book.worldBook.list();
    expect(worldBook.length, 2);
    expect(worldBook.first.keywords, ['龙', '蛇']);
    expect(worldBook.first.isUsing, isTrue);
    expect(worldBook.last.isUsing, isFalse);

    // 启用 Mod：预置统一成 preset::<id>，重复项只留一条
    final useMods = await book.useMods.list();
    expect(useMods.map((e) => e.modUuid), ['preset::wuxia', 'm1']);
    expect(useMods.map((e) => e.sortOrder), [0, 1]);
    await book.close();

    // 缓存库
    final cache = CacheDb(pathOverride: paths.cacheDbPath);
    final index = (await cache.allIndex()).single;
    expect(index.bookUuid, 'b1');
    expect(index.title, '测试书');
    expect(index.dbMtimeMs, greaterThan(0));
    final refs = await cache.imageRefsOf('b1');
    expect(refs.single.imagePath, 'img/a.png');
    expect(refs.single.refCount, 1);
    await cache.close();

    // 进度
    final state = (await MigrationState.read(File(paths.statePath)))!;
    expect(state.done, isTrue);
    expect(state.migratedBooks, {'b1'});
    expect(state.masterUuid, report.masterUuid);
  });

  test('幂等：迁移完成后再跑一次什么都不做', () async {
    await seedR2(
      books: [bookRow('b1')],
      rounds: [roundRow('b1', 1, useStackUuid: 'g1')],
      stack: [stackRow('g1', 'b1', 1)],
    );

    final first = await R2ToR3Migrator(paths: paths, clock: () => fixedNow).run();
    expect(first.migratedBooks, 1);

    final bookFile = File(paths.bookDbPath('b1'));
    final firstBytes = await bookFile.length();

    final second = await R2ToR3Migrator(paths: paths, clock: () => fixedNow).run();
    expect(second.alreadyDone, isTrue);
    expect(second.migratedBooks, 0);
    expect(await bookFile.length(), firstBytes);
  });

  test('续跑：进度里已完成的书跳过，未完成的补上', () async {
    await seedR2(
      books: [bookRow('b1'), bookRow('b2')],
      rounds: [
        roundRow('b1', 1, useStackUuid: 'g1'),
        roundRow('b2', 1, useStackUuid: 'h1'),
      ],
      stack: [
        stackRow('g1', 'b1', 1),
        stackRow('h1', 'b2', 1),
      ],
    );

    // 先只迁 b1：伪造"上次迁到一半"的现场
    final first = await R2ToR3Migrator(paths: paths, clock: () => fixedNow).run();
    expect(first.migratedBooks, 2);

    // 回滚进度文件到「只完成 b1」
    final stateFile = File(paths.statePath);
    await MigrationState.write(
      stateFile,
      MigrationState(
        masterUuid: first.masterUuid,
        migratedBooks: const {'b1'},
        failedBooks: const {},
      ),
    );

    final second = await R2ToR3Migrator(paths: paths, clock: () => fixedNow).run();
    expect(second.skippedBooks, 1, reason: 'b1 已完成且文件在');
    expect(second.migratedBooks, 1, reason: 'b2 重新迁');
    expect(second.masterUuid, first.masterUuid, reason: 'master_uuid 不能换');
  });

  test('降级残留：备份还在又冒出 narrchat.db，改名留证不迁移', () async {
    await seedR2(
      books: [bookRow('b1')],
      rounds: [roundRow('b1', 1, useStackUuid: 'g1')],
      stack: [stackRow('g1', 'b1', 1)],
    );
    // 先人为造出「已有 .r2.bak」的局面
    await File(paths.legacyDbPath).rename(paths.backupPath);
    // 再让 narrchat.db 冒出来（模拟降级期间旧版本写入）
    final db = await DatabaseHelper.openAt(paths.legacyDbPath);
    await db.insert('books', bookRow('ghost'));
    await db.close();

    final report = await R2ToR3Migrator(paths: paths, clock: () => fixedNow).run();
    expect(report.migratedBooks, 1, reason: '只迁移 .r2.bak 里的 b1');
    expect(await File(paths.legacyDbPath).exists(), isFalse);
    expect(await File(paths.downgradePath).exists(), isTrue);

    final library = LibraryDb(pathOverride: paths.libraryDbPath);
    expect((await library.books()).map((b) => b.bookUuid), ['b1']);
    await library.close();
  });

  test('全新安装：没有旧库时只写完成标记', () async {
    final report = await R2ToR3Migrator(paths: paths, clock: () => fixedNow).run();
    expect(report.freshInstall, isTrue);
    expect(report.migratedBooks, 0);
    final state = (await MigrationState.read(File(paths.statePath)))!;
    expect(state.done, isTrue);
    expect(state.masterUuid, isEmpty, reason: '全新安装的 master_uuid 由 library 首次打开时生成');
  });

  test('单本失败不影响其它书，并记账', () async {
    await seedR2(
      books: [bookRow('bad/uuid'), bookRow('b2')],
      rounds: [roundRow('b2', 1, useStackUuid: 'h1')],
      stack: [stackRow('h1', 'b2', 1)],
    );

    final report = await R2ToR3Migrator(paths: paths, clock: () => fixedNow).run();
    expect(report.migratedBooks, 1);
    expect(report.failedBooks.keys, ['bad/uuid']);
    expect(await File(paths.bookDbPath('b2')).exists(), isTrue);

    final state = (await MigrationState.read(File(paths.statePath)))!;
    expect(state.done, isTrue);
    expect(state.failedBooks.keys, ['bad/uuid']);
  });

  test('旧库版本高于本版支持范围时拒绝迁移', () async {
    await seedR2(books: []);
    final db = await databaseFactory.openDatabase(paths.legacyDbPath);
    await db.execute('PRAGMA user_version = 99');
    await db.close();

    await expectLater(
      R2ToR3Migrator(paths: paths, clock: () => fixedNow).run(),
      throwsA(isA<StateError>()),
    );
  });

  group('buildGenerationsFromLegacy', () {
    test('锚点缺失时按组内序号合成一代，父代接上一轮', () {
      final generations = buildGenerationsFromLegacy(
        bookUuid: 'b1',
        roundRows: [
          roundRow('b1', 1, useStackUuid: 'g1', narrative: '答一'),
          roundRow('b1', 2, useStackUuid: 'missing', narrative: '答二'),
        ],
        stackRows: [stackRow('g1', 'b1', 1)],
        bookRow: bookRow('b1'),
        now: fixedNow,
      );
      expect(generations.length, 2);
      expect(generations[0].uuid, 'g1');
      expect(generations[1].aiNarrative, '答二');
      expect(generations[1].fatherUuid, 'g1');
      expect(generations[1].roundSerialNum, 1);
      expect(generations[1].isUsing, isTrue);
    });

    test('失败占位代转成 error 代，并从 books.failed_* 补回输入', () {
      final generations = buildGenerationsFromLegacy(
        bookUuid: 'b1',
        roundRows: [roundRow('b1', 1, useStackUuid: 'g1')],
        stackRows: [
          stackRow('g1', 'b1', 1),
          stackRow('f1', 'b1', 2, father: 'g1', state: 'failed', message: '超时'),
        ],
        bookRow: bookRow('b1', failedInput: '失败输入', failedMessage: '超时'),
        now: fixedNow,
      );
      final error = generations.firstWhere((g) => g.uuid == 'f1');
      expect(error.isUsing, isTrue);
      expect(error.meta.effectiveMessageStatus, RoundMessageStatus.error);
      expect(error.meta.message, '超时');
      expect(error.userInput, '失败输入');
      expect(error.fatherUuid, 'g1');
    });

    test('只有 books.failed_* 时补一代 error，轮号接在最后一轮之后', () {
      final generations = buildGenerationsFromLegacy(
        bookUuid: 'b1',
        roundRows: [roundRow('b1', 3, useStackUuid: 'g3')],
        stackRows: [stackRow('g3', 'b1', 3)],
        bookRow: bookRow('b1', failedInput: '再试一次', failedMessage: ''),
        now: fixedNow,
      );
      final error = generations.last;
      expect(error.roundIndex, 4);
      expect(error.meta.message, '已中断');
      expect(error.userInput, '再试一次');
      expect(error.fatherUuid, 'g3');
    });

    test('没有失败记录时不造假代', () {
      final generations = buildGenerationsFromLegacy(
        bookUuid: 'b1',
        roundRows: [roundRow('b1', 1, useStackUuid: 'g1')],
        stackRows: [stackRow('g1', 'b1', 1)],
        bookRow: bookRow('b1'),
        now: fixedNow,
      );
      expect(generations.length, 1);
      expect(generations.single.meta.effectiveMessageStatus, RoundMessageStatus.info);
    });

    test('轮号断裂也按父指针接上', () {
      final generations = buildGenerationsFromLegacy(
        bookUuid: 'b1',
        roundRows: [
          roundRow('b1', 1, useStackUuid: 'g1'),
          roundRow('b1', 50, useStackUuid: 'g50'),
        ],
        stackRows: [
          stackRow('g1', 'b1', 1),
          stackRow('g50', 'b1', 50, father: 'g1'),
        ],
        bookRow: bookRow('b1'),
        now: fixedNow,
      );
      expect(generations.length, 2);
      expect(generations.last.roundIndex, 50);
      expect(generations.last.fatherUuid, 'g1');
    });
  });
}
