import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/round_stack.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/sync/sync_models.dart';

import 'helpers/fakes.dart';

/// `RoundProvider` 生成结束自动同步触发测试：
/// - 成功落库后触发一次自动同步；
/// - 失败（红框报错条目）后同样触发；
/// - 触发发生在数据落库之后（成功路径轮次已入库）；
/// - 触发种类为 both（轮次含图片引用：数据推送 + 图片补跑一起排队）；
/// - v19 版本切换**不**触发（只改投影，不改内容权威，见 [FakeCloudSyncProvider]）。
void main() {
  const book = Book(uuid: 'b1', title: '测试书');

  ({RoundProvider provider, FakeRoundDao dao, FakeRoundStackService stack,
    FakeCloudSyncProvider cloud, FakeBookDao bookDao}) build({
    List<RoundStackMeta> metas = const [],
    AiService? aiService,
  }) {
    final dao = FakeRoundDao();
    final stack = FakeRoundStackService(roundDao: dao)..metas = List.of(metas);
    final bookDao = FakeBookDao();
    final cloud = FakeCloudSyncProvider();
    final rp = RoundProvider(
      dao: dao,
      roundStackService: stack,
      bookDao: bookDao,
      aiService: aiService ?? ToggleAiService(),
      cloudSyncProvider: cloud,
      retryDelay: Duration.zero,
    );
    return (provider: rp, dao: dao, stack: stack, cloud: cloud, bookDao: bookDao);
  }

  /// 既有用例的简写：构造并加载好 `b1`，返回 (Provider, 云同步替身)。
  Future<(RoundProvider, FakeCloudSyncProvider)> buildLoaded() async {
    final env = build();
    await env.provider.loadRounds('b1');
    return (env.provider, env.cloud);
  }

  test('生成成功 → 触发一次自动同步（轮次已落库）', () async {
    final (rp, cloud) = await buildLoaded();
    expect(cloud.triggers, 0);

    final ok = await rp.sendRound(userInput: '第一轮', book: book);

    expect(ok, isTrue);
    expect(rp.rounds, hasLength(2), reason: '第零轮 + 成功一轮');
    expect(cloud.triggers, 1, reason: '成功落库后触发一次性自动同步');
    expect(cloud.lastKind, SyncKind.both, reason: '轮次可能带图：数据 + 图片补跑');
  });

  test('生成失败（红框报错条目）→ 同样触发自动同步', () async {
    final env = build(aiService: ToggleAiService()..fail = true);
    final rp = env.provider;
    await rp.loadRounds('b1');

    final ok = await rp.sendRound(userInput: '失败轮', book: book);

    expect(ok, isFalse);
    expect(rp.hasFailureEntry, isTrue, reason: '失败条目已落库（红框）');
    expect(env.cloud.triggers, 1, reason: '失败条目落库后同样触发自动同步');
  });

  test('生成取消（中断）→ 同样触发自动同步', () async {
    final env = build();
    final rp = env.provider;
    await rp.loadRounds('b1');

    final future = rp.sendRound(userInput: '中断轮', book: book);
    rp.cancelGeneration(bookUuid: 'b1');
    final ok = await future;

    expect(ok, isFalse);
    expect(env.cloud.triggers, 1, reason: '用户中断后（失败条目）同样触发自动同步');
  });

  test('侧边栏字段保存（updateRoundField）→ 触发一次自动同步', () async {
    final (rp, cloud) = await buildLoaded();
    final roundId = rp.rounds.single.id!;
    expect(cloud.triggers, 0);

    final ok = await rp.updateRoundField(
      roundId,
      RoundField.worldState,
      '新的世界状态',
    );

    expect(ok, isTrue);
    expect(rp.rounds.single.worldState, '新的世界状态');
    expect(cloud.triggers, 1, reason: '侧边栏保存后应触发一次自动同步');
    expect(cloud.lastKind, SyncKind.both, reason: '与生成结束触发种类一致');
  });

  test('AI 正文保存（updateNarrative）→ 触发一次自动同步', () async {
    final (rp, cloud) = await buildLoaded();
    final roundId = rp.rounds.single.id!;
    expect(cloud.triggers, 0);

    await rp.updateNarrative(roundId, '修改后的正文');

    expect(rp.rounds.single.aiNarrative, '修改后的正文');
    expect(cloud.triggers, 1, reason: '编辑 AI 正文保存后应触发一次自动同步');
  });

  test('用户输入保存（updateUserInput）→ 触发一次自动同步', () async {
    final (rp, cloud) = await buildLoaded();
    final roundId = rp.rounds.single.id!;
    expect(cloud.triggers, 0);

    await rp.updateUserInput(roundId, '修改后的输入');

    expect(rp.rounds.single.userInput, '修改后的输入');
    expect(cloud.triggers, 1, reason: '编辑用户输入保存后应触发一次自动同步');
  });

  test('非法字段保存被拒 → 不触发同步', () async {
    final (rp, cloud) = await buildLoaded();
    final roundId = rp.rounds.single.id!;

    final ok = await rp.updateRoundField(roundId, 'not_a_field', 'x');

    expect(ok, isFalse);
    expect(cloud.triggers, 0, reason: '未落库的编辑不应触发同步');
  });

  group('版本树写路径（SY-6）', () {
    test('切换版本（switchRoundVersion）→ 不触发同步（只改投影，不改内容权威）', () async {
      final env = build();
      await env.provider.loadRounds('b1');
      expect(await env.provider.sendRound(userInput: '第一章', book: book), isTrue);
      // 投影行 id 变动后同步触发已计入上一行；此处清零，只看切换本身。
      env.cloud.triggers = 0;

      // 同一分组再补一代（模拟「重写本轮」留下的旧代），切换才有目标。
      final father = env.provider.rounds.first.useStackUuid;
      await env.stack.attachNewGeneration(
        bookUuid: 'b1',
        round: Round(bookUuid: 'b1', roundIndex: 1, aiNarrative: '另一代正文'),
        fatherUuid: father,
      );
      await env.provider.loadRounds('b1');
      final info = env.provider.versionInfoFor(1);
      expect(info, isNotNull, reason: '两代存活 → 控件可切换');
      expect(info!.switchable, isTrue);
      expect(info.prevUuid, isNotNull);

      final switched =
          await env.provider.switchRoundVersion(1, forward: false);

      expect(switched, isTrue);
      expect(env.stack.switches, hasLength(1), reason: '切换确实落地到服务层');
      expect(env.cloud.triggers, 0,
          reason: '切换不改变内容权威（除 round_state 外无内容变化），不该触发云同步');
    });

    test('采纳（有变化）→ **不**主动触发同步（采纳源本身已是触发节点）', () async {
      final env = build();
      await env.provider.loadRounds('b1');
      env.cloud.triggers = 0;
      env.stack.adoptReport = const RoundStackAdoptionReport(created: 1);

      await env.provider.adoptRoundStack(force: true);

      expect(env.provider.versionsRevision, greaterThan(0),
          reason: '采纳确实改写了锚点 / 索引');
      expect(
        env.cloud.triggers,
        0,
        reason: '采纳由「同步完成 / 导入 db / 启动指纹」调用——三者本身已是同步触发'
            '节点（见 docs/sync_auto_triggers.md 的触发白名单闭集）；'
            '在采纳内部再触发会与正在跑的同步自激。',
      );
    });

    test('删除轮次 → 触发一次同步（内容部件真实变更）', () async {
      final env = build();
      await env.provider.loadRounds('b1');
      expect(await env.provider.sendRound(userInput: '第一章', book: book), isTrue);
      env.cloud.triggers = 0;
      final round = env.provider.rounds.last;

      await env.provider.deleteRound(round, deleteFollowing: false);

      expect(env.stack.deletes.single.fromRoundIndex, round.roundIndex);
      expect(
        env.provider.rounds.map((r) => r.roundIndex),
        [0],
        reason: '该轮被物理删除',
      );
      expect(env.cloud.triggers, 1, reason: '删除照旧触发（内容已变更）');
    });

    test('采纳（无变化）→ 不触发同步（无改动可推）', () async {
      final env = build();
      await env.provider.loadRounds('b1');
      env.cloud.triggers = 0;

      await env.provider.adoptRoundStack(force: true);

      expect(env.stack.adoptReport, isNull, reason: '替身未报告变化');
      expect(env.cloud.triggers, 0, reason: '无变化即早返回，不打网络');
    });
  });
}
