import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/agent_mode_profile.dart';
import 'package:narrchat/services/agent/agent_round_runner.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/memory_merge_planner.dart';
import 'package:narrchat/utils/memory_entry_format.dart';

/// `AgentRoundRunner` 单元测试：分阶段执行器（Lv.2 = 正文轮 auto /
/// 维护轮 required；Lv.1 = 准备 → 记忆 → 正文，维护轮仅兜底）、档位差异、
/// 帧级正文分类与「最后一个标题帧胜出」、门控上屏、读取器自取、
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

  /// 编辑调用：按栏目选对应编辑器（参数只剩 `edits`）。
  AiToolCall editCall(
    String id,
    AgentStateSection section,
    List<Map<String, dynamic>> edits,
  ) =>
      AiToolCall(
        id: id,
        name: agentEditToolName(section),
        arguments: {'edits': edits},
      );

  /// 读取调用：按栏目选对应读取器。
  AiToolCall readCall(String id, AgentStateSection section, {int round = 2}) =>
      AiToolCall(
        id: id,
        name: agentReadToolName(section),
        arguments: {'round': round},
      );

  /// 脚本化执行器：按序返回 [script] 中的帧结果（`AiException` 项 = 该次调用
  /// 直接失败，用于测协议降级重发），并把每帧请求记入 [requests]。
  ({AgentRoundRunner runner, List<_Request> requests, List<AiStreamChunk> sunk})
      harness({
    required AgentStateWorkingCopy copy,
    required List<Object> script,
    AgentModeLevel level = AgentModeLevel.lv2,
    MemoryMergePlan? memoryMergePlan,
    bool chaining = false,
    bool supportsToolChoice = true,
    bool supportsThinkingEffort = true,
    bool reduceReasoningReplay = false,
    int maxPrepFrames = kAgentMaxPrepFrames,
    int maxMemoryFrames = kAgentMaxMemoryFrames,
    int maxStateFrames = kAgentMaxStateFrames,
  }) {
    final requests = <_Request>[];
    final sunk = <AiStreamChunk>[];
    var callIndex = 0;
    final profile = AgentModeProfile.of(level);
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
      tools: buildStateTools(copy, sections: profile.toolSections),
      workingCopy: copy,
      profile: profile,
      memoryMergePlan: memoryMergePlan,
      chaining: chaining,
      supportsToolChoice: supportsToolChoice,
      supportsThinkingEffort: supportsThinkingEffort,
      reduceReasoningReplay: reduceReasoningReplay,
      maxPrepFrames: maxPrepFrames,
      maxMemoryFrames: maxMemoryFrames,
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

  /// 正文 + 一个「历史声明无变化」的调用（历史每轮必须补条目 → 必被拒）。
  AiCallResult turnWithBadMemory(String id) {
    return AiCallResult(
      content: '## 剧情演绎\n正文\n\n## 推荐行动\n行动',
      toolCalls: [
        editCall(id, AgentStateSection.memorySummary, [
          {'op': 'noChange'},
        ]),
      ],
      promptTokens: 1,
      completionTokens: 1,
      responseId: 'resp_1',
    );
  }

  /// 维护轮的一帧：三个栏目全部补齐（[story] 非空时附带标题正文
  /// + `## 当前时间`；时间属于正文，不在工具清单里）。
  AiCallResult fullStateTurn(String prefix, {String story = ''}) => AiCallResult(
        content: story.isEmpty
            ? ''
            : '## 剧情演绎\n$story\n\n## 推荐行动\n行动\n\n## 当前时间\n第二天 申时',
        toolCalls: [
          editCall('${prefix}_w', AgentStateSection.worldState, [
            {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
          ]),
          editCall('${prefix}_c', AgentStateSection.characterState, [
            {'op': 'set', 'before': '- 气血：80', 'newLine': '- 气血：70'},
          ]),
          editCall('${prefix}_m', AgentStateSection.memorySummary, [
            {
              'op': 'append',
              'newLine': '- 第2轮｜日期：第二天 申时｜主角前往主峰',
            },
          ]),
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
          editCall('call_1', AgentStateSection.worldState, [
            {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
          ]),
          editCall('call_2', AgentStateSection.characterState, [
            {'op': 'set', 'before': '- 气血：80', 'newLine': '- 气血：70'},
          ]),
          editCall('call_3', AgentStateSection.memorySummary, [
            {
              'op': 'append',
              'newLine': '- 第2轮｜日期：第二天 申时｜主角前往主峰',
            },
          ]),
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

  test('正文轮只写正文 → 自动发起维护轮（required + 维护轮思考降为 low）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [storyOnly(), fullStateTurn('s')]);

    final result = await run(h.runner);

    expect(h.requests, hasLength(2));
    expect(h.requests[0].stage, AgentStage.story);
    expect(h.requests[1].stage, AgentStage.state);
    // 维护轮：强制调工具 + 思考强度覆盖为 low（不硬关——状态维护要理解正文）。
    expect(h.requests[1].toolChoice, 'required');
    expect(h.requests[1].stateThinkingEffort, kAgentStateThinkingEffort);
    // 正文轮不覆盖（沿用用户设置）。
    expect(h.requests[0].stateThinkingEffort, isNull);
    // 两阶段前缀完全一致（instructions / tools 由 provider 保证，这里比 input 前缀）。
    expect(h.requests[1].items.length, greaterThan(h.requests[0].items.length));
    // 状态**不再预置注入**：request 里的 input 不含任何读取结果。
    final readItems = h.requests[1].items.where(
      (i) => i['name'] == kReadWorldStateToolName,
    );
    expect(readItems, isEmpty, reason: '状态改为模型自取，应用不做预置');
    expect(result.stateTurnUsed, isTrue);
    expect(result.warnings, isEmpty);
    expect(copy.worldState, '- 地点：主峰\n- 天气：晴');
  });

  /// 模型主动读取三栏的合法流程帧：只读，无文本、无编辑。
  AiCallResult readAllTurn(String prefix, {int round = 2}) => AiCallResult(
        content: '',
        toolCalls: [
          for (final section in AgentStateSection.values)
            readCall('${prefix}_${section.tag}', section, round: round),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_$prefix',
      );

  test('读取器自取：正文回合只读一次，每栏只保留最新一份结果', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      readAllTurn('rs1'), // 正文轮第 1 帧：读三栏（开场白，不上屏）
      storyOnly(), // 正文轮第 2 帧：正文
      fullStateTurn('s'), // 维护轮第 1 帧：直接编辑（复用 rs1 的读取结果）
    ]);

    final result = await run(h.runner);

    expect(result.content, contains('正文'));
    expect(result.stateTurnUsed, isTrue);
    expect(copy.worldState, '- 地点：主峰\n- 天气：晴');
    expect(h.requests, hasLength(3));
    // 正文帧的请求里：模型自己读取后，每栏恰好一份结果（按栏剔除旧份）。
    for (final section in AgentStateSection.values) {
      final name = agentReadToolName(section);
      final calls =
          h.requests[1].items.where((i) => i['name'] == name).toList();
      expect(calls, hasLength(1), reason: '$name 应只保留一份');
      expect(calls.single['call_id'], 'rs1_${section.tag}');
    }
    // 维护帧的请求里：**同一份**读取结果仍在上下文（正文回合的读取就是
    // 维护回合的锚点来源），维护帧自身不再产生任何读取调用。
    final maintenanceItems = h.requests[2].items;
    for (final section in AgentStateSection.values) {
      final name = agentReadToolName(section);
      final calls = maintenanceItems.where((i) => i['name'] == name).toList();
      expect(calls, hasLength(1), reason: '$name 仍应只有正文回合那一份');
      expect(calls.single['call_id'], 'rs1_${section.tag}');
    }
    // 读取结果 = 工作副本当前渲染，且只含被请求的那一栏标签。
    final worldOutput = maintenanceItems
        .where((i) => i['type'] == 'function_call_output')
        .firstWhere((i) => '${i['output']}'.contains('NARRCHAT_STATE'));
    expect('${worldOutput['output']}', contains('<<<NARRCHAT_STATE round=2>>>'));
    final historyCall = maintenanceItems.firstWhere(
      (i) => i['name'] == kReadHistoryToolName,
    );
    final historyOutput = maintenanceItems.firstWhere(
      (i) =>
          i['type'] == 'function_call_output' &&
          i['call_id'] == historyCall['call_id'],
    );
    expect('${historyOutput['output']}', contains('<memorySummary'));
    expect('${historyOutput['output']}', isNot(contains('<worldState>')));
  });

  test('维护轮护栏：已提供过的栏目重复读取被拒绝（正文回合结果不被顶替）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      readAllTurn('rs1'), // 正文轮：读三栏
      storyOnly(), // 正文轮：正文
      readAllTurn('rs2'), // 维护轮第 1 帧：多此一举地再读一遍 → 全部被拒
      fullStateTurn('s'), // 维护轮第 2 帧：按已有全文直接编辑
    ]);

    final result = await run(h.runner);

    expect(h.requests, hasLength(4));
    expect(result.warnings, isEmpty, reason: '被拒的重复读取不算缺项，照常完成');
    expect(copy.worldState, '- 地点：主峰\n- 天气：晴');
    expect(copy.memorySummary, contains('第2轮'));

    // 三次读取调用都执行了「拒绝」语义（UI 事件框 ✕ + 回传说明）。
    final refused = result.outcomes.where((o) => !o.applied).toList();
    expect(refused, hasLength(3));
    for (final o in refused) {
      expect(o.message, contains('不再重复读取'));
      expect(o.isStateTool, isFalse, reason: '流程违规不进入缺项清单');
    }

    // 第 4 帧（编辑帧）的请求里：rs2 的调用与拒绝说明在上下文，但**没有**
    // 可用的新读取结果——正文回合的 rs1 结果仍是唯一一份（未被顶替）。
    final items = h.requests[3].items;
    for (final section in AgentStateSection.values) {
      final name = agentReadToolName(section);
      final executed = items
          .where((i) => i['name'] == name)
          .map((i) => i['call_id'])
          .toList();
      expect(executed, containsAll(['rs1_${section.tag}', 'rs2_${section.tag}']));
    }
    final rs2Output = items.firstWhere(
      (i) =>
          i['type'] == 'function_call_output' &&
          i['call_id'] == 'rs2_worldState',
    );
    expect('${rs2Output['output']}', contains('本次不再重复读取'));
    expect('${rs2Output['output']}', contains(kEditWorldStateToolName));
    expect('${rs2Output['output']}', isNot(contains('NARRCHAT_STATE')));
    // 回传说明：中文概述在英文要求之后，无 [EN] / 【中】 语言标记。
    expect('${rs2Output['output']}', contains('已在对话中'));
    expect('${rs2Output['output']}', isNot(contains('[EN]')));
    expect('${rs2Output['output']}', isNot(contains('【中】')));
    // 正文回合那一份仍在（护栏不能把模型的唯一锚点来源剔掉）。
    final rs1Output = items.firstWhere(
      (i) =>
          i['type'] == 'function_call_output' &&
          i['call_id'] == 'rs1_worldState',
    );
    expect('${rs1Output['output']}', contains('NARRCHAT_STATE'));
  });

  test('维护轮护栏：正文回合**漏读**的栏目照常允许读取（非合规流程不失明）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      // 正文轮第 1 帧：只读了世界状态（漏了角色 / 历史）。
      AiCallResult(
        content: '',
        toolCalls: [
          readCall('r_w', AgentStateSection.worldState),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      storyOnly(), // 正文轮第 2 帧：正文
      // 维护轮：补齐漏读的两栏（允许执行）+ 直接编辑全部清单项。
      AiCallResult(
        content: '',
        toolCalls: [
          readCall('m_c', AgentStateSection.characterState),
          readCall('m_m', AgentStateSection.memorySummary),
          ...fullStateTurn('s').toolCalls,
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_2',
      ),
    ]);

    final result = await run(h.runner);

    expect(h.requests, hasLength(3));
    // 正文回合那一份读取结果在维护帧仍可用（未读的栏目不受护栏影响）。
    expect(
      h.requests[2].items.any(
        (i) => i['call_id'] == 'r_w' && '${i['output']}'.contains('<worldState>'),
      ),
      isTrue,
    );
    // 漏读的两栏照常执行读取（未提供过 → 护栏放行）。
    final readOutcomes =
        result.outcomes.where((o) => kReadStateToolNames.contains(o.name)).toList();
    expect(readOutcomes.map((o) => o.callId),
        containsAll(['r_w', 'm_c', 'm_m']));
    expect(readOutcomes.every((o) => o.applied), isTrue);
    // 编辑照常落地，整轮无警告。
    expect(copy.characterState, contains('- 气血：70'));
    expect(copy.memorySummary, contains('第2轮'));
    expect(result.warnings, isEmpty);
  });

  test('维护轮文本不上屏、也不覆盖已采纳正文', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      storyOnly(),
      AiCallResult(
        // 维护轮违规复读正文（结构上不可能成为本轮正文）。
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

    // 帧 2 没有正文（维护轮语义）→ 采纳的仍是帧 1 的正文。
    expect(result.content, contains('写了一半'));
    expect(h.requests.first.items, hasLength(1)); // 历史；状态不预置（模型自取）
    expect(h.requests[1].stage, AgentStage.story);
    // 搜索帧的输出被回传（模型据此续写）。
    expect(
      h.requests[1].items.any((i) => i['type'] == 'function_call_output'),
      isTrue,
    );
    // 帧 1 正文上屏过；帧 2 无文本 → 不再有第二次重置。
    expect(sunk.where((c) => c.narrativeReset), hasLength(1));
  });

  test('思考块按**每个工具调用**各回传一块（服务端逐块校验）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      // 帧 1：一次思考 + **两个**工具调用（读取器 → 必然继续下一帧）。
      AiCallResult(
        content: '## 剧情演绎\n写了一半\n\n## 推荐行动\n行动',
        reasoningContent: '先读世界状态',
        reasoningItems: const [
          AiReasoningItem(id: 'r1', text: '先读世界状态'),
        ],
        toolCalls: [
          readCall('r_w', AgentStateSection.worldState),
          readCall('r_c', AgentStateSection.characterState),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      // 帧 2：补齐三栏（正文轮闭环；缺口已无 → 不发维护轮，脚本刚好用尽）。
      fullStateTurn('f2'),
    ]);
    final result = await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    expect(result.content, contains('写了一半'));
    expect(h.requests, hasLength(2));
    final frame2 = h.requests[1].items;
    // 服务端实测规则：带 tools 的请求里**每个 function_call 都必须紧邻其前**
    // 各有一块非空 reasoning（一帧两个调用只回一块 → 400
    //「The reasoning_text in the thinking mode must be passed back」）。
    final calls = <int>[
      for (var i = 0; i < frame2.length; i++)
        if (frame2[i]['type'] == 'function_call') i,
    ];
    expect(calls, hasLength(2));
    for (final callAt in calls) {
      expect(
        callAt,
        greaterThan(0),
        reason: 'function_call 前必须有紧邻的思考块',
      );
      expect(frame2[callAt - 1]['type'], 'reasoning');
      expect(frame2[callAt - 1]['text'], isNotEmpty);
    }
    // 正文帧的 assistant 消息在（思考块不会被正文顶替）。
    expect(
      frame2.any((i) => i['role'] == 'assistant' && '${i['content']}'.contains('写了一半')),
      isTrue,
    );
  });

  test('无工具调用的帧：思考块照常回传（先于正文，单块）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      // 帧 1：只有正文（无工具）→ 正文轮直接结束；缺口 → 维护轮。
      AiCallResult(
        content: '## 剧情演绎\n正文\n\n## 推荐行动\n行动',
        reasoningContent: '想了一下剧情',
        reasoningItems: const [
          AiReasoningItem(id: 'r1', text: '想了一下剧情'),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      fullStateTurn('f2'),
    ]);
    await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    // 维护轮首帧请求体里：思考块恰一块，且先于正文消息。
    final frame2 = h.requests[1].items;
    final reasonings = [
      for (final i in frame2)
        if (i['type'] == 'reasoning') i,
    ];
    expect(reasonings, hasLength(1));
    expect(reasonings.single['text'], '想了一下剧情');
    expect(
      frame2.indexOf(reasonings.single),
      lessThan(frame2.indexWhere((i) => i['role'] == 'assistant')),
    );
  });

  test('模型未产出思考时仍逐块兜底（工具帧绝不缺块）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      // 帧 1：无 reasoningItems / reasoningContent，但有两个工具调用。
      AiCallResult(
        content: '',
        toolCalls: [
          readCall('r_w', AgentStateSection.worldState),
          readCall('r_c', AgentStateSection.characterState),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      // 帧 2：正文 + 三栏闭环（正文轮退出，缺口已无 → 不再发维护轮）。
      fullStateTurn('f2', story: '正文'),
    ]);
    await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    final frame2 = h.requests[1].items;
    final calls = <int>[
      for (var i = 0; i < frame2.length; i++)
        if (frame2[i]['type'] == 'function_call') i,
    ];
    expect(calls, hasLength(2));
    for (final at in calls) {
      expect(frame2[at - 1]['type'], 'reasoning');
      // 兜底文本非空（本帧无正文 → 占位文本；服务端只校验「非空且紧邻」）。
      expect('${frame2[at - 1]['text']}', isNotEmpty);
    }
  });

  test('精简思考回传（开关开启时）：多段只回传首段 + 末段（`\\n\\n` 空行不计段）', () async {
    final copy = workingCopy();
    // 多段思考（中间过程整段丢弃；空行只是格式占位，不算段）。
    const long = '先读世界状态确定地点。\n\n'
        '再搜索两位角色的资料。\n\n'
        '最后按五区块写正文，时间沿用上轮格式。';
    final h = harness(
      copy: copy,
      reduceReasoningReplay: true,
      script: [
        AiCallResult(
          content: '',
          reasoningContent: long,
          reasoningItems: const [AiReasoningItem(id: 'r1', text: long)],
          toolCalls: [readCall('r_w', AgentStateSection.worldState)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_1',
        ),
        fullStateTurn('f2', story: '正文'),
      ],
    );
    await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    final frame2 = h.requests[1].items;
    final reasoning = frame2.firstWhere((i) => i['type'] == 'reasoning');
    expect(
      reasoning['text'],
      '先读世界状态确定地点。\n\n最后按五区块写正文，时间沿用上轮格式。',
    );
    // 中间段不得出现在回传里。
    expect('${reasoning['text']}', isNot(contains('再搜索两位角色的资料')));
  });

  test('精简关闭（默认）：逐字节回传思考原文', () async {
    final copy = workingCopy();
    const long = '第一段过程。\n\n第二段过程。\n\n第三段结论。';
    final h = harness(
      copy: copy,
      script: [
        AiCallResult(
          content: '',
          reasoningContent: long,
          reasoningItems: const [AiReasoningItem(id: 'r1', text: long)],
          toolCalls: [readCall('r_w', AgentStateSection.worldState)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_1',
        ),
        fullStateTurn('f2', story: '正文'),
      ],
    );
    await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    final reasoning =
        h.requests[1].items.firstWhere((i) => i['type'] == 'reasoning');
    expect(reasoning['text'], long);
  });

  test('无状态重发：每帧全量 input，状态不预置（模型自取）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [storyOnly(), fullStateTurn('s')]);
    await run(h.runner);

    expect(h.requests[0].previousResponseId, isNull);
    expect(h.requests[1].previousResponseId, isNull);
    final first = h.requests[0].items;
    // 历史 1 条；状态**不再预置**（模型应自行调用读取器获取）。
    expect(first, hasLength(1));
    expect(first.single['role'], 'user');
    // 第 2 帧：正文轮 assistant 消息已回传（旧缺陷：续接帧「失忆」）。
    expect(
      h.requests[1].items.any((i) =>
          i['role'] == 'assistant' && '${i['content']}'.contains('正文')),
      isTrue,
    );
    // 维护轮指令是最后一条 user 消息，且列出六个工具名。
    final last = h.requests[1].items.last;
    expect(last['role'], 'user');
    expect('${last['content']}', contains('[State-maintenance turn]'));
    expect('${last['content']}', contains('读取器已禁用'));
    expect('${last['content']}', contains(kEditHistoryToolName));
    // 指令形态：简明中文（必要英文只保留回合标记与工具名），不加语言标记。
    expect('${last['content']}', startsWith('[State-maintenance turn]'));
    expect('${last['content']}', contains('正文已在上方完成'));
    for (final marker in const ['[EN]', '【中】']) {
      expect('${last['content']}', isNot(contains(marker)), reason: marker);
    }
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
    // 只发第 1 帧之后新增的条目（assistant 正文 + 维护轮指令）。
    expect(h.requests[1].items, hasLength(2));
  });

  test('服务商拒绝 tool_choice → 就地降级重发同一帧（不额外计帧）', () async {
    final copy = workingCopy();
    var attempt = 0;
    final requests = <_Request>[];
    final profile = AgentModeProfile.of(AgentModeLevel.lv2);
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
      tools: buildStateTools(copy, sections: profile.toolSections),
      workingCopy: copy,
      profile: profile,
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

  test('维护轮空手帧不再提前止损：保留修复机会（帧数上限兜底）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxStateFrames: 2, script: [
      storyOnly(), // 正文轮（未动状态 → 3 个栏目缺口）
      storyOnly(story: '正文'), // 维护帧 0：只回文本（空手，不应结束整轮）
      fullStateTurn('s'), // 维护帧 1：补齐全部栏目
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

  test('维护轮用尽仍有缺项 → 警告钳制（正文照常返回）', () async {
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
    expect(result.frames, 3); // 正文轮 1 + 维护轮 2
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
          editCall('call_1', AgentStateSection.worldState, [
            {
              'op': 'set',
              'before': '- 地点：完全不存在的行',
              'newLine': '- 地点：主峰',
            },
          ]),
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
    // 维护轮把失败项一并列出（点名对应栏目编辑器）。
    expect(
      '${h.requests[1].items.last['content']}',
      contains(kEditWorldStateToolName),
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
            name: kEditWorldStateToolName,
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
    // 截断帧什么都没改（世界状态仍是基座），补齐由维护轮那一帧完成。
    final truncatedOutput =
        '${h.requests[1].items.firstWhere((i) =>
            i['type'] == 'function_call_output' &&
            i['call_id'] == 'call_1')['output']}';
    expect(truncatedOutput, contains('TRUNCATED'));
    // 拒绝回传与维护轮反馈都是「英文要求 + 中文概述」，无语言标记。
    expect(truncatedOutput, contains('工具参数被截断'));
    final feedback = '${h.requests[1].items.last['content']}';
    expect(feedback, contains('TRUNCATED'));
    expect(feedback, contains('工具参数被截断'));
    for (final text in [truncatedOutput, feedback]) {
      for (final marker in const ['[EN]', '【中】']) {
        expect(text, isNot(contains(marker)), reason: marker);
      }
    }
    // 截断项进了维护轮反馈，修复帧完成后无警告。
    expect(result.warnings, isEmpty);
  });

  test('懒修改：本轮出场角色块未变 → 维护轮点名', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      // 正文提到林远，但角色状态只声明无变化（且带了 reason，栏目级合法）。
      AiCallResult(
        content: '## 剧情演绎\n林远握紧了剑。\n\n## 推荐行动\n行动',
        toolCalls: [
          editCall('call_1', AgentStateSection.worldState, [
            {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
          ]),
          editCall('call_2', AgentStateSection.characterState, [
            {'op': 'noChange', 'reason': '林远状态未变'},
          ]),
          editCall('call_3', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': '- 第2轮｜日期：第二天 午时｜林远握剑'},
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      ),
      AiCallResult(
        content: '',
        toolCalls: [
          editCall('call_5', AgentStateSection.characterState, [
            {'op': 'set', 'before': '- 气血：80', 'newLine': '- 气血：75'},
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_2',
      ),
    ]);

    final result = await run(h.runner);

    // 第 1 帧后仍缺角色状态 → 维护轮指令点名「林远」，并引导改为实际行级编辑。
    expect(h.requests, hasLength(2));
    expect(h.requests[1].stage, AgentStage.state);
    expect('${h.requests[1].items.last['content']}', contains('林远'));
    expect('${h.requests[1].items.last['content']}', contains('op=set'));
    expect('${h.requests[1].items.last['content']}', contains('懒修改'));
    expect(
      '${h.requests[1].items.last['content']}',
      contains(kEditCharacterStateToolName),
    );
    expect(result.warnings, isEmpty);
    expect(copy.characterState, contains('- 气血：75'));
  });

  /// 被输出上限截断的维护帧：一处编辑成功，另一处参数没写完（JSON 不闭合）。
  AiCallResult truncatedStateTurn(String prefix) => AiCallResult(
        content: '',
        toolCalls: [
          editCall('${prefix}_w', AgentStateSection.worldState, [
            {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
          ]),
          const AiToolCall(
            id: 'x',
            name: kEditCharacterStateToolName,
            arguments: {},
            argumentsUnparsable: true,
          ),
        ],
        promptTokens: 1,
        completionTokens: 4096,
        incomplete: true,
        incompleteReason: kIncompleteMaxOutputTokens,
      );

  test('维护帧被截断：不判失败，下一帧带「拆短调用」指令重发', () async {
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
    final capDirective = '${h.requests[2].items.last['content']}';
    expect(capDirective, contains('TRUNCATED'));
    // 「拆短调用」提示：中文概述紧跟英文要求之后，无 [EN] / 【中】 语言标记。
    expect(capDirective, contains('上一帧在输出上限处被截断'));
    expect(capDirective, isNot(contains('[EN]')));
    expect(capDirective, isNot(contains('【中】')));
    expect('${h.requests[2].items.last['content']}', contains('拆短'));
    // 末帧未截断 → 不再对用户提示截断。
    expect(result.incomplete, isFalse);
    expect(result.incompleteReason, isEmpty);
  });

  test('维护帧末帧仍截断 → 给用户一条可操作的「调高最大 token」提示', () async {
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

    // 维护帧 1 走续接（只发新增项）。
    expect(h.requests[1].previousResponseId, 'resp_1');
    // 维护帧 1 被截断 → 帧 2 不能作为基点：全量重发且不带 previous_response_id。
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

    // 维护帧第 1 次尝试覆盖为 low → 被拒 → 同帧重发时不再覆盖（沿用户设置）。
    expect(h.requests, hasLength(3));
    expect(h.requests[1].stateThinkingEffort, kAgentStateThinkingEffort);
    expect(h.requests[2].stateThinkingEffort, isNull);
    expect(h.requests[2].toolChoice, 'required');
    expect(h.runner.supportsThinkingEffort, isFalse);
    // 失败的那次尝试不计帧。
    expect(result.frames, 2);
    expect(copy.worldState, contains('- 地点：主峰'));
  });

  // ---------------------------------------------------------------------------
  // Lv.1（仅历史工具 + 5 区块正文）
  //
  // 四步流程：准备（读史 + 大纲，`auto`）→ 记忆（`required`，条目**先于正文**
  // 落地）→ 正文（`auto`，唯一采纳 / 上屏阶段）→ 缺口驱动的维护轮（兜底）。
  // ---------------------------------------------------------------------------

  /// Lv.1 准备帧：只有大纲文本、**无工具调用** → 准备阶段立即结束
  /// （准备阶段文本不上屏、不采纳）。
  AiCallResult lv1PrepareTurn({
    String outline = '本轮大纲：主角前往主峰，结束时间 = 第二天 申时。',
    List<AiToolCall> toolCalls = const [],
  }) =>
      AiCallResult(
        content: outline,
        toolCalls: toolCalls,
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_prep',
      );

  /// Lv.1 准备帧：先读一次历史（读取器不是编辑器 → 准备阶段继续到下一帧）。
  AiCallResult lv1PrepareReadTurn(String id) => AiCallResult(
        content: '',
        toolCalls: [readCall(id, AgentStateSection.memorySummary)],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_read',
      );

  /// Lv.1 空手帧：只有文本、无工具调用（记忆帧模拟「模型没调编辑器」）。
  AiCallResult lv1EmptyTurn(String text) => AiCallResult(
        content: text,
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_empty',
      );

  /// Lv.1 正文帧：5 区块（世界 / 角色随正文携带，记忆区块应由应用剥离）。
  AiCallResult lv1StoryTurn({
    String extra = '',
    List<AiToolCall> toolCalls = const [],
  }) =>
      AiCallResult(
        content: '## 剧情演绎\n正文\n\n## 推荐行动\n行动\n\n## 当前时间\n第二天 申时\n\n'
            '## 世界状态\n- 地点：主峰\n- 天气：晴\n\n'
            '## 角色状态\n# 主角\n## 林远\n- 气血：70$extra',
        toolCalls: toolCalls,
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_1',
      );

  /// 历史编辑帧（追加恰好一条本轮条目）：既是**记忆阶段**的正解，
  /// 也是**维护轮兜底**的正解——两处都是同一个工具调用形态。
  AiCallResult lv1HistoryTurn(String id, {String entry = ''}) => AiCallResult(
        content: '',
        toolCalls: [
          editCall(id, AgentStateSection.memorySummary, [
            {
              'op': 'append',
              'newLine': entry.isEmpty
                  ? '- 第2轮｜日期：第二天 申时｜主角前往主峰'
                  : entry,
            },
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_2',
      );

  test('Lv.1：准备(读史) → 记忆(条目先落地) → 正文(5 区块，剥离记忆)', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      // 把脚本钉在「准备恰好一帧」上：准备阶段本来会在模型继续调工具时循环，
      // 这里用 maxPrepFrames = 1 让第一帧（读史）后即进入记忆阶段。
      maxPrepFrames: 1,
      script: [
        lv1PrepareReadTurn('p1'),
        lv1HistoryTurn('h1'),
        // 模型违规多写了记忆区块：采纳时必须剥离（历史只走工具）。
        lv1StoryTurn(extra: '\n\n## 记忆总结\n- 第2轮｜日期：第二天 申时｜正文里偷写的'),
      ],
    );

    final result = await run(h.runner);

    // 三帧固定顺序：准备(auto) → 记忆(required + 思考降为 low) → 正文(auto)。
    expect(
      h.requests.map((r) => r.stage).toList(),
      [AgentStage.prepare, AgentStage.memory, AgentStage.story],
    );
    expect(
      h.requests.map((r) => r.toolChoice).toList(),
      ['auto', 'required', 'auto'],
    );
    expect(h.requests[1].stateThinkingEffort, kAgentStateThinkingEffort);
    expect(h.requests[0].stateThinkingEffort, isNull);
    expect(h.requests[2].stateThinkingEffort, isNull);
    // 准备帧指令：本阶段先读历史一次（这里由脚本自己扮演模型）。
    expect(
      '${h.requests[0].items.last['content']}',
      contains('【准备回合】'),
    );
    expect(
      '${h.requests[0].items.last['content']}',
      contains(kReadHistoryToolName),
    );

    // 记忆条目在正文**之前**落地，合规一轮不发起维护轮。
    expect(result.stateTurnUsed, isFalse);
    expect(result.frames, 3);
    expect(result.warnings, isEmpty);
    expect(copy.memorySummary, contains('第2轮'));
    expect(copy.memorySummary, contains('主角前往主峰'));

    // 正文帧请求里：读史 → 记忆编辑（含回传的栏目全文）→ 正文阶段指令，
    // 顺序即「先读、再写条目、最后写正文」。
    final storyItems = h.requests[2].items;
    final readAt = storyItems.indexWhere(
      (i) => i['type'] == 'function_call' && i['call_id'] == 'p1',
    );
    final editAt = storyItems.indexWhere(
      (i) => i['type'] == 'function_call' && i['call_id'] == 'h1',
    );
    final editOutAt = storyItems.indexWhere(
      (i) => i['type'] == 'function_call_output' && i['call_id'] == 'h1',
    );
    final storyNoteAt = storyItems.indexWhere(
      (i) => '${i['content']}'.startsWith('【正文回合】'),
    );
    expect(readAt, greaterThanOrEqualTo(0));
    expect(editAt, greaterThan(readAt));
    expect(editOutAt, greaterThan(editAt));
    expect(storyNoteAt, greaterThan(editOutAt));
    // 记忆条目已随工具结果进入正文帧上下文（不是「写完正文再补」）。
    expect('${storyItems[editOutAt]['output']}', contains('第2轮'));
    // 正文帧请求被组装时正文**还不存在**：没有任何 `## 剧情演绎` assistant 消息
    // （唯一采纳阶段是正文阶段，正文条目在它之后才进会话）。
    expect(
      storyItems.any(
        (i) =>
            i['role'] == 'assistant' &&
            '${i['content']}'.contains('## 剧情演绎'),
      ),
      isFalse,
    );

    // 正文保留世界 / 角色（Lv.1 由正文携带），记忆区块被剥离。
    expect(result.content, contains('## 剧情演绎'));
    expect(result.content, contains('## 世界状态'));
    expect(result.content, contains('- 地点：主峰'));
    expect(result.content, contains('## 角色状态'));
    expect(result.content, isNot(contains('## 记忆总结')));
    expect(result.content, isNot(contains('正文里偷写的')));

    // 世界 / 角色不被工具改动（落库由 provider 从正文解析）；时间取自正文。
    expect(copy.worldState, '- 地点：青云宗\n- 天气：晴');
    expect(copy.currentTime, '第二天 申时');
  });

  test('Lv.1：会话累积顺序——记忆条目先于正文 assistant 回传（续写帧可见）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      maxPrepFrames: 1,
      script: [
        lv1PrepareReadTurn('p1'),
        lv1HistoryTurn('h1'),
        // 正文帧 1：半截正文 + 读取器（非编辑器 → 正文阶段继续下一帧）。
        AiCallResult(
          content: '## 剧情演绎\n写了一半',
          toolCalls: [readCall('s1', AgentStateSection.memorySummary)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_s1',
        ),
        lv1StoryTurn(),
      ],
    );

    final result = await run(h.runner);

    expect(h.requests, hasLength(4));
    final items = h.requests[3].items;
    final editOutAt = items.indexWhere(
      (i) => i['type'] == 'function_call_output' && i['call_id'] == 'h1',
    );
    final storyAssistantAt = items.indexWhere(
      (i) =>
          i['role'] == 'assistant' &&
          '${i['content']}'.contains('## 剧情演绎'),
    );
    expect(editOutAt, greaterThanOrEqualTo(0));
    expect(storyAssistantAt, greaterThan(editOutAt),
        reason: '记忆条目必须排在正文 assistant 消息之前（正文受其约束）');
    // 最后一个标题帧胜出：半截正文不进入本轮结果。
    expect(result.content, contains('## 世界状态'));
    expect(result.content, isNot(contains('写了一半')));
    expect(result.stateTurnUsed, isFalse);
  });

  test('Lv.1：记忆阶段调用历史编辑器**被执行成功**（旧「正文轮拒绝」护栏已删除）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      maxPrepFrames: 1,
      script: [
        lv1PrepareReadTurn('p1'),
        lv1HistoryTurn('h1'),
        lv1StoryTurn(),
      ],
    );

    final result = await run(h.runner);

    // 记忆帧的历史编辑直接落地（不再有「正文轮才写历史 → 被拒 → 维护轮补」）。
    final edit = result.outcomes.firstWhere((o) => o.callId == 'h1');
    expect(edit.name, kEditHistoryToolName);
    expect(edit.applied, isTrue);
    expect(edit.isStateTool, isTrue);
    expect(edit.message, contains('已更新'));
    expect(copy.memorySummary, contains('第2轮'));
    expect(copy.failedSections, isEmpty);
    expect(result.stateTurnUsed, isFalse);
    expect(result.warnings, isEmpty);
  });

  test('Lv.1：记忆阶段模型抢写正文被丢弃，正文只来自正文阶段', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      maxPrepFrames: 1,
      script: [
        lv1PrepareReadTurn('p1'),
        // 记忆帧违规抢写正文（`## 剧情演绎`）+ 正常追加本轮条目。
        AiCallResult(
          content: '## 剧情演绎\n抢写的正文',
          toolCalls: [
            editCall('h1', AgentStateSection.memorySummary, [
              {
                'op': 'append',
                'newLine': '- 第2轮｜日期：第二天 申时｜主角前往主峰',
              },
            ]),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_mem',
        ),
        lv1StoryTurn(),
      ],
    );
    final sunk = <AiStreamChunk>[];
    final result = await h.runner.run(
      initialInputItems: const [
        {'role': 'user', 'content': 'hi'},
      ],
      stream: true,
      onChunk: sunk.add,
    );

    // 采纳的正文只来自正文阶段（记忆帧的抢写文本不是候选）。
    expect(result.content, contains('## 剧情演绎\n正文'));
    expect(result.content, contains('## 世界状态'));
    expect(result.content, isNot(contains('抢写的正文')));
    // 上屏同样不含抢写文本（记忆阶段文本通道关闭）。
    final published = sunk
        .where((c) => c.contentDelta.isNotEmpty)
        .map((c) => c.contentDelta)
        .join();
    expect(published, contains('## 剧情演绎'));
    expect(published, isNot(contains('抢写的正文')));
    // 抢写文本确实以 assistant 消息留在会话里（模型看得见自己的输出），
    // 但**不参与采纳**——结构上无法成为本轮正文。
    expect(
      h.requests[2].items.any(
        (i) => i['role'] == 'assistant' && '${i['content']}'.contains('抢写的正文'),
      ),
      isTrue,
    );
    // 记忆条目照常落地，合规一轮无维护轮、无警告。
    expect(copy.memorySummary, contains('第2轮'));
    expect(result.frames, 3);
    expect(result.stateTurnUsed, isFalse);
    expect(result.warnings, isEmpty);
  });

  test('Lv.1：记忆阶段空手帧 → 重发指令，用尽后由维护轮兜底', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      maxPrepFrames: 1,
      script: [
        lv1PrepareReadTurn('p1'),
        lv1EmptyTurn('（记忆帧 1：只回文本）'),
        lv1EmptyTurn('（记忆帧 2：只回文本）'),
        lv1EmptyTurn('（记忆帧 3：只回文本）'),
        lv1StoryTurn(),
        lv1HistoryTurn('m1'),
      ],
    );

    final result = await run(h.runner);

    // 准备 1 帧 + 记忆 3 帧（用尽）+ 正文 1 帧 + 维护轮 1 帧。
    expect(
      h.requests.map((r) => r.stage).toList(),
      [
        AgentStage.prepare,
        AgentStage.memory,
        AgentStage.memory,
        AgentStage.memory,
        AgentStage.story,
        AgentStage.state,
      ],
    );
    expect(
      h.requests.map((r) => r.toolChoice).toList(),
      ['auto', 'required', 'required', 'required', 'auto', 'required'],
    );
    expect(result.frames, 6);
    expect(result.stateTurnUsed, isTrue);
    // 每帧都重发记忆指令：首帧与「仍缺」帧的文案不同（不重复回传失败说明）。
    expect(
      '${h.requests[1].items.last['content']}',
      contains('【记忆回合】'),
    );
    for (final at in const [2, 3]) {
      expect(
        '${h.requests[at].items.last['content']}',
        contains('【记忆回合·仍缺本轮条目】'),
      );
      expect(
        '${h.requests[at].items.last['content']}',
        contains(kEditHistoryToolName),
      );
    }
    // 维护轮兜底指令只谈历史（世界 / 角色由正文携带，不再是维护对象）。
    final directive = '${h.requests[5].items.last['content']}';
    expect(directive, contains('[State-maintenance turn]'));
    expect(directive, contains(kEditHistoryToolName));
    expect(directive, contains('历史栏不接受'));
    expect(directive, isNot(contains(kEditCharacterStateToolName)));
    expect(directive, isNot(contains(kEditWorldStateToolName)));
    // 条目由维护轮补上 → 无残留警告。
    expect(copy.memorySummary, contains('第2轮'));
    expect(result.warnings, isEmpty);
  });

  test('Lv.1：记忆帧重复读取历史被拒绝（编辑照常落地）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      maxPrepFrames: 1,
      script: [
        lv1PrepareReadTurn('p1'),
        // 记忆帧：多此一举地再读一遍历史（本轮已提供全文 → 被拒）+ 正常编辑。
        AiCallResult(
          content: '',
          toolCalls: [
            readCall('m_read', AgentStateSection.memorySummary),
            editCall('m_edit', AgentStateSection.memorySummary, [
              {
                'op': 'append',
                'newLine': '- 第2轮｜日期：第二天 申时｜主角前往主峰',
              },
            ]),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_mem',
        ),
        lv1StoryTurn(),
      ],
    );

    final result = await run(h.runner);

    // 读取被拒：不执行、不算状态缺项（流程违规 ≠ 待修栏目）。
    final refusedRead =
        result.outcomes.firstWhere((o) => o.callId == 'm_read');
    expect(refusedRead.applied, isFalse);
    expect(refusedRead.message, contains('本阶段不再重复读取'));
    expect(refusedRead.isStateTool, isFalse);
    // 回传说明：英文要求在前、中文概述在后，点名历史编辑器，无语言标记。
    final refusedOutput = h.requests[2].items.firstWhere(
      (i) => i['type'] == 'function_call_output' && i['call_id'] == 'm_read',
    );
    final refusedText = '${refusedOutput['output']}';
    expect(refusedText, contains(kEditHistoryToolName));
    expect(refusedText, contains('已在对话中'));
    expect(refusedText, isNot(contains('[EN]')));
    expect(refusedText, isNot(contains('【中】')));

    // 编辑照常落地：合规一轮（3 帧）无维护轮、无警告。
    expect(
      result.outcomes.firstWhere((o) => o.callId == 'm_edit').applied,
      isTrue,
    );
    expect(copy.memorySummary, contains('第2轮'));
    expect(result.frames, 3);
    expect(result.stateTurnUsed, isFalse);
    expect(result.warnings, isEmpty);
  });

  test('Lv.1：准备帧就写完记忆条目 → 记忆阶段零帧直接跳过（不逼重复追加）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      script: [
        // 准备帧：工具**全是编辑器** → 准备阶段立即闭环（该帧文本不上屏）。
        lv1HistoryTurn('p1', entry: '- 第2轮｜日期：第二天 申时｜准备帧写入'),
        lv1StoryTurn(),
      ],
    );

    final result = await run(h.runner);

    // 进入记忆阶段时本轮条目已在准备帧落地 → [_memorySatisfied] 成立 →
    // **不再发** `required` 帧（否则会逼模型重复 `op=append`，第二条条目让
    // applyEdits 整栏失败并多烧两帧修复）。
    expect(
      h.requests.map((r) => r.stage).toList(),
      [AgentStage.prepare, AgentStage.story],
    );
    expect(
      h.requests.map((r) => r.toolChoice).toList(),
      ['auto', 'auto'],
    );
    expect(result.frames, 2);
    // 准备帧落地的那一条没有被重复追加（历史栏恰好一条本轮条目）。
    expect(memoryEntryCount(copy.memorySummary, 2), 1);
    expect(copy.memorySummary, contains('准备帧写入'));
    expect(result.stateTurnUsed, isFalse);
    expect(result.warnings, isEmpty);
  });

  test('Lv.1：准备帧按新格式写完记忆条目 → 记忆阶段同样零帧跳过', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      script: [
        // 新格式（`- {轮次} | {时间} | {记忆内容}`）与旧格式同等成立：
        // `_memorySatisfied` 走共享解析，两种写法都只算一条。
        lv1HistoryTurn('p1', entry: '- 2 | 第二天 申时 | 准备帧写入'),
        lv1StoryTurn(),
      ],
    );

    final result = await run(h.runner);

    expect(
      h.requests.map((r) => r.stage).toList(),
      [AgentStage.prepare, AgentStage.story],
    );
    expect(result.frames, 2);
    expect(copy.memorySummary, '- 2 | 第二天 申时 | 准备帧写入');
    expect(memoryEntryCount(copy.memorySummary, 2), 1);
    expect(result.stateTurnUsed, isFalse);
    expect(result.warnings, isEmpty);
  });

  test('Lv.1：历史工具集只注册历史一读一写', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      script: [lv1PrepareTurn(), lv1HistoryTurn('h1'), lv1StoryTurn()],
    );
    // 工具集（Lv.1）= 历史读取 + 历史编辑。
    expect(h.runner.tools.map((t) => t.name), [
      kReadHistoryToolName,
      kEditHistoryToolName,
    ]);
    await run(h.runner);
    expect(copy.memorySummary, contains('第2轮'));
  });

  test('用户中断在执行工具前抛出 AiCancelledException', () async {
    final copy = workingCopy();
    var calls = 0;
    final profile = AgentModeProfile.of(AgentModeLevel.lv2);
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
      tools: buildStateTools(copy, sections: profile.toolSections),
      workingCopy: copy,
      profile: profile,
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

  // ---------------------------------------------------------------------------
  // 记忆总结「轮次合并」（档位驱动）
  // ---------------------------------------------------------------------------

  /// 上一轮（第 9 轮）的记忆总结：散条目 1..9 → 档位 5 时第 10 轮达到 2T。
  const mergeMemoryText = '- 1 | t1 | 第1轮。\n'
      '- 2 | t2 | 第2轮。\n'
      '- 3 | t3 | 第3轮。\n'
      '- 4 | t4 | 第4轮。\n'
      '- 5 | t5 | 第5轮。\n'
      '- 6 | t6 | 第6轮。\n'
      '- 7 | t7 | 第7轮。\n'
      '- 8 | t8 | 第8轮。\n'
      '- 9 | t9 | 第9轮。';
  const mergeLastRound = Round(
    id: 1,
    bookUuid: 'b1',
    roundIndex: 9,
    worldState: '- 地点：青云宗\n- 天气：晴',
    characterState: '# 主角\n## 林远\n- 气血：80',
    memorySummary: mergeMemoryText,
    currentTime: 't9',
  );

  /// 待合并区间 1-5 的原文（`op=set` 的多行 `before`）。
  const mergeSourceLines = '- 1 | t1 | 第1轮。\n'
      '- 2 | t2 | 第2轮。\n'
      '- 3 | t3 | 第3轮。\n'
      '- 4 | t4 | 第4轮。\n'
      '- 5 | t5 | 第5轮。';

  AgentStateWorkingCopy mergeCopy() => AgentStateWorkingCopy(
        roundIndex: 10,
        lastRound: mergeLastRound,
        categoryNames: const ['主角'],
      );

  MemoryMergePlan mergePlan() => planMemoryMerge(
        memoryText: mergeMemoryText,
        tier: 5,
        newRoundIndex: 10,
      );

  /// 记忆帧：一次调用同时完成「合并 1-5」与「追加第 10 轮条目」。
  AiCallResult mergeHistoryTurn(String id) => AiCallResult(
        content: '',
        toolCalls: [
          editCall(id, AgentStateSection.memorySummary, [
            {
              'op': 'set',
              'before': mergeSourceLines,
              'newLine': '- 1 - 5 | t1 ~ t5 | 前五轮要点。',
            },
            {'op': 'append', 'newLine': '- 10 | t10 | 第十轮。'},
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_merge',
      );

  /// 只追加本轮条目、**不合并**的记忆帧。
  AiCallResult appendOnlyTurn(String id) => AiCallResult(
        content: '',
        toolCalls: [
          editCall(id, AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': '- 10 | t10 | 第十轮。'},
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_append',
      );

  String itemsText(List<Map<String, dynamic>> items) =>
      items.map((i) => '${i['content']}').join('\n');

  test('Lv.1：记忆阶段一帧内合并 1-5 + 追加本轮条目 → 满足门槛、零警告', () async {
    final copy = mergeCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      memoryMergePlan: mergePlan(),
      script: [lv1PrepareTurn(), mergeHistoryTurn('m1'), lv1StoryTurn()],
    );

    final result = await run(h.runner);

    expect(
      h.requests.map((r) => r.stage).toList(),
      [AgentStage.prepare, AgentStage.memory, AgentStage.story],
      reason: '合并落地即满足记忆阶段门槛，不重复发帧',
    );
    final memoryItems = itemsText(h.requests[1].items);
    expect(memoryItems, contains('【本轮记忆合并】'));
    expect(memoryItems, contains('- 1 - 5 | t1 ~ t5 | {记忆内容}'));
    expect(memoryItems, contains('op=set'));

    expect(copy.memorySummary, contains('- 1 - 5 | t1 ~ t5 | 前五轮要点。'));
    expect(copy.memorySummary, isNot(contains('- 1 | t1 |')), reason: '被合并的下限行已替换');
    expect(memoryEntryCount(copy.memorySummary, 10), 1);
    expect(memoryEntryCount(copy.memorySummary, 3), 1);
    expect(result.warnings, isEmpty);
  });

  test('Lv.1：只追加不合并 → 记忆阶段重试（提示合并未完成），帧数用尽后常驻警告', () async {
    final copy = mergeCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      memoryMergePlan: mergePlan(),
      maxStateFrames: 1,
      script: [
        lv1PrepareTurn(),
        appendOnlyTurn('h1'),
        lv1EmptyTurn('（模型没动）'),
        lv1EmptyTurn('（模型仍没合并）'),
        lv1StoryTurn(),
        // 记忆阶段用尽后维护轮兜底一次（同样带合并指令），仍不合并 → 常驻警告。
        lv1EmptyTurn('（维护轮仍没合并）'),
      ],
    );

    final result = await run(h.runner);

    final memoryStages =
        h.requests.where((r) => r.stage == AgentStage.memory).toList();
    expect(memoryStages, hasLength(kAgentMaxMemoryFrames),
        reason: '合并未落地 → 记忆帧循环到上限');
    expect(itemsText(memoryStages[1].items), contains('合并还没完成'),
        reason: '重试帧lead 要点明「条目已在、合并未完成」');
    final stateStages =
        h.requests.where((r) => r.stage == AgentStage.state).toList();
    expect(stateStages, hasLength(1),
        reason: '记忆阶段失败 → 维护轮兜底，且同样带合并指令');
    expect(itemsText(stateStages.single.items), contains('【本轮记忆合并】'));
    expect(result.warnings, contains('记忆总结未按档位（5）合并：应合并 1-5'));
    expect(copy.memorySummary, contains('- 10 | t10 | 第十轮。'));
    expect(copy.memorySummary, isNot(contains('- 1 - 5 |')), reason: '确实没合并');
  });

  test('Lv.2：维护轮问题清单带上合并指令，合并落地后零警告', () async {
    final copy = mergeCopy();
    final h = harness(
      copy: copy,
      memoryMergePlan: mergePlan(),
      script: [
        storyOnly(),
        AiCallResult(
          content: '',
          toolCalls: [
            editCall('s1_w', AgentStateSection.worldState, [
              {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
            ]),
            editCall('s1_c', AgentStateSection.characterState, [
              {'op': 'set', 'before': '- 气血：80', 'newLine': '- 气血：70'},
            ]),
            editCall('s1_m', AgentStateSection.memorySummary, [
              {
                'op': 'set',
                'before': mergeSourceLines,
                'newLine': '- 1 - 5 | t1 ~ t5 | 前五轮要点。',
              },
              {'op': 'append', 'newLine': '- 10 | t10 | 第十轮。'},
            ]),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_s1',
        ),
      ],
    );

    final result = await run(h.runner);

    expect(h.requests.map((r) => r.stage).toList(),
        [AgentStage.story, AgentStage.state]);
    expect(itemsText(h.requests[1].items), contains('【本轮记忆合并】'));
    expect(itemsText(h.requests[1].items), contains('- 1 - 5 | t1 ~ t5 | {记忆内容}'));
    expect(copy.memorySummary, contains('- 1 - 5 | t1 ~ t5 | 前五轮要点。'));
    expect(result.warnings, isEmpty);
  });

  test('Lv.2：维护轮没合并 → 继续修复帧；用尽后常驻警告', () async {
    final copy = mergeCopy();
    final h = harness(
      copy: copy,
      memoryMergePlan: mergePlan(),
      maxStateFrames: 2,
      script: [
        storyOnly(),
        AiCallResult(
          content: '',
          toolCalls: [
            editCall('s1_w', AgentStateSection.worldState, [
              {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
            ]),
            editCall('s1_c', AgentStateSection.characterState, [
              {'op': 'set', 'before': '- 气血：80', 'newLine': '- 气血：70'},
            ]),
            editCall('s1_m', AgentStateSection.memorySummary, [
              {'op': 'append', 'newLine': '- 10 | t10 | 第十轮。'},
            ]),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_s1',
        ),
        AiCallResult(
          content: '',
          toolCalls: const [],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_s2',
        ),
      ],
    );

    final result = await run(h.runner);

    final stateStages =
        h.requests.where((r) => r.stage == AgentStage.state).toList();
    expect(stateStages, hasLength(2),
        reason: '合并未落地 → 维护轮继续修复（不再因「无缺口」提前返回）');
    expect(result.warnings, contains('记忆总结未按档位（5）合并：应合并 1-5'));
    expect(copy.memorySummary, isNot(contains('- 1 - 5 |')));
  });

  test('Lv.1：准备阶段漏读历史时，记忆阶段仍允许补读一次（合并没有锚点就落不了地）', () async {
    final copy = mergeCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      memoryMergePlan: mergePlan(),
      script: [
        // 非合规流程：准备帧只有大纲、没读历史（无 `<memorySummary>` 锚点来源）。
        lv1PrepareTurn(),
        // 记忆帧 1：该栏目本轮尚未提供过 → 放行（否则合并无从锚定）。
        AiCallResult(
          content: '',
          toolCalls: [readCall('m_read', AgentStateSection.memorySummary, round: 10)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_read',
        ),
        // 记忆帧 2：用读到的锚点合并 + 追加本轮条目。
        mergeHistoryTurn('m1'),
        lv1StoryTurn(),
      ],
    );

    final result = await run(h.runner);

    final read = result.outcomes.firstWhere((o) => o.callId == 'm_read');
    expect(read.applied, isTrue,
        reason: '漏读的栏目必须允许补读一次，否则 op=set 没有逐字锚点');
    expect(
      h.requests.map((r) => r.stage).toList(),
      [
        AgentStage.prepare,
        AgentStage.memory,
        AgentStage.memory,
        AgentStage.story,
      ],
    );
    expect(copy.memorySummary, contains('- 1 - 5 | t1 ~ t5 | 前五轮要点。'));
    expect(memoryEntryCount(copy.memorySummary, 10), 1);
    expect(result.warnings, isEmpty);
  });

  test('Lv.1：准备阶段已读过历史 → 记忆帧的重复读取仍被拒（护栏不变）', () async {
    final copy = mergeCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      memoryMergePlan: mergePlan(),
      script: [
        lv1PrepareReadTurn('p_read'),
        // 重复读取被拒（不消耗编辑机会），紧接着的合并帧照常落地。
        AiCallResult(
          content: '',
          toolCalls: [readCall('m_read', AgentStateSection.memorySummary, round: 10)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_read2',
        ),
        mergeHistoryTurn('m1'),
        lv1StoryTurn(),
      ],
    );

    final result = await run(h.runner);

    final repeated = result.outcomes.firstWhere((o) => o.callId == 'm_read');
    expect(repeated.applied, isFalse, reason: '已提供过全文的栏目重复读取仍被拒');
    expect(copy.memorySummary, contains('- 1 - 5 | t1 ~ t5 | 前五轮要点。'));
    expect(result.warnings, isEmpty);
  });

  test('无待合并动作（档位 0 / 未到 2T）→ 不注入指令、不产生警告', () async {
    final copy = mergeCopy();
    final h = harness(
      copy: copy,
      level: AgentModeLevel.lv1,
      memoryMergePlan: planMemoryMerge(
        memoryText: mergeMemoryText,
        tier: 0,
        newRoundIndex: 10,
      ),
      script: [lv1PrepareTurn(), lv1HistoryTurn('h1', entry: '- 10 | t10 | 第十轮。'), lv1StoryTurn()],
    );

    final result = await run(h.runner);

    expect(itemsText(h.requests[1].items), isNot(contains('【本轮记忆合并】')));
    expect(result.warnings, isEmpty);
  });
}

/// 一次帧调用的记录（阶段 / input 快照 / tool_choice / 维护轮思考覆盖）。
typedef _Request = ({
  AgentStage stage,
  List<Map<String, dynamic>> items,
  String? previousResponseId,
  String? toolChoice,
  String? stateThinkingEffort,
});
