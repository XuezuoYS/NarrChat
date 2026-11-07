import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/providers/round_provider.dart';

import 'helpers/fakes.dart';

/// [RoundProvider] 的「代 / 版本」接线契约（R3：真库 + 临时目录）。
///
/// 覆盖：生成后版本索引可见、单代不可切换、多代可切换且链内容跟着换、
/// **RAW 按代保留（切换不清）**、失败落 error 代（方案 A）、删除当前代回落。
void main() {
  const book = Book(uuid: 'b1', title: '测试书');

  late ({RoundProvider provider, TestStack stack, ToggleAiService ai}) env;

  Future<void> boot() async {
    final stack = await TestStack.create();
    addTearDown(stack.dispose);
    await stack.seedBook(uuid: 'b1', title: '测试书');
    final ai = ToggleAiService();
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');
    env = (provider: provider, stack: stack, ai: ai);
  }

  /// 在同一轮里直接补一代（模拟「重新生成 / 修改提问」留下的旧代）。
  Future<void> seedGeneration({
    required String uuid,
    required int serial,
    required String narrative,
    bool using = false,
  }) async {
    await env.stack.repos.rounds.appendGeneration(
      bookUuid: 'b1',
      generation: RoundGeneration(
        meta: RoundMeta(
          uuid: uuid,
          roundIndex: 1,
          roundSerialNum: serial,
          isUsing: using,
          operatedAt: DateTime.now().toUtc(),
        ),
        aiNarrative: narrative,
      ),
    );
    await env.provider.loadRounds('b1');
  }

  setUp(boot);

  test('生成后：链上有一轮，版本索引可见但不可切换', () async {
    final before = env.provider.versionsRevision;

    expect(await env.provider.sendRound(userInput: '第一章', book: book), isTrue);

    expect(env.provider.rounds.map((r) => r.roundIndex), [1]);
    expect(env.provider.versionsRevision, greaterThan(before));

    final info = env.provider.versionInfoFor(1);
    expect(info, isNotNull);
    expect(info!.aliveCount, 1);
    expect(info.currentSerial, 1);
    expect(info.latestSerial, 1);
    expect(info.switchable, isFalse, reason: '单代不显示切换控件');
    expect(info.prevUuid, isNull);
    expect(info.nextUuid, isNull);
  });

  test('单代：前 / 后切换都直接返回 false', () async {
    await env.provider.sendRound(userInput: '第一章', book: book);

    expect(await env.provider.switchRoundVersion(1, forward: true), isFalse);
    expect(await env.provider.switchRoundVersion(1, forward: false), isFalse);
  });

  test('多代：索引给出上一/下一代，切换后链内容跟着换', () async {
    await env.provider.sendRound(userInput: '第一章', book: book);
    final firstUuid = env.provider.rounds.single.uuid;
    await seedGeneration(uuid: 'g2', serial: 2, narrative: '另一代正文');

    final info = env.provider.versionInfoFor(1)!;
    expect(info.aliveCount, 2);
    expect(info.switchable, isTrue);
    expect(info.currentSerial, 1, reason: '当前仍是第 1 代');
    expect(info.latestSerial, 2);
    expect(info.nextUuid, 'g2');
    expect(info.prevUuid, isNull);

    expect(await env.provider.switchRoundVersion(1, forward: true), isTrue);

    final switched = env.provider.rounds.single;
    expect(switched.uuid, 'g2');
    expect(switched.aiNarrative, '另一代正文');
    expect(switched.uuid, isNot(firstUuid));

    // 切回来：索引反过来给出上一代。
    final back = env.provider.versionInfoFor(1)!;
    expect(back.currentSerial, 2);
    expect(back.prevUuid, firstUuid);
    expect(await env.provider.switchRoundVersion(1, forward: false), isTrue);
    expect(env.provider.rounds.single.uuid, firstUuid);
  });

  test('RAW 按代保留：切换版本不清 RAW，切回来仍在', () async {
    await env.provider.sendRound(userInput: '第一章', book: book);
    final first = env.provider.rounds.single;
    expect(env.provider.rawExchangesFor(first.uuid), isNotNull,
        reason: '直发路径必须捕获 RAW');

    await seedGeneration(uuid: 'g2', serial: 2, narrative: '另一代正文');
    await env.provider.switchRoundVersion(1, forward: true);

    expect(env.provider.rawExchangesFor('g2'), isNull, reason: '这一代没生成过');
    expect(env.provider.rawExchangesFor(first.uuid), isNotNull,
        reason: 'RAW 属于「代」，切换不清');

    await env.provider.switchRoundVersion(1, forward: false);
    expect(env.provider.rawExchangesFor(first.uuid), isNotNull,
        reason: '切回来仍在');
  });

  test('失败落 error 代（方案 A）：链上有红条轮，而不是 books.failed_*', () async {
    env.ai.fail = true;

    expect(await env.provider.sendRound(userInput: '第一章', book: book), isFalse);

    final rounds = env.provider.rounds;
    expect(rounds, hasLength(1), reason: '失败也是一轮，不是空链');
    expect(rounds.single.roundIndex, 1);
    expect(rounds.single.isError, isTrue, reason: '红条由 message_status=error 驱动');
    expect(rounds.single.message, isNotEmpty, reason: '红条必须有文案');

    // 失败代不进「可切换」，但仍是这一轮的唯一代。
    final info = env.provider.versionInfoFor(1)!;
    expect(info.aliveCount, 1);
    expect(info.switchable, isFalse);
  });

  test('删除当前代：回落到前一存活代；唯一一代时拒绝', () async {
    await env.provider.sendRound(userInput: '第一章', book: book);
    final firstUuid = env.provider.rounds.single.uuid;

    // 只有一代 → 拒绝删除。
    expect(await env.provider.deleteCurrentGeneration(env.provider.rounds.single),
        isFalse);

    await seedGeneration(uuid: 'g2', serial: 2, narrative: '另一代正文', using: true);
    expect(env.provider.rounds.single.uuid, 'g2');

    expect(
      await env.provider.deleteCurrentGeneration(env.provider.rounds.single),
      isTrue,
    );
    expect(env.provider.rounds.single.uuid, firstUuid, reason: '回落到前一代');
    expect(env.provider.versionInfoFor(1)!.aliveCount, 1);
  });

  test('跳号：latestSerial 取最大存活序号，aliveCount 只数存活代', () async {
    await env.provider.sendRound(userInput: '第一章', book: book);
    // 人为造出「序号 5」的存活代（模拟物理删除后复用序号造成的跳步）。
    await seedGeneration(uuid: 'g5', serial: 5, narrative: '第五代');

    final info = env.provider.versionInfoFor(1)!;
    expect(info.latestSerial, 5, reason: 'y = 最大存活序号');
    expect(info.aliveCount, 2);
    expect(info.currentSerial, 1);
  });

  test('删除代：RAW 随代一起清掉，不残留', () async {
    await env.provider.sendRound(userInput: '第一章', book: book);
    await seedGeneration(uuid: 'g2', serial: 2, narrative: '另一代正文', using: true);
    expect(env.provider.rounds.single.uuid, 'g2');

    expect(
      await env.provider.deleteCurrentGeneration(env.provider.rounds.single),
      isTrue,
    );
    expect(env.provider.rawExchangesFor('g2'), isNull, reason: '代没了 RAW 也不该留');
  });

  test('重新生成：同轮新增一代，链长不变、新代被选中', () async {
    await env.provider.sendRound(userInput: '第一章', book: book);
    final before = env.provider.rounds.single;
    final aliveBefore = env.provider.versionInfoFor(1)!.aliveCount;

    await env.provider.refreshRound(before, book: book);

    expect(env.provider.rounds, hasLength(1), reason: '还是同一轮，链长不变');
    final after = env.provider.rounds.single;
    expect(after.uuid, isNot(before.uuid), reason: '新代成为选中代');
    expect(after.isError, isFalse);
    expect(
      env.provider.versionInfoFor(1)!.aliveCount,
      aliveBefore + 1,
      reason: '旧代留在组里，可切回',
    );
  });

  test('失败刷新：链尾是 error 代时刷新 → 得到正常代，红条消失', () async {
    env.ai.fail = true;
    expect(await env.provider.sendRound(userInput: '第一章', book: book), isFalse);
    final failed = env.provider.rounds.single;
    expect(failed.isError, isTrue, reason: '前置：链尾是 error 代');
    expect(failed.message, isNotEmpty);

    env.ai.fail = false;
    await env.provider.refreshRound(failed, book: book);

    final refreshed = env.provider.rounds.single;
    expect(refreshed.uuid, isNot(failed.uuid), reason: '刷新会产生新代');
    expect(refreshed.isError, isFalse, reason: '成功后不再红条');
    expect(refreshed.aiNarrative, isNotEmpty);
    expect(
      env.provider.versionInfoFor(1)!.aliveCount,
      greaterThanOrEqualTo(1),
      reason: 'error 代即便被回收，也至少留一代',
    );
  });
}
