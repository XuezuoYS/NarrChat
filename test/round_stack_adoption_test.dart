import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/round_stack_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/round_stack.dart';
import 'package:narrchat/services/round_stack_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 采纳（`rounds` 为准收敛版本树）契约：设计规格 §9.3 的 AD-1…AD-7。
///
/// 场景全部模拟「老客户端 / 外部工具直接改 `rounds`」：版本树必须收敛到
/// 「不复活、不回退、非活动分支保留」。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late String bookUuid;
  late RoundDao roundDao;
  late RoundStackDao stackDao;
  late RoundStackService service;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('round_stack_adoption_test_');
    DatabaseHelper.debugDatabasePathOverride = p.join(dir.path, 'narrchat.db');
    bookUuid = await BookDao().insertBook(const Book(title: '书A'));
    roundDao = RoundDao();
    stackDao = RoundStackDao();
    service = RoundStackService();
  });

  tearDown(() async {
    DatabaseHelper.debugDatabasePathOverride = null;
    await DatabaseHelper.instance.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 忽略清理失败。
    }
  });

  Round newRound(int index, {String? narrative, String? input}) => Round(
        bookUuid: bookUuid,
        roundIndex: index,
        userInput: input ?? '输入$index',
        aiNarrative: narrative ?? '正文$index',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000 + index),
      );

  Future<List<Round>> projection() => roundDao.getRoundsByBook(bookUuid);

  Future<Round> roundAt(int index) async =>
      (await projection()).firstWhere((r) => r.roundIndex == index);

  Future<List<RoundStackRow>> stack() => stackDao.loadByBook(bookUuid);

  Future<void> expectChainInvariant() async {
    final rounds = await projection();
    final byUuid = {for (final row in await stack()) row.uuid: row};
    for (var i = 0; i < rounds.length; i++) {
      final gen = byUuid[rounds[i].useStackUuid];
      expect(gen, isNotNull, reason: '第 ${rounds[i].roundIndex} 轮的锚点必须指向存活代');
      if (i == 0) {
        expect(gen!.fatherUuid, isNull);
      } else {
        expect(gen!.fatherUuid, rounds[i - 1].useStackUuid, reason: '父子一致');
      }
    }
  }

  /// 老客户端改 `rounds` 行内容（不动 `use_stack_uuid`，也不碰 stack）。
  Future<void> oldClientEdit(int index, String narrative) async {
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'rounds',
      {'ai_narrative': narrative},
      where: 'book_uuid = ? AND round_index = ?',
      whereArgs: [bookUuid, index],
    );
  }

  /// 老客户端直接删 `rounds` 行（stack 里留着陈旧代）。
  Future<void> oldClientDeleteRound(int index) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'rounds',
      where: 'book_uuid = ? AND round_index = ?',
      whereArgs: [bookUuid, index],
    );
  }

  /// 走生产路径建好「第零轮 + 第 1 轮两代（A / B，B 为当前）」。
  Future<({String root, String genA, String genB})> bootstrapTwoGenerations() async {
    await roundDao.insertRound(newRound(0));
    await service.adoptIfNeeded(bookUuid, force: true);
    final root = (await roundAt(0)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: 'A 正文'),
      fatherUuid: root,
    );
    final genA = (await roundAt(1)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: 'B 正文'),
      fatherUuid: root,
    );
    final genB = (await roundAt(1)).useStackUuid;
    return (root: root, genA: genA, genB: genB);
  }

  test('AD-7 第零轮单独处理：v18 老库升级后按采纳懒建根节点（无父）', () async {
    await roundDao.insertRound(newRound(0));
    expect((await projection()).single.useStackUuid, '');
    expect(await stack(), isEmpty);

    final report = await service.adoptIfNeeded(bookUuid);

    expect(report, isNotNull);
    expect(report!.created, 1, reason: '懒建一代');
    final root = (await roundAt(0)).useStackUuid;
    expect(root, isNotEmpty);
    final row = await stackDao.getByUuid(root);
    expect(row!.fatherUuid, isNull, reason: '第零轮的代是根');
    expect(row.roundSerialNum, 1);
    expect(row.isUse, isTrue);
    expect(row.aiNarrative, '正文0');
    // 幂等：健康检查命中，第二次直接跳过。
    expect(await service.adoptIfNeeded(bookUuid), isNull);
    await expectChainInvariant();
  });

  test('AD-1 老客户端改内容 → 复用同内容代（不新建），锚点重指', () async {
    final ids = await bootstrapTwoGenerations();
    await service.switchTo(bookUuid: bookUuid, roundIndex: 1, targetUuid: ids.genA);
    expect((await roundAt(1)).useStackUuid, ids.genA);
    final rowsBefore = (await stack()).length;

    // 老客户端把内容改成 B 代的内容（等价于「切回 B」），但锚点仍是 A。
    await oldClientEdit(1, 'B 正文');
    final report = await service.adoptIfNeeded(bookUuid, force: true);

    expect(report!.created, 0, reason: '内容相同的代必须复用，不新建');
    expect(report.reused, 1);
    expect((await stack()).length, rowsBefore, reason: '不得长出新代');
    final current = await roundAt(1);
    expect(current.useStackUuid, ids.genB, reason: '锚点重指到同内容代');
    expect(current.aiNarrative, 'B 正文', reason: '老客户端的修改被保留');
    await expectChainInvariant();
  });

  test('AD-2 老客户端新增轮次 → 在活动父下新建代（序号 max+1）', () async {
    final ids = await bootstrapTwoGenerations();
    await roundDao.insertRound(newRound(2, narrative: '老客户端新增'));

    final report = await service.adoptIfNeeded(bookUuid, force: true);

    expect(report!.created, 1);
    final gen = await stackDao.getByUuid((await roundAt(2)).useStackUuid);
    expect(gen!.fatherUuid, (await roundAt(1)).useStackUuid, reason: '父 = 活动父');
    expect(gen.roundSerialNum, 1);
    expect(gen.aiNarrative, '老客户端新增');
    expect(ids.root, isNotEmpty);
    await expectChainInvariant();
  });

  test('AD-3 老客户端删轮 → 删除「匹配到的父」下的子树；父不匹配的分支保留', () async {
    final ids = await bootstrapTwoGenerations();
    // 活动分支：第 2 轮挂在 B 之下；另一分支：第 2 轮挂在 A 之下。
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(2, narrative: 'B 分支第 2 轮'),
      fatherUuid: ids.genB,
    );
    final underB = (await roundAt(2)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(2, narrative: 'A 分支第 2 轮'),
      fatherUuid: ids.genA,
    );
    final underA = (await roundAt(2)).useStackUuid;
    // 切回 B 分支，使「活动父」= B。
    await service.switchTo(bookUuid: bookUuid, roundIndex: 1, targetUuid: ids.genB);

    // 老客户端删除第 2 轮（活动分支）。
    await oldClientDeleteRound(2);
    final report = await service.adoptIfNeeded(bookUuid, force: true);

    expect(report!.removedSubtree, 1, reason: '命中「删除匹配到的父」');
    expect(await stackDao.getByUuid(underB), isNull, reason: '活动父下的子树被删');
    expect(await stackDao.getByUuid(underA), isNotNull,
        reason: '父不匹配的其它分支必须保留');
    expect((await projection()).map((r) => r.roundIndex), [0, 1]);
    await expectChainInvariant();
  });

  test('AD-4 父不存在 / 父不一致 → 一律新建（不复用其它分支的同内容代）', () async {
    final ids = await bootstrapTwoGenerations();
    // 在「不存在的父」下挂一代（内容与活动分支同内容，用于验证「父不一致不参与复用」），
    // 并把投影行的锚点指向悬空父、内容改成任何存活代都没有的正文。
    final db = await DatabaseHelper.instance.database;
    await stackDao.insertGeneration(
      db,
      RoundStackRow.fromRound(
        newRound(1, narrative: '正文1'),
        uuid: 'ghost-child',
        fatherUuid: 'ghost-father',
        roundSerialNum: 7,
        roundState: 'use',
      ),
    );
    await db.update(
      'rounds',
      {'use_stack_uuid': 'ghost-father', 'ai_narrative': '全新正文'},
      where: 'book_uuid = ? AND round_index = 1',
      whereArgs: [bookUuid],
    );
    final rowsBefore = (await stack()).length;

    final report = await service.adoptIfNeeded(bookUuid, force: true);

    expect(report!.created, 1, reason: '父锚点不一致 → 一律新建，不得复用别的分支');
    expect(report.reused, 0);
    expect((await stack()).length, rowsBefore, reason: '新建一代 + 清理一个孤儿');
    final gen = await stackDao.getByUuid((await roundAt(1)).useStackUuid);
    expect(gen!.fatherUuid, ids.root, reason: '父取上一轮当前代');
    expect(gen.aiNarrative, '全新正文');
    expect(gen.roundSerialNum, 3, reason: '新建代序号 = 分组 max+1');
    // 悬空的「伪代」不可达 → 孤儿清理移除。
    expect(await stackDao.getByUuid('ghost-child'), isNull);
    await expectChainInvariant();
  });

  test('AD-5 从早到晚重建：祖先用本轮新建的行，后代锚点正确（链式校验）', () async {
    await roundDao.insertRound(newRound(0));
    for (var i = 1; i <= 3; i++) {
      await roundDao.insertRound(newRound(i, narrative: '老内容$i'));
    }
    // 全部锚点为空（老库）→ 全量采纳必须链式建立。
    final report = await service.adoptIfNeeded(bookUuid, force: true);
    expect(report!.created, 4);
    await expectChainInvariant();

    final rounds = await projection();
    final gens = {for (final row in await stack()) row.uuid: row};
    for (var i = 1; i < rounds.length; i++) {
      expect(
        gens[rounds[i].useStackUuid]!.fatherUuid,
        rounds[i - 1].useStackUuid,
        reason: '第 $i 轮的父必须是第 ${i - 1} 轮**本轮新建**的行',
      );
    }
  });

  test('AD-6 采纳幂等：连续两次采纳，第二次不产生新行也不报变化', () async {
    await roundDao.insertRound(newRound(0));
    await roundDao.insertRound(newRound(1));
    final first = await service.adoptIfNeeded(bookUuid, force: true);
    expect(first!.hasChanges, isTrue);
    final rowsAfterFirst = (await stack()).length;

    final second = await service.adoptIfNeeded(bookUuid, force: true);

    expect(second!.hasChanges, isFalse, reason: '内容一致时不得产生新代');
    expect((await stack()).length, rowsAfterFirst);
    expect(second.created, 0);
    expect(second.reused, 0);
    await expectChainInvariant();
  });

  test('AD-4b 切换前的单轮防覆盖：投影与当前代不一致时先采纳，不把陈旧内容写回', () async {
    final ids = await bootstrapTwoGenerations();
    await service.switchTo(bookUuid: bookUuid, roundIndex: 1, targetUuid: ids.genA);
    // 老客户端改了内容（锚点仍指 A）→ 直接调用切换不得把 A 的旧内容写回。
    await oldClientEdit(1, '老客户端的新正文');

    expect(
      await service.switchTo(bookUuid: bookUuid, roundIndex: 1, targetUuid: ids.genB),
      isTrue,
    );
    // 采纳把「老客户端的新正文」收敛成 B 分支上的一代（复用同内容代则 B 原地更新）。
    final rows = await stack();
    final reused = rows.where((r) => r.uuid == ids.genB).single;
    final projectionRound = await roundAt(1);
    expect(
      projectionRound.aiNarrative,
      'B 正文',
      reason: '切到 B 后投影内容 = B 代内容（采纳已把外部改动收敛进版本树）',
    );
    expect(reused.aiNarrative, 'B 正文');
    await expectChainInvariant();
  });

  test('轮号断裂（1,2,50）：采纳自动上溯，50 轮之父 = 第 2 轮当前代；切换可跳过空洞', () async {
    await roundDao.insertRound(newRound(1));
    await roundDao.insertRound(newRound(2));
    await roundDao.insertRound(newRound(50, narrative: '第 50 轮正文'));

    final report = await service.adoptIfNeeded(bookUuid, force: true);

    expect(report!.created, 3);
    final rounds = await projection();
    expect(rounds.map((r) => r.roundIndex), [1, 2, 50]);
    final gen1 = (await stackDao.getByUuid((await roundAt(1)).useStackUuid))!;
    final gen2 = (await stackDao.getByUuid((await roundAt(2)).useStackUuid))!;
    final gen50 = (await stackDao.getByUuid((await roundAt(50)).useStackUuid))!;
    expect(gen1.fatherUuid, isNull, reason: '最小轮 = 根');
    expect(gen2.fatherUuid, gen1.uuid);
    expect(
      gen50.fatherUuid,
      gen2.uuid,
      reason: '断裂处自动上溯：50 的父是最近存在的更早一轮（第 2 轮）',
    );

    // 第 2 轮补一代（同父兄弟代），切到旧代：链必须**跳过空洞**把第 50 轮带回来。
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(2, narrative: '第 2 轮的另一代'),
      fatherUuid: gen2.fatherUuid,
    );
    final gen2b = (await roundAt(2)).useStackUuid;
    expect(gen2b, isNot(gen2.uuid));

    expect(
      await service.switchTo(bookUuid: bookUuid, roundIndex: 2, targetUuid: gen2.uuid),
      isTrue,
    );
    expect(
      (await projection()).map((r) => r.roundIndex),
      [1, 2, 50],
      reason: '活动链跳过 3…49 的空洞',
    );
    expect((await roundAt(50)).useStackUuid, gen50.uuid);

    // 切到「无子代」的那一代 → 第 50 轮从视图消失；再切回 → 原样回来。
    expect(
      await service.switchTo(bookUuid: bookUuid, roundIndex: 2, targetUuid: gen2b),
      isTrue,
    );
    expect((await projection()).map((r) => r.roundIndex), [1, 2]);
    expect(
      await service.switchTo(bookUuid: bookUuid, roundIndex: 2, targetUuid: gen2.uuid),
      isTrue,
    );
    expect((await projection()).map((r) => r.roundIndex), [1, 2, 50]);
    expect((await roundAt(50)).aiNarrative, '第 50 轮正文');
  });

  test('AD-6b 采纳后 touchBook(rounds)：下次同步能判定为本地变更', () async {
    await roundDao.insertRound(newRound(0));
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'books',
      {'rounds_updated_at': 0},
      where: 'uuid = ?',
      whereArgs: [bookUuid],
    );
    final before = (await db.query(
      'books',
      columns: ['rounds_updated_at'],
      where: 'uuid = ?',
      whereArgs: [bookUuid],
    ))
        .single['rounds_updated_at'] as int;

    await service.adoptIfNeeded(bookUuid, force: true);

    final after = (await db.query(
      'books',
      columns: ['rounds_updated_at'],
      where: 'uuid = ?',
      whereArgs: [bookUuid],
    ))
        .single['rounds_updated_at'] as int;
    expect(after, greaterThan(before), reason: '采纳改动了轮次部件 → 必须触碰写时间戳');
  });
}
