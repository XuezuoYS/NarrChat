import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/sync/sync_models.dart';

import 'helpers/fakes.dart';

/// 「从此代拷贝链至新的分支」的 Provider 集成：
/// - 成功后**不**切分支、分支列表更新、云同步触发一次；
/// - 切过去以后活动链 / 下一轮轮号正确；
/// - 生成中 / 失败代拒绝且不写库。
///
/// 父指针重映射、整棵子代树、根分支 / 链首等数据语义在
/// `round_repository_test.dart` 的「拷贝链至新分支」组里测（隔离层优先）。
void main() {
  const book = Book(uuid: 'b1', title: '测试书');

  late TestStack stack;

  setUp(() async {
    stack = await TestStack.create(prefix: 'branch_chain_copy_');
    await stack.repos.books.createBook(book);
  });

  tearDown(() async {
    await stack.dispose();
  });

  Future<RoundProvider> makeProvider({
    AiService? ai,
    FakeCloudSyncProvider? cloud,
  }) async {
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai ?? ToggleAiService(),
      cloudSyncProvider: cloud ?? FakeCloudSyncProvider(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds(book.uuid);
    return provider;
  }

  test('拷贝成功：新分支不激活，分支列表 +1，切过去链 / 轮号正确', () async {
    await stack.seedRounds(book.uuid, count: 3);
    final cloud = FakeCloudSyncProvider();
    final provider = await makeProvider(cloud: cloud);
    final sourceRounds = provider.rounds.toList();
    final target = sourceRounds[1];
    expect(provider.branches.length, 1, reason: '只有默认分支');
    cloud.triggers = 0;

    final result = await provider.copyChainToNewBranch(round: target);

    expect(result, isNotNull);
    expect(result!.branchName, '分支 2');
    expect(result.generationCount, 2, reason: '目标代（第 2 轮）及其子代（第 3 轮）');
    expect(result.firstRoundIndex, 2);
    expect(result.lastRoundIndex, 3);
    expect(result.branch.fatherRow, sourceRounds.first.uuid);
    expect(result.branch.fatherRowIndex, 1);
    expect(cloud.triggers, 1, reason: '拷贝是内容变更，要上云');
    expect(cloud.lastKind, SyncKind.both);

    // 留在原分支：活动链仍是源分支，只有分支列表多一条。
    expect(provider.workingBranchUuid, '', reason: '拷贝后不自动切分支');
    expect(provider.branches.length, 2, reason: '默认分支 + 新分支');
    expect(
      provider.rounds.map((r) => r.roundIndex),
      [1, 2, 3],
      reason: '当前分支的链一行没动',
    );
    expect(provider.branches.last.branchWorking, isFalse);

    // 点「点击跳转」之后：切到新分支，链从被点那一代开始。
    final switched = await provider.switchBranch(result.branch.branchUuid);
    expect(switched, isTrue);
    expect(provider.workingBranchUuid, result.branch.branchUuid);
    expect(provider.rounds.map((r) => r.roundIndex), [2, 3]);
    expect(provider.nextRoundIndex, 4);
    final sourceUuids = sourceRounds.map((r) => r.uuid).toSet();
    for (final round in provider.rounds) {
      expect(sourceUuids.contains(round.uuid), isFalse, reason: '副本必须是新 uuid');
    }
    expect(provider.currentBranch?.fatherRow, sourceRounds.first.uuid);
  });

  test('生成中：拒绝拷贝并给出原因，不建分支', () async {
    await stack.seedRounds(book.uuid, count: 1);
    final ai = FakeStreamingAiService();
    final provider = await makeProvider(ai: ai);
    final target = provider.rounds.single;

    final sendFuture = provider.sendRound(userInput: '正在生成', book: book);
    expect(provider.isSending, isTrue);
    final result = await provider.copyChainToNewBranch(round: target);
    expect(result, isNull);
    expect(provider.error, contains('生成中'));
    expect(provider.branches.length, 1, reason: '被拒时一条分支都不建');

    // 收尾：放行流式，避免留下悬挂的生成任务。
    ai.complete();
    await sendFuture;
  });

  test('失败代：拒绝拷贝并提示先重新生成', () async {
    await stack.seedRound(
      book.uuid,
      roundIndex: 1,
      userInput: '断线那一次',
      messageStatus: 'error',
      message: '连接超时',
    );
    final provider = await makeProvider();
    final result = await provider.copyChainToNewBranch(
      round: provider.rounds.single,
    );

    expect(result, isNull);
    expect(provider.error, contains('失败代'));
    expect(provider.branches.length, 1);
  });

  test('仓储拒绝（不在活动链上）：错误文案不带 Bad state 前缀', () async {
    await stack.seedRound(
      book.uuid,
      roundIndex: 1,
      userInput: '第一轮',
      aiNarrative: '正文 1',
    );
    await stack.seedRound(
      book.uuid,
      roundIndex: 2,
      userInput: '选中的第二代',
      aiNarrative: '正文 2a',
    );
    final stale = await stack.seedRound(
      book.uuid,
      roundIndex: 2,
      userInput: '未选中的第二代',
      aiNarrative: '正文 2b',
      isUsing: false,
    );
    final provider = await makeProvider();

    final result = await provider.copyChainToNewBranch(
      round: Round.fromGeneration(stale, bookUuid: book.uuid),
    );

    expect(result, isNull);
    expect(provider.error, contains('不在当前活动链上'));
    expect(provider.error ?? '', isNot(contains('Bad state')));
    expect(provider.branches.length, 1);
  });

  test('复制后后续轮未激活代完整、目标代兄弟代不拷', () async {
    // 第 2 轮：选中 g2a / 未启用 g2b；第 3 轮在 g2a 下选中 g3a，另有一条
    // 挂在 g2b 下的隐藏线 g3b→g4c；第 4 轮在 g3a 下有两个版本。
    // 拷贝 g2a 后：
    // - 第 2 轮不应出现 g2b（兄弟代不拷）；
    // - 第 3 轮应出现 g3a + 挂回来的 g3b（未激活）；
    // - 切到 g3b 后，它的隐藏后续 g4c 必须完整存在。
    await stack.seedRound(book.uuid, roundIndex: 1, userInput: '第一轮');
    final g2a = await stack.seedRound(
      book.uuid,
      roundIndex: 2,
      userInput: '第二轮·选中',
      aiNarrative: '正文 2a',
    );
    final g2b = await stack.seedRound(
      book.uuid,
      roundIndex: 2,
      fatherUuid: g2a.fatherUuid,
      userInput: '第二轮·未启用',
      aiNarrative: '正文 2b',
      isUsing: false,
    );
    final g3a = await stack.seedRound(
      book.uuid,
      roundIndex: 3,
      userInput: '第三轮·选中',
      aiNarrative: '正文 3a',
    );
    final g3b = await stack.seedRound(
      book.uuid,
      roundIndex: 3,
      fatherUuid: g2b.uuid,
      userInput: '隐藏线的根',
      aiNarrative: '正文 3b',
    );
    await stack.seedRound(
      book.uuid,
      roundIndex: 4,
      fatherUuid: g3a.uuid,
      userInput: '第四轮·选中',
      aiNarrative: '正文 4a',
    );
    await stack.seedRound(
      book.uuid,
      roundIndex: 4,
      fatherUuid: g3a.uuid,
      userInput: '第四轮·未启用',
      aiNarrative: '正文 4b',
      serialNum: 2,
      isUsing: false,
    );
    await stack.seedRound(
      book.uuid,
      roundIndex: 4,
      fatherUuid: g3b.uuid,
      userInput: '隐藏线的后续',
      aiNarrative: '正文 4c',
    );
    final provider = await makeProvider();

    final result = await provider.copyChainToNewBranch(
      round: provider.rounds[1],
    );
    expect(result, isNotNull);
    await provider.switchBranch(result!.branch.branchUuid);

    // 第 2 轮：只有被点的 g2a，兄弟代不带。
    final round2 = provider.versionInfoFor(2);
    expect(round2, isNotNull);
    expect(round2!.aliveCount, 1, reason: '目标代的兄弟代不该拷过来');
    expect(round2.nextUuid, isNull);

    // 第 3 轮：g3a + 从隐藏线挂回来的 g3b（未激活）。
    final round3 = provider.versionInfoFor(3);
    expect(round3, isNotNull);
    expect(round3!.aliveCount, 2, reason: '隐藏线的根也要作为未激活代在');
    expect(round3.nextUuid, isNotNull, reason: '能切到挂回来的 g3b');

    // 第 4 轮：活动链上（g3a 下）的两代都在。
    final round4 = provider.versionInfoFor(4);
    expect(round4, isNotNull);
    expect(round4!.aliveCount, 2, reason: '第 4 轮的两个版本都要在');
    expect(round4.nextUuid, isNotNull);

    // 切到 g3b 的副本：它的隐藏后续 g4c 必须完整存在。
    final switched = await provider.switchRoundVersion(3, forward: true);
    expect(switched, isTrue);
    expect(provider.rounds.map((r) => r.roundIndex), [2, 3, 4]);
    expect(provider.rounds.last.userInput, '隐藏线的后续');
  });
}
