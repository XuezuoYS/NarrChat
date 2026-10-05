import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/prompt_interface.dart';
import 'package:narrchat/services/prompt_v2_sections.dart';

/// v2「修改轮」user 注入模板测试（文案真源：`docs/ai_prompt_v2.md` 的
/// 「*修改轮*注入提示词」）。
///
/// 修改轮 = 按意见重写某一轮：模板与新建轮**同构**，只有两处不同——
/// 标题「创作第 {轮次} 轮」→「重写第 {轮次} 轮」、时间标签「上轮时间」→
/// 「此轮时间」（取**被重写轮**当前代的时间）；此时 `lastRound` 是生成基座
/// （被重写轮的上一轮），因此记忆合并等一律以它为基准。
void main() {
  const book = Book(
    uuid: 'b1',
    title: '测试书',
    globalPrePrompt: '用户前置词',
    globalPostPrompt: '用户后置词',
    historyRounds: 1,
  );

  /// 生成基座 = 被重写轮（第 3 轮）的上一轮（第 2 轮）。
  const base = Round(
    id: 2,
    bookUuid: 'b1',
    roundIndex: 2,
    userInput: '上一轮输入',
    aiNarrative: '上一轮正文',
    worldState: '- 地点：青云宗',
    currentTime: '第二天 午时',
  );

  const opinion = '把这段写紧凑些，别拖。';

  PromptRequest rewriteRequestOf(
    PromptMode mode, {
    String roundTime = '第三天 卯时',
    int roundIndex = 3,
  }) =>
      PromptRequest(
        book: book,
        mode: mode,
        lastRound: base,
        userInput: opinion,
        rewrite: RewriteTarget(roundIndex: roundIndex, roundTime: roundTime),
      );

  PromptRequest newRoundRequestOf(PromptMode mode) => PromptRequest(
        book: book,
        mode: mode,
        lastRound: base,
        userInput: opinion,
      );

  test('修改轮头部：标题「重写第 {轮次} 轮」+「此轮时间」取被重写轮的时间', () {
    final user = promptInterface.user(rewriteRequestOf(PromptMode.chat));

    expect(user, startsWith('你并没有按照主人的要求完成，你需要按照主人的要求，重写第 3 轮：'));
    expect(user, contains('- 此轮时间：第三天 卯时'));
    // 该行仍是总模板里的同一句格式要求（沿用 `## 当前时间` 的写法）。
    expect(user, contains('`## 当前时间` 必须沿用此格式，仅按剧情推进更新时间内容，不得随意改变格式'));
    // 本轮输入 = 用户填写的修改意见（不落库，只在这一处进请求）。
    expect(user, contains('【主人的输入】\n\n$opinion\n\n【主人的输入stop】'));
    expect(user, isNot(contains('上轮时间')));
  });

  test('修改轮与新建轮逐字同构：只差标题与时间标签两处', () {
    final normal = promptInterface.user(newRoundRequestOf(PromptMode.chat));
    // 时间取值取成与基座轮一致，使唯一的差异只剩「标题」与「时间标签」两处。
    final rewritten = promptInterface.user(
      rewriteRequestOf(PromptMode.chat, roundTime: base.currentTime),
    );

    // 把修改轮的两处差异归一化回新建轮写法后，两段文本必须逐字一致。
    final normalized = rewritten
        .replaceFirst(
          PromptV2Sections.rewriteHead(3),
          PromptV2Sections.newRoundHead(3),
        )
        .replaceFirst('- 此轮时间：', '- 上轮时间：');
    expect(normalized, normal);
    expect(rewritten, isNot(normal));
  });

  test('此轮时间为空（该轮当前代无时间）→ 整条不注入', () {
    final user = promptInterface.user(rewriteRequestOf(
      PromptMode.chat,
      roundTime: '  ',
    ));

    expect(user, startsWith('你并没有按照主人的要求完成'));
    expect(user, isNot(contains('此轮时间')));
  });

  test('三种模式的 # 总协议2 合同与新建轮完全一致', () {
    for (final mode in PromptMode.values) {
      final y = promptInterface.user(rewriteRequestOf(mode));
      final n = promptInterface.user(newRoundRequestOf(mode));
      // 合同正文（模式专属「现在开始做什么」）不变：截取 `# 总协议2` 之后比较。
      final yContract = y.substring(y.indexOf('# 总协议2'));
      final nContract = n.substring(n.indexOf('# 总协议2'));
      expect(yContract, nContract, reason: mode.name);
      expect(y, contains(PromptV2Sections.userContract(mode)), reason: mode.name);
    }
  });

  test('Chat 记忆合并以「被重写轮号 + 基座轮记忆」计划（不是投影尾号 +1）', () {
    const tier5 = Book(title: '档 5', memorySummaryRounds: 5);
    final mergeBase = Round(
      id: 10,
      bookUuid: 'b1',
      roundIndex: 10,
      userInput: '第10轮输入',
      aiNarrative: '第10轮正文',
      memorySummary: [
        for (var i = 1; i <= 10; i++) '- $i | 第$i天 | 事件$i。',
      ].join('\n'),
      currentTime: '第十天',
    );

    final user = promptInterface.user(PromptRequest(
      book: tier5,
      mode: PromptMode.chat,
      lastRound: mergeBase,
      userInput: opinion,
      rewrite: const RewriteTarget(roundIndex: 11, roundTime: '第十一天'),
    ));

    expect(user, contains('重写第 11 轮：'));
    expect(user, contains('- 此轮时间：第十一天'));
    expect(user, contains('【本轮记忆合并】'));
    expect(user, contains('第 1~5 轮'));
  });
}
