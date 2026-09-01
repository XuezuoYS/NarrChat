import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/services/ai_response_parser.dart';
import 'package:narrchat/services/prompt_builder.dart';

/// 完整 6 字段的解析结果（供 serialize 多组用例复用）。
const _fullParsed = ParsedAiResponse(
  aiNarrative: '主角踏入山门。',
  worldState: '晴天。',
  characterState: '疲惫。',
  memorySummary: '- 第1轮｜日期：第三天 午时｜已入山门',
  currentTime: '第三天 午时',
  recommendedAction: '继续前进。',
);

void main() {
  group('AiResponseParser 正常解析', () {
    test('完整 6 区块正常解析', () {
      const raw = '''
## 剧情演绎
主角踏入山门。

## 世界状态
晴天。

## 角色状态
疲惫。

## 记忆总结
已入山门。

## 当前时间
第三天 午时

## 推荐行动
继续前进。
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, '主角踏入山门。');
      expect(result.worldState, '晴天。');
      expect(result.characterState, '疲惫。');
      expect(result.memorySummary, '已入山门。');
      expect(result.currentTime, '第三天 午时');
      expect(result.recommendedAction, '继续前进。');
    });

    test('标题容错：无空格、层级不严、前后空白', () {
      const raw = '''
##剧情演绎
正文一

### 当前时间
中午

# 推荐行动
行动一
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, '正文一');
      expect(result.currentTime, '中午');
      expect(result.recommendedAction, '行动一');
    });

    test('空输入返回空结果', () {
      final result = AiResponseParser.parse('');
      expect(result.isEmpty, isTrue);
      expect(result.aiNarrative, isEmpty);
    });

    test('只含空白输入返回空结果', () {
      final result = AiResponseParser.parse('  \n \t ');
      expect(result.isEmpty, isTrue);
    });
  });

  group('AiResponseParser 剧情演绎缺失兜底', () {
    test('无剧情演绎但有「正文」标题区块时，正文区块作为正文', () {
      const raw = '''
## 正文
主角直接开始行动的描写，这是正文内容。

## 当前时间
中午

## 推荐行动
继续。
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, '主角直接开始行动的描写，这是正文内容。');
      expect(result.currentTime, '中午');
      expect(result.recommendedAction, '继续。');
    });

    test('「正文」标题变体（无空格）同样识别', () {
      const raw = '''
##正文
无空格标题的正文内容。
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, '无空格标题的正文内容。');
    });

    test('整个响应只有「正文」区块时全部作为正文', () {
      const raw = '''
## 正文
全部内容都是正文。
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, '全部内容都是正文。');
    });

    test('无剧情演绎、无「正文」标题但有开头无标题内容时，开头内容作为正文', () {
      const raw = '''
主角在无标题情况下直接开始生成正文内容。

## 当前时间
午后
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, '主角在无标题情况下直接开始生成正文内容。');
      expect(result.currentTime, '午后');
    });

    test('整个响应完全没有标题时，全部内容作为正文', () {
      const raw = '''
主角完全放弃格式，直接生成剧情正文的第一段。
第二段也继续。
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, contains('第一段'));
      expect(result.aiNarrative, contains('第二段'));
    });

    test('无剧情演绎、有「正文」区块且有开头无标题内容时，正文区块优先', () {
      const raw = '''
开头无标题的杂散文字。

## 正文
正文区块的优先内容。
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, '正文区块的优先内容。');
    });

    test('「正文」标题在多个位置出现时内容累积（保留区块间空行）', () {
      const raw = '''
## 正文
第一段正文。

## 正文
第二段正文。
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, '第一段正文。\n\n第二段正文。');
    });

    test('有剧情演绎时，正文区块与开头无标题内容不覆盖剧情演绎', () {
      const raw = '''
开头杂散文字。

## 剧情演绎
真正的剧情正文。

## 正文
不应被采用的正文区块。
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, '真正的剧情正文。');
    });

    test('剧情演绎区块即使出现在正文区块之后仍优先', () {
      const raw = '''
## 正文
正文区块内容。

## 剧情演绎
剧情演绎内容。
''';
      final result = AiResponseParser.parse(raw);
      expect(result.aiNarrative, '剧情演绎内容。');
    });
  });

  group('AiResponseParser serialize 反解析', () {
    test('完整 6 字段反解析为原生 6 标题格式（顺序与 PromptBuilder 一致）', () {
      expect(
        AiResponseParser.serialize(_fullParsed),
        '## 剧情演绎\n主角踏入山门。\n\n'
        '## 推荐行动\n继续前进。\n\n'
        '## 当前时间\n第三天 午时\n\n'
        '## 世界状态\n晴天。\n\n'
        '## 角色状态\n疲惫。\n\n'
        '## 记忆总结\n- 第1轮｜日期：第三天 午时｜已入山门',
      );
    });

    test('反解析区块顺序与 PromptBuilder.sectionOrder 一致', () {
      final raw = AiResponseParser.serialize(_fullParsed);
      final headings = RegExp(r'^## (.+)$', multiLine: true)
          .allMatches(raw)
          .map((m) => m.group(1)!)
          .toList();
      expect(headings, PromptBuilder.sectionOrder);
    });

    test('空字段输出对应的空 `## 标题` 区块，6 区块齐全', () {
      const parsed = ParsedAiResponse(aiNarrative: '只有正文。');
      expect(
        AiResponseParser.serialize(parsed),
        '## 剧情演绎\n只有正文。\n\n'
        '## 推荐行动\n\n'
        '## 当前时间\n\n'
        '## 世界状态\n\n'
        '## 角色状态\n\n'
        '## 记忆总结',
      );
    });

    test('空 ParsedAiResponse 反解析为 6 个空标题区块，可再解析为空结果', () {
      final raw = AiResponseParser.serialize(const ParsedAiResponse());
      expect(
        raw,
        '## 剧情演绎\n\n## 推荐行动\n\n## 当前时间\n\n'
        '## 世界状态\n\n## 角色状态\n\n## 记忆总结',
      );
      expect(AiResponseParser.parse(raw).isEmpty, isTrue);
    });

    test('完整字段 round-trip：反解析后再解析得到相同字段', () {
      final reparsed =
          AiResponseParser.parse(AiResponseParser.serialize(_fullParsed));
      expect(reparsed.aiNarrative, _fullParsed.aiNarrative);
      expect(reparsed.worldState, _fullParsed.worldState);
      expect(reparsed.characterState, _fullParsed.characterState);
      expect(reparsed.memorySummary, _fullParsed.memorySummary);
      expect(reparsed.currentTime, _fullParsed.currentTime);
      expect(reparsed.recommendedAction, _fullParsed.recommendedAction);
    });

    test('角色状态含二级标题（角色名）时 round-trip 原样保留', () {
      const parsed = ParsedAiResponse(
        aiNarrative: '正文。',
        characterState: '# 主角\n## 张三\n- 体力：100',
      );
      final reparsed =
          AiResponseParser.parse(AiResponseParser.serialize(parsed));
      expect(reparsed.aiNarrative, '正文。');
      expect(reparsed.characterState, '# 主角\n## 张三\n- 体力：100');
      expect(reparsed.recommendedAction, isEmpty);
    });
  });
}
