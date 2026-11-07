import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/sync/sync_models.dart';

import 'helpers/fakes.dart';

/// `RoundProvider` 自动同步触发点测试（R3）。
///
/// 触发白名单（契约 §5）：**内容真变了**才触发云备份——
/// 生成落库 / 生成失败（error 代）/ 用户中断 / 改正文 /
/// 改用户输入 / 改设置字段 / 删轮 / 删分支；
/// **不触发**：切版本（只看哪一代）、切分支（只改本机激活态）。
///
/// 这些用例只关心「触发没触发、触发几次、种类对不对」，不测同步内容本身
/// （那是 `backup_*_test` 的事）。
void main() {
  const book = Book(uuid: 'b1', title: '测试书');

  late TestStack stack;

  setUp(() async {
    stack = await TestStack.create(prefix: 'round_auto_sync_');
    await stack.repos.books.createBook(book);
  });

  tearDown(() async {
    await stack.dispose();
  });

  RoundProvider makeProvider({
    AiService? aiService,
    FakeCloudSyncProvider? cloud,
  }) {
    return RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: aiService ?? ToggleAiService(),
      cloudSyncProvider: cloud ?? FakeCloudSyncProvider(),
      retryDelay: Duration.zero,
    );
  }

  /// 读取书库里的 `book_meta.updated_at`（"内容有没有变"的权威时间戳）。
  Future<DateTime> metaUpdatedAt() async {
    final db = await stack.repos.stores.books.open('b1');
    return (await db.meta.read()).updatedAt;
  }

  /// 建好 provider 并读一次空书，返回 (provider, 云同步替身)。
  Future<(RoundProvider, FakeCloudSyncProvider)> buildLoaded({
    AiService? aiService,
  }) async {
    final cloud = FakeCloudSyncProvider();
    final provider = makeProvider(aiService: aiService, cloud: cloud);
    await provider.loadRounds('b1');
    return (provider, cloud);
  }

  group('内容变更 → 触发一次自动同步', () {
    test('生成成功：轮次落库后触发，种类 both', () async {
      final (rp, cloud) = await buildLoaded();
      expect(cloud.triggers, 0);

      final ok = await rp.sendRound(userInput: '第一轮', book: book);

      expect(ok, isTrue);
      expect(
        rp.rounds.map((r) => r.roundIndex),
        [1],
        reason: 'R3 不再自动创建第零轮',
      );
      expect(cloud.triggers, 1, reason: '成功落库后触发一次自动同步');
      expect(cloud.lastKind, SyncKind.both, reason: '轮次可能带图：数据 + 图片补跑');
    });

    test('生成失败：错误代落库后同样触发', () async {
      final (rp, cloud) = await buildLoaded(
        aiService: ToggleAiService()..fail = true,
      );

      final ok = await rp.sendRound(userInput: '失败轮', book: book);

      expect(ok, isFalse);
      expect(rp.rounds.single.isError, isTrue, reason: '失败就是链上一条 error 代');
      expect(cloud.triggers, 1, reason: '错误代也是内容变更');
    });

    test('用户中断：中断轮落库后同样触发', () async {
      final (rp, cloud) = await buildLoaded();

      final future = rp.sendRound(userInput: '中断轮', book: book);
      rp.cancelGeneration(bookUuid: 'b1');
      final ok = await future;

      expect(ok, isFalse);
      expect(rp.rounds.single.isError, isTrue);
      expect(cloud.triggers, 1, reason: '中断也落一条 error 代，属内容变更');
    });

    test('侧边栏字段保存（updateRoundField）→ 触发一次', () async {
      final (rp, cloud) = await buildLoaded();
      expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
      cloud.triggers = 0;

      final uuid = rp.rounds.single.uuid;
      final ok = await rp.updateRoundField(
        uuid,
        RoundField.worldState,
        '新的世界状态',
      );

      expect(ok, isTrue);
      expect(rp.rounds.single.worldState, '新的世界状态');
      expect(cloud.triggers, 1, reason: '改正文应触发一次');
      expect(cloud.lastKind, SyncKind.both);
    });

    test('AI 正文保存（updateNarrative）→ 触发一次', () async {
      final (rp, cloud) = await buildLoaded();
      expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
      cloud.triggers = 0;

      await rp.updateNarrative(rp.rounds.single.uuid, '修改后的正文');

      expect(rp.rounds.single.aiNarrative, '修改后的正文');
      expect(cloud.triggers, 1);
    });

    test('用户输入保存（updateUserInput）→ 触发一次', () async {
      final (rp, cloud) = await buildLoaded();
      expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
      cloud.triggers = 0;

      await rp.updateUserInput(rp.rounds.single.uuid, '修改后的输入');

      expect(rp.rounds.single.userInput, '修改后的输入');
      expect(cloud.triggers, 1);
    });

    test('非法字段保存被拒 → 不触发', () async {
      final (rp, cloud) = await buildLoaded();
      expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
      cloud.triggers = 0;

      final ok = await rp.updateRoundField(
        rp.rounds.single.uuid,
        'not_a_field',
        'x',
      );

      expect(ok, isFalse);
      expect(cloud.triggers, 0, reason: '未落库的编辑不该触发同步');
    });

    test('删除轮次 → 触发一次（内容真实减少）', () async {
      final (rp, cloud) = await buildLoaded();
      expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
      cloud.triggers = 0;
      final round = rp.rounds.last;

      await rp.deleteRound(round, deleteFollowing: false);

      expect(rp.rounds, isEmpty, reason: '该轮被物理删除');
      expect(cloud.triggers, 1, reason: '删除照旧触发');
    });

    test('删除未启用的代 → 触发一次（内容真实减少）', () async {
      final (rp, cloud) = await buildLoaded();
      expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
      await stack.seedRound(
        'b1',
        roundIndex: 1,
        uuid: 'gen-old',
        isUsing: false,
        aiNarrative: '旧代正文',
      );
      await rp.loadRounds('b1');
      await (await stack.repos.stores.books.open('b1'))
          .meta
          .setUpdatedAt(DateTime.utc(2020));
      cloud.triggers = 0;

      final result = await rp.deleteUnusedGenerations('b1');

      expect(result.deleted, 1);
      expect(rp.versionInfoFor(1)!.aliveCount, 1, reason: '只留下当前选中代');
      expect(cloud.triggers, 1, reason: '删除旧代属内容变更');
      expect(
        (await metaUpdatedAt()).isAfter(DateTime.utc(2020)),
        isTrue,
        reason: '删除代应刷新 book_meta.updated_at',
      );
    });

    test('没有未启用的代可删 → 不触发同步', () async {
      final (rp, cloud) = await buildLoaded();
      expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
      cloud.triggers = 0;

      final result = await rp.deleteUnusedGenerations('b1');

      expect(result.deleted, 0);
      expect(cloud.triggers, 0, reason: '没写库就不该触发同步');
    });
  });

  group('只改"看哪一代 / 哪条分支" → 不触发、不动 updated_at', () {
    /// 造出同组两代，返回 provider 与云同步替身。
    Future<(RoundProvider, FakeCloudSyncProvider)> withTwoGenerations() async {
      final (rp, cloud) = await buildLoaded();
      expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
      // 同组再补一代（模拟「重写本轮」留下的旧代），切换才有目标。
      await stack.seedRound(
        'b1',
        roundIndex: 1,
        uuid: 'gen-old',
        isUsing: false,
        aiNarrative: '另一代正文',
      );
      await rp.loadRounds('b1');
      cloud.triggers = 0;
      return (rp, cloud);
    }

    test('切换版本：不触发同步，也不刷新 updated_at', () async {
      final (rp, cloud) = await withTwoGenerations();
      final before = await metaUpdatedAt();

      final info = rp.versionInfoFor(1);
      expect(info, isNotNull, reason: '两代存活 → 控件可切换');
      expect(info!.switchable, isTrue);
      // 当前选中是第一代（序号 1），所以只能往后切。
      expect(info.prevUuid, isNull);
      expect(info.nextUuid, isNotNull);

      final switched = await rp.switchRoundVersion(1, forward: true);

      expect(switched, isTrue);
      expect(rp.rounds.single.uuid, info.nextUuid, reason: '真的切到另一代');
      expect(cloud.triggers, 0, reason: '切换只改"看哪一代"，不是内容变更');
      expect(
        await metaUpdatedAt(),
        before,
        reason: '切换版本不得刷新 book_meta.updated_at',
      );
    });

    test('切换分支：不触发同步，也不刷新 updated_at', () async {
      final (rp, cloud) = await buildLoaded();
      expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
      // 从第 1 轮分叉：建分支并自动切到新分支（分支内暂无轮次）。
      final branchUuid = await rp.forkBranch(round: rp.rounds.single);
      expect(branchUuid, isNotNull);
      expect(rp.workingBranchUuid, branchUuid);
      expect(rp.rounds, isEmpty, reason: '新分支还没生成过');

      cloud.triggers = 0;
      final before = await metaUpdatedAt();

      final switched = await rp.switchBranch('');
      expect(switched, isTrue);
      expect(rp.workingBranchUuid, '', reason: '切回默认分支');
      expect(rp.rounds, hasLength(1), reason: '默认分支的活动链回来了');
      expect(cloud.triggers, 0, reason: '切分支只改本机激活态');
      expect(
        await metaUpdatedAt(),
        before,
        reason: '切分支不得刷新 book_meta.updated_at',
      );
    });
  });

  test('删除分支 → 触发一次（分支内容真实消失）', () async {
    final (rp, cloud) = await buildLoaded();
    expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
    final branchUuid = await rp.forkBranch(round: rp.rounds.first);
    expect(branchUuid, isNotNull);
    cloud.triggers = 0;

    final ok = await rp.deleteBranch(branchUuid!);

    expect(ok, isTrue);
    expect(cloud.triggers, 1, reason: '删分支删掉了它的轮次，属内容变更');
    expect(rp.workingBranchUuid, '', reason: '删掉激活分支后回到默认分支');
  });

  // 兼容旧调用点的方法在 R3 只剩"重载"语义：不该产生任何触发。
  test('reloadCurrent（原采纳入口）→ 只重载，不触发同步', () async {
    final (rp, cloud) = await buildLoaded();
    expect(await rp.sendRound(userInput: '第一轮', book: book), isTrue);
    cloud.triggers = 0;

    await rp.reloadCurrent();

    expect(rp.rounds, hasLength(1));
    expect(cloud.triggers, 0, reason: '重载不是内容变更');
  });
}
