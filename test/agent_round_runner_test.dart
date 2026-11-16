import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/agent_activity.dart';
import 'package:narrchat/services/agent/agent_mode_profile.dart';
import 'package:narrchat/services/agent/agent_round_runner.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/memory_merge_planner.dart';

/// `AgentRoundRunner` 单元测试：当前唯一 Agent 档位（Lv.1）的两步执行器——
/// 第一步「调研 → 正文」、第二步「状态维护」；所有步结束后才由调用方入库，
/// 执行器本身只返回结果与总 token。
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

  AiToolCall editCall(
    String id,
    AgentStateSection section,
    List<Map<String, dynamic>> edits,
  ) => AiToolCall(
        id: id,
        name: agentEditToolName(section),
        arguments: {'edits': edits},
      );

  AiToolCall readCall(String id, AgentStateSection section, {int round = 2}) =>
      AiToolCall(
        id: id,
        name: agentReadToolName(section),
        arguments: {'round': round},
      );

  const String story5 =
      '## 剧情演绎\n殿前风冷。\n\n## 推荐行动\n递上名帖\n\n'
      '## 当前时间\n第二天 申时\n\n## 世界状态\n- 地点：主峰\n- 天气：晴\n\n'
      '## 角色状态\n# 主角\n## 林远\n- 气血：70';

  AiCallResult prepareRead(String id) => const AiCallResult(
        content: '',
        promptTokens: 0,
        completionTokens: 0,
        responseId: 'resp_read',
  ).copyWithToolCalls([readCall(id, AgentStateSection.memorySummary)]);

  AiCallResult historyAppend(
    String id, {
    String entry = '- 2 | 第二天 申时 | 主角前往主峰',
  }) => AiCallResult(
        content: '',
        toolCalls: [
          editCall(id, AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': entry},
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_edit',
      );

  AiCallResult storyTurn({
    String extra = '',
    List<AiToolCall> toolCalls = const [],
  }) => AiCallResult(
        content: '$story5$extra',
        toolCalls: toolCalls,
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_story',
      );

  AiCallResult emptyTurn(String text, {int prompt = 1, int completion = 1}) =>
      AiCallResult(
        content: text,
        promptTokens: prompt,
        completionTokens: completion,
        responseId: 'resp_empty',
      );

  AiCallResult badHistory(String id) => AiCallResult(
        content: '',
        toolCalls: [
          editCall(id, AgentStateSection.memorySummary, [
            {'op': 'noChange', 'reason': '本轮无进展'},
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_bad',
      );

  AiCallResult truncatedState(String id) => AiCallResult(
        content: '',
        toolCalls: [
          AiToolCall(
            id: id,
            name: kEditHistoryToolName,
            arguments: const {},
            argumentsUnparsable: true,
          ),
        ],
        promptTokens: 1,
        completionTokens: 4096,
        incomplete: true,
        incompleteReason: kIncompleteMaxOutputTokens,
      );

  ({
    AgentRoundRunner runner,
    List<_Request> requests,
    List<AiStreamChunk> sunk,
    List<Map<String, dynamic>> subBodies,
    List<bool> mainStreams,
    List<bool> subStreams,
  })
      harness({
    required AgentStateWorkingCopy copy,
    required List<Object> script,
    List<Object>? subScript,
    List<NarrAgentTool> extraTools = const [],
    MemoryMergePlan? memoryMergePlan,
    bool chaining = false,
    bool compressNonBodyReasoning = true,
    bool compressAllReasoning = false,
    int maxPrepFrames = kAgentMaxPrepFrames,
    int maxStateFrames = kAgentMaxStateFrames,
    void Function(AgentStage stage)? onStageStarted,
    bool Function(AgentStage stage)? streamForStage,
    String subagentModelName = '',
  }) {
    final requests = <_Request>[];
    final sunk = <AiStreamChunk>[];
    final subBodies = <Map<String, dynamic>>[];
    final mainStreams = <bool>[];
    final subStreams = <bool>[];
    var callIndex = 0;
    var subCallIndex = 0;
    final profile = AgentModeProfile.lv1;

    Future<AiCallResult> invoke(
      Object entry,
      void Function(AiStreamChunk chunk)? onChunk,
    ) async {
      if (entry is AiException) throw entry;
      if (entry is AiCancelledException) throw entry;
      final result = entry as AiCallResult;
      onChunk?.call(AiStreamChunk(contentDelta: result.content));
      for (final tc in result.toolCalls) {
        onChunk?.call(AiStreamChunk(toolCallId: tc.id, toolName: tc.name));
      }
      onChunk?.call(const AiStreamChunk(done: true));
      return result;
    }

    final runner = AgentRoundRunner(
      buildBody: (t) {
        requests.add(
          _Request(
            stage: t.stage,
            items: List.of(t.items),
            previousResponseId: t.previousResponseId,
          ),
        );
        return {
          'input': t.items,
          'previous_response_id': ?t.previousResponseId,
        };
      },
      call: (requestBody, stream, onChunk, onRequestBody, isCancelled) {
        mainStreams.add(stream);
        return invoke(script[callIndex++], onChunk);
      },
      subagentCall: subScript == null
          ? null
          : (requestBody, stream, onChunk, onRequestBody, isCancelled) {
              subBodies.add(requestBody);
              subStreams.add(stream);
              return invoke(subScript[subCallIndex++], onChunk);
      },
      subagentModelName: subagentModelName,
      streamForStage: streamForStage,
      tools: [
        ...buildStateTools(copy, sections: profile.toolSections),
        ...extraTools,
      ],
      workingCopy: copy,
      profile: profile,
      memoryMergePlan: memoryMergePlan,
      chaining: chaining,
      compressNonBodyReasoning: compressNonBodyReasoning,
      compressAllReasoning: compressAllReasoning,
      maxPrepFrames: maxPrepFrames,
      maxStateFrames: maxStateFrames,
      onStageStarted: onStageStarted,
    );
    return (
      runner: runner,
      requests: requests,
      sunk: sunk,
      subBodies: subBodies,
      mainStreams: mainStreams,
      subStreams: subStreams,
    );
  }

  Future<AgentRoundResult> run(AgentRoundRunner runner) => runner.run(
        initialInputItems: const [
          {'role': 'user', 'content': 'hi'},
        ],
        stream: true,
        onChunk: null,
      );

  Future<AgentRoundResult> runCollecting(
    AgentRoundRunner runner,
    List<AiStreamChunk> sunk,
  ) => runner.run(
        initialInputItems: const [
          {'role': 'user', 'content': 'hi'},
        ],
        stream: true,
        onChunk: sunk.add,
      );

  // ---------------------------------------------------------------------------
  // 主流程与顺序
  // ---------------------------------------------------------------------------

  test('Lv.1 主流程：调研读史 → 直接写正文 → 单独维护记忆；共 3 回合', () async {
    final copy = workingCopy();
    final stages = <AgentStage>[];
    final h = harness(
      copy: copy,
      onStageStarted: stages.add,
      script: [prepareRead('p1'), storyTurn(), historyAppend('m1')],
    );

    final result = await run(h.runner);

    expect(h.requests.map((r) => r.stage).toList(), [
      AgentStage.prepare,
      AgentStage.story,
      AgentStage.state,
    ]);
    expect(stages, [AgentStage.prepare, AgentStage.story, AgentStage.state]);
    expect(result.content, contains('殿前风冷'));
    expect(result.frames, 3);
    expect(result.maintenanceCompleted, isTrue);
    expect(result.maintenanceCancelled, isFalse);
    expect(result.warnings, isEmpty);
    expect(copy.memorySummary, contains('- 2 | 第二天 申时 | 主角前往主峰'));
    // 维护回合是独立的 user 指令，且明确只维护记忆。
    final maintenanceInput = h.requests[2].items.last;
    expect(maintenanceInput['role'], 'user');
    expect(
      '${maintenanceInput['content']}',
      startsWith('[State-maintenance turn]'),
    );
    expect('${maintenanceInput['content']}', contains('只维护记忆总结'));
    expect('${maintenanceInput['content']}', isNot(contains('【记忆回合】')));
  });

  test('正文先于记忆：正文请求发出时记忆栏仍为空，维护请求才带编辑结果', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [prepareRead('p1'), storyTurn(), historyAppend('m1')],
    );

    await run(h.runner);

    // 第 2 个请求（正文）之前只有读史结果，没有历史编辑。
    final storyItems = h.requests[1].items;
    expect(
      storyItems.any(
        (i) =>
            i['type'] == 'function_call' && i['name'] == kEditHistoryToolName,
      ),
      isFalse,
    );
    expect(copy.memorySummary, isNotEmpty, reason: '维护结束后才写入');
  });

  test('第一步调用历史编辑器被拒绝：记忆只允许在第二步维护', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [
      // 调研回合：模型跳步直接写记忆 → 拒绝；本回合没有正文，进入正文步。
      AiCallResult(
        content: '',
        toolCalls: [
          editCall('early', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': '- 2 | 第二天 申时 | 抢写'},
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_early',
      ),
      storyTurn(),
      historyAppend('m1'),
      ],
    );

    final result = await run(h.runner);

    final early = result.outcomes.firstWhere((o) => o.callId == 'early');
    expect(early.applied, isFalse);
    expect(early.message, contains('第二步维护'));
    expect(copy.memorySummary, isNot(contains('抢写')));
    expect(result.maintenanceCompleted, isTrue);
  });

  test('第二步拒绝联网：维护只维护记忆总结', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      extraTools: [_StubWebSearchTool()],
      script: [
      prepareRead('p1'),
      storyTurn(),
      AiCallResult(
        content: '',
        toolCalls: [
          const AiToolCall(
            id: 'search',
            name: 'narrchat_webSearch',
            arguments: {'query': '不该搜索'},
          ),
          ...historyAppend('m1').toolCalls,
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_state',
      ),
      ],
    );

    final result = await run(h.runner);

    final search = result.outcomes.firstWhere((o) => o.callId == 'search');
    expect(search.applied, isFalse);
    expect(search.message, contains('不联网'));
    expect(copy.memorySummary, contains('主角前往主峰'));
    expect(result.maintenanceCompleted, isTrue);
  });

  // ---------------------------------------------------------------------------
  // 读取护栏
  // ---------------------------------------------------------------------------

  test('维护步重复读取已提供的历史被拒绝（调研结果不被顶替）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [
      prepareRead('p1'),
      storyTurn(),
      AiCallResult(
        content: '',
        toolCalls: [readCall('m_read', AgentStateSection.memorySummary)],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_read2',
      ),
      historyAppend('m1'),
      ],
    );

    final result = await run(h.runner);

    final refused = result.outcomes.firstWhere((o) => o.callId == 'm_read');
    expect(refused.applied, isFalse);
    expect(refused.message, contains('不再重复读取'));
    expect(refused.isStateTool, isFalse);
    final refusedOutput = h.requests[3].items.firstWhere(
      (i) => i['type'] == 'function_call_output' && i['call_id'] == 'm_read',
    );
    expect('${refusedOutput['output']}', contains('已在对话中'));
    expect('${refusedOutput['output']}', isNot(contains('NARRCHAT_STATE')));
    // 调研回合那一份仍在。
    final providedOutput = h.requests[3].items.firstWhere(
      (i) => i['type'] == 'function_call_output' && i['call_id'] == 'p1',
    );
    expect('${providedOutput['output']}', contains('NARRCHAT_STATE'));
    expect(result.maintenanceCompleted, isTrue);
  });

  test('调研漏读历史时，维护步允许补读一次', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [
      emptyTurn('（调研回合没有工具）'),
      storyTurn(),
      AiCallResult(
        content: '',
        toolCalls: [
          readCall('m_read', AgentStateSection.memorySummary),
          ...historyAppend('m_edit').toolCalls,
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_fix',
      ),
      ],
    );

    final result = await run(h.runner);

    final read = result.outcomes.firstWhere((o) => o.callId == 'm_read');
    expect(read.applied, isTrue);
    expect(copy.memorySummary, contains('主角前往主峰'));
    expect(result.maintenanceCompleted, isTrue);
  });

  // ---------------------------------------------------------------------------
  // 正文分类 / 维护文本
  // ---------------------------------------------------------------------------

  test('正文最后一个标题帧胜出；维护文本只进流式框、不覆盖正文', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [
      prepareRead('p1'),
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
        responseId: 'resp_s1',
      ),
      storyTurn(),
      AiCallResult(
        content: '## 剧情演绎\n维护回合又写了一份正文',
        toolCalls: historyAppend('m1').toolCalls,
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_state',
      ),
      ],
    );

    final sunk = <AiStreamChunk>[];
    final result = await runCollecting(h.runner, sunk);

    expect(result.content, contains('殿前风冷'));
    expect(result.content, isNot(contains('写了一半')));
    expect(result.content, isNot(contains('维护回合又写了一份正文')));
    // 两个正文标题回合各发一次重置；维护文本不在正文里。
    expect(sunk.where((c) => c.narrativeReset), hasLength(2));
    expect(
      sunk
          .where((c) => c.contentDelta.isNotEmpty)
          .map((c) => c.contentDelta)
          .join(),
      contains('维护回合又写了一份正文'),
    );
  });

  test('无标题 + 无工具的正文回合按兜底正文采纳', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [emptyTurn(''), emptyTurn('没有标题的兜底正文'), historyAppend('m1')],
    );

    final result = await run(h.runner);
    expect(result.content, contains('没有标题的兜底正文'));
  });

  // ---------------------------------------------------------------------------
  // 维护失败 / 取消 / 重试
  // ---------------------------------------------------------------------------

  test('维护空手回合不提前结束：保留修复机会，帧数上限兜底', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      maxStateFrames: 2,
      script: [
      prepareRead('p1'),
      storyTurn(),
      emptyTurn('（维护 0：空手）'),
      historyAppend('m1'),
      ],
    );

    final result = await run(h.runner);

    expect(h.requests, hasLength(4));
    expect(h.requests[2].stage, AgentStage.state);
    expect(h.requests[3].stage, AgentStage.state);
    expect(result.maintenanceCompleted, isTrue);
    expect(result.warnings, isEmpty);
  });

  test('维护用尽仍缺项：正文照常返回，maintenanceCompleted=false + 黄框警告', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      maxStateFrames: 2,
      script: [
      prepareRead('p1'),
      storyTurn(),
      badHistory('bad1'),
      badHistory('bad2'),
      ],
    );

    final result = await run(h.runner);

    expect(result.content, contains('殿前风冷'));
    expect(result.frames, 4); // 调研 1 + 正文 1 + 维护 2
    expect(result.maintenanceCompleted, isFalse);
    expect(result.maintenanceCancelled, isFalse);
    expect(result.warnings.join(), contains('记忆总结'));
    expect(copy.memorySummary, isEmpty);
  });

  test('维护请求异常：正文保留，转 warning，不抛整轮失败', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [prepareRead('p1'), storyTurn(), const AiException('维护网络断开')],
    );

    final result = await run(h.runner);

    expect(result.content, contains('殿前风冷'));
    expect(result.maintenanceCompleted, isFalse);
    expect(result.maintenanceCancelled, isFalse);
    expect(result.warnings.join(), contains('状态维护未完成'));
    expect(result.warnings.join(), contains('维护网络断开'));
  });

  test('维护被取消：正文保留，maintenanceCancelled=true + 中断警告', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [prepareRead('p1'), storyTurn(), const AiCancelledException()],
    );

    final result = await run(h.runner);

    expect(result.content, contains('殿前风冷'));
    expect(result.maintenanceCompleted, isFalse);
    expect(result.maintenanceCancelled, isTrue);
    expect(result.warnings.join(), contains('状态维护已中断'));
  });

  // ---------------------------------------------------------------------------
  // Token / 续接 / 截断
  // ---------------------------------------------------------------------------

  test('token 是所有回合的总和（含调研 / 正文 / 维护）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [
      AiCallResult(
        content: '',
        toolCalls: [readCall('p1', AgentStateSection.memorySummary)],
        promptTokens: 2,
        completionTokens: 3,
        cachedTokensIn: 1,
        responseId: 'r1',
      ),
      storyTurn().copyWithUsage(prompt: 4, completion: 5, cached: 2),
      historyAppend('m1').copyWithUsage(prompt: 6, completion: 7, cached: 3),
      ],
    );

    final result = await run(h.runner);

    expect(result.promptTokens, 12);
    expect(result.completionTokens, 15);
    expect(result.cachedTokensIn, 6);
  });

  test('启用子模型：第二步走子调用，主 / 子 token 分桶', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      subagentModelName: 'cheap-model',
      script: [
        prepareRead('p1'),
        storyTurn().copyWithUsage(prompt: 4, completion: 5, cached: 2),
      ],
      subScript: [
        historyAppend('m1').copyWithUsage(prompt: 6, completion: 7, cached: 3),
      ],
    );

    final result = await run(h.runner);

    expect(h.requests.map((r) => r.stage).toList(), [
      AgentStage.prepare,
      AgentStage.story,
      AgentStage.state,
    ]);
    expect(h.subBodies, hasLength(1), reason: '只有维护步走子调用');
    expect(result.subagentUsed, isTrue);
    expect(result.subagentModelName, 'cheap-model');
    expect(result.mainPromptTokens, 4);
    expect(result.mainCompletionTokens, 5);
    expect(result.mainCachedTokensIn, 2);
    expect(result.subagentPromptTokens, 6);
    expect(result.subagentCompletionTokens, 7);
    expect(result.subagentCachedTokensIn, 3);
    expect(result.promptTokens, 10);
    expect(result.completionTokens, 12);
    expect(result.cachedTokensIn, 5);
    expect(result.maintenanceCompleted, isTrue);
  });

  test('启用子模型：进入维护步前断开 previous_response_id', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      chaining: true,
      compressNonBodyReasoning: false,
      subagentModelName: 'cheap-model',
      script: [prepareRead('p1'), storyTurn()],
      subScript: [historyAppend('m1')],
    );

    await run(h.runner);

    expect(h.requests[0].previousResponseId, isNull);
    expect(h.requests[1].previousResponseId, 'resp_read');
    expect(
      h.requests[2].previousResponseId,
      isNull,
      reason: '主模型的响应 id 不能发给子模型 / 子平台',
    );
  });

  test('streamForStage 按步生效：维护步用子模型自己的流式能力', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      streamForStage: (stage) => stage != AgentStage.state,
      script: [prepareRead('p1'), storyTurn()],
      subScript: [historyAppend('m1')],
    );

    await run(h.runner);

    expect(h.mainStreams, everyElement(isTrue));
    expect(h.subStreams, [isFalse]);
  });

  test('有状态链式：续接回合只发新增 item + previous_response_id', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      chaining: true,
      compressNonBodyReasoning: false,
      script: [prepareRead('p1'), storyTurn(), historyAppend('m1')],
    );

    await run(h.runner);

    expect(h.requests[0].previousResponseId, isNull);
    expect(h.requests[1].previousResponseId, 'resp_read');
    expect('${h.requests[1].items.last['content']}', startsWith('【正文回合】'));
    expect(h.requests[2].previousResponseId, 'resp_story');
    expect(
      '${h.requests[2].items.last['content']}',
      startsWith('[State-maintenance turn]'),
    );
  });

  test('维护回合被截断：下一回合带「拆短调用」提示重发', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      maxStateFrames: 2,
      script: [
      prepareRead('p1'),
      storyTurn(),
      truncatedState('a'),
      historyAppend('b'),
      ],
    );

    final result = await run(h.runner);

    expect(h.requests.map((r) => r.stage).toList(), [
      AgentStage.prepare,
      AgentStage.story,
      AgentStage.state,
      AgentStage.state,
    ]);
    final capDirective = '${h.requests[3].items.last['content']}';
    expect(capDirective, contains('TRUNCATED'));
    expect(capDirective, contains('上一帧在输出上限处被截断'));
    expect(capDirective, isNot(contains('[EN]')));
    expect(capDirective, isNot(contains('【中】')));
    expect(result.incomplete, isFalse);
    expect(result.maintenanceCompleted, isTrue);
  });

  test('维护末回合仍截断：提示调高最大 token，正文照常返回', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      maxStateFrames: 2,
      script: [
      prepareRead('p1'),
      storyTurn(),
      truncatedState('a'),
      truncatedState('b'),
      ],
    );

    final result = await run(h.runner);

    expect(result.incomplete, isTrue);
    expect(result.incompleteReason, kIncompleteMaxOutputTokens);
    expect(result.maintenanceCompleted, isFalse);
    expect(result.warnings.first, contains('最大 token'));
    expect(result.content, contains('殿前风冷'));
  });

  test('被截断的维护回合不作为续接基点：下一回合全量重发', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      chaining: true,
      compressNonBodyReasoning: false,
      maxStateFrames: 2,
      script: [
        prepareRead('p1'),
        storyTurn(),
        truncatedState('a'),
        historyAppend('b'),
      ],
    );

    await run(h.runner);

    expect(h.requests[2].previousResponseId, 'resp_story');
    expect(h.requests[3].previousResponseId, isNull);
    expect(h.requests[3].items.length, greaterThan(h.requests[2].items.length));
    expect(copy.memorySummary, contains('主角前往主峰'));
  });

  // ---------------------------------------------------------------------------
  // 记忆合并
  // ---------------------------------------------------------------------------

  test('维护一步完成合并 + 追加本轮条目 → maintenanceCompleted=true', () async {
    final copy = AgentStateWorkingCopy(
      roundIndex: 11,
      lastRound: const Round(
        id: 10,
        bookUuid: 'b1',
        roundIndex: 10,
        memorySummary:
            '- 1 | 第一天 | 一\n- 2 | 第二天 | 二\n- 3 | 第三天 | 三\n'
            '- 4 | 第四天 | 四\n- 5 | 第五天 | 五\n- 6 | 第六天 | 六\n'
            '- 7 | 第七天 | 七\n- 8 | 第八天 | 八\n- 9 | 第九天 | 九\n'
            '- 10 | 第十天 | 十',
        currentTime: '第十天',
      ),
      categoryNames: const ['主角'],
    );
    final plan = planMemoryMerge(
      memoryText: copy.memorySummary,
      tier: 5,
      newRoundIndex: 11,
    );
    expect(plan.hasAction, isTrue);
    final h = harness(
      copy: copy,
      memoryMergePlan: plan,
      script: [
      prepareRead('p1'),
      storyTurn(),
      AiCallResult(
        content: '',
        toolCalls: [
          editCall('m1', AgentStateSection.memorySummary, [
            {
              'op': 'set',
                'before':
                    '- 1 | 第一天 | 一\n- 2 | 第二天 | 二\n'
                  '- 3 | 第三天 | 三\n- 4 | 第四天 | 四\n- 5 | 第五天 | 五',
              'newLine': '- 1 - 5 | 第一天 ~ 第五天 | 前五轮摘要',
            },
            {'op': 'append', 'newLine': '- 11 | 第十一天 | 本轮'},
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_merge',
      ),
      ],
    );

    final result = await run(h.runner);

    expect(result.maintenanceCompleted, isTrue);
    expect(result.warnings, isEmpty);
    expect(isMemoryMergeApplied(copy.memorySummary, plan), isTrue);
    expect(copy.memorySummary, contains('- 11 | 第十一天 | 本轮'));
  });

  test('只追加不合并 → 维护不判完成并转常驻警告', () async {
    final copy = AgentStateWorkingCopy(
      roundIndex: 11,
      lastRound: const Round(
        id: 10,
        bookUuid: 'b1',
        roundIndex: 10,
        memorySummary:
            '- 1 | 第一天 | 一\n- 2 | 第二天 | 二\n- 3 | 第三天 | 三\n'
            '- 4 | 第四天 | 四\n- 5 | 第五天 | 五\n- 6 | 第六天 | 六\n'
            '- 7 | 第七天 | 七\n- 8 | 第八天 | 八\n- 9 | 第九天 | 九\n'
            '- 10 | 第十天 | 十',
        currentTime: '第十天',
      ),
      categoryNames: const ['主角'],
    );
    final plan = planMemoryMerge(
      memoryText: copy.memorySummary,
      tier: 5,
      newRoundIndex: 11,
    );
    expect(plan.hasAction, isTrue);
    final h = harness(
      copy: copy,
      memoryMergePlan: plan,
      maxStateFrames: 2,
      script: [
        prepareRead('p1'),
        storyTurn(),
        AiCallResult(
          content: '',
          toolCalls: [
            editCall('m1', AgentStateSection.memorySummary, [
              {'op': 'append', 'newLine': '- 11 | 第十一天 | 本轮'},
            ]),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_append',
        ),
        emptyTurn('（维护回合空手）'),
      ],
    );

    final result = await run(h.runner);

    expect(result.maintenanceCompleted, isFalse);
    expect(result.warnings.join(), contains('记忆总结未按档位'));
  });

  // ---------------------------------------------------------------------------
  // 思考回传 / 精简
  // ---------------------------------------------------------------------------

  test('思考块按每个工具调用各回传一块（服务端逐块校验）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      maxStateFrames: 2,
      script: [
      prepareRead('p1'),
      storyTurn(),
      AiCallResult(
        content: '',
        reasoningContent: '先读一遍历史，再落条目',
        reasoningItems: const [
          AiReasoningItem(id: 'r1', text: '先读一遍历史，再落条目'),
        ],
        toolCalls: [
          readCall('m_read', AgentStateSection.memorySummary),
          ...badHistory('h_bad').toolCalls,
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_state1',
      ),
      emptyTurn('（维护回合 2：空手）'),
      ],
    );

    await run(h.runner);

    // 第 2 个维护回合的请求里，上一回合的两个工具调用与各自紧邻的思考块都在。
    final stateItems = h.requests[3].items;
    final callAt = <String, int>{
      for (var i = 0; i < stateItems.length; i++)
        if (stateItems[i]['type'] == 'function_call')
          '${stateItems[i]['call_id']}': i,
    };
    for (final id in const ['m_read', 'h_bad']) {
      expect(callAt.keys, contains(id));
      final at = callAt[id]!;
      expect(stateItems[at - 1]['type'], 'reasoning');
      expect('${stateItems[at - 1]['text']}', isNotEmpty);
    }
  });

  List<String> reasoningTexts(List<Map<String, dynamic>> items) => [
        for (final item in items)
          if (item['type'] == 'reasoning') '${item['text']}',
      ];

  test('主开子关：第一步 reasoning 完整，维护步收到的前序 reasoning 压缩', () async {
    final copy = workingCopy();
    const prepareLong = '调研第一段。\n\n调研第二段。\n\n调研第三段。';
    const storyLong = '正文第一段。\n\n正文第二段。\n\n正文第三段。';
    final h = harness(
      copy: copy,
      compressNonBodyReasoning: true,
      compressAllReasoning: false,
      script: [
        AiCallResult(
          content: '',
          reasoningContent: prepareLong,
          reasoningItems: const [
            AiReasoningItem(id: 'r_prep', text: prepareLong),
          ],
          toolCalls: [readCall('p1', AgentStateSection.memorySummary)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_prep',
        ),
        AiCallResult(
          content: story5,
          reasoningContent: storyLong,
          reasoningItems: const [
            AiReasoningItem(id: 'r_story', text: storyLong),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_story',
        ),
        historyAppend('h1'),
      ],
    );

    final result = await run(h.runner);

    // 正文回合收到的调研思考链仍是完整原文（第一步 = 正文步）。
    final storyReasonings = reasoningTexts(h.requests[1].items);
    expect(storyReasonings, contains(prepareLong));
    // 维护回合收到的调研 + 正文思考链都压缩。
    final maintenanceReasonings = reasoningTexts(h.requests[2].items);
    expect(maintenanceReasonings, contains('调研第一段。\n\n调研第三段。'));
    expect(maintenanceReasonings, contains('正文第一段。\n\n正文第三段。'));
    expect(maintenanceReasonings, isNot(contains(prepareLong)));
    expect(maintenanceReasonings, isNot(contains(storyLong)));
    // UI / 结果聚合仍是完整原文。
    expect(result.reasoningContent, contains(prepareLong));
    expect(result.reasoningContent, contains(storyLong));
  });

  test('主开子开：第一步的调研 / 正文 reasoning 也压缩', () async {
    final copy = workingCopy();
    const prepareLong = '调研第一段。\n\n调研第二段。\n\n调研第三段。';
    const storyLong = '正文第一段。\n\n正文第二段。\n\n正文第三段。';
    final h = harness(
      copy: copy,
      compressNonBodyReasoning: true,
      compressAllReasoning: true,
      chaining: true,
      script: [
        AiCallResult(
          content: '',
          reasoningContent: prepareLong,
          reasoningItems: const [
            AiReasoningItem(id: 'r_prep', text: prepareLong),
          ],
          toolCalls: [readCall('p1', AgentStateSection.memorySummary)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_prep',
        ),
        AiCallResult(
          content: story5,
          reasoningContent: storyLong,
          reasoningItems: const [
            AiReasoningItem(id: 'r_story', text: storyLong),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_story',
        ),
        historyAppend('h1'),
      ],
    );

    final result = await run(h.runner);

    // 子开关打开时整轮不续接，正文回合直接收到压缩后的调研 reasoning。
    expect(h.requests[1].previousResponseId, isNull);
    expect(reasoningTexts(h.requests[1].items), contains('调研第一段。\n\n调研第三段。'));
    expect(reasoningTexts(h.requests[2].items), contains('正文第一段。\n\n正文第三段。'));
    // UI / 结果聚合仍完整。
    expect(result.reasoningContent, contains(prepareLong));
    expect(result.reasoningContent, contains(storyLong));
  });

  test('主开关关：所有步完整回传 reasoning', () async {
    final copy = workingCopy();
    const prepareLong = '调研第一段。\n\n调研第二段。\n\n调研第三段。';
    const storyLong = '正文第一段。\n\n正文第二段。\n\n正文第三段。';
    final h = harness(
      copy: copy,
      compressNonBodyReasoning: false,
      compressAllReasoning: false,
      script: [
        AiCallResult(
          content: '',
          reasoningContent: prepareLong,
          reasoningItems: const [
            AiReasoningItem(id: 'r_prep', text: prepareLong),
          ],
          toolCalls: [readCall('p1', AgentStateSection.memorySummary)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_prep',
        ),
        AiCallResult(
          content: story5,
          reasoningContent: storyLong,
          reasoningItems: const [
            AiReasoningItem(id: 'r_story', text: storyLong),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_story',
        ),
        historyAppend('h1'),
      ],
    );

    await run(h.runner);

    expect(reasoningTexts(h.requests[1].items), contains(prepareLong));
    final maintenanceReasonings = reasoningTexts(h.requests[2].items);
    expect(maintenanceReasonings, contains(prepareLong));
    expect(maintenanceReasonings, contains(storyLong));
  });

  test('主开子关 + 续接：正文步可续接，维护步断链后才发送压缩版本', () async {
    final copy = workingCopy();
    const prepareLong = '调研第一段。\n\n调研第二段。\n\n调研第三段。';
    final h = harness(
      copy: copy,
      chaining: true,
      compressNonBodyReasoning: true,
      compressAllReasoning: false,
      script: [
        AiCallResult(
          content: '',
          reasoningContent: prepareLong,
          reasoningItems: const [
            AiReasoningItem(id: 'r_prep', text: prepareLong),
          ],
          toolCalls: [readCall('p1', AgentStateSection.memorySummary)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_prep',
        ),
        storyTurn(),
        historyAppend('h1'),
      ],
    );

    await run(h.runner);

    expect(h.requests[1].previousResponseId, 'resp_prep');
    expect(h.requests[2].previousResponseId, isNull);
    expect(reasoningTexts(h.requests[2].items), contains('调研第一段。\n\n调研第三段。'));
  });

  test('维护修复回合收到压缩后的维护 reasoning', () async {
    final copy = workingCopy();
    const stateLong = '维护第一段。\n\n维护第二段。\n\n维护第三段。';
    final h = harness(
      copy: copy,
      compressNonBodyReasoning: true,
      compressAllReasoning: false,
      maxStateFrames: 2,
      script: [
        prepareRead('p1'),
        storyTurn(),
        AiCallResult(
          content: '',
          reasoningContent: stateLong,
          reasoningItems: const [
            AiReasoningItem(id: 'r_state', text: stateLong),
          ],
          toolCalls: badHistory('bad').toolCalls,
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_state_1',
        ),
        historyAppend('h1'),
      ],
    );

    await run(h.runner);

    final repairReasonings = reasoningTexts(h.requests[3].items);
    expect(repairReasonings, contains('维护第一段。\n\n维护第三段。'));
    expect(repairReasonings, isNot(contains(stateLong)));
  });
}

class _Request {
  const _Request({
    required this.stage,
    required this.items,
    required this.previousResponseId,
  });

  final AgentStage stage;
  final List<Map<String, dynamic>> items;
  final String? previousResponseId;
}

class _StubWebSearchTool extends NarrAgentTool {
  _StubWebSearchTool();

  @override
  String get name => 'narrchat_webSearch';

  @override
  String get description => '测试搜索';

  @override
  Map<String, dynamic> get parameters => const {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
      };

  @override
  AgentActivityType get activityType => AgentActivityType.searching;

  @override
  bool get isReadOnly => false;

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async =>
      const AgentToolResult(success: true, content: '搜索结果');
}

extension on AiCallResult {
  AiCallResult copyWithToolCalls(List<AiToolCall> calls) => AiCallResult(
        content: content,
        reasoningContent: reasoningContent,
        reasoningItems: reasoningItems,
        toolCalls: calls,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        cachedTokensIn: cachedTokensIn,
        responseId: responseId,
        incomplete: incomplete,
        incompleteReason: incompleteReason,
      );

  AiCallResult copyWithUsage({
    required int prompt,
    required int completion,
    required int cached,
  }) => AiCallResult(
        content: content,
        reasoningContent: reasoningContent,
        reasoningItems: reasoningItems,
        toolCalls: toolCalls,
        promptTokens: prompt,
        completionTokens: completion,
        cachedTokensIn: cached,
        responseId: responseId,
        incomplete: incomplete,
        incompleteReason: incompleteReason,
      );
}
