import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/agent_round_runner.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/ai_service.dart';

/// `AgentRoundRunner` 单元测试：两阶段（正文轮 auto / 状态轮 required）、
/// 帧级正文分类与「最后一个标题帧胜出」、门控上屏、预置状态轨迹、
/// 协议兼容降级、无进展止损。
void main() {
  const lastRound = Round(
    id: 1,
    bookUuid: 'b1',
    roundIndex: 1,
    worldState: '- 地点：青云宗\n- 天气：晴',
    characterState: '# 主角\n## 林远\n- 气血：80',
    memorySummary: '',
    currentTime: '第二天 午时',
  );

  AgentStateWorkingCopy workingCopy() => AgentStateWorkingCopy(
        roundIndex: 2,
        lastRound: lastRound,
        categoryNames: const ['主角'],
      );

  /// 脚本化执行器：按序返回 [script] 中的帧结果（`AiException` 项 = 该次调用
  /// 直接失败，用于测协议降级重发），并把每帧请求记入 [requests]。
  ({AgentRoundRunner runner, List<_Request> requests, List<AiStreamChunk> sunk})
      harness({
    required AgentStateWorkingCopy copy,
    required List<Object> script,
    bool chaining = false,
    bool supportsToolChoice = true,
    bool supportsThinkingEffort = true,
    int maxStateFrames = kAgentMaxStateFrames,
  }) {
    final requests = <_Request>[];
    final sunk = <AiStreamChunk>[];
    var callIndex = 0;
    final runner = AgentRoundRunner(
      buildBody: (t) {
        requests.add((
          stage: t.stage,
          items: List.of(t.items),
          previousResponseId: t.previousResponseId,
          toolChoice: t.toolChoice,
          stateThinkingEffort: t.stateThinkingEffort,
        ));
        return {
          'input': t.items,
          'previous_response_id': ?t.previousResponseId,
          'tool_choice': ?t.toolChoice,
        };
      },
      call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
        final entry = script[callIndex++];
        if (entry is AiException) throw entry;
        final result = entry as AiCallResult;
        // 模拟流式：正文按块下发（门控必须与真实流一致地缓冲 / 重置）。
        onChunk?.call(AiStreamChunk(contentDelta: result.content));
        for (final tc in result.toolCalls) {
          onChunk?.call(
            AiStreamChunk(toolCallId: tc.id, toolName: tc.name),
          );
        }
        onChunk?.call(const AiStreamChunk(done: true));
        return result;
      },
      tools: buildStateTools(copy),
      workingCopy: copy,
      chaining: chaining,
      supportsToolChoice: supportsToolChoice,
      supportsThinkingEffort: supportsThinkingEffort,
      maxStateFrames: maxStateFrames,
    );
    return (runner: runner, requests: requests, sunk: sunk);
  }

  Future<AgentRoundResult> run(AgentRoundRunner r) => r.run(
        initialInputItems: const [
          {'role': 'user', 'content': 'hi'},
        ],
        stream: true,
        onChunk: null,
      );

  /// 正文 + 一个「记忆总结声明无变化」的调用（记忆每轮必须补条目 → 必被拒）。
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

  /// 状态轮的一帧：三个栏目全部补齐（[story] 非空时附带标题正文
  /// + `## 当前时间`；时间属于正文，不在工具清单里）。
  AiCallResult fullStateTurn(String prefix, {String story = ''}) => AiCallResult(
        content: story.isEmpty
            ? ''
            : '## 剧情演绎\n$story\n\n## 推荐行动\n行动\n\n## 当前时间\n第二天 申时',
        toolCalls: [
          AiToolCall(
            id: '${prefix}_w',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
              ],
            },
          ),
          AiToolCall(
            id: '${prefix}_c',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'characterState',
              'edits': [
                {'op': 'set', 'before': '- 气血：80', 'newLine': '- 气血：70'},
              ],
            },
          ),
          AiToolCall(
            id: '${prefix}_m',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'memorySummary',
              'edits': [
                {
                  'op': 'append',
                  'newLine': '- 第2轮｜日期：第二天 申时｜主角前往主峰',
                },
              ],
            },
          ),
        ],
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'resp_2',
      );

  AiCallResult storyOnly({String story = '正文', String time = ''}) =>
      AiCallResult(
        content: '## 剧情演绎\n$story\n\n## 推荐行动\n行动'
            '${time.isEmpty ? '' : '\n\n## 当前时间\n$time'}',
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      );

  test('正文轮已把状态补齐 → 单次调用即结束（零额外请求、无警告）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      AiCallResult(
        content: '## 剧情演绎\n正文\n\n## 推荐行动\n行动\n\n## 当前时间\n第二天 申时',
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
          AiToolCall(
            id: 'call_2',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'characterState',
              'edits': [
                {'op': 'set', 'before': '- 气血：80', 'newLine': '- 气血：70'},
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
                  'newLine': '- 第2轮｜日期：第二天 申时｜主角前往主峰',
                },
              ],
            },
          ),
        ],
        promptTokens: 5,
        completionTokens: 3,
        responseId: 'resp_1',
      ),
    ]);

    final result = await run(h.runner);

    expect(h.requests, hasLength(1));
    expect(h.requests.single.stage, AgentStage.story);
    expect(h.requests.single.toolChoice, 'auto');
    expect(result.stateTurnUsed, isFalse);
    expect(result.frames, 1);
    expect(result.warnings, isEmpty);
    expect(result.content, contains('正文'));
    expect(copy.worldState, '- 地点：主峰\n- 天气：晴');
    // 时间来自正文 `## 当前时间`（工作副本由解析写入）。
    expect(copy.currentTime, '第二天 申时');
    expect(copy.memorySummary, contains('第2轮'));
  });

  test('正文轮只写正文 → 自动发起状态轮（required + 状态轮思考降为 low）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [storyOnly(), fullStateTurn('s')]);

    final result = await run(h.runner);

    expect(h.requests, hasLength(2));
    expect(h.requests[0].stage, AgentStage.story);
    expect(h.requests[1].stage, AgentStage.state);
    // 状态轮：强制调工具 + 思考强度覆盖为 low（不硬关——状态维护要理解正文）。
    expect(h.requests[1].toolChoice, 'required');
    expect(h.requests[1].stateThinkingEffort, kAgentStateThinkingEffort);
    // 正文轮不覆盖（沿用用户设置）。
    expect(h.requests[0].stateThinkingEffort, isNull);
    // 两阶段前缀完全一致（instructions / tools 由 provider 保证，这里比 input 前缀）。
    expect(h.requests[1].items.length, greaterThan(h.requests[0].items.length));
    // 快照**不再预置注入**：request 里的 input 不含 readState 条目。
    final readItems = h.requests[1]
        .items
        .where((i) => i['name'] == kReadStateToolName)
        .toList();
    expect(readItems, isEmpty, reason: '状态快照改为模型自取，应用不做预置');
    expect(result.stateTurnUsed, isTrue);
    expect(result.warnings, isEmpty);
    expect(copy.worldState, '- 地点：主峰\n- 天气：晴');
  });

  /// 模型主动调用 readState 的合法流程帧：只读，无文本、无编辑。
  AiCallResult readStateTurn(String id, {int round = 2}) => AiCallResult(
        content: '',
        toolCalls: [
          AiToolCall(
            id: id,
            name: kReadStateToolName,
            arguments: {'round': round},
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_$id',
      );

  test('readState 自取：正文轮先读后写；上下文只保留最新一份快照', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      readStateTurn('rs1'), // 正文轮第 1 帧：读状态（开场白，不上屏）
      storyOnly(), // 正文轮第 2 帧：正文
      readStateTurn('rs2'), // 状态轮第 1 帧：读正文后的最新态
      fullStateTurn('s'), // 状态轮第 2 帧：全部编辑
    ]);

    final result = await run(h.runner);

    expect(result.content, contains('正文'));
    expect(result.stateTurnUsed, isTrue);
    expect(copy.worldState, '- 地点：主峰\n- 天气：晴');
    expect(h.requests, hasLength(4));
    // 正文帧的请求里：模型**自己**调用后只留下一次 readState 结果（最初
    // 请求不含任何快照；读取结果随帧 1 追加，帧 2 可见且仅此一份）。
    final rsCalls = h.requests[1]
        .items
        .where((i) => i['name'] == kReadStateToolName)
        .toList();
    expect(rsCalls, hasLength(1));
    expect(rsCalls.single['call_id'], 'rs1');
    // 状态轮第 2 帧：第 1 帧新读的结果替换了旧份（仍只有一份快照）。
    final latest = h.requests[3]
        .items
        .where((i) => i['name'] == kReadStateToolName)
        .toList();
    expect(latest, hasLength(1));
    expect(latest.single['call_id'], 'rs2');
    // 读取结果 = 工作副本当前渲染（含「本轮正文之后」的语义来源标记）。
    final snapshot = h.requests[3].items
        .where((i) => i['type'] == 'function_call_output')
        .firstWhere((i) => '${i['output']}'.contains('NARRCHAT_STATE'));
    expect('${snapshot['output']}', contains('<<<NARRCHAT_STATE round=2>>>'));
  });

  test('状态轮文本不上屏、也不覆盖已采纳正文', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      storyOnly(),
      AiCallResult(
        // 状态轮违规复读正文（结构上不可能成为本轮正文）。
        content: '## 剧情演绎\n状态轮里又写了一份正文\n\n## 推荐行动\nx',
        toolCalls: fullStateTurn('s').toolCalls,
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'resp_2',
      ),
    ]);
    final sunk = <AiStreamChunk>[];
    await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
      onChunk: sunk.add,
    );

    final published = sunk
        .where((c) => c.contentDelta.isNotEmpty)
        .map((c) => c.contentDelta)
        .join();
    expect(published, contains('正文'));
    expect(published, isNot(contains('状态轮里又写了一份正文')));
  });

  test('写到一半去搜索 → 后一个标题帧胜出，界面收到重置信号', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      // 帧 1：半截正文 + 搜索工具（非状态工具 → 必须继续下一帧）。
      AiCallResult(
        content: '## 剧情演绎\n写了一半',
        toolCalls: const [
          AiToolCall(
            id: 's1',
            name: 'narrchat_webSearch',
            arguments: {'query': '青云宗'},
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      // 帧 2：完整正文 + 全部状态工具 → 覆盖帧 1。
      fullStateTurn('f2'),
    ]);
    final sunk = <AiStreamChunk>[];
    final result = await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
      onChunk: sunk.add,
    );

    // 帧 2 没有正文（状态轮语义）→ 采纳的仍是帧 1 的正文。
    expect(result.content, contains('写了一半'));
    expect(h.requests.first.items, hasLength(1)); // 历史；快照不预置（模型自取）
    expect(h.requests[1].stage, AgentStage.story);
    // 搜索帧的输出被回传（模型据此续写）。
    expect(
      h.requests[1].items.any((i) => i['type'] == 'function_call_output'),
      isTrue,
    );
    // 帧 1 正文上屏过；帧 2 无文本 → 不再有第二次重置。
    expect(sunk.where((c) => c.narrativeReset), hasLength(1));
  });

  test('无状态重发：每帧全量 input，快照不预置（模型自取）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [storyOnly(), fullStateTurn('s')]);
    await run(h.runner);

    expect(h.requests[0].previousResponseId, isNull);
    expect(h.requests[1].previousResponseId, isNull);
    final first = h.requests[0].items;
    // 历史 1 条；快照**不再预置**（模型应自行调用 readState 获取）。
    expect(first, hasLength(1));
    expect(first.single['role'], 'user');
    // 第 2 帧：正文轮 assistant 消息已回传（旧缺陷：续接帧「失忆」）。
    expect(
      h.requests[1].items.any((i) =>
          i['role'] == 'assistant' && '${i['content']}'.contains('正文')),
      isTrue,
    );
    // 状态轮指令是最后一条 user 消息。
    final last = h.requests[1].items.last;
    expect(last['role'], 'user');
    expect('${last['content']}', contains('[State-maintenance turn]'));
    expect('${last['content']}', contains('narrchat_readState'));
  });

  test('有状态链式：续接帧只发新增 item + previous_response_id', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      chaining: true,
      script: [storyOnly(), fullStateTurn('s')],
    );
    await run(h.runner);

    expect(h.requests[0].previousResponseId, isNull);
    expect(h.requests[0].items, hasLength(1));
    expect(h.requests[1].previousResponseId, 'resp_1');
    // 只发第 1 帧之后新增的条目（assistant 正文 + 状态轮指令）。
    expect(h.requests[1].items, hasLength(2));
  });

  test('服务商拒绝 tool_choice → 就地降级重发同一帧（不额外计帧）', () async {
    final copy = workingCopy();
    var attempt = 0;
    final requests = <_Request>[];
    final runner = AgentRoundRunner(
      buildBody: (t) {
        requests.add((
          stage: t.stage,
          items: List.of(t.items),
          previousResponseId: t.previousResponseId,
          toolChoice: t.toolChoice,
          stateThinkingEffort: t.stateThinkingEffort,
        ));
        return {'input': t.items, 'tool_choice': ?t.toolChoice};
      },
      call: (body, stream, onChunk, onRequestBody, isCancelled) async {
        attempt++;
        if (attempt == 1) {
          throw const AiException('Unsupported parameter: tool_choice');
        }
        return fullStateTurn('r', story: '正文');
      },
      tools: buildStateTools(copy),
      workingCopy: copy,
    );

    final result = await runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );
    // 降级重发的是**同一帧**：不计帧、正文照常采纳（旧行为：一次兼容性
    // 4xx 直接判失败，白烧用户这一轮的钱）。
    expect(result.frames, 1);
    expect(result.content, contains('正文'));
    expect(result.outcomes, hasLength(3));
    expect(runner.supportsToolChoice, isFalse);
    expect(requests, hasLength(2));
    expect(requests.first.toolChoice, 'auto');
    expect(requests.last.toolChoice, isNull);
    // 降级重发的是同一帧：input 完全一致。
    expect(requests.last.items, requests.first.items);
  });

  test('状态轮空手帧不再提前止损：保留修复机会（帧数上限兜底）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxStateFrames: 2, script: [
      storyOnly(), // 正文轮（未动状态 → 3 个栏目缺口）
      storyOnly(story: '正文'), // 状态帧 0：只回文本（空手，不应结束整轮）
      fullStateTurn('s'), // 状态帧 1：补齐全部栏目
    ]);

    final result = await run(h.runner);

    expect(h.requests, hasLength(3));
    expect(h.requests[1].stage, AgentStage.state);
    expect(h.requests[2].stage, AgentStage.state);
    expect(result.stateTurnUsed, isTrue);
    // 空手帧后仍把缺口补上 → 无警告。
    expect(result.warnings, isEmpty);
    expect(copy.worldState, '- 地点：主峰\n- 天气：晴');
    expect(copy.memorySummary, contains('第2轮'));
  });

  test('状态轮用尽仍有缺项 → 警告钳制（正文照常返回）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      maxStateFrames: 2,
      script: [
        turnWithBadMemory('call_1'),
        turnWithBadMemory('call_2'),
        turnWithBadMemory('call_3'),
      ],
    );

    final result = await run(h.runner);

    expect(result.content, contains('正文'));
    expect(result.frames, 3); // 正文轮 1 + 状态轮 2
    expect(result.warnings, isNotEmpty);
    expect(result.warnings.join(), contains('记忆总结'));
    // 记忆总结未被污染（noChange 被拒）。
    expect(copy.memorySummary, isEmpty);
    expect(copy.worldState, '- 地点：青云宗\n- 天气：晴');
  });

  test('锚点未命中 → 回传该栏目当前全文供重锚', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      AiCallResult(
        content: '## 剧情演绎\n正文\n\n## 推荐行动\n行动',
        toolCalls: [
          AiToolCall(
            id: 'call_1',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {
                  'op': 'set',
                  'before': '- 地点：完全不存在的行',
                  'newLine': '- 地点：主峰',
                },
              ],
            },
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      fullStateTurn('s'),
    ]);
    await run(h.runner);

    final outputs = h.requests[1].items
        .where((i) => i['type'] == 'function_call_output')
        .map((i) => '${i['output']}')
        .join('\n');
    expect(outputs, contains('未找到与 before 匹配的行'));
    expect(outputs, contains('当前全文'));
    expect(outputs, contains('- 天气：晴'));
    // 状态轮把失败项一并列出。
    expect(
      '${h.requests[1].items.last['content']}',
      contains('narrchat_editSection'),
    );
  });

  test('工具参数被截断 → 不执行，并给出「一栏目一次调用」的重试指引', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      AiCallResult(
        content: '## 剧情演绎\n正文\n\n## 推荐行动\n行动',
        toolCalls: [
          AiToolCall(
            id: 'call_1',
            name: 'narrchat_editSection',
            arguments: const {},
            argumentsUnparsable: true,
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      fullStateTurn('s'),
    ]);

    final result = await run(h.runner);

    expect(result.outcomes.first.applied, isFalse);
    expect(result.outcomes.first.message, contains('截断'));
    // 截断帧什么都没改（世界状态仍是基座），补齐由状态轮那一帧完成。
    expect(
      '${h.requests[1].items.firstWhere((i) =>
          i['type'] == 'function_call_output' &&
          i['call_id'] == 'call_1')['output']}',
      contains('TRUNCATED'),
    );
    // 截断项进了状态轮反馈，修复帧完成后无警告。
    expect(
      '${h.requests[1].items.last['content']}',
      contains('TRUNCATED'),
    );
    expect(result.warnings, isEmpty);
  });

  test('懒修改：本轮出场角色块未变 → 状态轮点名', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      // 正文提到林远，但角色状态只声明无变化（且带了 reason，栏目级合法）。
      AiCallResult(
        content: '## 剧情演绎\n林远握紧了剑。\n\n## 推荐行动\n行动',
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
          AiToolCall(
            id: 'call_2',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'characterState',
              'edits': [
                {'op': 'noChange', 'reason': '林远状态未变'},
              ],
            },
          ),
          AiToolCall(
            id: 'call_3',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'memorySummary',
              'edits': [
                {'op': 'append', 'newLine': '- 第2轮｜日期：第二天 午时｜林远握剑'},
              ],
            },
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      AiCallResult(
        content: '',
        toolCalls: [
          AiToolCall(
            id: 'call_5',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'characterState',
              'edits': [
                {'op': 'set', 'before': '- 气血：80', 'newLine': '- 气血：75'},
              ],
            },
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_2',
      ),
    ]);

    final result = await run(h.runner);

    // 第 1 帧后仍缺角色状态 → 状态轮指令点名「林远」，并引导改为实际行级编辑。
    expect(h.requests, hasLength(2));
    expect(h.requests[1].stage, AgentStage.state);
    expect('${h.requests[1].items.last['content']}', contains('林远'));
    expect('${h.requests[1].items.last['content']}', contains('op=set'));
    expect('${h.requests[1].items.last['content']}', contains('懒修改'));
    expect(result.warnings, isEmpty);
    expect(copy.characterState, contains('- 气血：75'));
  });

  /// 被输出上限截断的状态帧：一处编辑成功，另一处栏目参数没写完（JSON 不闭合）。
  AiCallResult truncatedStateTurn(String prefix) => AiCallResult(
        content: '',
        toolCalls: [
          AiToolCall(
            id: '${prefix}_w',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
              ],
            },
          ),
          const AiToolCall(
            id: 'x',
            name: 'narrchat_editSection',
            arguments: {},
            argumentsUnparsable: true,
          ),
        ],
        promptTokens: 1,
        completionTokens: 4096,
        incomplete: true,
        incompleteReason: kIncompleteMaxOutputTokens,
      );

  test('状态帧被截断：不判失败，下一帧带「拆短调用」指令重发', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxStateFrames: 2, script: [
      storyOnly(),
      truncatedStateTurn('a'),
      fullStateTurn('b'),
    ]);

    final result = await run(h.runner);

    expect(h.requests, hasLength(3));
    // 补救只走提示词与思考强度覆盖：请求体里的 max_output_tokens 由用户设置
    // 决定，执行器不擅自抬高（帧间唯一的差异仍是 tool_choice / 思考覆盖）。
    expect(h.requests[1].toolChoice, 'required');
    expect(h.requests[2].toolChoice, 'required');
    expect(h.requests[2].stateThinkingEffort, kAgentStateThinkingEffort);
    expect('${h.requests[2].items.last['content']}', contains('TRUNCATED'));
    expect('${h.requests[2].items.last['content']}', contains('拆短'));
    // 末帧未截断 → 不再对用户提示截断。
    expect(result.incomplete, isFalse);
    expect(result.incompleteReason, isEmpty);
  });

  test('状态帧末帧仍截断 → 给用户一条可操作的「调高最大 token」提示', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxStateFrames: 2, script: [
      storyOnly(),
      truncatedStateTurn('a'),
      truncatedStateTurn('b'),
    ]);

    final result = await run(h.runner);

    expect(result.incomplete, isTrue);
    expect(result.incompleteReason, kIncompleteMaxOutputTokens);
    expect(result.warnings.first, contains('最大 token'));
    // 正文照常产出：截断只影响状态，不再赔掉整轮。
    expect(result.content, contains('正文'));
  });

  test('被截断的帧不作为续接基点：下一帧改为全量重发', () async {
    final copy = workingCopy();
    const story = AiCallResult(
      content: '## 剧情演绎\n正文\n\n## 推荐行动\n行动',
      promptTokens: 1,
      completionTokens: 1,
      responseId: 'resp_1',
    );
    final h = harness(copy: copy, chaining: true, maxStateFrames: 2, script: [
      story,
      truncatedStateTurn('a'),
      fullStateTurn('b'),
    ]);

    await run(h.runner);

    // 状态帧 1 走续接（只发新增项）。
    expect(h.requests[1].previousResponseId, 'resp_1');
    // 状态帧 1 被截断 → 帧 2 不能作为基点：全量重发且不带 previous_response_id。
    expect(h.requests[2].previousResponseId, isNull);
    expect(
      h.requests[2].items.length,
      greaterThan(h.requests[1].items.length),
    );
  });

  test('服务商拒绝中途调整思考强度 → 回落用户设置重发同一帧（不额外烧帧）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      storyOnly(),
      const AiException(
        "Unsupported parameter: 'reasoning.effort' is not supported",
        kind: AiExceptionKind.api,
      ),
      fullStateTurn('b'),
    ]);

    final result = await run(h.runner);

    // 状态帧第 1 次尝试覆盖为 low → 被拒 → 同帧重发时不再覆盖（沿用户设置）。
    expect(h.requests, hasLength(3));
    expect(h.requests[1].stateThinkingEffort, kAgentStateThinkingEffort);
    expect(h.requests[2].stateThinkingEffort, isNull);
    expect(h.requests[2].toolChoice, 'required');
    expect(h.runner.supportsThinkingEffort, isFalse);
    // 失败的那次尝试不计帧。
    expect(result.frames, 2);
    expect(copy.worldState, contains('- 地点：主峰'));
  });

  test('用户中断在执行工具前抛出 AiCancelledException', () async {
    final copy = workingCopy();
    var calls = 0;
    final runner = AgentRoundRunner(
      buildBody: (t) => {'input': t.items},
      call: (body, stream, onChunk, onRequestBody, isCancelled) async {
        calls++;
        return const AiCallResult(
          content: '',
          toolCalls: [
            AiToolCall(id: 'x', name: 'narrchat_unknown', arguments: {}),
          ],
          promptTokens: 1,
          completionTokens: 1,
        );
      },
      tools: buildStateTools(copy),
      workingCopy: copy,
    );

    await expectLater(
      runner.run(
        initialInputItems: const [{'role': 'user', 'content': 'hi'}],
        stream: true,
        isCancelled: () => calls >= 2,
      ),
      throwsA(isA<AiCancelledException>()),
    );
  });
}

/// 一次帧调用的记录（阶段 / input 快照 / tool_choice / 状态轮思考覆盖）。
typedef _Request = ({
  AgentStage stage,
  List<Map<String, dynamic>> items,
  String? previousResponseId,
  String? toolChoice,
  String? stateThinkingEffort,
});

