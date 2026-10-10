import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/round_stack.dart';
import 'package:narrchat/providers/round_provider.dart';

import 'helpers/fakes.dart';

/// [RoundProvider] 的「修改还原」接线契约（内存替身，不触碰真实数据库）。
///
/// 覆盖：失败态严格按 v18（OP-7）、同步版本索引（UI-1 的取数口径）、
/// 切换编排（切换后不滚不生成、清黄框 / 失败态；**RAW 按代保留、不随切换清**）、
/// 采纳入口、失败条目重试下沉、RAW 的「代」归属（换书才清；删除代随代清）、
/// 单代删除的编排（走服务删除 + 重载 + 版本计数；拒绝时不改动）。
void main() {
  const book = Book(uuid: 'b1', title: '测试书');

  ({
    RoundProvider provider,
    FakeRoundDao dao,
    FakeRoundStackService stack,
    FakeBookDao bookDao,
    ToggleAiService ai,
  }) build({List<RoundStackMeta> metas = const []}) {
    final dao = FakeRoundDao();
    final stack = FakeRoundStackService(roundDao: dao)..metas = List.of(metas);
    final bookDao = FakeBookDao(books: [book]);
    final ai = ToggleAiService();
    final provider = RoundProvider(
      dao: dao,
      bookDao: bookDao,
      aiService: ai,
      roundStackService: stack,
      retryDelay: Duration.zero,
    );
    return (provider: provider, dao: dao, stack: stack, bookDao: bookDao, ai: ai);
  }

  test('生成走版本树路径：投影 + 内存版本树同源，versionsRevision 自增', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    final before = env.provider.versionsRevision;

    expect(
      await env.provider.sendRound(userInput: '第一章', book: book),
      isTrue,
    );

    expect(env.provider.rounds.map((r) => r.roundIndex), [0, 1]);
    expect(env.stack.attachCalls, 1, reason: '生成必须经 attachNewGeneration');
    expect(env.provider.versionsRevision, greaterThan(before));
    final round = env.provider.rounds.last;
    expect(round.useStackUuid, isNotEmpty, reason: '投影行必须带锚点');
    expect(
      env.stack.rows['b1']!.where((r) => r.roundIndex == 1),
      hasLength(1),
    );
  });

  test('versionInfoFor：同步读缓存；单代不显示；跳号时 y 取最大存活序号', () async {
    final env = build(
      metas: [
        const RoundStackMeta(
          uuid: 'g-a',
          bookUuid: 'b1',
          roundIndex: 2,
          roundSerialNum: 2,
          roundState: 'use',
        ),
        const RoundStackMeta(
          uuid: 'g-b',
          bookUuid: 'b1',
          roundIndex: 2,
          roundSerialNum: 5,
        ),
      ],
    );
    await env.provider.loadRounds('b1');
    // 第 1 轮没有任何存活代 → 不显示控件。
    expect(env.provider.versionInfoFor(1), isNull);

    await env.dao.insertRound(
      const Round(
        bookUuid: 'b1',
        roundIndex: 2,
        useStackUuid: 'g-a',
        aiNarrative: '当前代正文',
      ),
    );
    await env.provider.loadRounds('b1');

    final info = env.provider.versionInfoFor(2);
    expect(info, isNotNull);
    expect(info!.currentSerial, 2);
    expect(info.latestSerial, 5, reason: '跳步时 y = 最大存活序号');
    expect(info.aliveCount, 2);
    expect(info.switchable, isTrue);
    expect(info.nextUuid, 'g-b', reason: '→ 取下一存活代');
    expect(info.prevUuid, isNull);
  });

  test('切换：目标由 forward 决定；不发起生成、不滚屏（Provider 侧无滚屏）', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    await env.provider.sendRound(userInput: '第一章', book: book);
    final round = env.provider.rounds.last;

    // 手工给该分组补一代（模拟「刷新本轮」留下的旧代），并让索引可见。
    final info = env.provider.versionInfoFor(1);
    expect(info, isNotNull, reason: 'attach 已写入内存版本树');
    final second = await env.stack.attachNewGeneration(
      bookUuid: 'b1',
      round: Round(
        bookUuid: 'b1',
        roundIndex: 1,
        aiNarrative: '另一代正文',
        createdAt: DateTime.now(),
      ),
      fatherUuid: null,
    );
    expect(second, isPositive);
    await env.provider.loadRounds('b1');

    final before = env.provider.versionsRevision;
    final afterReload = env.provider.versionInfoFor(1);
    expect(afterReload, isNotNull, reason: '重载后索引仍可见（同步缓存）');
    expect(afterReload!.prevUuid, isNotNull, reason: '存在可回落的上一代');
    final switched = await env.provider.switchRoundVersion(1, forward: false);

    expect(switched, isTrue);
    expect(env.stack.switches, hasLength(1));
    expect(
      env.stack.switches.single.roundIndex,
      1,
      reason: '切换目标轮 = 请求轮',
    );
    expect(env.provider.versionsRevision, greaterThan(before));
    expect(round.id, isNotNull);
  });

  test('切换：没有可切换目标时不调用服务（单代）', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    await env.provider.sendRound(userInput: '第一章', book: book);

    expect(await env.provider.switchRoundVersion(1, forward: true), isFalse);
    expect(await env.provider.switchRoundVersion(1, forward: false), isFalse);
    expect(env.stack.switches, isEmpty);
  });

  test('OP-7 失败态：只写 books.failed_*，不写 stack / rounds；轮次操作即清失败态', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    expect(await env.provider.sendRound(userInput: '第一章', book: book), isTrue);

    // 刷新本轮：旧代保留在版本树，投影被删后生成失败 → 红条失败态。
    env.ai.fail = true;
    await env.provider.refreshRound(env.provider.rounds.last, book: book);

    expect(env.provider.hasFailureEntry, isTrue);
    expect(env.bookDao.failed.userInput, '第一章', reason: '失败条目已落库');
    expect(
      env.dao.rounds.map((r) => r.roundIndex),
      [0],
      reason: '失败不写 rounds（否则老客户端「空正文轮次 + 红条」双渲染）',
    );
    expect(
      env.stack.rows['b1']!.where((r) => r.roundIndex == 1),
      hasLength(1),
      reason: '失败不写 stack；被重写的旧代仍在（可还原）',
    );

    // 失败态 + 单代：控件信息给出「可还原的上一代」。
    final info = env.provider.versionInfoFor(1);
    expect(info, isNotNull);
    expect(info!.currentSerial, isNull, reason: '失败态是临时代（无编号）');
    expect(info.prevUuid, isNotNull);

    // 任何轮次操作先删失败态。
    await env.provider.updateUserInput(env.provider.rounds.first.id!, '改第零轮');
    expect(env.provider.hasFailureEntry, isFalse);
  });

  test('失败态「← 还原上一代」：切换被调用且失败态被清除', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    await env.provider.sendRound(userInput: '第一章', book: book);
    env.ai.fail = true;
    await env.provider.refreshRound(env.provider.rounds.last, book: book);
    final info = env.provider.versionInfoFor(1)!;

    expect(await env.provider.switchRoundVersion(1, forward: false), isTrue);

    expect(env.stack.switches.single.targetUuid, info.prevUuid);
    expect(env.provider.hasFailureEntry, isFalse, reason: '还原即清除失败态');
  });

  test('刷新本轮（失败条目载体）：以失败条目的输入与图片重刷那一轮', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    env.ai.fail = true;
    await env.provider.sendRound(
      userInput: '第一章',
      book: book,
      userImages: const ['img/a.png'],
    );
    expect(env.provider.hasFailureEntry, isTrue);

    // 与 UI 同口径（`ChatScreen._handleRefreshFailure`）：失败条目现构一个
    // 「本该产生的那一轮」载体，交给**唯一入口** `refreshRound`。
    Round carrier() => Round(
          bookUuid: 'b1',
          roundIndex: env.provider.nextRoundIndex,
          userInput: env.provider.failedUserInput,
          userImages: env.provider.failedUserImages,
        );

    // AI 仍失败 → 刷新失败，失败条目保留。
    await env.provider.refreshRound(carrier(), book: book);
    expect(env.provider.hasFailureEntry, isTrue);

    env.ai.fail = false;
    await env.provider.refreshRound(carrier(), book: book);
    expect(env.provider.rounds.last.roundIndex, 1, reason: '重刷的是「本该产生」的那一轮');
    expect(env.provider.rounds.last.userInput, '第一章');
    expect(env.provider.rounds.last.userImages, ['img/a.png']);
    expect(env.provider.hasFailureEntry, isFalse, reason: '刷新前先清失败条目');
  });

  test('adoptRoundStack：按 force 透传并在有变化时重载投影 + 自增版本计数', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    final before = env.provider.versionsRevision;
    env.stack.adoptReport = const RoundStackAdoptionReport(created: 1);

    await env.provider.adoptRoundStack(force: true);

    expect(env.stack.adoptCalls, greaterThanOrEqualTo(1));
    expect(env.stack.lastAdoptForce, isTrue);
    expect(env.provider.versionsRevision, greaterThan(before));

    // 无变化 → 不计版本、不重载。
    env.stack.adoptReport = null;
    final revision = env.provider.versionsRevision;
    await env.provider.adoptRoundStack();
    expect(env.stack.lastAdoptForce, isFalse);
    expect(env.provider.versionsRevision, revision);
  });

  test('RAW 按代归属：投影重建换行 id 也能命中；同书重载不丢', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    await env.provider.sendRound(userInput: '第一章', book: book);
    final oldId = env.provider.rounds.last.id!;
    final anchor = env.provider.rounds.last.useStackUuid;
    expect(env.provider.rawExchangesFor(oldId), isNotNull);
    expect(anchor, isNotEmpty, reason: 'v19 投影行必带代锚点');

    // 模拟真实库的投影重建（切换 / 采纳会换行 id）：删旧行 → 以同一代锚点重新插入。
    final old = env.provider.rounds.last;
    await env.dao.deleteRound(old.id!);
    await env.dao.insertRound(
      Round(
        bookUuid: 'b1',
        roundIndex: 1,
        userInput: old.userInput,
        aiNarrative: old.aiNarrative,
        useStackUuid: anchor,
        createdAt: old.createdAt,
      ),
    );
    await env.provider.loadRounds('b1');
    final newId = env.provider.rounds.last.id!;
    expect(newId, isNot(oldId), reason: '前置条件：行 id 已变');

    expect(
      env.provider.rawExchangesFor(newId),
      isNotNull,
      reason: 'RAW 以「代」为键：换行 id 照样取得到',
    );
    expect(env.provider.rawExchangesFor(oldId), isNull, reason: '旧行 id 已不在投影');
  });

  test('RAW 归属到「代」：同一行指向别的代时取不到，指回来又可见', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    await env.provider.sendRound(userInput: '第一章', book: book);
    final round = env.provider.rounds.last;
    final ownAnchor = round.useStackUuid;
    expect(env.provider.rawExchangesFor(round.id!), isNotNull);

    // 同一行 id 改指另一代（等价于切到旧代后投影重建的结果）。
    await env.dao.updateRoundFields(round.id!, {'use_stack_uuid': 'g-old'});
    await env.provider.loadRounds('b1');
    expect(
      env.provider.rawExchangesFor(round.id!),
      isNull,
      reason: '那是另一代：不应把这一代的 RAW 冒充给它',
    );

    // 指回原代 → 记录仍在（本机内存只丢换书 / 进程结束）。
    await env.dao.updateRoundFields(round.id!, {'use_stack_uuid': ownAnchor});
    await env.provider.loadRounds('b1');
    expect(env.provider.rawExchangesFor(round.id!), isNotNull);
  });

  test('RAW 只在换书时清空（避免跨书误配）；同书重载不清', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    await env.provider.sendRound(userInput: '第一章', book: book);
    final roundId = env.provider.rounds.last.id!;
    expect(env.provider.rawExchangesFor(roundId), isNotNull);

    // 同一本书重载：保留。
    await env.provider.loadRounds('b1');
    expect(env.provider.rawExchangesFor(roundId), isNotNull);

    // 换到另一本书：清理；切回原书也不复活（内存态，仅本次运行捕获）。
    await env.provider.loadRounds('b2');
    await env.provider.loadRounds('b1');
    expect(
      env.provider.rawExchangesFor(roundId),
      isNull,
      reason: '换书即整体清空（RAW 为本机内存数据）',
    );
  });

  test('删除此代：删当前代走服务删除 + 自增版本 + 重载；被删代的 RAW 随之清理', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    await env.provider.sendRound(userInput: '第一章', book: book);
    final anchorA = env.provider.rounds.last.useStackUuid;
    expect(
      env.provider.rawExchangesFor(env.provider.rounds.last.id!),
      isNotNull,
      reason: '夹具：本代有 RAW',
    );

    // 同分组补一代（模拟「按意见修改」留下的旧代），再把投影切回第 1 代。
    await env.stack.attachNewGeneration(
      bookUuid: 'b1',
      round: Round(
        bookUuid: 'b1',
        roundIndex: 1,
        aiNarrative: '另一代正文',
        createdAt: DateTime.now(),
      ),
      fatherUuid: null,
    );
    await env.provider.loadRounds('b1');
    env.stack.onSwitch = (bookUuid, roundIndex, targetUuid) {
      final index = env.dao.rounds.indexWhere((r) => r.roundIndex == roundIndex);
      env.dao.rounds[index] =
          env.dao.rounds[index].copyWith(useStackUuid: targetUuid);
    };
    expect(
      await env.provider.switchRoundVersion(1, forward: false),
      isTrue,
      reason: '夹具：存在可回落的上一代',
    );
    var round = env.provider.rounds.last;
    expect(round.useStackUuid, anchorA);
    expect(env.provider.rawExchangesFor(round.id!), isNotNull);
    final before = env.provider.versionsRevision;

    expect(await env.provider.deleteCurrentGeneration(round), isTrue);

    expect(env.stack.generationDeletes, hasLength(1));
    expect(env.stack.generationDeletes.single.roundIndex, 1);
    expect(env.stack.generationDeletes.single.generationUuid, anchorA);
    expect(env.provider.versionsRevision, greaterThan(before));
    round = env.provider.rounds.last;
    expect(
      env.provider.rawExchangesFor(round.id!),
      isNull,
      reason: '被删代的 RAW 随代清理（其余代的 RAW 不受影响）',
    );
  });

  test('删除此代：服务拒绝（唯一一代等）→ 返回 false，不重载、不累计版本', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    await env.provider.sendRound(userInput: '第一章', book: book);
    final round = env.provider.rounds.last;
    // 真库的「唯一一代拒绝删除」见 round_stack_service_test.dart 的 OP-13c。
    env.stack.deleteGenerationResult = false;

    final before = env.provider.versionsRevision;
    expect(await env.provider.deleteCurrentGeneration(round), isFalse);
    expect(env.provider.versionsRevision, before, reason: '没删成 → 不累计版本');
    expect(env.provider.rounds.last.useStackUuid, round.useStackUuid);
  });

  test('删除此代：无当前代（失败态 / 未采纳）→ 不触碰服务', () async {
    final env = build();
    await env.provider.loadRounds('b1');
    await env.provider.sendRound(userInput: '第一章', book: book);
    // 影射「投影行不存在」：没有当前代就没有可删的一代。
    await env.dao.deleteRound(env.provider.rounds.last.id!);
    await env.provider.loadRounds('b1');

    expect(
      await env.provider.deleteCurrentGeneration(
        const Round(bookUuid: 'b1', roundIndex: 1),
      ),
      isFalse,
    );
    expect(env.stack.generationDeletes, isEmpty);
  });
}
