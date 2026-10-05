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

/// [RoundStackService] 的领域语义契约（真库 + 临时目录）。
///
/// 覆盖设计规格 §9.2 的 OP-1…OP-12：生成 / 原地修改 / 切换（同父、跨父、切回）/
/// 序号复用 / 删除 / 归一化 / 孤儿清理 / 不变量 / 纯函数。
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
    dir = Directory.systemTemp.createTempSync('round_stack_service_test_');
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

  // ---------------------------------------------------------------------------
  // 夹具
  // ---------------------------------------------------------------------------

  Round newRound(int index, {String? input, String? narrative}) => Round(
        bookUuid: bookUuid,
        roundIndex: index,
        userInput: input ?? '输入$index',
        aiNarrative: narrative ?? '正文$index',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000 + index),
      );

  Future<List<Round>> projection() => roundDao.getRoundsByBook(bookUuid);

  Future<List<RoundStackRow>> stack() => stackDao.loadByBook(bookUuid);

  Future<Round> roundAt(int index) async =>
      (await projection()).firstWhere((r) => r.roundIndex == index);

  Future<RoundStackRow> stackRow(String uuid) async =>
      (await stackDao.getByUuid(uuid))!;

  Future<Map<String, Object?>> rawRound(int index) async {
    final db = await DatabaseHelper.instance.database;
    return (await db.query(
      'rounds',
      where: 'book_uuid = ? AND round_index = ?',
      whereArgs: [bookUuid, index],
    ))
        .single;
  }

  /// OP-11：`father(rounds[i].use) == rounds[i-1].use` 全链成立。
  Future<void> expectChainInvariant() async {
    final rounds = await projection();
    final byUuid = {for (final row in await stack()) row.uuid: row};
    for (var i = 0; i < rounds.length; i++) {
      final gen = byUuid[rounds[i].useStackUuid];
      expect(gen, isNotNull, reason: '第 ${rounds[i].roundIndex} 轮的锚点必须指向存活代');
      if (i == 0) {
        expect(gen!.fatherUuid, isNull, reason: '第零轮的代必须是根');
      } else {
        expect(
          gen!.fatherUuid,
          rounds[i - 1].useStackUuid,
          reason: '父子一致：第 ${rounds[i].roundIndex} 轮的父必须是上一轮当前代',
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // OP-1 / OP-2
  // ---------------------------------------------------------------------------

  /// 走生产路径建立初始版本树：第零轮 + 第 1 轮（父 = 第零轮当前代）。
  Future<({String root, String first})> bootstrap() async {
    final id0 = await roundDao.insertRound(newRound(0));
    await service.adoptIfNeeded(bookUuid, force: true);
    var rounds = await projection();
    final root = rounds.single.useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1).copyWith(id: id0),
      fatherUuid: root,
    );
    rounds = await projection();
    return (root: root, first: rounds.last.useStackUuid);
  }

  test('OP-1 生成：father = 活动链尾，序号 = max+1，同组旧 use 被清', () async {
    await bootstrap();
    final root = (await roundAt(0)).useStackUuid;
    var rounds = await projection();
    final firstGen = await stackRow(rounds.last.useStackUuid);
    expect(firstGen.fatherUuid, root, reason: '父 = 上一轮当前代');
    expect(firstGen.roundSerialNum, 1);
    expect(firstGen.isUse, isTrue);

    // 同一轮再生成一代（同父兄弟代）：序号 max+1，旧代让位为闲置。
    final id = await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: '第二代正文'),
      fatherUuid: root,
    );
    expect(id, isPositive);
    rounds = await projection();
    expect(rounds, hasLength(2), reason: '投影仍是一轮一行');
    final second = await stackRow(rounds.last.useStackUuid);
    expect(second.roundSerialNum, 2, reason: '序号 = 同组 max+1');
    expect(second.isUse, isTrue);
    expect(second.aiNarrative, '第二代正文');
    expect((await stackRow(firstGen.uuid)).roundState, isNull,
        reason: '同组旧 use 必须被清');
    expect(await stack(), hasLength(3), reason: '根 + 两代');
    await expectChainInvariant();
  });

  test('OP-2 原地修改：不新增行、uuid / 序号不变，投影同事务同步且 updated_at 刷新', () async {
    await bootstrap();
    final before = await roundAt(1);
    final beforeRaw = await rawRound(1);
    final rowsBefore = await stack();

    await service.applyInPlaceEdit(
      round: before.copyWith(userInput: '改后输入', aiNarrative: '改后正文'),
    );

    final rowsAfter = await stack();
    expect(rowsAfter, hasLength(rowsBefore.length), reason: '原地修改不新增代');
    final gen = await stackRow(before.useStackUuid);
    expect(gen.uuid, before.useStackUuid);
    expect(gen.roundSerialNum, 1, reason: '序号不变');
    expect(gen.isUse, isTrue, reason: '状态不变');
    expect(gen.userInput, '改后输入');
    expect(gen.aiNarrative, '改后正文');
    expect(gen.roundCreatedAt, before.createdAt, reason: '本代创建时间不变');

    final after = await roundAt(1);
    expect(after.userInput, '改后输入');
    expect(after.aiNarrative, '改后正文');
    expect(after.useStackUuid, before.useStackUuid, reason: '锚点不动');
    final afterRaw = await rawRound(1);
    expect(
      (afterRaw['updated_at'] as int) >= (beforeRaw['updated_at'] as int),
      isTrue,
      reason: 'updated_at 必须刷新',
    );
  });

  // ---------------------------------------------------------------------------
  // OP-3 / OP-4 / OP-5
  // ---------------------------------------------------------------------------

  test('OP-3 切换（同分组）：投影 = 目标代，锚点重指，created_at = round_created_at', () async {
    await bootstrap();
    final root = (await roundAt(0)).useStackUuid;
    final genA = (await roundAt(1)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: '第二代正文'),
      fatherUuid: root,
    );
    final genB = (await roundAt(1)).useStackUuid;
    expect(genB, isNot(genA));

    expect(
      await service.switchTo(
        bookUuid: bookUuid,
        roundIndex: 1,
        targetUuid: genA,
      ),
      isTrue,
    );

    final switched = await roundAt(1);
    expect(switched.aiNarrative, '正文1', reason: '投影内容 = 目标代内容');
    expect(switched.useStackUuid, genA);
    final genARow = await stackRow(genA);
    expect(switched.createdAt, genARow.roundCreatedAt,
        reason: 'created_at 取本代 round_created_at');
    expect((await stackRow(genB)).roundState, isNull, reason: '目标代之外的 use 被清');
    expect((await stackRow(genA)).isUse, isTrue);
    await expectChainInvariant();
  });

  test('OP-4 切换（跨父）：后续轮次按 use 重建；无存活子代 → 后续轮次从视图消失', () async {
    late final String root;
    late final String genA;
    late final String genB;
    // 第 1 轮两代 A / B（同父），只在 B 分支下挂第 2 轮。
    await bootstrap();
    root = (await roundAt(0)).useStackUuid;
    genA = (await roundAt(1)).useStackUuid;
    final b = await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: 'B 正文'),
      fatherUuid: root,
    );
    genB = (await roundAt(1)).useStackUuid;
    expect(b, isPositive);
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(2, narrative: 'B 之后的第 2 轮'),
      fatherUuid: genB,
    );
    expect(await projection(), hasLength(3));

    // 切到 A：A 分支没有存活子代 → 第 2 轮从视图消失（投影被删）。
    expect(
      await service.switchTo(bookUuid: bookUuid, roundIndex: 1, targetUuid: genA),
      isTrue,
    );
    expect(
      (await projection()).map((r) => r.roundIndex),
      [0, 1],
      reason: '链在无存活子代处结束',
    );
    expect((await roundAt(1)).aiNarrative, '正文1');
    // 被隐藏的代仍在库里（历史保留）。
    expect((await stackRow(genB)).isUse, isFalse);
    expect(await stack(), hasLength(4));

    // 切回 B：第 2 轮原样回来（内容 = 当时保存的代）。
    expect(
      await service.switchTo(bookUuid: bookUuid, roundIndex: 1, targetUuid: genB),
      isTrue,
    );
    final restored = await projection();
    expect(restored.map((r) => r.roundIndex), [0, 1, 2]);
    expect(restored.last.aiNarrative, 'B 之后的第 2 轮');
    await expectChainInvariant();
  });

  test('OP-5 切换往返多次：内容与代身份稳定（不产生新代）', () async {
    await bootstrap();
    final root = (await roundAt(0)).useStackUuid;
    final genA = (await roundAt(1)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: 'B 正文'),
      fatherUuid: root,
    );
    final genB = (await roundAt(1)).useStackUuid;
    final rowsBefore = (await stack()).length;

    for (var i = 0; i < 3; i++) {
      await service.switchTo(bookUuid: bookUuid, roundIndex: 1, targetUuid: genA);
      expect((await roundAt(1)).aiNarrative, '正文1');
      expect((await roundAt(1)).useStackUuid, genA);
      await service.switchTo(bookUuid: bookUuid, roundIndex: 1, targetUuid: genB);
      expect((await roundAt(1)).aiNarrative, 'B 正文');
      expect((await roundAt(1)).useStackUuid, genB);
    }
    expect((await stack()).length, rowsBefore, reason: '往返切换不得长出新代');
    await expectChainInvariant();
  });

  // ---------------------------------------------------------------------------
  // OP-6 / OP-8 / OP-10
  // ---------------------------------------------------------------------------

  test('OP-6 序号复用：删掉最大序号后新建代复用该号且不串数据（身份 = uuid）', () async {
    await bootstrap();
    final root = (await roundAt(0)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: '第二代正文'),
      fatherUuid: root,
    );
    final genB = (await roundAt(1)).useStackUuid;
    final db = await DatabaseHelper.instance.database;
    await stackDao.deleteByUuids(db, [genB]);

    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: '第三代正文'),
      fatherUuid: root,
    );
    final reused = await stackRow((await roundAt(1)).useStackUuid);
    expect(reused.roundSerialNum, 2, reason: '物理删除后序号可复用（max+1）');
    expect(reused.uuid, isNot(genB), reason: '身份靠 uuid，不复用旧身份');
    expect(reused.aiNarrative, '第三代正文', reason: '不得串到已删除那一代的内容');
    expect(await stackDao.getByUuid(genB), isNull);
  });

  test('OP-8 用户删除：该轮全部代（跨分支）+ 全部后代被物理删除，投影一致', () async {
    await bootstrap();
    final root = (await roundAt(0)).useStackUuid;
    final genA = (await roundAt(1)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: 'B 正文'),
      fatherUuid: root,
    );
    final genB = (await roundAt(1)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(2, narrative: '第 2 轮'),
      fatherUuid: genB,
    );

    await service.deleteFrom(
      bookUuid: bookUuid,
      fromRoundIndex: 1,
      deleteFollowing: true,
    );

    expect((await projection()).map((r) => r.roundIndex), [0]);
    final rows = await stack();
    expect(rows.map((r) => r.uuid), [root], reason: '跨分支的全部代都被物理删除');
    expect(await stackDao.getByUuid(genA), isNull);
    expect(await stackDao.getByUuid(genB), isNull);
    await expectChainInvariant();
  });

  test('OP-10 孤儿清理：删父行后子行视为已删除被清理，幂等且不影响可达代', () async {
    await bootstrap();
    final root = (await roundAt(0)).useStackUuid;
    final genA = (await roundAt(1)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(2, narrative: '第 2 轮'),
      fatherUuid: genA,
    );
    // 直接物理删除父行（模拟外部脏数据）：子行变成孤儿。
    final db = await DatabaseHelper.instance.database;
    await stackDao.deleteByUuids(db, [genA]);

    final purged = await service.purgeOrphans(bookUuid);
    expect(purged, 1, reason: '孤儿子行被清理');
    expect((await stack()).map((r) => r.uuid), [root]);
    expect(await service.purgeOrphans(bookUuid), 0, reason: '清理幂等');
    expect((await stack()).map((r) => r.uuid), [root], reason: '可达代不受影响');
  });

  // ---------------------------------------------------------------------------
  // OP-9 / OP-11 / OP-12
  // ---------------------------------------------------------------------------

  test('OP-9 归一化：多 use 取最大序号；无 use 取最大存活序号；确定性', () async {
    await bootstrap();
    final root = (await roundAt(0)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: 'B 正文'),
      fatherUuid: root,
    );
    final genA = (await stack()).firstWhere((r) => r.roundIndex == 1 && r.roundSerialNum == 1).uuid;
    final genB = (await roundAt(1)).useStackUuid;
    final db = await DatabaseHelper.instance.database;

    // 脏数据一：同组两个 use → 保留最大序号（genB）。
    await stackDao.setGroupUseState(db, setUse: [genA, genB]);
    await service.normalizeGroup(bookUuid, 1, root);
    var group = await stackDao.loadGroup(bookUuid, 1, root);
    expect(group.where((m) => m.isUse).map((m) => m.uuid), [genB]);
    expect(group.firstWhere((m) => m.uuid == genA).roundState, isNull);

    // 脏数据二：同组无 use → 取最大存活序号（genB）。
    await stackDao.setGroupUseState(db, clearUse: [genA, genB]);
    await service.normalizeGroup(bookUuid, 1, root);
    group = await stackDao.loadGroup(bookUuid, 1, root);
    expect(group.where((m) => m.isUse).map((m) => m.uuid), [genB]);

    // 确定性：连续两次归一化结果一致（不新增行、不改内容）。
    final snapshot = (await stack())
        .map((r) => '${r.uuid}:${r.roundSerialNum}:${r.roundState}')
        .toList()
      ..sort();
    await service.normalizeBook(bookUuid);
    final again = (await stack())
        .map((r) => '${r.uuid}:${r.roundSerialNum}:${r.roundState}')
        .toList()
      ..sort();
    expect(again, snapshot, reason: '归一化必须同输入同输出');
  });

  test('OP-9b 归一化：重复序号保留创建时间最新者，其余顺移（确定性）', () async {
    await bootstrap();
    final root = (await roundAt(0)).useStackUuid;
    final genA = (await roundAt(1)).useStackUuid;
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(1, narrative: 'B 正文')
          .copyWith(createdAt: DateTime.fromMillisecondsSinceEpoch(1_800_000_000_000)),
      fatherUuid: root,
    );
    final genB = (await roundAt(1)).useStackUuid;
    final db = await DatabaseHelper.instance.database;
    // 制造重复序号：A 与 B 都写 1（B 创建时间更新 → B 应保留原序号）。
    await stackDao.setSerial(db, genA, 1);
    await stackDao.setSerial(db, genB, 1);
    expect(
      (await stackDao.getByUuid(genB))!.roundCreatedAt!.isAfter(
        (await stackDao.getByUuid(genA))!.roundCreatedAt!,
      ),
      isTrue,
      reason: '夹具前提：B 的创建时间必须严格晚于 A',
    );

    await service.normalizeGroup(bookUuid, 1, root);

    final group = await stackDao.loadGroup(bookUuid, 1, root);
    expect(group.map((m) => m.roundSerialNum).toSet(), hasLength(2),
        reason: '重复序号必须被消解');
    final a = group.firstWhere((m) => m.uuid == genA);
    final b = group.firstWhere((m) => m.uuid == genB);
    expect(b.roundSerialNum, 1, reason: '创建时间最新者保留原序号');
    expect(a.roundSerialNum, 2, reason: '较旧者顺移到末尾');
    expect(group.where((m) => m.isUse).map((m) => m.uuid), [genB]);
  });

  test('OP-11 不变量：生成 / 切换 / 原地修改后 father 链始终一致', () async {
    await bootstrap();
    final root = (await roundAt(0)).useStackUuid;
    for (var i = 2; i <= 4; i++) {
      final prev = await roundAt(i - 1);
      await service.attachNewGeneration(
        bookUuid: bookUuid,
        round: newRound(i),
        fatherUuid: prev.useStackUuid,
      );
    }
    await expectChainInvariant();

    final genAt3 = (await roundAt(3)).useStackUuid;
    // 「重写本轮」= 先删该轮起的投影行（旧代保留在 stack 里），再新建一代。
    await service.deleteProjectionFrom(bookUuid, 3);
    await service.attachNewGeneration(
      bookUuid: bookUuid,
      round: newRound(3, narrative: '第 3 轮的另一代'),
      fatherUuid: (await roundAt(2)).useStackUuid,
    );
    expectChainInvariant();
    // 切回被重写掉的那一代：其后轮次随父原样回来（链重新闭合）。
    await service.switchTo(bookUuid: bookUuid, roundIndex: 3, targetUuid: genAt3);
    expectChainInvariant();
    expect((await projection()).map((r) => r.roundIndex), [0, 1, 2, 3, 4]);
    await service.applyInPlaceEdit(
      round: (await roundAt(3)).copyWith(aiNarrative: '再改一次'),
    );
    await expectChainInvariant();
    expect(root, (await roundAt(0)).useStackUuid);
  });

  test('OP-10b 根守卫：无父行（NULL）是合法链首，孤儿清理只删「父查不到」的行', () async {
    await bootstrap();
    final db = await DatabaseHelper.instance.database;
    final root = (await roundAt(0)).useStackUuid;
    // 再插一条「无父」的代（模拟链首 / 历史根）与一条真孤儿（父不存在）。
    await stackDao.insertGeneration(
      db,
      RoundStackRow.fromRound(
        newRound(3, narrative: '无父的历史根'),
        uuid: 'g-root-3',
        roundSerialNum: 1,
        roundState: 'use',
      ),
    );
    await stackDao.insertGeneration(
      db,
      RoundStackRow.fromRound(
        newRound(4),
        uuid: 'g-orphan',
        fatherUuid: 'ghost-father',
        roundSerialNum: 1,
      ),
    );

    final purged = await service.purgeOrphans(bookUuid);

    expect(purged, 1, reason: '只清理「父查不到」的那一条');
    expect(await stackDao.getByUuid('g-root-3'), isNotNull,
        reason: 'father_uuid IS NULL = 本代没有父（链首），不是孤儿');
    expect(await stackDao.getByUuid(root), isNotNull, reason: '第零轮的根同样存活');
    expect(await stackDao.getByUuid('g-orphan'), isNull);
    expect(await service.purgeOrphans(bookUuid), 0, reason: '根守卫下清理幂等');
    expect(await stackDao.getByUuid('g-root-3'), isNotNull);
  });

  test('OP-12 纯函数 planChain：空分组 / 单代 / 多分支 / 缺链', () {
    RoundStackRow row(String uuid, int index, {String? father, int serial = 1, bool use = false}) =>
        RoundStackRow(
          uuid: uuid,
          bookUuid: 'b',
          fatherUuid: father,
          roundIndex: index,
          roundSerialNum: serial,
          roundState: use ? 'use' : null,
        );

    final root = row('g0', 0, use: true);
    // 单代：链到此为止。
    expect(
      RoundStackService.planChain(anchor: root, byGroup: {}).map((r) => r.uuid),
      ['g0'],
    );

    // 多分支：use 优先；无 use 时取最大序号；分支各走各的。
    final a = row('a', 1, father: 'g0', use: true);
    final b = row('b', 1, father: 'g0', serial: 2);
    final c = row('c', 2, father: 'a', serial: 1, use: true);
    final d = row('d', 2, father: 'a', serial: 3);
    final e = row('e', 3, father: 'c', serial: 1, use: true);
    final f = row('f', 3, father: 'd', serial: 1, use: true);
    final rows = [root, a, b, c, d, e, f];
    expect(
      RoundStackService.planChain(
        anchor: root,
        byGroup: RoundStackService.groupRows(rows),
      ).map((r) => r.uuid),
      ['g0', 'a', 'c', 'e'],
      reason: '第 1 轮 use=a（b 序号更大但不选）；第 2 轮 use=c',
    );
    // 无 use 的分组取序号最大者：d 未标 use，则走 d → f。
    expect(
      RoundStackService.planChain(
        anchor: root,
        byGroup: RoundStackService.groupRows([
          root,
          a,
          b,
          row('c', 2, father: 'a', serial: 1),
          d,
          e,
          f,
        ]),
      ).map((r) => r.uuid),
      ['g0', 'a', 'd', 'f'],
      reason: '分组内无 use → 取序号最大者',
    );

    // 缺链：子树为空 → 链在缺链处结束。
    final orphanBranch = RoundStackService.planChain(
      anchor: row('x', 0, use: true),
      byGroup: RoundStackService.groupRows([a, b]),
    );
    expect(orphanBranch.map((r) => r.uuid), ['x']);
  });

  test('OP-12c 纯函数：轮号断裂（空洞）时活动链跳过空洞、父锚点自动上溯', () {
    RoundStackRow row(String uuid, int index, {String? father, bool use = true}) =>
        RoundStackRow(
          uuid: uuid,
          bookUuid: 'b',
          fatherUuid: father,
          roundIndex: index,
          roundSerialNum: 1,
          roundState: use ? 'use' : null,
        );
    final g1 = row('r1', 1);
    final g2 = row('r2', 2, father: 'r1');
    final g50 = row('r50', 50, father: 'r2');
    final byGroup = RoundStackService.groupRows([g1, g2, g50]);

    expect(RoundStackService.groupRoundIndexes(byGroup), [1, 2, 50]);
    expect(
      RoundStackService.planChain(anchor: g1, byGroup: byGroup)
          .map((r) => r.uuid),
      ['r1', 'r2', 'r50'],
      reason: '3…49 空号不阻断链：从第 2 轮直接走到第 50 轮',
    );
    expect(
      RoundStackService.planChain(anchor: g50, byGroup: byGroup)
          .map((r) => r.uuid),
      ['r50'],
      reason: '链尾无更大轮号 → 到此结束',
    );

    expect(
      RoundStackService.nearestEarlierAnchor({1: 'a1', 2: 'a2'}, 50),
      'a2',
      reason: '50 轮上溯到最近存在的更早一轮（2）',
    );
    expect(RoundStackService.nearestEarlierAnchor({2: 'a2'}, 3), 'a2');
    expect(RoundStackService.nearestEarlierAnchor({}, 0), isNull);
    expect(
      RoundStackService.nearestEarlierAnchor({1: null, 2: 'a2'}, 2),
      isNull,
      reason: '更早一轮存在但没有锚点（未采纳）→ 仍按根处理',
    );
  });

  test('OP-12b 纯函数 subtreeUuids：含自身、跨分支后代、无环重复', () {
    RoundStackRow row(String uuid, int index, {String? father}) => RoundStackRow(
          uuid: uuid,
          bookUuid: 'b',
          fatherUuid: father,
          roundIndex: index,
          roundSerialNum: 1,
        );
    final root = row('r', 1);
    final kids = [
      root,
      row('c1', 2, father: 'r'),
      row('c2', 2, father: 'r'),
      row('c3', 3, father: 'c1'),
      row('c4', 3, father: 'c2'),
      row('other', 2, father: 'x'),
    ];
    final byChildren = RoundStackService.childRows(kids);
    expect(
      RoundStackService.subtreeUuids(root, byChildren),
      ['c1', 'c2', 'c3', 'c4', 'r'],
      reason: '确定性输出（字典序）且只含本子树',
    );
    expect(
      RoundStackService.subtreeUuids(row('leaf', 5), byChildren),
      ['leaf'],
    );
  });
}
