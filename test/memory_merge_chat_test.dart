import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/fakes.dart';

/// Chat 模式的「记忆总结轮次合并」：本轮请求体携带合并指令、生成后未落地时
/// 给出常驻警告（Chat 无法回炉重试，故只警告；Agent 的重试见
/// `agent_round_runner_test.dart`）。
void main() {
  const bookUuid = 'b1';

  /// 第 1~9 轮的散条目（第 10 轮达到档位 5 的 2T=10 触发点）。
  final nineEntries =
      [for (var r = 1; r <= 9; r++) '- $r | t$r | 第$r轮。'].join('\n');

  /// 返回固定 6 区块的 AI：`## 记忆总结` 内容由用例给定。
  final service = _FixedMemoryAiService();
  late FakeRoundDao dao;

  Future<Book> buildBook(int tier) async {
    dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookUuid: bookUuid,
        roundIndex: 9,
        userInput: '第九轮',
        aiNarrative: '第九轮正文',
        memorySummary: nineEntries,
        currentTime: 't9',
      ),
    );
    return Book(uuid: bookUuid, title: '测试书', memorySummaryRounds: tier);
  }

  RoundProvider providerFor(Book book) => RoundProvider(
        dao: dao,
        roundStackService: FakeRoundStackService(roundDao: dao),
        bookDao: FakeBookDao(books: [book]),
        aiService: service,
        aiSettingsProvider: ChatCompatibleSettings(),
      );

  test('档位 5：请求体注入合并指令（含填好区间的模板行）', () async {
    final book = await buildBook(5);
    final provider = providerFor(book);
    await provider.loadRounds(bookUuid);

    final preview = await provider.previewRequestBody(
      userInput: '继续',
      book: book,
    );

    expect(preview, contains('【本轮记忆合并】'));
    expect(preview, contains('- 1 - 5 | t1 ~ t5 | {记忆内容}'));
    expect(preview, contains('2 × 5'));
  });

  test('档位 0：只给「不合并」策略，不注入本轮指令', () async {
    final book = await buildBook(0);
    final provider = providerFor(book);
    await provider.loadRounds(bookUuid);

    final preview = await provider.previewRequestBody(
      userInput: '继续',
      book: book,
    );

    expect(preview, contains('不要主动合并'));
    expect(preview, isNot(contains('【本轮记忆合并】')));
  });

  test('模型没合并 → 本轮常驻警告（带应合并区间）', () async {
    final book = await buildBook(5);
    service.memory = '$nineEntries\n- 10 | t10 | 第十轮。';
    final provider = providerFor(book);
    await provider.loadRounds(bookUuid);
    final preview = await provider.previewRequestBody(
      userInput: '继续',
      book: book,
    );
    expect(preview, contains('【本轮记忆合并】'), reason: '前置：本轮确实要求合并');

    final ok = await provider.sendRound(userInput: '继续', book: book);

    expect(ok, isTrue);
    expect(provider.roundWarningsFor(10), [
      '记忆总结未按档位（5）合并：应合并 1-5',
    ]);
    expect(dao.rounds.last.memorySummary, contains('- 10 | t10 | 第十轮。'));
    expect(dao.rounds.last.memorySummary, isNot(contains('- 1 - 5 |')));
  });

  test('模型完成合并 → 无警告，合并行落库', () async {
    final book = await buildBook(5);
    service.memory = '- 1 - 5 | t1 ~ t5 | 前五轮要点。\n'
        '- 6 | t6 | 第6轮。\n'
        '- 7 | t7 | 第7轮。\n'
        '- 8 | t8 | 第8轮。\n'
        '- 9 | t9 | 第9轮。\n'
        '- 10 | t10 | 第十轮。';
    final provider = providerFor(book);
    await provider.loadRounds(bookUuid);

    final ok = await provider.sendRound(userInput: '继续', book: book);

    expect(ok, isTrue);
    expect(provider.roundWarningsFor(10), isEmpty);
    expect(dao.rounds.last.memorySummary, contains('- 1 - 5 | t1 ~ t5 | 前五轮要点。'));
    expect(dao.rounds.last.memorySummary, contains('- 6 | t6 | 第6轮。'),
        reason: '未触及的条目原样保留');
  });

  test('档位 0：模型爱怎么写就怎么写，不产生合并警告', () async {
    final book = await buildBook(0);
    service.memory = '$nineEntries\n- 10 | t10 | 第十轮。';
    final provider = providerFor(book);
    await provider.loadRounds(bookUuid);

    final ok = await provider.sendRound(userInput: '继续', book: book);

    expect(ok, isTrue);
    expect(provider.roundWarningsFor(10), isEmpty);
  });
}

/// 可注入 `## 记忆总结` 内容的 AI 替身（其余 5 个区块固定）。
class _FixedMemoryAiService extends AiService {
  String memory = '';

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    onRequestBody?.call('{"model":"test","messages":[]}');
    const body = '## 剧情演绎\n成功正文\n\n'
        '## 推荐行动\n行动\n\n'
        '## 当前时间\nt10\n\n'
        '## 世界状态\n\n'
        '## 角色状态\n\n';
    return AiCallResult(
      content: '$body## 记忆总结\n$memory',
      promptTokens: 1,
      completionTokens: 2,
    );
  }
}
