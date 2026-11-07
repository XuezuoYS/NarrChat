import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_db.dart';
import 'package:narrchat/database/book_db_pool.dart';
import 'package:narrchat/models/book_meta.dart';
import 'package:narrchat/models/branch.dart';
import 'package:narrchat/models/branch_father_snapshot.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/repositories/round_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 轮次仓储：活动链、版本组、分支操作、提示词上文拼合。
void main() {
  final tempDirs = <Directory>[];
  late Directory userData;
  late BookDbPool pool;
  late RoundRepository repository;
  late BookDb book;

  final epoch = DateTime.utc(2026, 1, 1);

  String newTempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    tempDirs.add(dir);
    return dir.path;
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    userData = Directory(newTempDir('round_repo_'));
    pool = BookDbPool(booksDir: p.join(userData.path, 'books'));
    repository = RoundRepository(books: pool);
    book = await BookDb.create(
      meta: BookMeta(
        bookUuid: 'b1',
        masterUuid: 'm',
        title: '书',
        createdAt: epoch,
        updatedAt: epoch,
      ),
      pathOverride: p.join(userData.path, 'books', 'narrbook_b1.db'),
    );
  });

  tearDown(() async {
    await pool.closeAll();
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

  RoundGeneration gen(
    String uuid,
    int index, {
    String? father,
    String branch = '',
    int serial = 1,
    bool using = false,
    String narrative = '',
    String status = '',
    String message = '',
  }) {
    return RoundGeneration(
      meta: RoundMeta(
        uuid: uuid,
        fatherUuid: father,
        branchUuid: branch,
        roundIndex: index,
        roundSerialNum: serial,
        isUsing: using,
        operatedAt: epoch,
        messageStatus: status,
        message: message,
      ),
      userInput: '问-$uuid',
      aiNarrative: narrative.isEmpty ? '正文-$uuid' : narrative,
    );
  }

  Future<void> seedChain() async {
    await book.rounds.insert(gen('g1', 1, using: true));
    await book.rounds.insert(gen('g2', 2, father: 'g1', using: true));
    await book.rounds.insert(gen('g3', 3, father: 'g2', using: true));
  }

  test('活动链：按父指针串起来，正文随链带出', () async {
    await seedChain();
    final chain = await repository.loadChain('b1');

    expect(chain.rounds.map((r) => r.uuid), ['g1', 'g2', 'g3']);
    expect(chain.rounds.map((r) => r.roundIndex), [1, 2, 3]);
    expect(chain.rounds.first.aiNarrative, '正文-g1');
    expect(chain.rounds.first.bookUuid, 'b1');
    expect(chain.workingBranch, Branch.defaultBranchUuid);
    expect(chain.nextRoundIndex, 4);
    expect(chain.tail!.uuid, 'g3');
    expect(chain.allMeta.length, 3);
  });

  test('版本组：同组代数与当前序号', () async {
    await book.rounds.insert(gen('g1', 1, using: true));
    await book.rounds.insert(gen('g2', 1, father: null, serial: 2));
    await book.rounds.insert(gen('g3', 1, father: null, serial: 3));

    final chain = await repository.loadChain('b1');
    final set = chain.generationSetOf('g1');
    expect(set.total, 3);
    expect(set.hasMultiple, isTrue);
    expect(set.currentIndex, 1);
    expect(set.current!.uuid, 'g1');

    // 没选中的代也属于同一组：组内当前仍是 g1。
    final other = chain.generationSetOf('g2');
    expect(other.total, 3);
    expect(other.current!.uuid, 'g1');
    expect(other.currentIndex, 1);
  });

  test('切换版本：链内容跟着换，且不刷新 updated_at', () async {
    await book.rounds.insert(gen('g1', 1, using: true));
    await book.rounds.insert(gen('g2', 1, serial: 2, narrative: '另一版'));
    final beforeTouch = (await book.meta.read()).updatedAt;

    await repository.switchGeneration(bookUuid: 'b1', generationUuid: 'g2');
    final chain = await repository.loadChain('b1');
    expect(chain.rounds.single.uuid, 'g2');
    expect(chain.rounds.single.aiNarrative, '另一版');
    expect((await book.meta.read()).updatedAt, beforeTouch,
        reason: '看哪一代不是内容变更');
  });

  test('删除一代：唯一一代被拒绝，多代时删后代并回落前一代', () async {
    await book.rounds.insert(gen('g1', 1, using: true));
    final refused = await repository.deleteGeneration(
      bookUuid: 'b1',
      generationUuid: 'g1',
    );
    expect(refused.isRefused, isTrue);
    expect(refused.refusal, contains('删除本轮'));

    await book.rounds.insert(gen('g2', 1, serial: 2, using: true));
    await book.rounds.insert(gen('n1', 2, father: 'g2', using: true));
    await book.rounds.insert(gen('n2', 3, father: 'n1', using: true));

    final result = await repository.deleteGeneration(
      bookUuid: 'b1',
      generationUuid: 'g2',
    );
    expect(result.isRefused, isFalse);
    expect(result.deleted, 3);
    final chain = await repository.loadChain('b1');
    expect(chain.rounds.single.uuid, 'g1', reason: '回落到前一代');
  });

  test('删除未启用的代：保留选中代与活动链，连带删除不可达后代', () async {
    await book.rounds.insert(gen('g1', 1, using: true));
    await book.rounds.insert(gen('old1', 1, serial: 2));
    await book.rounds.insert(gen('g2', 2, father: 'g1', using: true));
    await book.rounds.insert(gen('ghost1', 2, father: 'old1', using: true));
    await book.rounds.insert(gen('ghost2', 3, father: 'ghost1', using: true));
    // 用一个远古时间戳做锚点，确认删除会刷新 updated_at（内容变更）。
    await book.meta.setUpdatedAt(epoch);

    final result = await repository.deleteUnusedGenerations(bookUuid: 'b1');

    expect(result.deleted, 3, reason: '未启用的 old1 + 只能从它到达的 ghost1/ghost2');
    final metas = await book.rounds.listMeta();
    expect(metas.map((m) => m.uuid).toSet(), {'g1', 'g2'});
    final chain = await repository.loadChain('b1');
    expect(chain.rounds.map((r) => r.uuid), ['g1', 'g2'],
        reason: '活动链原样保留');
    expect((await book.meta.read()).updatedAt.isAfter(epoch), isTrue,
        reason: '删除代属内容变更');
  });

  test('删除未启用的代：没有可删项时返回 0 且不动 updated_at', () async {
    await seedChain();
    await book.meta.setUpdatedAt(epoch);

    final result = await repository.deleteUnusedGenerations(bookUuid: 'b1');

    expect(result.deleted, 0);
    expect((await book.rounds.listMeta()).length, 3);
    expect((await book.meta.read()).updatedAt, epoch,
        reason: '没删东西就不刷新时间戳');
  });

  test('删除本轮及之后：本分支后续清空，前面保留', () async {
    await seedChain();
    final result = await repository.deleteRoundAndFollowing(
      bookUuid: 'b1',
      roundIndex: 2,
    );
    expect(result.deleted, 2);
    final chain = await repository.loadChain('b1');
    expect(chain.rounds.map((r) => r.uuid), ['g1']);
  });

  test('分叉：建分支并切换，分支内暂无轮次；第一轮接在分叉点之后', () async {
    await seedChain();
    final branch = await repository.forkBranch(
      bookUuid: 'b1',
      generationUuid: 'g2',
      branchName: '如果',
    );
    expect(branch.fatherRow, 'g2');
    expect(branch.fatherRowIndex, 2);

    final emptyChain = await repository.loadChain('b1');
    expect(emptyChain.rounds, isEmpty);
    expect(emptyChain.workingBranch, branch.branchUuid);
    expect(emptyChain.nextRoundIndex, 3, reason: '分叉点 2 + 1');

    await book.rounds.insert(gen(
      'b1r1',
      3,
      branch: branch.branchUuid,
      using: true,
    ));
    final chain = await repository.loadChain('b1');
    expect(chain.rounds.single.uuid, 'b1r1');
    expect(chain.allBranches.length, 2, reason: '默认分支 + 这一条 IF 线');
  });

  test('失败代不能分叉', () async {
    await book.rounds.insert(gen('e1', 1, using: true, status: 'error'));
    await expectLater(
      repository.forkBranch(
        bookUuid: 'b1',
        generationUuid: 'e1',
        branchName: 'x',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('分支改名与删除：默认分支不可删，子分支记录保留', () async {
    await seedChain();
    final branch = await repository.forkBranch(
      bookUuid: 'b1',
      generationUuid: 'g1',
      branchName: '旧名',
    );
    await repository.renameBranch(
      bookUuid: 'b1',
      branchUuid: branch.branchUuid,
      name: '新名',
    );
    final chain = await repository.loadChain('b1');
    expect(chain.branches.single.branchName, '新名');

    await book.rounds.insert(gen('x1', 2, branch: branch.branchUuid, using: true));
    final result = await repository.deleteBranch(
      bookUuid: 'b1',
      branchUuid: branch.branchUuid,
    );
    expect(result.deleted, 1);
    final after = await repository.loadChain('b1');
    expect(after.branches, isEmpty);
    expect(after.workingBranch, Branch.defaultBranchUuid,
        reason: '删掉激活分支后回到默认分支');
    expect(after.rounds.map((r) => r.uuid), ['g1', 'g2', 'g3']);

    final refused = await repository.deleteBranch(
      bookUuid: 'b1',
      branchUuid: Branch.defaultBranchUuid,
    );
    expect(refused.isRefused, isTrue);
  });

  test('提示词上文：跳过 error 代，按历史轮数截断', () async {
    await book.rounds.insert(gen('g1', 1, using: true));
    await book.rounds.insert(gen('e2', 2, father: 'g1', serial: 2, status: 'error'));
    await book.rounds.insert(gen('g3', 3, father: 'e2', using: true));

    final chain = await repository.loadChain('b1');
    expect(chain.rounds.map((r) => r.uuid), ['g1', 'e2', 'g3'],
        reason: 'error 代仍在链上，界面要展示红条');

    final context = await repository.buildPromptContext(
      bookUuid: 'b1',
      chain: chain,
      historyRounds: 10,
    );
    expect(context.rounds.map((r) => r.uuid), ['g1', 'g3'],
        reason: '拼给模型时跳过 error 代');

    final limited = await repository.buildPromptContext(
      bookUuid: 'b1',
      chain: chain,
      historyRounds: 1,
    );
    expect(limited.rounds.map((r) => r.uuid), ['g3']);
  });

  test('提示词上文：跨分支上溯到父分支', () async {
    await seedChain();
    final branch = await repository.forkBranch(
      bookUuid: 'b1',
      generationUuid: 'g2',
      branchName: '如果',
    );
    await book.rounds.insert(gen('b1r1', 3, branch: branch.branchUuid, using: true));

    final chain = await repository.loadChain('b1');
    final context = await repository.buildPromptContext(
      bookUuid: 'b1',
      chain: chain,
      historyRounds: 10,
    );
    expect(context.rounds.map((r) => r.uuid), ['g1', 'g2', 'b1r1']);
    expect(context.truncated, isFalse);
  });

  test('提示词上文：刚分叉的空分支也要拿父分支到分叉点的轮次', () async {
    await seedChain();
    await repository.forkBranch(
      bookUuid: 'b1',
      generationUuid: 'g2',
      branchName: '如果',
    );

    final chain = await repository.loadChain('b1');
    expect(chain.rounds, isEmpty, reason: '分支内还没生成过');
    final context = await repository.buildPromptContext(
      bookUuid: 'b1',
      chain: chain,
      historyRounds: 10,
    );
    expect(
      context.rounds.map((r) => r.uuid),
      ['g1', 'g2'],
      reason: '首轮生成前必须拿到分叉点及以前的父上文',
    );
    expect(context.fallback, isNull);
    expect(context.truncated, isFalse);
  });

  test('父上文前缀：默认分支为空，空分支取分叉点及以前并受 limit 截断', () async {
    await seedChain();
    final defaultChain = await repository.loadChain('b1');
    final emptyDefault = await repository.loadUpstreamContext(
      bookUuid: 'b1',
      chain: defaultChain,
      limit: 10,
    );
    expect(emptyDefault.rounds, isEmpty);
    expect(emptyDefault.fallbackRound, isNull);

    await repository.forkBranch(
      bookUuid: 'b1',
      generationUuid: 'g2',
      branchName: '如果',
    );
    final branchChain = await repository.loadChain('b1');
    final all = await repository.loadUpstreamContext(
      bookUuid: 'b1',
      chain: branchChain,
      limit: 10,
    );
    expect(all.rounds.map((r) => r.uuid), ['g1', 'g2']);
    expect(all.fallbackRound, isNull);

    final recent = await repository.loadUpstreamContext(
      bookUuid: 'b1',
      chain: branchChain,
      limit: 1,
    );
    expect(
      recent.rounds.map((r) => r.uuid),
      ['g2'],
      reason: '只取最近 limit 条父轮次',
    );
  });

  test('父上文前缀：父代已删时用快照轮兜底，分支仍为空', () async {
    await seedChain();
    final branch = await repository.forkBranch(
      bookUuid: 'b1',
      generationUuid: 'g2',
      branchName: '如果',
    );
    // 回主线删掉分叉点及之后，再切回空分支。
    await repository.switchBranch(
      bookUuid: 'b1',
      branchUuid: Branch.defaultBranchUuid,
    );
    await repository.deleteRoundAndFollowing(bookUuid: 'b1', roundIndex: 2);
    await repository.switchBranch(
      bookUuid: 'b1',
      branchUuid: branch.branchUuid,
    );

    final chain = await repository.loadChain('b1');
    final upstream = await repository.loadUpstreamContext(
      bookUuid: 'b1',
      chain: chain,
      limit: 10,
    );
    expect(upstream.rounds, isEmpty);
    expect(upstream.fallbackRound, isNotNull);
    expect(upstream.fallbackRound!.uuid, 'g2');
    expect(upstream.fallbackRound!.userInput, '问-g2');
  });

  test('提示词上文：父代已删时用快照兜底一轮', () async {
    await seedChain();
    final branch = await repository.forkBranch(
      bookUuid: 'b1',
      generationUuid: 'g2',
      branchName: '如果',
    );
    await book.rounds.insert(gen('b1r1', 3, branch: branch.branchUuid, using: true));

    // 回主线把父代 g2 及其之后删掉，分支的父代就"消失"了
    await repository.switchBranch(
      bookUuid: 'b1',
      branchUuid: Branch.defaultBranchUuid,
    );
    await repository.deleteRoundAndFollowing(bookUuid: 'b1', roundIndex: 2);
    await repository.switchBranch(
      bookUuid: 'b1',
      branchUuid: branch.branchUuid,
    );

    final chain = await repository.loadChain('b1');
    final context = await repository.buildPromptContext(
      bookUuid: 'b1',
      chain: chain,
      historyRounds: 10,
    );
    expect(context.rounds.map((r) => r.uuid), ['b1r1']);
    expect(context.fallback, isNotNull);
    expect(context.fallback!.uuid, 'g2', reason: '快照是分叉那一刻的父代');
  });

  test('空书：链为空但 nextRoundIndex 从 1 起', () async {
    final chain = await repository.loadChain('b1');
    expect(chain.rounds, isEmpty);
    expect(chain.nextRoundIndex, 1);
    final context = await repository.buildPromptContext(
      bookUuid: 'b1',
      chain: chain,
      historyRounds: 5,
    );
    expect(context.rounds, isEmpty);
  });

  test('超长提示在写入口被截断（插代 / 批量导入 / 改元信息都收口）', () async {
    final long = '提' * (BookDb.maxMessageLength + 2000);

    // ① 插代路径
    await book.rounds.insert(
      gen('g1', 1, using: true, status: 'error', message: long),
    );
    final inserted = (await book.rounds.generation('g1'))!;
    expect(inserted.meta.message.length, BookDb.maxMessageLength);
    expect(inserted.meta.message.endsWith('…'), isTrue, reason: '截断处有省略号');

    // ② 批量导入路径（迁移 / 还原走这条）
    await book.rounds.importAll([
      gen('g2', 2, father: 'g1', status: 'warning', message: long),
    ]);
    final imported = (await book.rounds.generation('g2'))!;
    expect(imported.meta.message.length, BookDb.maxMessageLength);

    // ③ 改元信息路径（`updateMeta`：写提示等元信息列，同样收口）
    await book.rounds.updateMeta('g1', {
      'message_status': 'warning',
      'message': long,
    });
    final updated = (await book.rounds.generation('g1'))!;
    expect(updated.meta.message.length, BookDb.maxMessageLength);
    expect(updated.meta.messageStatus, 'warning');

    // 清空仍然是空串：不能被截断逻辑变成「只剩一个省略号」。
    await book.rounds.updateMeta('g1', {'message_status': '', 'message': ''});
    final cleared = (await book.rounds.generation('g1'))!;
    expect(cleared.meta.message, isEmpty);
  });

  group('拷贝链至新分支', () {
    /// 第 2 轮有一对兄弟代（g2a 选中）、第 3 轮有两个版本（g3a 选中），
    /// 以及一条只挂在 g2b 下面的 g3b —— 用来证明「只拷目标子树」。
    Future<void> seedCopyTree() async {
      await book.rounds.insert(gen('g1', 1, using: true));
      await book.rounds.insert(
        gen('g2a', 2, father: 'g1', using: true, narrative: '正文-g2a'),
      );
      await book.rounds.insert(gen('g2b', 2, father: 'g1', serial: 2));
      await book.rounds.insert(gen('g3a', 3, father: 'g2a', using: true));
      await book.rounds.insert(
        gen('g3a2', 3, father: 'g2a', serial: 2, message: '另一版本'),
      );
      await book.rounds.insert(gen('g3b', 3, father: 'g2b', using: true));
      await book.rounds.insert(gen('g4a', 4, father: 'g3a', using: true));
    }

    test('整棵子代树：新 uuid / 父指针重映射 / 源分支不变 / 新分支不激活', () async {
      await seedCopyTree();
      final sourceMetaCount = (await book.rounds.listMeta()).length;
      // 把 updated_at 拨回过去，才能证明拷贝确实刷新了它。
      await book.meta.setUpdatedAt(DateTime.utc(2000));
      final progress = <(int, int)>[];

      final result = await repository.copyChainToNewBranch(
        bookUuid: 'b1',
        fromGenerationUuid: 'g2a',
        branchName: '分支 2',
        onProgress: (done, total) => progress.add((done, total)),
      );

      expect(result.generationCount, 4, reason: 'g2a + g3a/g3a2 + g4a');
      expect(result.firstRoundIndex, 2);
      expect(result.lastRoundIndex, 4);
      expect(result.branchName, '分支 2');

      // 分支行：父级 = 目标代的父代 g1，且不激活。
      expect(result.branch.fatherRow, 'g1');
      expect(result.branch.fatherRowIndex, 1);
      expect(result.branch.fatherBranch, '');
      expect(result.branch.branchWorking, isFalse);
      final shot = BranchFatherSnapshot.decode(result.branch.fatherRowShot)!;
      expect(shot.uuid, 'g1');

      // 源分支一行不改，新分支只有 4 行。
      final metas = await book.rounds.listMeta();
      expect(metas.length, sourceMetaCount + 4);
      final copied =
          metas.where((m) => m.branchUuid == result.branch.branchUuid).toList();
      expect(copied.length, 4);
      expect(
        copied.map((m) => (m.roundIndex, m.roundSerialNum)).toSet(),
        {(2, 1), (3, 1), (3, 2), (4, 1)},
        reason: '轮号 / 代序号原样保留',
      );
      RoundMeta copyOf(int index, int serial) => copied.firstWhere(
        (m) => m.roundIndex == index && m.roundSerialNum == serial,
      );
      final c2 = copyOf(2, 1);
      final c3 = copyOf(3, 1);
      final c3old = copyOf(3, 2);
      final c4 = copyOf(4, 1);
      expect(c2.fatherUuid, isNull, reason: '链首副本的 father_uuid 为 NULL');
      expect(c3.fatherUuid, c2.uuid);
      expect(c3old.fatherUuid, c2.uuid, reason: '同轮兄弟代也重映射到同一个父副本');
      expect(c4.fatherUuid, c3.uuid);
      expect(c3.isUsing, isTrue);
      expect(c3old.isUsing, isFalse, reason: 'is_using 原样保留');
      expect(c3old.message, '另一版本');

      // 内容原样：新代 uuid 与源代不重叠，正文 / 输入完整带过来。
      final sourceUuids = {
        'g1', 'g2a', 'g2b', 'g3a', 'g3a2', 'g3b', 'g4a',
      };
      for (final meta in copied) {
        expect(sourceUuids.contains(meta.uuid), isFalse);
      }
      final copiedG2 = (await book.rounds.generation(c2.uuid))!;
      expect(copiedG2.userInput, '问-g2a');
      expect(copiedG2.aiNarrative, '正文-g2a');
      final copiedG3 = (await book.rounds.generation(c3.uuid))!;
      expect(copiedG3.userInput, '问-g3a');

      // 不在目标子树里的 g2b / g3b 一个都没被带走（用源代仍在证明没删源）。
      expect((await book.rounds.generation('g2b')), isNotNull);
      expect((await book.rounds.generation('g3b')), isNotNull);

      // 内容变更：updated_at 被刷新；工作分支仍是默认分支。
      final updatedAt = (await book.meta.read()).updatedAt;
      expect(updatedAt.isAfter(DateTime.utc(2000)), isTrue);
      final working = await repository.loadChain('b1');
      expect(working.workingBranch, Branch.defaultBranchUuid);
      expect(working.branches.single.branchWorking, isFalse);

      // 进度：开始 0/N，结束 N/N。
      expect(progress.first, (0, 4));
      expect(progress.last, (4, 4));
      for (final (done, total) in progress) {
        expect(total, 4);
        expect(done, inInclusiveRange(0, 4));
      }
    });

    test('新分支的提示词上文 = 父代 + 拷贝链（不重复）', () async {
      await seedCopyTree();
      final result = await repository.copyChainToNewBranch(
        bookUuid: 'b1',
        fromGenerationUuid: 'g2a',
        branchName: '分支 2',
      );
      await repository.switchBranch(
        bookUuid: 'b1',
        branchUuid: result.branch.branchUuid,
      );

      final chain = await repository.loadChain('b1');
      expect(chain.rounds.map((r) => r.roundIndex), [2, 3, 4]);
      expect(chain.rounds.map((r) => r.uuid), isNot(contains('g2a')));
      expect(chain.nextRoundIndex, 5);

      final context = await repository.buildPromptContext(
        bookUuid: 'b1',
        chain: chain,
        historyRounds: 10,
      );
      expect(
        context.rounds.map((r) => r.roundIndex),
        [1, 2, 3, 4],
        reason: '父代 g1 + 拷贝链；不能把 g2a 之前的父级重复一遍',
      );
      expect(context.rounds.first.uuid, 'g1');
      expect(
        context.rounds.where((r) => r.userInput == '问-g2a').length,
        1,
        reason: '目标代只以副本形式出现一次',
      );

      final upstream = await repository.loadUpstreamContext(
        bookUuid: 'b1',
        chain: chain,
        limit: 10,
      );
      expect(upstream.rounds.map((r) => r.uuid), ['g1']);
      expect(upstream.fallbackRound, isNull);
    });

    test('目标是链首：沿用源分支的父级四列', () async {
      await seedChain();
      final source = await repository.forkBranch(
        bookUuid: 'b1',
        generationUuid: 'g2',
        branchName: '源分支',
      );
      // fork 后工作分支已是源分支；补两轮链首 / 后续。
      await book.rounds.insert(
        gen('b3', 3, branch: source.branchUuid, using: true),
      );
      await book.rounds.insert(
        gen('b4', 4, father: 'b3', branch: source.branchUuid, using: true),
      );

      final result = await repository.copyChainToNewBranch(
        bookUuid: 'b1',
        fromGenerationUuid: 'b3',
        branchName: '拷贝分支',
      );

      expect(result.branch.fatherRow, 'g2', reason: '链首的父级 = 源分支的分叉点');
      expect(result.branch.fatherRowIndex, 2);
      expect(result.branch.fatherBranch, '');
      expect(result.generationCount, 2);
      final copied = (await book.rounds.listMeta())
          .where((m) => m.branchUuid == result.branch.branchUuid)
          .toList();
      final root = copied.firstWhere((m) => m.fatherUuid == null);
      expect(root.roundIndex, 3);
      expect(
        copied.firstWhere((m) => m.fatherUuid == root.uuid).roundIndex,
        4,
      );

      // 工作分支仍是源分支；切过去后上文从 g1 / g2 接回来。
      expect((await repository.loadChain('b1')).workingBranch,
          source.branchUuid);
      await repository.switchBranch(
        bookUuid: 'b1',
        branchUuid: result.branch.branchUuid,
      );
      final chain = await repository.loadChain('b1');
      final context = await repository.buildPromptContext(
        bookUuid: 'b1',
        chain: chain,
        historyRounds: 10,
      );
      expect(context.rounds.map((r) => r.roundIndex), [1, 2, 3, 4]);
      expect(context.rounds[1].uuid, 'g2');
    });

    test('默认分支第 1 轮：根分支（无父级），整链拷走', () async {
      await seedChain();
      final result = await repository.copyChainToNewBranch(
        bookUuid: 'b1',
        fromGenerationUuid: 'g1',
        branchName: '根拷贝',
      );

      expect(result.branch.fatherRow, isEmpty);
      expect(result.branch.fatherBranch, isEmpty);
      expect(result.branch.fatherRowShot, isEmpty);
      expect(result.branch.fatherRowIndex, 1);
      expect(result.generationCount, 3);

      await repository.switchBranch(
        bookUuid: 'b1',
        branchUuid: result.branch.branchUuid,
      );
      final chain = await repository.loadChain('b1');
      expect(chain.rounds.map((r) => r.roundIndex), [1, 2, 3]);
      expect(chain.nextRoundIndex, 4);
      final upstream = await repository.loadUpstreamContext(
        bookUuid: 'b1',
        chain: chain,
        limit: 10,
      );
      expect(upstream.rounds, isEmpty);
      expect(upstream.fallbackRound, isNull);
    });

    test('失败代 / 不在活动链上的代 / 找不到代：拒绝且不落库', () async {
      await seedChain();
      await book.rounds.insert(gen('g2b', 2, father: 'g1', serial: 2));
      await book.rounds.insert(
        gen('e4', 4, father: 'g3', status: 'error', using: true),
      );
      final before = (await book.rounds.listMeta()).length;

      await expectLater(
        repository.copyChainToNewBranch(
          bookUuid: 'b1',
          fromGenerationUuid: 'e4',
          branchName: 'x',
        ),
        throwsA(isA<StateError>()),
        reason: '失败代不能拷贝',
      );
      await expectLater(
        repository.copyChainToNewBranch(
          bookUuid: 'b1',
          fromGenerationUuid: 'g2b',
          branchName: 'x',
        ),
        throwsA(isA<StateError>()),
        reason: '非当前活动链上的代不能拷贝',
      );
      await expectLater(
        repository.copyChainToNewBranch(
          bookUuid: 'b1',
          fromGenerationUuid: 'missing',
          branchName: 'x',
        ),
        throwsA(isA<StateError>()),
      );

      expect((await book.rounds.listMeta()).length, before);
      final chain = await repository.loadChain('b1');
      expect(chain.branches, isEmpty, reason: '被拒时不留下半条分支');
    });
  });
}
