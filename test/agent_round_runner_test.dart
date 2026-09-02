import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/agent_round_runner.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/ai_service.dart';

/// `AgentRoundRunner` 单元测试：主响应语义（正文 + 行级工具同响应）、
/// 修复轮（≤2）、无状态重发 / 有状态链式续接帧、整轮累计完整性。
void main() {
  AgentStateWorkingCopy workingCopy() => AgentStateWorkingCopy(
        roundIndex: 2,
        lastRound: const Round(
          id: 1,
          bookUuid: 'b1',
          roundIndex: 1,
          worldState: '- 地点：青云宗\n- 天气：晴',
          characterState: '# 主角\n## 林远\n- 气血：80',
          memorySummary: '',
          currentTime: '第二天 午时',
        ),
        categoryNames: const ['主角'],
      );

  AgentRoundRunner runner({
    required AgentStateWorkingCopy copy,
    required List<AiCallResult> script,
    List<Map<String, dynamic>>? bodies,
    bool chaining = false,
  }) {
    var callIndex = 0;
    return AgentRoundRunner(
      buildBody: (items, prevId) {
        bodies?.add({'items': List.of(items), 'prevId': prevId});
        return {'input': items, 'previous_response_id': ?prevId};
      },
      call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
        final result = script[callIndex++];
        return result;
      },
      tools: buildStateTools(copy),
      chaining: chaining,
    );
  }

  /// 正文 + 一个「记忆总结变更缺本轮条目」的编辑（必然校验失败，用于修复轮场景）。
  AiCallResult turnWithBadMemory(String id) {
    return AiCallResult(
      content: '## 剧情演绎\n正文\n\n## 推荐行动\n行动',
      toolCalls: [
        AiToolCall(
          id: id,
          name: 'narrchat_editSection',
          arguments: {
            'section': 'memorySummary',
            'edits': [
              {'op': 'noChange'},
            ],
          },
        ),
      ],
      promptTokens: 1,
      completionTokens: 1,
      responseId: 'resp_1',
    );
  }

  AiCallResult worldEdit(String id) => AiCallResult(
        content: '## 剧情演绎\n正文\n\n## 推荐行动\n行动',
        toolCalls: [
          AiToolCall(
            id: id,
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
              ],
            },
          ),
        ],
        promptTokens: 5,
        completionTokens: 3,
        responseId: 'resp_1',
      );

  test('主响应：正文 + 行级工具同响应 → 单次调用即结束', () async {
    final copy = workingCopy();
    final r = runner(copy: copy, script: [
      worldEdit('call_1'),
    ]);

    final result = await r.run(
      initialInputItems: const [
        {'role': 'user', 'content': 'hi'},
      ],
      stream: true,
    );

    expect(result.content, contains('正文'));
    expect(result.promptTokens, 5);
    expect(result.completionTokens, 3);
    expect(result.outcomes, hasLength(1));
    expect(result.outcomes.every((o) => o.applied), isTrue);
    expect(result.warnings, isEmpty);
    expect(copy.worldState, '- 地点：主峰\n- 天气：晴');
  });

  test('校验失败 → 单次修复轮（第 2 帧带反馈），修正后结束；修复帧正文被丢弃', () async {
    final copy = workingCopy();
    final r = runner(copy: copy, script: [
      turnWithBadMemory('call_1'),
      AiCallResult(
        // 修复帧：模型复读正文（契约禁止但可能发生）→ 必须被丢弃。
        content: '## 剧情演绎\n补充后正文\n\n## 推荐行动\nx',
        toolCalls: const [
          AiToolCall(
            id: 'call_2',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
              ],
            },
          ),
          AiToolCall(
            id: 'call_3',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'memorySummary',
              'edits': [
                {
                  'op': 'append',
                  'newLine': '- 第2轮｜日期：第二天 申时｜主角见到掌门',
                },
              ],
            },
          ),
        ],
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'resp_2',
      ),
    ]);

    final result = await r.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    expect(result.outcomes.where((o) => !o.applied), hasLength(1));
    expect(result.warnings, isEmpty);
    expect(copy.worldState, '- 地点：主峰\n- 天气：晴');
    expect(copy.memorySummary, contains('第2轮'));
    // 正文采纳制：本轮正文 = 首个含正文帧；修复帧复读的正文被丢弃，
    // 不再拼接（旧行为会累积成「正文+补充后正文」）。
    expect(result.content, contains('正文'));
    expect(result.content, isNot(contains('补充后正文')));
  });

  test('修复 2 次仍失败 → 钳制跳过并记录警告，不阻塞正文落库', () async {
    final copy = workingCopy();
    final r = runner(copy: copy, script: [
      turnWithBadMemory('call_1'),
      turnWithBadMemory('call_2'),
      turnWithBadMemory('call_3'),
    ]);

    final result = await r.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    expect(result.warnings, hasLength(1));
    expect(result.warnings.single, contains('narrchat_editSection'));
    // 记忆总结未被污染（仍为空）。
    expect(copy.memorySummary, isEmpty);
    expect(copy.worldState, '- 地点：青云宗\n- 天气：晴');
  });

  test('无状态：修复帧全量重发 input（含修复反馈）', () async {
    final copy = workingCopy();
    final bodies = <Map<String, dynamic>>[];
    final r = runner(copy: copy, bodies: bodies, script: [
      turnWithBadMemory('call_1'),
      worldEdit('call_2'),
    ]);

    await r.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    expect(bodies, hasLength(2));
    expect(bodies[0]['prevId'], isNull);
    expect((bodies[0]['items'] as List), hasLength(1));
    // 第 2 帧（无状态重发）：初始 1 条 + function_call 重放 + output + 反馈。
    final items2 = bodies[1]['items'] as List;
    expect(items2, hasLength(4));
    expect((items2[1] as Map)['type'], 'function_call');
    expect((items2[1] as Map)['call_id'], 'call_1');
    expect((items2[2] as Map)['type'], 'function_call_output');
    expect((items2[3] as Map)['content'], contains('状态维护反馈'));
  });

  test('有状态链式：修复帧仅发新增 item + previous_response_id', () async {
    final copy = workingCopy();
    final bodies = <Map<String, dynamic>>[];
    final r = runner(copy: copy, bodies: bodies, chaining: true, script: [
      turnWithBadMemory('call_1'),
      worldEdit('call_2'),
    ]);

    await r.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    expect(bodies, hasLength(2));
    expect(bodies[1]['prevId'], 'resp_1');
    // 链式帧只发新增 item（函数产出 + 反馈）。
    expect(bodies[1]['items'] as List, hasLength(2));
  });

  test('工具轮（无正文）→ 继续循环直至正文', () async {
    final copy = workingCopy();
    final r = runner(copy: copy, script: [
      const AiCallResult(
        content: '',
        toolCalls: [
          AiToolCall(
            id: 'call_1',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
              ],
            },
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      const AiCallResult(
        content: '## 剧情演绎\n最终\n\n## 推荐行动\nx',
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'resp_2',
      ),
    ]);

    final result = await r.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    expect(result.content, contains('最终'));
    expect(copy.worldState, '- 地点：主峰\n- 天气：晴');
  });

  test('完整性缺失 → 补充修复轮；整轮累计判定（跨帧已调用不误判）', () async {
    final copy = workingCopy();
    List<String> checker(List<AgentToolOutcome> outcomes) {
      final used = {for (final o in outcomes) o.name};
      return [
        if (!used.contains('narrchat_advanceTime')) '未推进当前时间',
        if (!used.contains('narrchat_editSection')) '未编辑栏目',
      ];
    }

    // 场景 A：帧1 = 正文 + 行级编辑（无时间）→ 完整性缺失 → 补充轮；
    // 帧2 = 正文 + 时间与记忆 → 结束（帧2 正文被丢弃）。
    var callIndex = 0;
    final script = <AiCallResult>[
      worldEdit('call_1'),
      AiCallResult(
        content: '## 剧情演绎\n补充后正文\n\n## 推荐行动\nx',
        toolCalls: const [
          AiToolCall(
            id: 'call_2',
            name: 'narrchat_advanceTime',
            arguments: {'time': '第二天 申时'},
          ),
          AiToolCall(
            id: 'call_3',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'memorySummary',
              'edits': [
                {
                  'op': 'append',
                  'newLine': '- 第2轮｜日期：第二天 申时｜主角见到掌门',
                },
              ],
            },
          ),
        ],
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'resp_2',
      ),
    ];
    final r = AgentRoundRunner(
      buildBody: (items, prevId) => {'input': items},
      call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
        return script[callIndex++];
      },
      tools: buildStateTools(copy),
      completenessCheck: checker,
    );

    final result = await r.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );
    expect(result.warnings, isEmpty);
    expect(copy.currentTime, '第二天 申时');
    expect(copy.memorySummary, contains('第2轮'));
    // 正文 = 首发帧；补充帧复读正文被丢弃。
    expect(result.content, contains('正文'));
    expect(result.content, isNot(contains('补充后正文')));

    // 场景 B：帧1 已推进时间，帧2 仅正文 → 整轮累计不误判「未推进」。
    final copyB = workingCopy();
    final r2 = AgentRoundRunner(
      buildBody: (items, prevId) => {'input': items},
      call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
        return const AiCallResult(
          content: '## 剧情演绎\n正文\n\n## 推荐行动\nx',
          toolCalls: [
            AiToolCall(
              id: 'call_1',
              name: 'narrchat_advanceTime',
              arguments: {'time': '第二天 申时'},
            ),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_1',
        );
      },
      tools: buildStateTools(copyB),
      completenessCheck: checker,
    );
    final resultB = await r2.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );
    expect(resultB.warnings, contains('未编辑栏目'));
    expect(resultB.warnings, isNot(contains('未推进当前时间')));
  });

  test('无标题开场白帧（带工具）不采纳为正文；后续标题帧正常采纳', () async {
    final copy = workingCopy();
    final r = runner(copy: copy, script: [
      AiCallResult(
        // 模型先输出说明性开场白（无 ## 剧情演绎 标题）+ 工具调用 → 搜索开场白。
        content: 'I\'ll search for information about the two characters before writing the story.',
        toolCalls: [
          AiToolCall(
            id: 'call_1',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：灯会'},
              ],
            },
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      AiCallResult(
        // 标题帧：真正的正文 → 采纳；开场白不阻塞、不被当作正文。
        content: '## 剧情演绎\n真正的正文\n\n## 推荐行动\nx',
        toolCalls: const [
          AiToolCall(
            id: 'call_2',
            name: 'narrchat_advanceTime',
            arguments: {'time': '第二天 申时'},
          ),
          AiToolCall(
            id: 'call_3',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'memorySummary',
              'edits': [
                {
                  'op': 'append',
                  'newLine': '- 第2轮｜日期：第二天 申时｜主角来到灯会',
                },
              ],
            },
          ),
        ],
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'resp_2',
      ),
    ]);

    final result = await r.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    expect(result.content, contains('真正的正文'));
    expect(result.content, isNot(contains('I\'ll search')));
    // 全帧拼接仍保留开场白（文本状态兜底 / RAW 追溯用）。
    expect(result.fullContent, contains('I\'ll search'));
    expect(copy.worldState, '- 地点：灯会\n- 天气：晴');
    expect(copy.currentTime, '第二天 申时');
  });

  test('用户中断在执行工具前抛出 AiCancelledException', () async {
    final copy = workingCopy();
    var calls = 0;
    final r = AgentRoundRunner(
      buildBody: (items, prevId) => {'input': items},
      call: (body, stream, onChunk, onRequestBody, isCancelled) async {
        calls++;
        return const AiCallResult(
          content: '',
          toolCalls: [AiToolCall(id: 'x', name: 'narrchat_unknown', arguments: {})],
          promptTokens: 1,
          completionTokens: 1,
        );
      },
      tools: buildStateTools(copy),
    );

    await expectLater(
      r.run(
        initialInputItems: const [{'role': 'user', 'content': 'hi'}],
        stream: true,
        isCancelled: () => calls >= 2,
      ),
      throwsA(isA<AiCancelledException>()),
    );
  });
}
