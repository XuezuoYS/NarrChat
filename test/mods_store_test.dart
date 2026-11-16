import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/mods_store.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/providers/mod_provider.dart';
import 'package:narrchat/repositories/mod_repository.dart';
import 'package:narrchat/utils/timestamp_format.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/fakes.dart';
import 'helpers/sync_conflict_fixtures.dart';

/// `ModsDb.mergeRows`：逐 Mod 合并把远端整行落进本地库（含墓碑），不碰其它行。
void main() {
  late TestStack stack;
  late ModsStore mods;

  setUp(() async {
    stack = await TestStack.create();
    mods = stack.stores.mods;
  });

  tearDown(() async {
    await stack.dispose();
  });

  test('覆盖已有 Mod 的内容、时间与墓碑（含 v26 的三个新列）', () async {
    final uuid = await stack.seedMod(name: '旧名字', prePrompt: '旧前置词');
    final updatedAt = DateTime.utc(2026, 5, 1);
    final deletedAt = DateTime.utc(2026, 6, 1);

    await mods.mergeRows([
      {
        ...modRow(
          uuid: uuid,
          name: '新名字',
          content: '新前置词',
          updatedAt: updatedAt,
          deletedAt: deletedAt,
        ),
        'description': '新简介',
        'post_prompt': '新后置词',
        'system_prompt': '新通用约束',
        'system_setting': '新设定',
        'system_writing_style': '新文笔',
        'system_must': '新最高优先约束',
        'world_book': '[{"keyword":"关键词","content":"内容"}]',
      },
    ]);

    final all = await mods.list(includeDeleted: true);
    final saved = all.singleWhere((mod) => mod.uuid == uuid);
    expect(saved.name, '新名字');
    expect(saved.description, '新简介');
    expect(saved.prePrompt, '新前置词');
    expect(saved.postPrompt, '新后置词');
    expect(saved.systemPrompt, '新通用约束');
    expect(saved.systemSetting, '新设定');
    expect(saved.systemWritingStyle, '新文笔');
    expect(saved.systemMust, '新最高优先约束');
    expect(saved.worldBookEntries.single.keyword, '关键词');
    expect(saved.worldBookEntries.single.content, '内容');
    expect(saved.createdAt, updatedAt);
    expect(saved.updatedAt, updatedAt);

    // 墓碑：默认列表与 get 都看不到，includeDeleted 能看到这一行。
    expect((await mods.list()).where((mod) => mod.uuid == uuid), isEmpty);
    expect(await mods.get(uuid), isNull);
    expect((await mods.list(includeDeleted: true)).map((mod) => mod.uuid), [
      uuid,
    ]);
  });

  test('墓碑可被一次合并清掉（复活）', () async {
    final uuid = await stack.seedMod(name: '先删后恢复');
    await mods.mergeRows([
      modRow(
        uuid: uuid,
        name: '先删后恢复',
        updatedAt: DateTime.utc(2026, 5, 1),
        deletedAt: DateTime.utc(2026, 5, 2),
      ),
    ]);
    expect(await mods.list(), isEmpty);

    await mods.mergeRows([
      modRow(uuid: uuid, name: '先删后恢复', updatedAt: DateTime.utc(2026, 5, 3)),
    ]);

    final alive = await mods.list();
    expect(alive.single.uuid, uuid);
    expect(await mods.get(uuid), isNotNull);
  });

  test('只覆盖传入的行，其它 Mod 原样保留', () async {
    final keep = await stack.seedMod(name: '保留的 Mod', prePrompt: '保留内容');
    final change = await stack.seedMod(name: '要改的 Mod', prePrompt: '旧内容');
    final before = (await mods.get(keep))!;

    await mods.mergeRows([
      modRow(
        uuid: change,
        name: '改后的 Mod',
        content: '新内容',
        updatedAt: DateTime.utc(2026, 7, 1),
      ),
    ]);

    final after = (await mods.get(keep))!;
    expect(after.name, before.name);
    expect(after.prePrompt, before.prePrompt);
    expect(after.updatedAt, before.updatedAt);

    final changed = (await mods.get(change))!;
    expect(changed.name, '改后的 Mod');
    expect(changed.prePrompt, '新内容');
    expect(await mods.list(), hasLength(2));
  });

  test('空列表是 no-op', () async {
    final uuid = await stack.seedMod(name: '不动的 Mod', prePrompt: '原内容');

    await mods.mergeRows(const <Map<String, Object?>>[]);

    final saved = (await mods.list()).single;
    expect(saved.uuid, uuid);
    expect(saved.name, '不动的 Mod');
    expect(saved.prePrompt, '原内容');
  });

  test('缺 mod_uuid 或为空 → ArgumentError，一行都不写', () async {
    final missingUuid = {...modRow(uuid: 'm1', name: '缺少 uuid')}
      ..remove('mod_uuid');

    await expectLater(
      mods.mergeRows([missingUuid]),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      mods.mergeRows([modRow(uuid: '', name: '空 uuid')]),
      throwsA(isA<ArgumentError>()),
    );

    expect(await mods.list(includeDeleted: true), isEmpty);
  });

  for (final column in const ['name', 'created_at', 'updated_at']) {
    test('缺 $column → ArgumentError，整批不写', () async {
      final existing = await stack.seedMod(name: '原有 Mod');
      final invalid = {...modRow(uuid: 'm-invalid', name: '缺列 Mod')}
        ..remove(column);
      final valid = modRow(uuid: 'm-valid', name: '同批合法行');

      await expectLater(
        mods.mergeRows([valid, invalid]),
        throwsA(isA<ArgumentError>()),
      );

      final rows = await mods.list(includeDeleted: true);
      expect(rows.map((mod) => mod.uuid).toList(), [
        existing,
      ], reason: '校验失败时合法行也不该落库');
    });
  }

  test('缺省文本列写成空串而不是 NULL（含 v26 三列）', () async {
    await mods.mergeRows([
      {
        'mod_uuid': 'm-min',
        'name': '只有必填列',
        'created_at': formatTimestamp(DateTime.utc(2026, 1, 1)),
        'updated_at': formatTimestamp(DateTime.utc(2026, 1, 1)),
      },
    ]);

    final saved = (await mods.list()).single;
    expect(saved.uuid, 'm-min');
    expect(saved.description, '');
    expect(saved.prePrompt, '');
    expect(saved.postPrompt, '');
    expect(saved.systemPrompt, '');
    // v25 快照缺这三列 → 按空串落地（与建表默认值一致，避免摘要漂移）。
    expect(saved.systemMust, '');
    expect(saved.systemSetting, '');
    expect(saved.systemWritingStyle, '');
    expect(saved.worldBookEntries, isEmpty);
    expect(saved.createdAt, DateTime.utc(2026, 1, 1));
    expect(saved.updatedAt, DateTime.utc(2026, 1, 1));
  });

  test('ModProvider 读到「被旧版本访问过」预检结果，且提示可关闭一次', () async {
    final dir = Directory.systemTemp.createTempSync('mods_downgraded_');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'narrchat_mods.db');

    // 先造一个正常的 v26 库，再把版本写回 25 —— 这就是「3.0 打开过 v26 库」的
    // 遗留状态（列在、版本低）。
    final seed = ModsDb(pathOverride: path, masterUuidOverride: 'm');
    await seed.upsert(const Mod(uuid: 'm1', name: '甲'));
    await seed.close();
    final raw = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await raw.execute('PRAGMA user_version = 25');
    await raw.close();

    final store = ModsDb(pathOverride: path, masterUuidOverride: 'm');
    addTearDown(store.close);
    final provider = ModProvider(
      repository: ModRepository(mods: store, books: stack.repos.mod.books),
    );
    addTearDown(provider.dispose);

    await provider.loadUserMods();
    expect(provider.modsDowngraded, isTrue);
    expect(provider.userMods.single.name, '甲');

    provider.dismissModsDowngraded();
    expect(provider.modsDowngraded, isFalse);
  });
}
