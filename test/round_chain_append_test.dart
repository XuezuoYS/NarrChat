import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/round_provider.dart';

import 'helpers/fakes.dart';

/// 连发多轮 → 每一代的 `father_uuid` 必须指向上一轮当前代，活动链才解析得出来。
///
/// 这是 R3 的命门：`_appendRound` 不显式传 `fatherUuid` 时会默认 null，
/// 于是每轮都成"链首"，三代各自成根，`RoundTree.planChain` 只能解析出最后一轮
/// （现象：连发 3 次后 `provider.rounds` 长度为 1、`roundIndex` 是 3）。
/// 这个 bug 曾真实存在过，所以留成回归用例。
void main() {
  test('连发 3 轮：father_uuid 串成链，活动链为 [1,2,3]', () async {
    final stack = await TestStack.create();
    addTearDown(stack.dispose);
    final bookUuid = await stack.seedBook(title: '链测试书');
    final book = await stack.repos.books.loadBook(bookUuid);
    expect(book, isNotNull);

    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ToggleAiService(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds(bookUuid);

    for (final input in ['A', 'B', 'C']) {
      final ok = await provider.sendRound(userInput: input, book: book);
      expect(ok, isTrue, reason: '第 $input 轮发送失败：${provider.error}');
    }

    final chain = await stack.repos.rounds.loadChain(bookUuid);
    expect(
      chain.rounds.map((r) => r.roundIndex).toList(),
      [1, 2, 3],
      reason: '三轮都应是活动链的一环',
    );
    expect(chain.allMeta.length, 3);

    // 父指针：第 1 轮是链首（null），第 2/3 轮各自指向上一轮。
    final byIndex = {
      for (final meta in chain.allMeta) meta.roundIndex: meta,
    };
    expect(byIndex[1]!.fatherUuid, isNull);
    expect(byIndex[2]!.fatherUuid, byIndex[1]!.uuid);
    expect(byIndex[3]!.fatherUuid, byIndex[2]!.uuid);
    // 同组只有一个代，序号都是 1。
    expect(chain.allMeta.map((m) => m.roundSerialNum).toList(), [1, 1, 1]);
  });
}
