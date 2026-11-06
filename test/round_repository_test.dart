import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_db.dart';
import 'package:narrchat/database/book_db_pool.dart';
import 'package:narrchat/models/book_meta.dart';
import 'package:narrchat/models/branch.dart';
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

    // ③ 改元信息路径（关闭提示 / 生成后写警告走这条）
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
}
