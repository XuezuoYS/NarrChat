import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/services/recommended_action_parser.dart';

/// 「推荐下一步」正文切分（`splitRecommendedAction`）：列表项 → 可双击选项，
/// 其余文本 → Markdown 片段。
void main() {
  /// 取出片段里的选项内容（顺序不变），便于断言。
  List<String> optionContents(List<RecommendedActionSegment> segments) => [
        for (final s in segments)
          if (s is RecommendedActionOption) s.content,
      ];

  /// 取出片段里的 Markdown 文本块。
  List<String> markdownTexts(List<RecommendedActionSegment> segments) => [
        for (final s in segments)
          if (s is RecommendedActionMarkdown) s.text,
      ];

  group('列表项解析', () {
    test('有序列表：剥掉 `1. ` 标记，显示序号按 Markdown 语义派生', () {
      final segments = splitRecommendedAction(
        '1. 上前行礼\n2. 询问掌门\n3. 转身离开',
      );
      expect(optionContents(segments), ['上前行礼', '询问掌门', '转身离开']);
      final options = segments.whereType<RecommendedActionOption>().toList();
      expect(options.map((o) => o.number), [1, 2, 3]);
      expect(options.every((o) => o.ordered), isTrue);
      expect(segments, hasLength(3), reason: '无额外 Markdown 片段');
    });

    test('无序列表：`- ` 与 `* ` 都是选项，序号无意义', () {
      final segments = splitRecommendedAction('- 观察四周\n* 拔剑戒备');
      expect(optionContents(segments), ['观察四周', '拔剑戒备']);
      final options = segments.whereType<RecommendedActionOption>().toList();
      expect(options.every((o) => !o.ordered), isTrue);
      expect(options.map((o) => o.number), [1, 1]);
    });

    test('源序号不照抄：`1.` 连写四次仍派生 1/2/3/4；从 3 起则 3/4', () {
      final repeated = splitRecommendedAction('1. 甲\n1. 乙\n1. 丙\n1. 丁');
      expect(
        repeated.whereType<RecommendedActionOption>().map((o) => o.number),
        [1, 2, 3, 4],
      );
      final started = splitRecommendedAction('3. 甲\n4. 乙');
      expect(
        started.whereType<RecommendedActionOption>().map((o) => o.number),
        [3, 4],
      );
    });

    test('被非列表行打断后重新计数', () {
      final segments = splitRecommendedAction('1. 甲\n2. 乙\n\n（补充说明）\n\n1. 丙');
      expect(optionContents(segments), ['甲', '乙', '丙']);
      expect(
        segments.whereType<RecommendedActionOption>().map((o) => o.number),
        [1, 2, 1],
      );
      expect(markdownTexts(segments), ['（补充说明）']);
    });

    test('缩进行 / `+` / `1)` / 空条目不是选项（仍走 Markdown）', () {
      final segments = splitRecommendedAction(
        '  - 嵌套项\n+ 加号项\n1) 括号序号\n- \n- 正常项',
      );
      expect(optionContents(segments), ['正常项']);
      expect(markdownTexts(segments), ['  - 嵌套项\n+ 加号项\n1) 括号序号\n- ']);
    });
  });

  group('Markdown 片段', () {
    test('无列表项时只剩一个 Markdown 片段（原文保留）', () {
      final segments = splitRecommendedAction('继续前进。\n\n**保持警惕**');
      expect(optionContents(segments), isEmpty);
      expect(markdownTexts(segments), ['继续前进。\n\n**保持警惕**']);
    });

    test('列表前后的文本各自成块，且顺序与原文一致', () {
      final segments = splitRecommendedAction(
        '可以先做这些：\n\n1. 甲\n2. 乙\n\n也可以直接输入自己的行动。',
      );
      expect(
        segments.map((s) => switch (s) {
          RecommendedActionMarkdown() => 'md:${s.text}',
          RecommendedActionOption() => 'opt:${s.content}',
        }),
        [
          'md:可以先做这些：',
          'opt:甲',
          'opt:乙',
          'md:也可以直接输入自己的行动。',
        ],
      );
    });

    test('片段首尾空行被剥离，内部空行保留', () {
      final segments = splitRecommendedAction('\n\n正文\n\n结尾\n\n');
      expect(markdownTexts(segments), ['正文\n\n结尾']);
    });

    test('空文本 / 全空白 → 无片段', () {
      expect(splitRecommendedAction(''), isEmpty);
      expect(splitRecommendedAction('  \n\n  '), isEmpty);
    });
  });

  group('末条「自定义行动」', () {
    test('内容为「自定义行动」时标记 isCustomAction（其余项为 false）', () {
      final segments = splitRecommendedAction('1. 上前行礼\n2. 自定义行动');
      final options = segments.whereType<RecommendedActionOption>().toList();
      expect(options.map((o) => o.isCustomAction), [false, true]);
      expect(options.last.content, kCustomActionLabel);
    });

    test('容忍句末标点与首尾空白（`自定义行动：` / `自定义行动。`）', () {
      expect(
        splitRecommendedAction('1. 自定义行动：')
            .whereType<RecommendedActionOption>()
            .single
            .isCustomAction,
        isTrue,
      );
      expect(
        splitRecommendedAction('- 自定义行动。')
            .whereType<RecommendedActionOption>()
            .single
            .isCustomAction,
        isTrue,
      );
    });

    test('含附加说明的条目不算「自定义行动」（仍按普通选项插入其文本）', () {
      final option = splitRecommendedAction('1. 自定义行动：做你想做的事')
          .whereType<RecommendedActionOption>()
          .single;
      expect(option.isCustomAction, isFalse);
      expect(option.content, '自定义行动：做你想做的事');
    });
  });
}
