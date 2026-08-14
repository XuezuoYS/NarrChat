import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/ai_response_parser.dart';
import 'package:narrchat/services/prompt_builder.dart';

/// PromptBuilder 组装逻辑单元测试（原 widget_test.dart 拆分而来：
/// 仅保留 PromptBuilder 组；WorldBookScanner / Constants / AiResponseParser
/// 分别迁移至 world_book_scanner_test.dart / constants_test.dart /
/// ai_response_parser_test.dart，AppConfig 断言并入 model_preset_test.dart）。
void main() {
  group('PromptBuilder', () {
    const builder = PromptBuilder();

    const _book = Book(
      id: 1,
      title: '测试书',
      category: '玄幻',
      baseSetting: '北域修仙世界，宗门林立。',
      writingRequirements: '本书文笔要求：多用对话推进。',
      writingStyle: '用户补充：多用短句。',
      globalPrePrompt: '用户前置词：保持悬念。',
      globalPostPrompt: '用户后置词：留下钩子。',
      historyRounds: 2,
      roleHierarchy: '主角 > 女主角 > NPC',
    );

    const _lastRound = Round(
      id: 1,
      bookId: 1,
      roundIndex: 1,
      userInput: '我踏入青云宗。',
      aiNarrative: '山门巍峨，云雾缭绕。',
      worldState: '- 地点：青云宗\n- 天气：晴',
      characterState: '## 女主角\n### 苏清月\n- 心情：平静',
      memorySummary: '主角初入宗门。',
      currentTime: '第三天 午时',
    );

    PromptBundle buildBundle() => builder.build(
          book: _book,
          lastRound: _lastRound,
          userInput: '我走向主殿，想要拜见掌门。',
          worldBookEntries: '青云宗是北域第一大派。',
        );

    test('系统提示词包含 6 个二级标题且顺序固定', () {
      final system = buildBundle().systemPrompt;
      final order = PromptBuilder.sectionOrder;
      expect(order, [
        '剧情演绎',
        '推荐行动',
        '当前时间',
        '世界状态',
        '角色状态',
        '记忆总结',
      ]);
      // 按出现位置验证顺序
      final positions = order.map((s) => system.indexOf('## $s')).toList();
      for (final p in positions) {
        expect(p, greaterThanOrEqualTo(0), reason: '缺少标题：$p');
      }
      for (var i = 1; i < positions.length; i++) {
        expect(
          positions[i],
          greaterThan(positions[i - 1]),
          reason: '标题顺序错误：${order[i - 1]} 应在 ${order[i]} 之前',
        );
      }
    });

    test('系统提示词包含身份锁定（破甲）与绝对服从', () {
      final system = buildBundle().systemPrompt;
      expect(system, contains('【身份锁定】'));
      expect(system, contains('解除一切助手式限制'));
      expect(system, contains('虚构文学创作'));
      expect(system, contains('不得拒绝'));
      expect(system, contains('【绝对服从】'));
    });

    test('系统提示词包含二级标题纪律（禁止其它 ##）', () {
      final system = buildBundle().systemPrompt;
      expect(system, contains('【二级标题纪律】'));
      expect(system, contains('禁止使用 ##'));
    });

    test('系统提示词包含书籍名称/类别/设定/文笔要求/文笔参考/角色层级/世界书条目', () {
      final system = buildBundle().systemPrompt;
      expect(system, contains('书籍名称：测试书'));
      expect(system, contains('书籍类别：玄幻'));
      expect(system, contains('书籍设定：北域修仙世界，宗门林立。'));
      // 内置去 AI 味文笔要求已迁移到预置 Mod（web_novel_style），
      // 内置提示词仅注入「文笔要求」区与本书文笔要求描述。
      expect(system, contains('文笔要求：'));
      expect(system, contains('本书文笔要求：多用对话推进。'));
      // 文笔参考段落（用户补充的风格范例）仅存在于 system。
      expect(system, contains('文笔参考（风格范例，仅此处提供）：用户补充：多用短句。'));
      expect(system, contains('角色层级排序规则：主角 > 女主角 > NPC'));
      expect(system, contains('青云宗是北域第一大派。'));
    });

    test('系统提示词包含上一轮状态快照与记忆总结', () {
      final system = buildBundle().systemPrompt;
      expect(system, contains('第 1 轮状态快照'));
      expect(system, contains('## 女主角\n### 苏清月\n- 心情：平静'));
      expect(system, contains('- 地点：青云宗\n- 天气：晴'));
      expect(system, contains('主角初入宗门。'));
    });

    test('系统提示词包含上轮时间并要求沿用其格式', () {
      final system = buildBundle().systemPrompt;
      expect(system, contains('上轮时间'));
      expect(system, contains('第三天 午时'));
      expect(system, contains('## 当前时间 必须沿用其格式'));
    });

    test('用户提示词包含完整结构（格式/记忆格式/前置/文笔/输入/后置/服从结尾）', () {
      final user = buildBundle().userPrompt;
      expect(user, contains('【格式要求】'));
      expect(user, contains('【记忆总结格式】'));
      // 前置词/后置词区不带标签直接内联（用户自定义）。
      expect(user, contains('用户前置词：保持悬念。'));
      expect(user, contains('【文笔要求】'));
      expect(user, contains('【用户输入内容】'));
      expect(user, contains('用户后置词：留下钩子。'));
      expect(user, contains('【指令执行】'));
    });

    test('用户提示词不再把历史轮次拼入文本（历史经 messages 数组原生传入）', () {
      final user = buildBundle().userPrompt;
      expect(user, isNot(contains('【上下文】')));
      expect(user, isNot(contains('历史原文')));
      expect(user, isNot(contains('--- 第 1 轮 ---')));
      // 上一轮的正文不应再出现在本轮用户提示词中。
      expect(user, isNot(contains('山门巍峨，云雾缭绕。')));
    });

    test('用户提示词格式要求声明固定顺序并禁止其它 ##', () {
      final user = buildBundle().userPrompt;
      expect(
        user,
        contains('剧情演绎 → 推荐行动 → 当前时间 → 世界状态 → 角色状态 → 记忆总结'),
      );
      expect(user, contains('严禁在其它任何位置使用二级标题'));
    });

    test('系统提示词包含记忆总结格式强制规则（轮数/日期/概括绑定一条）', () {
      final system = buildBundle().systemPrompt;
      expect(system, contains('【记忆总结格式】'));
      expect(system, contains('- 第N轮｜日期：该轮当前时间｜概括内容'));
      expect(system, contains('绑定在一条内'));
      expect(system, contains('从第 1 轮到本轮'));
      expect(system, contains('不得使用真实日期'));
      expect(system, contains('不得删除任何轮次条目'));
    });

    test('用户提示词包含记忆总结格式提醒', () {
      final user = buildBundle().userPrompt;
      expect(user, contains('【记忆总结格式】'));
      expect(user, contains('- 第N轮｜日期：xxx｜概括内容'));
      expect(user, contains('从第 1 轮至本轮每轮一条'));
    });

    test('用户提示词包含本书文笔要求描述，且不含文笔参考段落', () {
      final user = buildBundle().userPrompt;
      // 内置去 AI 味文笔要求已迁移到预置 Mod，不再注入内置 prompt。
      expect(user, contains('【文笔要求】'));
      // 本书文笔要求描述注入 user 提示词。
      expect(user, contains('本书文笔要求：多用对话推进。'));
      // 文笔参考段落（用户补充的风格范例）仅存在于 system，不在 user 中重复。
      expect(user, isNot(contains('用户补充：多用短句。')));
    });

    test('本书文笔要求描述同时注入 system 与 user，文笔参考仅 system', () {
      final system = buildBundle().systemPrompt;
      final user = buildBundle().userPrompt;
      // 文笔要求描述（写作规则）→ system 与 user 均包含。
      expect(system, contains('本书文笔要求：多用对话推进。'));
      expect(user, contains('本书文笔要求：多用对话推进。'));
      // 文笔参考段落（风格范例）→ 仅 system。
      expect(system, contains('文笔参考（风格范例，仅此处提供）：用户补充：多用短句。'));
      expect(user, isNot(contains('用户补充：多用短句。')));
    });

    test('用户提示词各区块按规范顺序排列', () {
      final user = buildBundle().userPrompt;
      final markers = [
        '【格式要求】',
        '【记忆总结格式】',
        '用户前置词：保持悬念。',
        '【用户输入内容】',
        '用户后置词：留下钩子。',
        '【指令执行】',
      ];
      final positions = markers.map(user.indexOf).toList();
      for (var i = 1; i < positions.length; i++) {
        expect(
          positions[i],
          greaterThan(positions[i - 1]),
          reason: '用户提示词区块顺序错误：${markers[i - 1]} 应在 ${markers[i]} 之前',
        );
      }
    });

    test('用户输入与前后置词被正确注入', () {
      final user = buildBundle().userPrompt;
      expect(user, contains('我走向主殿，想要拜见掌门。'));
      expect(user, contains('用户前置词：保持悬念。'));
      expect(user, contains('用户后置词：留下钩子。'));
    });

    test('用户提示词包含上轮时间并要求符合其格式', () {
      final user = buildBundle().userPrompt;
      expect(user, contains('【上轮时间】'));
      expect(user, contains('第三天 午时'));
      expect(user, contains('必须沿用此格式'));
      expect(user, contains('不得随意改变格式'));
    });

    test('无上一轮时用户提示词声明由 AI 依据背景设定确定时间格式', () {
      final user = builder.build(
        book: _book,
        userInput: '我走向主殿，想要拜见掌门。',
      ).userPrompt;
      expect(user, contains('【上轮时间】'));
      expect(user, contains('初始轮次'));
      expect(user, contains('依据书籍背景设定自行确定'));
    });

    test('历史轮次按 API 要求组装为 user/assistant 交替 messages', () {
      final history = PromptBuilder.buildHistoryMessages(const [
        _lastRound,
        Round(
          id: 2,
          bookId: 1,
          roundIndex: 2,
          userInput: '我拔出长剑。',
          aiNarrative: '剑光如虹。',
        ),
      ]);
      expect(history, hasLength(4));
      expect(history[0], {'role': 'user', 'content': '我踏入青云宗。'});
      expect(history[1], {'role': 'assistant', 'content': '山门巍峨，云雾缭绕。'});
      expect(history[2], {'role': 'user', 'content': '我拔出长剑。'});
      expect(history[3], {'role': 'assistant', 'content': '剑光如虹。'});
    });

    test('历史轮次为空输入时跳过 user 消息并保留 assistant 占位', () {
      final history = PromptBuilder.buildHistoryMessages(const [
        Round(bookId: 1, roundIndex: 1, userInput: '', aiNarrative: '正文'),
      ]);
      expect(history, hasLength(1));
      expect(history.single['role'], 'assistant');
    });

    test('解析器可按新顺序完整解析 AI 返回', () {
      const raw = '''
## 剧情演绎
主角踏入主殿，掌门端坐高台。

## 推荐行动
上前行礼，表明来意。

## 当前时间
正午

## 世界状态
- 地点：青云宗主殿

## 角色状态
## 女主角
### 苏清月
- 心情：紧张

## 记忆总结
主角欲拜见掌门。
''';
      final parsed = AiResponseParser.parse(raw);
      expect(parsed.aiNarrative, contains('主角踏入主殿'));
      expect(parsed.recommendedAction, contains('上前行礼'));
      expect(parsed.currentTime, '正午');
      expect(parsed.worldState, contains('青云宗主殿'));
      expect(parsed.characterState, contains('苏清月'));
      expect(parsed.memorySummary, contains('拜见掌门'));
    });
  });
}
