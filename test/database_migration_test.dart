import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据库迁移回归测试（sqflite_common_ffi + 临时文件库，不触碰真实库）。
///
/// 背景：1.3.1 将 DB 版本升至 9（rounds 新增 `model_name`）。若用户先运行过
/// 1.3.1 再运行 1.3.0（v8），sqflite 降级仅把 `user_version` 写回 8、
/// 但**不会移除**已存在的 `model_name` 列 → 1.3.1 再次启动时迁移执行
/// `ALTER TABLE rounds ADD COLUMN model_name` 报 `duplicate column name`，
/// 整个库无法打开且每次启动都失败。
/// 修复：所有 ADD COLUMN 迁移改为先查 `PRAGMA table_info`，列已存在则跳过。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    for (final dir in _tempDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 忽略清理失败。
      }
    }
    _tempDirs.clear();
  });

  test('版本回退遗留（user_version=8 但 model_name 已存在）迁移成功且数据保留', () async {
    final path = _newDbPath();

    // 1. 创建 v8 库并写入数据。
    final db8 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 8, onCreate: _createV8Schema),
    );
    await db8.insert('books', {
      'title': '书A',
      'category': '玄幻',
      'base_setting': '基础设定',
      'writing_requirements': '文笔要求',
      'writing_style': '参考段落',
      'history_rounds': 1,
      'role_hierarchy': '主角 > 女主角',
      'role_hierarchy_detail': '[]',
    });
    await db8.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '你好',
      'ai_narrative': '正文',
      'tokens_in': 10,
      'tokens_out': 20,
      'created_at': DateTime(2026, 8, 16).toIso8601String(),
    });

    // 2. 模拟「1.3.0 打开过 v9 库被降级」的遗留状态：列已存在、user_version 仍为 8。
    await db8.execute("ALTER TABLE rounds ADD COLUMN model_name TEXT DEFAULT ''");
    await db8.close();

    // 3. 以当前版本重开（模拟 1.3.1 修复后首次启动，迁移不再抛 duplicate column）。
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    expect(await db.rawQuery('SELECT COUNT(*) AS c FROM books'), [
      {'c': 1},
    ]);
    expect(await db.rawQuery('SELECT COUNT(*) AS c FROM rounds'), [
      {'c': 1},
    ]);
    final cols = await db.rawQuery('PRAGMA table_info(rounds)');
    expect(cols.map((c) => c['name']), contains('model_name'));
    await db.close();
  });

  test('正常 v8→v9 迁移新增 model_name 列且数据保留', () async {
    final path = _newDbPath();

    final db8 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 8, onCreate: _createV8Schema),
    );
    await db8.insert('books', {
      'title': '书B',
      'category': '都市',
      'base_setting': '设定',
      'writing_requirements': '',
      'writing_style': '',
      'history_rounds': 1,
      'role_hierarchy': '',
      'role_hierarchy_detail': '',
    });
    await db8.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '继续',
      'ai_narrative': '后续正文',
      'tokens_in': 1,
      'tokens_out': 2,
    });
    await db8.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    final cols = await db.rawQuery('PRAGMA table_info(rounds)');
    expect(cols.map((c) => c['name']), contains('model_name'));
    final round = (await db.rawQuery('SELECT * FROM rounds')).first;
    expect(round['user_input'], '继续');
    expect(round['ai_narrative'], '后续正文');
    await db.close();
  });

  test('v9→v10 迁移新增 user_images / ai_images 列且数据保留', () async {
    final path = _newDbPath();

    final db9 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 8, onCreate: _createV8Schema),
    );
    // 模拟 v9：先补上 model_name 列（前一版本迁移），此时无 user_images/ai_images。
    await db9.execute(
      "ALTER TABLE rounds ADD COLUMN model_name TEXT DEFAULT ''",
    );
    // v16 迁移按父表 JOIN 重建子表：轮次必须有父书，否则视为孤儿被丢弃。
    await db9.insert('books', {'title': '书D'});
    await db9.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '看图',
      'ai_narrative': '正文',
      'tokens_in': 1,
      'tokens_out': 2,
      'created_at': DateTime(2026, 8, 16).toIso8601String(),
    });
    await db9.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    final cols = await db.rawQuery('PRAGMA table_info(rounds)');
    expect(cols.map((c) => c['name']), contains('user_images'));
    expect(cols.map((c) => c['name']), contains('ai_images'));
    final round = (await db.rawQuery('SELECT * FROM rounds')).first;
    expect(round['user_input'], '看图');
    expect(round['user_images'], '[]');
    expect(round['ai_images'], '[]');
    await db.close();
  });

  test('v10→v11 迁移新增 failed_user_images 列且失败条目数据保留', () async {
    final path = _newDbPath();

    final db10 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 10, onCreate: _createV10Schema),
    );
    await db10.insert('books', {
      'title': '书E',
      'category': '玄幻',
      'base_setting': '设定',
      'failed_user_input': '带图失败',
      'failed_error_message': '模拟失败',
    });
    await db10.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    final bookCols = (await db.rawQuery('PRAGMA table_info(books)'))
        .map((c) => c['name'])
        .toList();
    expect(bookCols, contains('failed_user_images'));
    final book = (await db.rawQuery('SELECT * FROM books')).first;
    expect(book['failed_user_input'], '带图失败');
    expect(book['failed_error_message'], '模拟失败');
    // 新列默认空图片数组（历史失败条目不丢数据）。
    expect(book['failed_user_images'], '[]');
    await db.close();
  });

  test('v5→当前版本全链路迁移（含 rounds 重建）成功且数据保留', () async {
    final path = _newDbPath();

    final db5 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 5, onCreate: _createV5Schema),
    );
    await db5.insert('books', {
      'title': '书C',
      'category': '仙侠',
      'base_setting': '设定',
      'writing_requirements': '要求',
      'writing_style': '',
      'history_rounds': 1,
      'role_hierarchy': '主角',
      'role_hierarchy_detail': '[]',
    });
    await db5.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '开局',
      'ai_narrative': '正文内容',
      'tokens_in': 3,
      'tokens_out': 4,
      'created_at': DateTime(2026, 8, 1).toIso8601String(),
    });
    await db5.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);

    // rounds：重建后含 model_name，且不含历史中间版本（v6/v7）的失败列。
    final roundCols = (await db.rawQuery('PRAGMA table_info(rounds)'))
        .map((c) => c['name'])
        .toList();
    expect(roundCols, contains('model_name'));
    expect(roundCols, isNot(contains('is_truncated')));
    expect(roundCols, isNot(contains('error_message')));

    // books：补齐 v3/v4/v8 列。
    final bookCols = (await db.rawQuery('PRAGMA table_info(books)'))
        .map((c) => c['name'])
        .toList();
    expect(bookCols, containsAll(['role_hierarchy_detail', 'writing_requirements', 'failed_user_input', 'failed_error_message']));

    // 数据保留。
    final round = (await db.rawQuery('SELECT * FROM rounds')).first;
    expect(round['user_input'], '开局');
    expect(round['ai_narrative'], '正文内容');
    expect(await db.rawQuery('SELECT COUNT(*) AS c FROM books'), [
      {'c': 1},
    ]);
    await db.close();
  });

  test('v11→v12 迁移新增同步列与同步辅助表且数据保留', () async {
    final path = _newDbPath();

    final db11 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 11, onCreate: _createV11Schema),
    );
    await db11.insert('books', {
      'title': '书F',
      'category': '科幻',
      'base_setting': '设定',
      'writing_requirements': '',
      'writing_style': '',
      'history_rounds': 1,
      'role_hierarchy': '主角',
      'role_hierarchy_detail': '[]',
    });
    await db11.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '开始',
      'ai_narrative': '正文',
      'tokens_in': 1,
      'tokens_out': 2,
    });
    await db11.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);

    final bookCols = (await db.rawQuery('PRAGMA table_info(books)'))
        .map((c) => c['name'])
        .toList();
    expect(bookCols, containsAll(['settings_updated_at', 'rounds_updated_at', 'deleted_at']));
    final roundCols = (await db.rawQuery('PRAGMA table_info(rounds)'))
        .map((c) => c['name'])
        .toList();
    expect(roundCols, contains('updated_at'));
    final wbCols = (await db.rawQuery('PRAGMA table_info(world_book_entries)'))
        .map((c) => c['name'])
        .toList();
    expect(wbCols, contains('updated_at'));
    final modCols = (await db.rawQuery('PRAGMA table_info(mods)'))
        .map((c) => c['name'])
        .toList();
    expect(modCols, contains('deleted_at'));

    for (final table in ['sync_state', 'sync_book_base', 'sync_mod_base']) {
      final t = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      );
      expect(t, isNotEmpty, reason: '缺少表 $table');
    }
    // 图片删除墓碑已文件化（img_tombstones.dart），不再进数据库。
    for (final table in ['sync_pending_del', 'sync_image_revived']) {
      final t = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      );
      expect(t, isEmpty, reason: '墓碑表 $table 应已移除');
    }

    final book = (await db.rawQuery('SELECT * FROM books')).first;
    expect(book['title'], '书F');
    expect(book['deleted_at'], isNull);
    await db.close();
  });

  test('v12→v13 迁移：books/mods 回填 uuid、旧同步表重建为 uuid 主键、数据保留', () async {
    final path = _newDbPath();

    final db12 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 12, onCreate: _createV12Schema),
    );
    await db12.insert('books', {
      'title': '书G',
      'category': '武侠',
      'settings_updated_at': 100,
      'rounds_updated_at': 200,
    });
    await db12.insert('mods', {'name': '风格', 'updated_at': '2026-01-01T00:00:00.000'});
    // 旧同步表（title 主键）由 _createV12Schema 预置。
    await db12.insert('sync_book_base', {
      'title': '书G',
      'settings_fp': 'S0',
      'rounds_fp': 'R1',
    });
    await db12.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);

    // uuid 回填：每行非空且为 v4 格式。
    final book = (await db.rawQuery('SELECT * FROM books')).first;
    expect(book['uuid'], isNotEmpty);
    expect(RegExp(r'^[0-9a-f-]{36}$').hasMatch(book['uuid'] as String), isTrue);
    final mod = (await db.rawQuery('SELECT * FROM mods')).first;
    expect(mod['uuid'], isNotEmpty);
    expect(mod['name'], '风格');

    // 旧同步表重建为 uuid 主键（而不是 title 主键）。
    final syncBookSql = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='sync_book_base'",
    );
    expect(
      (syncBookSql.first['sql'] as String).contains('uuid TEXT PRIMARY KEY'),
      isTrue,
      reason: '同步表主键应为 uuid',
    );
    final syncModSql = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='sync_mod_base'",
    );
    expect(
      (syncModSql.first['sql'] as String).contains('uuid TEXT PRIMARY KEY'),
      isTrue,
    );
    // v14：新装/重建的同步表带 5 个子部件列（旧表行因重建清空，属设计行为）。
    final baseCols = (await db.rawQuery('PRAGMA table_info(sync_book_base)'))
        .map((c) => c['name'])
        .toList();
    expect(baseCols, containsAll(['info_fp', 'roles_fp', 'base_setting_fp', 'prompts_fp', 'failed_fp']));
    // 数据保留。
    expect(await db.rawQuery('SELECT COUNT(*) AS c FROM books'), [
      {'c': 1},
    ]);
    await db.close();
  });

  test('v13→v14 迁移：sync_book_base 补充子部件列并从旧 settings_fp 回填', () async {
    final path = _newDbPath();

    final db13 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 13, onCreate: _createV13Schema),
    );
    await db13.insert('sync_book_base', {
      'uuid': 'u-base-1',
      'title': '书H',
      'settings_fp': 'S0',
      'rounds_fp': 'R1',
    });
    await db13.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    // 旧单值 settings_fp 回填到 5 个子部件列（整书兼容直到下次同步重写）。
    final baseRow = (await db.rawQuery('SELECT * FROM sync_book_base')).first;
    expect(baseRow['info_fp'], 'S0');
    expect(baseRow['roles_fp'], 'S0');
    expect(baseRow['base_setting_fp'], 'S0');
    expect(baseRow['prompts_fp'], 'S0');
    expect(baseRow['failed_fp'], 'S0');
    expect(baseRow['rounds_fp'], 'R1');
    await db.close();
  });

  test('修复后迁移幂等：同一列重复出现在后续版本也不会重复 ADD', () async {
    // 模拟「v9 建表但 user_version 被降回 5」的极端遗留：migrate(5, current)
    // 中途 v8 重建会丢弃 model_name，v9 再补回，整个过程不应报 duplicate column。
    final path = _newDbPath();
    final db5 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 5, onCreate: _createV5Schema),
    );
    await db5.insert('books', {'title': '书D'});
    // 预置一个已存在的 model_name 列（模拟降级遗留）。
    await db5.execute("ALTER TABLE rounds ADD COLUMN model_name TEXT DEFAULT ''");
    await db5.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);
    final roundCols = (await db.rawQuery('PRAGMA table_info(rounds)'))
        .map((c) => c['name'])
        .toList();
    expect(roundCols, contains('model_name'));
    await db.close();
  });

  test('v14→v16 迁移：移除图片删除墓碑表（图片不再走数据库）', () async {
    final path = _newDbPath();

    final db14 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 14, onCreate: _createV14Schema),
    );
    // v14 库（历史版本）预置墓碑数据与一本书；迁移后墓碑表移除、业务数据保留。
    await db14.insert('sync_pending_del', {
      'path': 'img/a.png',
      'deleted_at': 100,
    });
    await db14.insert('books', {'title': '书I'});
    await db14.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onUpgrade: DatabaseHelper.migrate,
      ),
    );
    final ver = await db.rawQuery('PRAGMA user_version');
    expect(ver.first.values.first, DatabaseHelper.currentDbVersion);

    for (final table in ['sync_pending_del', 'sync_image_revived']) {
      final t = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      );
      expect(t, isEmpty, reason: '墓碑表 $table 应已移除');
    }
    // 业务表不受影响。
    final books = await db.query('books');
    expect(books.single['title'], '书I');
    await db.close();
  });

  // ========================================================================
  // v16：books / mods 去除本地 int 主键，uuid 成为唯一身份（子表改按 uuid 引用）
  // ========================================================================

  test('v9→v16 全链路：uuid 即主键，数据全保留，无中间表残留', () async {
    final path = _newDbPath();
    final db9 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 9, onCreate: _createV9Schema),
    );
    await db9.insert('books', {
      'title': '书A',
      'category': '玄幻',
      'failed_user_input': '半截输入',
    });
    await db9.insert('books', {'title': '书B'});
    await db9.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'user_input': '你好',
      'ai_narrative': 'A 正文',
      'model_name': 'gpt-x',
      'created_at': DateTime(2026, 8, 16).toIso8601String(),
    });
    await db9.insert('rounds', {
      'book_id': 2,
      'round_index': 1,
      'user_input': '第二本',
      'ai_narrative': 'B 正文',
    });
    await db9.insert('world_book_entries', {
      'book_id': 1,
      'keyword': '张三',
      'content': '佩剑剑客',
    });
    await db9.insert('mods', {'name': '自定义 Mod', 'pre_prompt': '前置'});
    await db9.insert('book_mods', {
      'book_id': 1,
      'preset_key': 'timeline',
      'sort_order': 0,
    });
    await db9.insert('book_mods', {'book_id': 1, 'mod_id': 1, 'sort_order': 1});
    await db9.close();

    final db = await _openUpgraded(path);
    expect(
      (await db.rawQuery('PRAGMA user_version')).first.values.first,
      DatabaseHelper.currentDbVersion,
    );

    // 父表：uuid 即主键，不再存在第二个 id 列（也不新增 created_at 列）。
    final bookCols = _columnNames(await db.rawQuery('PRAGMA table_info(books)'));
    expect(bookCols, contains('uuid'));
    expect(bookCols, isNot(contains('id')));
    expect(bookCols, isNot(contains('created_at')));
    expect(
      _columnNames(await db.rawQuery('PRAGMA table_info(mods)')),
      isNot(contains('id')),
    );
    final bookSql = (await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='books'",
    )).single['sql'] as String;
    expect(bookSql, contains('uuid TEXT PRIMARY KEY'));

    // 子表：自身 int 主键保留，父引用列名换为 uuid。
    final roundCols = _columnNames(
      await db.rawQuery('PRAGMA table_info(rounds)'),
    );
    expect(roundCols, containsAll(['id', 'book_uuid']));
    expect(roundCols, isNot(contains('book_id')));

    // 业务数据：两本书 / 两条轮次 / 一条世界书 / 一条 Mod / 两条挂载。
    final books = await db.query('books', orderBy: 'title ASC');
    expect(books.map((b) => b['title']), ['书A', '书B']);
    final bookA = books.first;
    expect(bookA['uuid'], isNotEmpty);
    expect(bookA['category'], '玄幻');
    expect(bookA['failed_user_input'], '半截输入');
    final roundsA = await db.query(
      'rounds',
      where: 'book_uuid = ?',
      whereArgs: [bookA['uuid']],
    );
    expect(roundsA.single['ai_narrative'], 'A 正文');
    expect(roundsA.single['model_name'], 'gpt-x');
    expect(
      (await db.query('world_book_entries')).single['book_uuid'],
      bookA['uuid'],
    );
    final modRow = (await db.query('mods')).single;
    expect(modRow['uuid'], isNotEmpty);
    final mounts = await db.query(
      'book_mods',
      where: 'book_uuid = ?',
      whereArgs: [bookA['uuid']],
      orderBy: 'sort_order ASC',
    );
    expect(mounts, hasLength(2));
    // 预置行（旧 mod_id 为 NULL）必须保住；用户行指向该 Mod 的 uuid。
    expect(mounts.first['preset_key'], 'timeline');
    expect(mounts.first['mod_uuid'], isNull);
    expect(mounts.last['mod_uuid'], modRow['uuid']);
    // 子表自增 id 原样保留（仅本地行标识，同步从不引用）。
    expect(
      (await db.query('rounds', orderBy: 'id ASC')).map((r) => r['id']).toList(),
      [1, 2],
    );

    // 无 *_new 中间表 / 旧索引残留，外键检查干净。
    final leftovers = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE instr(name, '_new') > 0",
    );
    expect(leftovers, isEmpty);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await db.close();
  });

  test('v15→v16 预清洗：空 uuid 补发身份，重复 uuid 只留最小 id 那行的原值', () async {
    final path = _newDbPath();
    final db15 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 15, onCreate: _createV15Schema),
    );
    await db15.insert('books', {'title': '空身份', 'uuid': ''});
    await db15.insert('books', {'title': '重复甲', 'uuid': 'dup'});
    await db15.insert('books', {'title': '重复乙', 'uuid': 'dup'});
    await db15.insert('mods', {'name': 'Mod甲', 'uuid': ''});
    await db15.insert('mods', {'name': 'Mod乙', 'uuid': ''});
    await db15.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'ai_narrative': '空身份轮次',
    });
    await db15.insert('rounds', {
      'book_id': 2,
      'round_index': 1,
      'ai_narrative': '重复甲轮次',
    });
    await db15.insert('rounds', {
      'book_id': 3,
      'round_index': 1,
      'ai_narrative': '重复乙轮次',
    });
    await db15.close();

    final db = await _openUpgraded(path);
    final books = await db.query('books');
    expect(books, hasLength(3));
    final uuidByTitle = {
      for (final b in books) b['title'] as String: b['uuid'] as String,
    };
    // 非空且互不相同（uuid 即将成为主键的前提）。
    expect(uuidByTitle.values.every((u) => u.isNotEmpty), isTrue);
    expect(uuidByTitle.values.toSet(), hasLength(3));
    // 重复组保留 id 最小那行的原值，其余行另发新 uuid。
    expect(uuidByTitle['重复甲'], 'dup');
    expect(uuidByTitle['重复乙'], isNot('dup'));
    // 子行跟随各自的父书，绝不串书。
    for (final title in ['空身份', '重复甲', '重复乙']) {
      final rows = await db.query(
        'rounds',
        where: 'book_uuid = ?',
        whereArgs: [uuidByTitle[title]],
      );
      expect(rows.single['ai_narrative'], '$title轮次');
    }
    final modUuids = (await db.query('mods')).map((m) => m['uuid'] as String);
    expect(modUuids.every((u) => u.isNotEmpty), isTrue);
    expect(modUuids.toSet(), hasLength(2));
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await db.close();
  });

  test('v15→v16 外键顺序：RENAME 后外键指向 books(uuid) / mods(uuid) 且级联生效',
      () async {
    final path = _newDbPath();
    final db15 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 15, onCreate: _createV15Schema),
    );
    await db15.insert('books', {'title': '书A', 'uuid': 'u-keep'});
    await db15.insert('mods', {'name': 'ModA', 'uuid': 'm-keep'});
    await db15.insert('rounds', {'book_id': 1, 'round_index': 1});
    await db15.insert('world_book_entries', {'book_id': 1, 'keyword': 'k'});
    await db15.insert('book_mods', {'book_id': 1, 'mod_id': 1});
    await db15.close();

    final db = await _openUpgraded(path);
    // 建表时外键只能指向 books_new / mods_new（旧表 uuid 无唯一索引）；
    // RENAME 把引用改写为最终表名 + uuid 父列 —— 顺序正确性的可断言证据。
    expect(_fkTargets(await db.rawQuery('PRAGMA foreign_key_list(rounds)')), {
      'books': 'uuid',
    });
    expect(
      _fkTargets(
        await db.rawQuery('PRAGMA foreign_key_list(world_book_entries)'),
      ),
      {'books': 'uuid'},
    );
    expect(_fkTargets(await db.rawQuery('PRAGMA foreign_key_list(book_mods)')), {
      'books': 'uuid',
      'mods': 'uuid',
    });

    await db.delete('book_mods', where: 'book_uuid = ?', whereArgs: ['u-keep']);
    await db.delete('books', where: 'uuid = ?', whereArgs: ['u-keep']);
    expect(await db.query('rounds'), isEmpty, reason: '删书应级联清理轮次');
    expect(await db.query('world_book_entries'), isEmpty);
    await db.close();
  });

  test('v15→v16：父行不存在的孤儿子行随拷贝丢弃，其余数据不受影响', () async {
    final path = _newDbPath();
    final db15 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 15, onCreate: _createV15Schema),
    );
    await db15.insert('books', {'title': '活书', 'uuid': 'u-live'});
    await db15.insert('rounds', {
      'book_id': 1,
      'round_index': 1,
      'ai_narrative': '正常轮次',
    });
    // 旧库外键在部分历史版本未生效，可能留下父行不存在的孤儿行。
    await db15.insert('rounds', {
      'book_id': 99,
      'round_index': 1,
      'ai_narrative': '孤儿轮次',
    });
    await db15.insert('world_book_entries', {
      'book_id': 99,
      'keyword': '孤儿条目',
    });
    await db15.close();

    final db = await _openUpgraded(path);
    final rounds = await db.query('rounds');
    expect(rounds, hasLength(1));
    expect(rounds.single['ai_narrative'], '正常轮次');
    expect(rounds.single['book_uuid'], 'u-live');
    expect(await db.query('world_book_entries'), isEmpty);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await db.close();
  });

  test(
    'v15→v16：开发期墓碑表 sync_pending_del / sync_image_revived 无条件清除',
    () async {
      final path = _newDbPath();
      final db15 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(version: 15, onCreate: _createV15Schema),
      );
      await db15.insert('books', {'title': '书J', 'uuid': 'u-j'});
      // 异常残留：现行 schema 从不建这两张表，但历史开发构建的库里可能还在。
      // 清理并入 v16 分支后，「升到 v16 即无墓碑表」成为无条件不变量。
      await db15.execute(
        'CREATE TABLE sync_pending_del '
        '(path TEXT NOT NULL, deleted_at INTEGER NOT NULL)',
      );
      await db15.execute(
        'CREATE TABLE sync_image_revived '
        '(path TEXT NOT NULL, revived_at INTEGER NOT NULL)',
      );
      await db15.insert(
        'sync_pending_del',
        {'path': 'img/a.png', 'deleted_at': 100},
      );
      await db15.insert(
        'sync_image_revived',
        {'path': 'img/b.png', 'revived_at': 200},
      );
      expect(await _tableNames(db15), containsAll([
        'sync_pending_del',
        'sync_image_revived',
      ]));
      await db15.close();

      final db = await _openUpgraded(path);
      final tables = await _tableNames(db);
      expect(
        tables,
        isNot(contains('sync_pending_del')),
        reason: '墓碑已文件化（img_tombstones.dart），库内不应再有该表',
      );
      expect(
        tables,
        isNot(contains('sync_image_revived')),
        reason: '复活标记同样只存在于墓碑文件，不进数据库',
      );
      // 清理不影响 uuid 主键改造与业务数据。
      final book = (await db.query('books')).single;
      expect(book['uuid'], 'u-j');
      expect(book['title'], '书J');
      expect(
        _columnNames(await db.rawQuery('PRAGMA table_info(books)')),
        isNot(contains('id')),
        reason: 'books 主键即 uuid，无第二个 int id',
      );
      await db.close();
    },
  );
  test('v15→v16 迁移结果与全新安装库的业务表 DDL 一致', () async {
    final migratedPath = _newDbPath();
    final db15 = await databaseFactoryFfi.openDatabase(
      migratedPath,
      options: OpenDatabaseOptions(version: 15, onCreate: _createV15Schema),
    );
    await db15.insert('books', {'title': '书A', 'uuid': 'u-1'});
    await db15.close();
    final migrated = await _openUpgraded(migratedPath);

    // 全新安装：走生产 onCreate（DatabaseHelper 单例 + 路径覆盖）。
    final freshPath = _newDbPath();
    DatabaseHelper.debugDatabasePathOverride = freshPath;
    final fresh = await DatabaseHelper.instance.database;
    addTearDown(() async {
      DatabaseHelper.debugDatabasePathOverride = null;
      await DatabaseHelper.instance.close();
    });

    const names = [
      'books',
      'rounds',
      'world_book_entries',
      'mods',
      'book_mods',
      'idx_rounds_book_index',
      'idx_world_book_book_uuid',
      'idx_book_mods_book_uuid',
    ];
    final migratedSchema = await _businessSchema(migrated, names);
    final freshSchema = await _businessSchema(fresh, names);
    // 迁移产物不引入「第二套 schema」：归一化后与新装库完全相同。
    expect(migratedSchema.keys.toList()..sort(),
        freshSchema.keys.toList()..sort());
    for (final name in names) {
      expect(
        migratedSchema[name],
        freshSchema[name],
        reason: '$name 的 DDL 在新装库与迁移库之间不一致',
      );
    }
    await migrated.close();
  });
}

final List<Directory> _tempDirs = [];

String _newDbPath() {
  final dir = Directory.systemTemp.createTempSync('db_migration_test_');
  _tempDirs.add(dir);
  return p.join(dir.path, 'narrchat.db');
}

/// 历史 v11 schema（v10 + books.failed_user_images；尚无同步列/辅助表）。
Future<void> _createV11Schema(Database db, int version) async {
  await _createV10Schema(db, version);
  await db.execute(
    "ALTER TABLE books ADD COLUMN failed_user_images TEXT NOT NULL DEFAULT '[]'",
  );
}

/// 历史 v13 schema（uuid 主键同步表 + 单值 settings_fp；尚无 4 个子部件列）。
Future<void> _createV13Schema(Database db, int version) async {
  await _createV12Schema(db, version);
  await db.execute(
    "ALTER TABLE books ADD COLUMN uuid TEXT NOT NULL DEFAULT ''",
  );
  await db.execute(
    "ALTER TABLE mods ADD COLUMN uuid TEXT NOT NULL DEFAULT ''",
  );
  await db.execute('DROP TABLE IF EXISTS sync_book_base');
  await db.execute('DROP TABLE IF EXISTS sync_mod_base');
  await db.execute('''
    CREATE TABLE sync_book_base (
      uuid TEXT PRIMARY KEY,
      title TEXT NOT NULL DEFAULT '',
      settings_fp TEXT DEFAULT '',
      rounds_fp TEXT DEFAULT '',
      worldbook_fp TEXT DEFAULT '',
      bookmods_fp TEXT DEFAULT '',
      settings_updated_at INTEGER NOT NULL DEFAULT 0,
      rounds_updated_at INTEGER NOT NULL DEFAULT 0,
      worldbook_updated_at INTEGER NOT NULL DEFAULT 0,
      bookmods_updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_mod_base (
      uuid TEXT PRIMARY KEY,
      name TEXT NOT NULL DEFAULT '',
      fingerprint TEXT DEFAULT '',
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
}

/// 历史 v14 schema（v13 + sync_book_base 5 个子部件列；尚无 sync_image_revived）。
Future<void> _createV14Schema(Database db, int version) async {
  await _createV13Schema(db, version);
  for (final col in const ['info_fp', 'roles_fp', 'base_setting_fp', 'prompts_fp', 'failed_fp']) {
    await db.execute(
      "ALTER TABLE sync_book_base ADD COLUMN $col TEXT DEFAULT ''",
    );
  }
}

/// 历史 v12 schema（v11 + 同步列/软删墓碑 + 旧版 title 主键同步表）。
Future<void> _createV12Schema(Database db, int version) async {
  await _createV11Schema(db, version);
  await db.execute(
    'ALTER TABLE books ADD COLUMN settings_updated_at INTEGER NOT NULL DEFAULT 0',
  );
  await db.execute(
    'ALTER TABLE books ADD COLUMN rounds_updated_at INTEGER NOT NULL DEFAULT 0',
  );
  await db.execute('ALTER TABLE books ADD COLUMN deleted_at INTEGER');
  await db.execute(
    'ALTER TABLE rounds ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
  );
  await db.execute(
    'ALTER TABLE world_book_entries ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
  );
  await db.execute('ALTER TABLE mods ADD COLUMN deleted_at INTEGER');
  await db.execute('''
    CREATE TABLE sync_state (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      device_id TEXT DEFAULT '',
      last_synced_at INTEGER NOT NULL DEFAULT 0,
      last_generation INTEGER NOT NULL DEFAULT 0,
      sync_in_flight INTEGER NOT NULL DEFAULT 0,
      last_phase TEXT DEFAULT '',
      last_error TEXT DEFAULT ''
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_book_base (
      title TEXT PRIMARY KEY,
      settings_fp TEXT DEFAULT '',
      rounds_fp TEXT DEFAULT '',
      worldbook_fp TEXT DEFAULT '',
      bookmods_fp TEXT DEFAULT '',
      settings_updated_at INTEGER NOT NULL DEFAULT 0,
      rounds_updated_at INTEGER NOT NULL DEFAULT 0,
      worldbook_updated_at INTEGER NOT NULL DEFAULT 0,
      bookmods_updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_mod_base (
      name TEXT PRIMARY KEY,
      fingerprint TEXT DEFAULT '',
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_pending_del (
      path TEXT PRIMARY KEY,
      deleted_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
}

/// 历史 v10 schema（books 含 failed_user_input/error；rounds 含
/// model_name/user_images/ai_images，尚无 failed_user_images）。
Future<void> _createV10Schema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      category TEXT DEFAULT '',
      base_setting TEXT DEFAULT '',
      writing_requirements TEXT DEFAULT '',
      writing_style TEXT DEFAULT '',
      global_pre_prompt TEXT DEFAULT '',
      global_post_prompt TEXT DEFAULT '',
      history_rounds INTEGER NOT NULL DEFAULT 1,
      role_hierarchy TEXT DEFAULT '',
      role_hierarchy_detail TEXT DEFAULT '',
      failed_user_input TEXT DEFAULT '',
      failed_error_message TEXT DEFAULT ''
    )
  ''');
  await db.execute('''
    CREATE TABLE rounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      round_index INTEGER NOT NULL,
      user_input TEXT DEFAULT '',
      ai_narrative TEXT DEFAULT '',
      world_state TEXT DEFAULT '',
      character_state TEXT DEFAULT '',
      memory_summary TEXT DEFAULT '',
      current_time TEXT DEFAULT '',
      recommended_action TEXT DEFAULT '',
      tokens_in INTEGER NOT NULL DEFAULT 0,
      tokens_out INTEGER NOT NULL DEFAULT 0,
      model_name TEXT DEFAULT '',
      user_images TEXT NOT NULL DEFAULT '[]',
      ai_images TEXT NOT NULL DEFAULT '[]',
      created_at DATETIME,
      FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_rounds_book_index ON rounds (book_id, round_index)',
  );
  await _createCommonTables(db);
}

/// 历史 v8 schema（books 含 v3/v4/v8 列；rounds 不含 model_name）。
Future<void> _createV8Schema(Database db, int version) async {  await db.execute('''
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      category TEXT DEFAULT '',
      base_setting TEXT DEFAULT '',
      writing_requirements TEXT DEFAULT '',
      writing_style TEXT DEFAULT '',
      global_pre_prompt TEXT DEFAULT '',
      global_post_prompt TEXT DEFAULT '',
      history_rounds INTEGER NOT NULL DEFAULT 1,
      role_hierarchy TEXT DEFAULT '',
      role_hierarchy_detail TEXT DEFAULT '',
      failed_user_input TEXT DEFAULT '',
      failed_error_message TEXT DEFAULT ''
    )
  ''');
  await db.execute('''
    CREATE TABLE rounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      round_index INTEGER NOT NULL,
      user_input TEXT DEFAULT '',
      ai_narrative TEXT DEFAULT '',
      world_state TEXT DEFAULT '',
      character_state TEXT DEFAULT '',
      memory_summary TEXT DEFAULT '',
      current_time TEXT DEFAULT '',
      recommended_action TEXT DEFAULT '',
      tokens_in INTEGER NOT NULL DEFAULT 0,
      tokens_out INTEGER NOT NULL DEFAULT 0,
      created_at DATETIME,
      FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
    )
  ''');
  await db.execute('CREATE INDEX idx_rounds_book_index ON rounds (book_id, round_index)');
  await _createCommonTables(db);
}

/// 历史 v5 schema（books 尚无 failed_* 列；含 world_book/mods/book_mods）。
Future<void> _createV5Schema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      category TEXT DEFAULT '',
      base_setting TEXT DEFAULT '',
      writing_requirements TEXT DEFAULT '',
      writing_style TEXT DEFAULT '',
      global_pre_prompt TEXT DEFAULT '',
      global_post_prompt TEXT DEFAULT '',
      history_rounds INTEGER NOT NULL DEFAULT 1,
      role_hierarchy TEXT DEFAULT '',
      role_hierarchy_detail TEXT DEFAULT ''
    )
  ''');
  await db.execute('''
    CREATE TABLE rounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      round_index INTEGER NOT NULL,
      user_input TEXT DEFAULT '',
      ai_narrative TEXT DEFAULT '',
      world_state TEXT DEFAULT '',
      character_state TEXT DEFAULT '',
      memory_summary TEXT DEFAULT '',
      current_time TEXT DEFAULT '',
      recommended_action TEXT DEFAULT '',
      tokens_in INTEGER NOT NULL DEFAULT 0,
      tokens_out INTEGER NOT NULL DEFAULT 0,
      created_at DATETIME,
      FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
    )
  ''');
  await db.execute('CREATE INDEX idx_rounds_book_index ON rounds (book_id, round_index)');
  await _createCommonTables(db);
}

/// v2 引入的世界书 + v5 引入的 mods / book_mods 表（迁移全链路会用到）。
Future<void> _createCommonTables(Database db) async {
  await db.execute('''
    CREATE TABLE world_book_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      keyword TEXT NOT NULL,
      content TEXT DEFAULT '',
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at DATETIME
    )
  ''');
  await db.execute('''
    CREATE TABLE mods (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      description TEXT DEFAULT '',
      pre_prompt TEXT DEFAULT '',
      post_prompt TEXT DEFAULT '',
      system_prompt TEXT DEFAULT '',
      world_book TEXT DEFAULT '',
      created_at DATETIME,
      updated_at DATETIME
    )
  ''');
  await db.execute('''
    CREATE TABLE book_mods (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      preset_key TEXT,
      mod_id INTEGER,
      sort_order INTEGER NOT NULL DEFAULT 0,
      is_enabled INTEGER NOT NULL DEFAULT 1
    )
  ''');
}

/// 库内全部表名（墓碑表等「不应存在」的断言用）。
Future<Set<String>> _tableNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table'",
  );
  return rows.map((r) => r['name'] as String).toSet();
}

/// 以生产迁移入口把 [path] 的库升级到当前版本（外键按生产配置打开）。
Future<Database> _openUpgraded(String path) =>
    databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.currentDbVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: DatabaseHelper.migrate,
      ),
    );

List<String> _columnNames(List<Map<String, Object?>> rows) =>
    rows.map((r) => r['name'] as String).toList();

/// \`PRAGMA foreign_key_list\` → {父表名: 父列名}。
Map<String, String> _fkTargets(List<Map<String, Object?>> rows) => {
      for (final r in rows) r['table'] as String: r['to'] as String,
    };

/// 业务表 / 索引的 DDL（去引号、压空白），用于跨库比较。
Future<Map<String, String>> _businessSchema(
  Database db,
  List<String> names,
) async {
  final rows = await db.rawQuery(
    "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL",
  );
  final all = {
    for (final r in rows)
    r['name'] as String:
        (r['sql'] as String)
          .replaceAll('"', '')
          .replaceAll(
      RegExp(r'\\s+'),
      ' ',
    ).trim(),
  };
  return {for (final n in names) if (all.containsKey(n)) n: all[n]!};
}

/// 已发布 v9 schema（v8 + rounds.model_name）。
Future<void> _createV9Schema(Database db, int version) async {
  await _createV8Schema(db, version);
  await db.execute(
    "ALTER TABLE rounds ADD COLUMN model_name TEXT DEFAULT ''",
  );
}

/// 已发布 v15 schema（v14 去掉图片墓碑表；books/mods 仍是 int 主键 + uuid 列）。
Future<void> _createV15Schema(Database db, int version) async {
  await _createV14Schema(db, version);
  await db.execute('DROP TABLE IF EXISTS sync_pending_del');
  await db.execute('DROP TABLE IF EXISTS sync_image_revived');
}