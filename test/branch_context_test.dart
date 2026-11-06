import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round_send_intent.dart';
import 'package:narrchat/providers/round_provider.dart';

import 'helpers/fakes.dart';

/// 分支继承父行轮次的 Provider 集成：首轮轮号、父上文、快照兜底与预览 ≡ 实发。
///
/// 背景：新分支建好后没有任何轮次，若请求只拿「当前分支链」，首轮会从第 1 轮
/// 重开、且父分支的上文一条都带不上（模型完全从零开始）。本文件守住修复后的
/// 两个口径：轮号 = 父轮 +1，请求历史 = 父分支到分叉点 + 本分支已有轮次。
void main() {
  const book = Book(uuid: 'b1', title: '测试书', historyRounds: 10);

  late TestStack stack;
  late RecordingAiService ai;

  setUp(() async {
    stack = await TestStack.create(prefix: 'branch_context_');
    await stack.seedBook(
      uuid: book.uuid,
      title: book.title,
      historyRounds: book.historyRounds,
    );
    ai = RecordingAiService();
  });

  tearDown(() async {
    await stack.dispose();
  });

  /// 预置第 1..[count] 轮；输入文案用「轮次N原文」避免互为子串。
  Future<void> seedRounds(int count) async {
    for (var i = 1; i <= count; i++) {
      final generation = await stack.seedRound(
        book.uuid,
        roundIndex: i,
        userInput: '轮次$i原文',
        aiNarrative: '第 $i 轮正文',
        operatedAt: DateTime.utc(2026, 1, i),
      );
      await stack.repos.rounds.updateContent(
        bookUuid: book.uuid,
        generationUuid: generation.uuid,
        fields: {'current_time': '第 $i 天'},
      );
    }
  }

  Future<RoundProvider> makeProvider() async {
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      retryDelay: Duration.zero,
    );
    await provider.loadRounds(book.uuid);
    return provider;
  }

  test('空分支首轮：轮号 = 父轮 +1，请求带父上文且不含分叉点之后', () async {
    await seedRounds(4);
    final provider = await makeProvider();

    final branchUuid = await provider.forkBranch(round: provider.rounds[1]);
    expect(branchUuid, isNotNull);
    expect(provider.rounds, isEmpty, reason: '新分支还没生成过');
    expect(provider.nextRoundIndex, 3, reason: '分叉点 2 + 1');

    const intent = RoundSendIntent.newRound(userInput: '分支首轮输入');
    final preview = await provider.previewRequestBody(
      intent: intent,
      book: book,
    );
    final text = jsonEncode(preview.firstFrame);

    expect(text, contains('轮次1原文'), reason: '父分支第 1 轮应进历史');
    expect(text, contains('轮次2原文'), reason: '分叉点父代应进历史');
    expect(text, contains('第 2 天'), reason: '基座 = 分叉点，上轮时间取它');
    expect(text, contains('创作第 3 轮'), reason: '首轮轮号必须是父轮 +1');
    expect(text, isNot(contains('轮次3原文')), reason: '分叉点之后的父轮次不得混入');
    expect(text, isNot(contains('轮次4原文')));
    expect(text, isNot(contains('第 3 天')), reason: '分叉点之后的状态也不得混入');

    expect(await provider.sendIntent(intent: intent, book: book), isTrue);
    expect(ai.calls, 1);
    expect(ai.bodies.single, preview.firstFrame, reason: '预览与实发同源');
    final first = provider.rounds.single;
    expect(first.roundIndex, 3, reason: '落库轮号必须接在分叉点之后');
    expect(first.fatherUuid, isNull, reason: '分支链首仍是根');
    expect(provider.nextRoundIndex, 4);
  });

  test('分支第二轮：继续带父前缀与分支历史，轮号递增', () async {
    await seedRounds(4);
    final provider = await makeProvider();
    await provider.forkBranch(round: provider.rounds[1]);
    expect(await provider.sendRound(userInput: '分支首轮输入', book: book), isTrue);
    expect(provider.rounds.single.roundIndex, 3);

    const intent = RoundSendIntent.newRound(userInput: '分支第二轮输入');
    final preview = await provider.previewRequestBody(
      intent: intent,
      book: book,
    );
    final text = jsonEncode(preview.firstFrame);
    expect(text, contains('轮次1原文'));
    expect(text, contains('轮次2原文'));
    expect(text, contains('分支首轮输入'), reason: '分支自己的历史也要在');
    expect(text, contains('创作第 4 轮'));
    expect(text, isNot(contains('轮次3原文')), reason: '分叉点之后的父轮次仍不得混入');

    expect(await provider.sendIntent(intent: intent, book: book), isTrue);
    expect(provider.rounds.last.roundIndex, 4);
  });

  test('父代已删：首轮用快照兜底，轮号仍为父轮 +1', () async {
    await seedRounds(3);
    final provider = await makeProvider();
    final branchUuid = await provider.forkBranch(round: provider.rounds[1]);
    expect(branchUuid, isNotNull);

    // 回主线删掉分叉点及之后，再切回空分支。
    expect(await provider.switchBranch(''), isTrue);
    await provider.deleteRound(provider.rounds[1], deleteFollowing: true);
    expect(await provider.switchBranch(branchUuid!), isTrue);
    expect(provider.rounds, isEmpty);
    expect(provider.nextRoundIndex, 3);

    const intent = RoundSendIntent.newRound(userInput: '分支首轮输入');
    final preview = await provider.previewRequestBody(
      intent: intent,
      book: book,
    );
    final text = jsonEncode(preview.firstFrame);
    expect(text, contains('轮次2原文'), reason: '父代删了要用 father_row_shot 快照');
    expect(text, contains('第 2 轮正文'));
    expect(text, contains('第 2 天'), reason: '快照也应提供基座时间');
    expect(text, contains('创作第 3 轮'));

    expect(await provider.sendIntent(intent: intent, book: book), isTrue);
    expect(provider.rounds.single.roundIndex, 3);
  });
}
