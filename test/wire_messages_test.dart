import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/wire_messages.dart';

/// 报文侧消息组装（[buildHistoryMessages]）单元测试。
///
/// 定位：**历史跟随报文**——历史 messages 与请求体同属请求组装侧，与提示词接口
/// 产出的 system / 本轮 user / 工具清单解耦。历史 assistant 的形态是模型的
/// **模仿对象**，必须与各模式的输出契约一致，因此单独立档锁定。
/// 提示词文案断言在 `prompt_interface_test.dart` / `prompt_placeholders_test.dart`，
/// 报文拼装路由断言在 `prompt_interface_test.dart`。
void main() {
  const lastRound = Round(
    id: 1,
    bookUuid: 'b1',
    roundIndex: 1,
    userInput: '我踏入青云宗。',
    aiNarrative: '山门巍峨，云雾缭绕。',
    worldState: '- 地点：青云宗\n- 天气：晴',
    characterState: '## 女主角\n### 苏清月\n- 心情：平静',
    memorySummary: '主角初入宗门。',
    currentTime: '第三天 午时',
  );

  test('按 API 要求组装为 user/assistant 交替 messages（最后一轮反解析，其余仅正文）', () {
    final history = buildHistoryMessages(const [
      lastRound,
      Round(
        id: 2,
        bookUuid: 'b1',
        roundIndex: 2,
        userInput: '我拔出长剑。',
        aiNarrative: '剑光如虹。',
        worldState: '- 地点：演武场',
        characterState: '疲惫。',
        memorySummary: '- 第1轮｜日期：第三天 午时｜初入宗门',
        currentTime: '第三天 申时',
        recommendedAction: '收剑回鞘。',
      ),
    ]);
    expect(history, hasLength(4));
    expect(history[0], {'role': 'user', 'content': '我踏入青云宗。'});
    // 更早的历史轮次仅置入正文。
    expect(history[1], {'role': 'assistant', 'content': '山门巍峨，云雾缭绕。'});
    expect(history[2], {'role': 'user', 'content': '我拔出长剑。'});
    // 最后一轮反解析为完整 6 区块原生格式（角色状态按契约带 ```markdown 围栏）。
    expect(history[3], {
      'role': 'assistant',
      'content': '## 剧情演绎\n剑光如虹。\n\n'
          '## 推荐行动\n收剑回鞘。\n\n'
          '## 当前时间\n第三天 申时\n\n'
          '## 世界状态\n- 地点：演武场\n\n'
          '## 角色状态\n```markdown\n疲惫。\n```\n\n'
          '## 记忆总结\n- 第1轮｜日期：第三天 午时｜初入宗门',
    });
  });

  test('最后一轮仅正文时仍反解析为 6 区块齐全形态', () {
    final history = buildHistoryMessages(const [
      Round(bookUuid: 'b1', roundIndex: 1, aiNarrative: '剑光如虹。'),
    ]);
    expect(
      history.single['content'],
      '## 剧情演绎\n剑光如虹。\n\n## 推荐行动\n\n## 当前时间\n\n'
      '## 世界状态\n\n## 角色状态\n\n## 记忆总结',
    );
  });

  test('最后一轮六字段全空时保留「（无正文）」占位', () {
    final history = buildHistoryMessages(const [
      Round(bookUuid: 'b1', roundIndex: 1, userInput: '输入'),
    ]);
    expect(history.last['content'], '（无正文）');
  });

  test('AGENT Lv.2（agentStoryOnly）：历史 assistant 只携带三个正文小节，状态一律不进历史', () {
    const withState = Round(
      bookUuid: 'b1',
      roundIndex: 1,
      userInput: '入门',
      aiNarrative: '山门巍峨。',
      recommendedAction: '拜见掌门。',
      worldState: '- 地点：青云宗',
      characterState: '## 林远\n- 气血：80',
      memorySummary: '- 第1轮｜日期：第一天 卯时｜入门',
      currentTime: '第一天 卯时',
    );
    final history = buildHistoryMessages(
      const [
        withState,
        Round(
          bookUuid: 'b1',
          roundIndex: 2,
          userInput: '拔剑',
          aiNarrative: '剑光如虹。',
          recommendedAction: '收剑。',
        ),
        Round(bookUuid: 'b1', roundIndex: 3, userInput: '沉默'),
      ],
      shape: AssistantHistoryShape.agentStoryOnly,
    );
    expect(history, hasLength(6));
    // 所有轮同一形状（含带状态的更早轮次）：模型只模仿一种输出格式
    //（剧情 / 行动 / 时间三小节；状态区块不入历史）。
    expect(
      history[1]['content'],
      '## 剧情演绎\n山门巍峨。\n\n## 推荐行动\n拜见掌门。\n\n## 当前时间\n第一天 卯时',
    );
    expect(
      history[3]['content'],
      '## 剧情演绎\n剑光如虹。\n\n## 推荐行动\n收剑。\n\n## 当前时间',
    );
    for (final m in history.where((m) => m['role'] == 'assistant')) {
      expect('${m['content']}', isNot(contains('## 世界状态')));
      expect('${m['content']}', isNot(contains('## 角色状态')));
      expect('${m['content']}', isNot(contains('## 记忆总结')));
    }
    // 时间属于正文：有时间的轮次序列化进历史。
    expect(history[1]['content'], contains('## 当前时间'));
    // 无正文无建议 → 占位，不发送空 assistant 消息。
    expect(history.last['content'], '（无正文）');
  });

  test('AGENT Lv.1（chatWithoutMemory）：仅最新一轮带 5 区块，历史区块永不入历史', () {
    const withState = Round(
      bookUuid: 'b1',
      roundIndex: 1,
      userInput: '入门',
      aiNarrative: '山门巍峨。',
      recommendedAction: '拜见掌门。',
      worldState: '- 地点：青云宗',
      characterState: '## 林远\n- 气血：80',
      memorySummary: '- 第1轮｜日期：第一天 卯时｜入门',
      currentTime: '第一天 卯时',
    );
    final history = buildHistoryMessages(
      const [
        withState,
        Round(
          bookUuid: 'b1',
          roundIndex: 2,
          userInput: '拔剑',
          aiNarrative: '剑光如虹。',
          recommendedAction: '收剑。',
          worldState: '- 地点：主峰',
          characterState: '## 林远\n- 气血：60',
          memorySummary: '- 第1轮｜日期：第一天 卯时｜入门',
          currentTime: '第二天 辰时',
        ),
      ],
      shape: AssistantHistoryShape.chatWithoutMemory,
    );
    // 更早轮次只带剧情正文（与 Chat 一致：控制上下文篇幅）。
    expect(history[1]['content'], '山门巍峨。');
    // 最新一轮 = 5 区块（剧情 / 行动 / 时间 / 世界 / 角色），**无记忆区块**；
    // 角色状态按契约带 ```markdown 围栏。
    expect(
      history[3]['content'],
      '## 剧情演绎\n剑光如虹。\n\n## 推荐行动\n收剑。\n\n## 当前时间\n第二天 辰时\n\n'
      '## 世界状态\n- 地点：主峰\n\n'
      '## 角色状态\n```markdown\n## 林远\n- 气血：60\n```',
    );
    for (final m in history.where((m) => m['role'] == 'assistant')) {
      expect('${m['content']}', isNot(contains('## 记忆总结')));
      expect('${m['content']}', isNot(contains('初入宗门')));
    }
  });

  test('历史轮次为空输入时跳过 user 消息并保留 assistant 占位', () {
    final history = buildHistoryMessages(const [
      Round(bookUuid: 'b1', roundIndex: 1, userInput: '', aiNarrative: '正文'),
    ]);
    expect(history, hasLength(1));
    expect(history.single['role'], 'assistant');
  });

  test('历史用户消息带图时 content 变为「文本 + 图片数组」（vision）', () {
    final history = buildHistoryMessages(
      const [
        Round(
          bookUuid: 'b1',
          roundIndex: 1,
          userInput: '看图',
          userImages: ['img/a.png'],
        ),
      ],
      imagePartsFor: (r) => [
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:image/png;base64,AA==',
            'detail': 'high',
          },
        },
      ],
    );
    final userMsg = history[0];
    expect(userMsg['role'], 'user');
    final content = userMsg['content'] as List;
    expect(content[0], {'type': 'text', 'text': '看图'});
    expect((content[1] as Map)['type'], 'image_url');
  });
}
