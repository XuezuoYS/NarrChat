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
import 'package:narrchat/utils/memory_entry_format.dart';

/// `AgentRoundRunner` 单元测试：当前唯一 Agent 档位（Lv.1）的三段执行器
/// （调研 → 记忆 → 正文，维护轮仅兜底）、帧级正文分类与「最后一个标题帧胜出」、
/// 门控上屏、读取器自取、协议兼容降级（链式续接）、维护帧截断补救、无进展止损。
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
  ///
  /// 档位固定为当前唯一档位（Lv.1）；[extraTools] 用于叠加联网等非状态工具替身。
  ({AgentRoundRunner runner, List<_Request> requests, List<AiStreamChunk> sunk})
      harness({
    required AgentStateWorkingCopy copy,
    required List<Object> script,
    List<NarrAgentTool> extraTools = const [],
    MemoryMergePlan? memoryMergePlan,
    bool chaining = false,
    bool reduceReasoningReplay = false,
    int maxPrepFrames = kAgentMaxPrepFrames,
    int maxMemoryFrames = kAgentMaxMemoryFrames,
    int maxStateFrames = kAgentMaxStateFrames,
  }) {
    final requests = <_Request>[];
    final sunk = <AiStreamChunk>[];
    var callIndex = 0;
    final profile = AgentModeProfile.lv1;
    final runner = AgentRoundRunner(
      buildBody: (t) {
        requests.add((
          stage: t.stage,
          items: List.of(t.items),
          previousResponseId: t.previousResponseId,
        ));
        return {
          'input': t.items,
          'previous_response_id': ?t.previousResponseId,
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
      tools: [
        ...buildStateTools(copy, sections: profile.toolSections),
        ...extraTools,
      ],
      workingCopy: copy,
      profile: profile,
      memoryMergePlan: memoryMergePlan,
      chaining: chaining,
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

  // ---------------------------------------------------------------------------
  // Lv.1 三段脚本（调研 → 记忆 → 正文）
  //
  // 当前唯一 Agent 档位：调研帧只读历史（+ 按需联网），记忆帧在同一回合推演并
  // 用历史编辑器落本轮条目，正文帧输出 5 区块（世界 / 角色随正文携带）。
  // ---------------------------------------------------------------------------

  /// 调研帧：无工具调用（联网结束）→ 调研阶段立即结束（本阶段文本不上屏）。
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

  /// 调研帧：读一次历史（只读帧 → 调研阶段就此结束，直接进入记忆阶段）。
  AiCallResult lv1PrepareReadTurn(String id) => AiCallResult(
        content: '',
        toolCalls: [readCall(id, AgentStateSection.memorySummary)],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_read',
      );

  /// 空手帧：只有文本、无工具调用（记忆帧模拟「模型没调编辑器」）。
  AiCallResult lv1EmptyTurn(String text) => AiCallResult(
        content: text,
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_empty',
      );

  /// 正文帧：5 区块（世界 / 角色随正文携带，记忆区块应由应用剥离）。
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

  /// 历史栏编辑被拒的一帧（`op=noChange` 在历史栏非法）→ 维护轮用尽告警用。
  AiCallResult badHistoryTurn(String id) => AiCallResult(
        content: '',
        toolCalls: [
          editCall(id, AgentStateSection.memorySummary, [
            {'op': 'noChange', 'reason': '本轮无进展'},
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_$id',
      );

  /// 联网工具替身：只回文本、不发起任何网络请求（帧序测试用）。
  List<NarrAgentTool> searchToolStub() => [const _StubWebSearchTool()];

  test('记忆阶段漏落条目 → 正文后自动发起维护轮补齐历史缺口', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxMemoryFrames: 1, script: [
      lv1PrepareReadTurn('p1'),
      lv1EmptyTurn('（记忆帧：只回文本）'),
      lv1StoryTurn(),
      lv1HistoryTurn('m1'),
    ]);

    final result = await run(h.runner);

    expect(
      h.requests.map((r) => r.stage).toList(),
      [AgentStage.prepare, AgentStage.memory, AgentStage.story, AgentStage.state],
    );
    // 状态**不预置注入**：请求 input 里没有应用塞进去的读取结果。
    expect(
      h.requests.first.items.where((i) => i['type'] == 'function_call_output'),
      isEmpty,
      reason: '状态由模型自取，应用不做预置',
    );
    expect(result.stateTurnUsed, isTrue);
    expect(result.warnings, isEmpty);
    expect(copy.memorySummary, contains('第2轮'));
  });

  test('读取器自取：正文阶段再次读史会顶替旧份（每栏只保留最新一份结果）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      lv1PrepareReadTurn('p1'),
      lv1HistoryTurn('h1'),
      // 正文帧 1：半截正文 + 再次读史（正文阶段放行，旧份随新结果剔除）。
      AiCallResult(
        content: '## 剧情演绎\n写了一半',
        toolCalls: [readCall('s1', AgentStateSection.memorySummary)],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_s1',
      ),
      lv1StoryTurn(),
    ]);

    final result = await run(h.runner);

    // 最后一个标题帧胜出：半截正文不进入本轮结果。
    expect(result.content, contains('## 世界状态'));
    expect(result.content, isNot(contains('写了一半')));
    final storyItems = h.requests[3].items;
    final reads = storyItems
        .where(
          (i) =>
              i['type'] == 'function_call' &&
              i['name'] == kReadHistoryToolName,
        )
        .map((i) => i['call_id'])
        .toList();
    // 只保留最新一份：调研帧的 p1 已被 s1 顶替（其紧邻思考块一并剔除）。
    expect(reads, ['s1']);
    final output = storyItems.firstWhere(
      (i) => i['type'] == 'function_call_output' && i['call_id'] == 's1',
    );
    expect('${output['output']}', contains('NARRCHAT_STATE'));
    expect('${output['output']}', contains('<memorySummary>'));
    // 读取结果 = 工作副本当前渲染（正文阶段读到的是本轮已落地的条目）。
    expect('${output['output']}', contains('第2轮'));
  });

  test('维护轮护栏：已提供过全文的历史栏重复读取被拒绝（调研结果不被顶替）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxMemoryFrames: 1, script: [
      lv1PrepareReadTurn('p1'),
      lv1EmptyTurn('（记忆帧没落条目）'),
      lv1StoryTurn(),
      // 维护帧 1：多此一举地再读一遍历史 → 被拒。
      AiCallResult(
        content: '',
        toolCalls: [readCall('m_read', AgentStateSection.memorySummary)],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_read2',
      ),
      // 维护帧 2：按已有全文直接追加条目。
      lv1HistoryTurn('m1'),
    ]);

    final result = await run(h.runner);

    expect(h.requests, hasLength(5));
    expect(result.stateTurnUsed, isTrue);
    // 读取被拒：不执行、不算状态缺项（流程违规 ≠ 待修栏目）。
    final refused = result.outcomes.firstWhere((o) => o.callId == 'm_read');
    expect(refused.applied, isFalse);
    expect(refused.message, contains('本阶段不再重复读取'));
    expect(refused.isStateTool, isFalse);
    final refusedOutput = h.requests[4].items.firstWhere(
      (i) => i['type'] == 'function_call_output' && i['call_id'] == 'm_read',
    );
    expect('${refusedOutput['output']}', contains('已在对话中'));
    expect('${refusedOutput['output']}', isNot(contains('NARRCHAT_STATE')));
    // 调研帧那一份仍在（护栏不能把模型唯一锚点来源剔掉）。
    final providedOutput = h.requests[4].items.firstWhere(
      (i) => i['type'] == 'function_call_output' && i['call_id'] == 'p1',
    );
    expect('${providedOutput['output']}', contains('NARRCHAT_STATE'));
    expect(copy.memorySummary, contains('第2轮'));
    expect(result.warnings, isEmpty);
  });

  test('维护轮护栏：调研阶段漏读的历史照常允许补读（非合规流程不失明）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxMemoryFrames: 1, script: [
      // 调研帧只有大纲、没有读史（无锚点来源）。
      lv1PrepareTurn(),
      lv1EmptyTurn('（记忆帧没落条目）'),
      lv1StoryTurn(),
      // 维护帧：补读历史 + 直接追加本轮条目（读取放行 → 锚点可抄）。
      AiCallResult(
        content: '',
        toolCalls: [
          readCall('m_read', AgentStateSection.memorySummary),
          ...lv1HistoryTurn('m_edit').toolCalls,
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_fix',
      ),
    ]);

    final result = await run(h.runner);

    // 漏读过的栏目照常执行读取（未提供过 → 护栏放行）。
    final read = result.outcomes.firstWhere((o) => o.callId == 'm_read');
    expect(read.applied, isTrue);
    expect(read.isStateTool, isFalse);
    // 编辑照常落地，整轮无警告。
    expect(copy.memorySummary, contains('第2轮'));
    expect(result.stateTurnUsed, isTrue);
    expect(result.warnings, isEmpty);
  });

  test('维护轮文本不上屏、也不覆盖已采纳正文', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxMemoryFrames: 1, script: [
      lv1PrepareReadTurn('p1'),
      lv1EmptyTurn('（记忆帧没落条目）'),
      lv1StoryTurn(),
      AiCallResult(
        // 维护轮违规复读正文（结构上不可能成为本轮正文）。
        content: '## 剧情演绎\n状态轮里又写了一份正文\n\n## 推荐行动\nx',
        toolCalls: lv1HistoryTurn('m1').toolCalls,
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
    final h = harness(copy: copy, extraTools: searchToolStub(), script: [
      lv1PrepareReadTurn('p1'),
      lv1HistoryTurn('h1'),
      // 正文帧 1：半截正文 + 搜索工具（非状态工具 → 必须继续下一帧）。
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
      // 正文帧 2：完整正文 → 覆盖帧 1。
      lv1StoryTurn(),
    ]);
    final sunk = <AiStreamChunk>[];
    final result = await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
      onChunk: sunk.add,
    );

    // 帧 2 的完整标题帧胜出 → 半截正文不进入本轮结果。
    expect(result.content, contains('## 世界状态'));
    expect(result.content, isNot(contains('写了一半')));
    // 搜索帧的输出被回传（模型据此续写）。
    final searchOutput = h.requests[3].items.firstWhere(
      (i) => i['type'] == 'function_call_output' && i['call_id'] == 's1',
    );
    expect('${searchOutput['output']}', contains('青云宗'));
    // 两个标题帧各发一次重置信号（界面正文块从标题处重新起流）。
    expect(sunk.where((c) => c.narrativeReset), hasLength(2));
  });

  test('思考块按**每个工具调用**各回传一块（服务端逐块校验）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      lv1PrepareReadTurn('p1'),
      // 记忆帧：一次思考 + **两个**工具调用（读取器被拒 + 历史编辑器落地）。
      AiCallResult(
        content: '',
        reasoningContent: '先读一遍历史，再落条目',
        reasoningItems: const [
          AiReasoningItem(id: 'r1', text: '先读一遍历史，再落条目'),
        ],
        toolCalls: [
          readCall('m_read', AgentStateSection.memorySummary),
          ...lv1HistoryTurn('h1').toolCalls,
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_mem',
      ),
      lv1StoryTurn(),
    ]);
    final result = await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    expect(result.content, contains('## 剧情演绎'));
    expect(copy.memorySummary, contains('第2轮'));
    final storyItems = h.requests[2].items;
    // 服务端实测规则：带 tools 的请求里**每个 function_call 都必须紧邻其前**
    // 各有一块非空 reasoning（一帧两个调用只回一块 → 400
    //「The reasoning_text in the thinking mode must be passed back」）。
    final callAt = <String, int>{
      for (var i = 0; i < storyItems.length; i++)
        if (storyItems[i]['type'] == 'function_call')
          '${storyItems[i]['call_id']}': i,
    };
    // 本帧的两个调用：读取器（被拒）+ 历史编辑器（落地）。
    for (final id in const ['m_read', 'h1']) {
      expect(callAt.keys, contains(id));
      final at = callAt[id]!;
      expect(
        at,
        greaterThan(0),
        reason: 'function_call 前必须有紧邻的思考块',
      );
      expect(storyItems[at - 1]['type'], 'reasoning');
      expect('${storyItems[at - 1]['text']}', isNotEmpty);
      // 块数不足时回落到最后一块：两个调用前都是模型本帧的那段思考原文。
      expect(storyItems[at - 1]['text'], '先读一遍历史，再落条目');
    }
  });

  test('无工具调用的帧：思考块照常回传（先于正文，单块）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxMemoryFrames: 1, script: [
      lv1PrepareReadTurn('p1'),
      // 记忆帧：只有文本与思考、没有工具调用（不满足 → 维护轮兜底）。
      AiCallResult(
        content: '（记忆帧只回文本）',
        reasoningContent: '想了一下剧情',
        reasoningItems: const [
          AiReasoningItem(id: 'r1', text: '想了一下剧情'),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_mem',
      ),
      lv1StoryTurn(),
      lv1HistoryTurn('m1'),
    ]);
    await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    // 正文帧请求体里：记忆帧（无工具）的思考块随帧收尾入队——恰一块，
    // 且紧挨在其 assistant 文本消息之前。
    final storyItems = h.requests[2].items;
    final memoryReasoning = storyItems
        .where(
          (i) => i['type'] == 'reasoning' && i['text'] == '想了一下剧情',
        )
        .toList();
    expect(memoryReasoning, hasLength(1));
    final reasoningAt = storyItems.indexOf(memoryReasoning.single);
    final assistantAt = storyItems.indexWhere(
      (i) =>
          i['role'] == 'assistant' &&
          '${i['content']}'.contains('记忆帧只回文本'),
    );
    expect(assistantAt, reasoningAt + 1);
  });

  test('模型未产出思考时仍逐块兜底（工具帧绝不缺块）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, extraTools: searchToolStub(), script: [
      // 调研帧：读史 + 搜索，无 reasoningItems / reasoningContent。
      AiCallResult(
        content: '',
        toolCalls: [
          readCall('p1', AgentStateSection.memorySummary),
          const AiToolCall(
            id: 'w1',
            name: 'narrchat_webSearch',
            arguments: {'query': '青云宗'},
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_prep',
      ),
      // 调研帧 2：不再调工具 → 调研阶段收束。
      lv1EmptyTurn(''),
      lv1HistoryTurn('h1'),
      lv1StoryTurn(),
    ]);
    await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    final memoryItems = h.requests[2].items;
    final calls = <int>[
      for (var i = 0; i < memoryItems.length; i++)
        if (memoryItems[i]['type'] == 'function_call') i,
    ];
    expect(calls, hasLength(2));
    for (final at in calls) {
      expect(memoryItems[at - 1]['type'], 'reasoning');
      // 兜底文本非空（本帧无正文 → 占位文本；服务端只校验「非空且紧邻」）。
      expect('${memoryItems[at - 1]['text']}', isNotEmpty);
    }
  });

  test('精简思考回传（开关开启时）：多段只回传首段 + 末段（`\\n\\n` 空行不计段）', () async {
    final copy = workingCopy();
    // 多段思考（中间过程整段丢弃；空行只是格式占位，不算段）。
    const long = '先读一遍历史确定锚点。\n\n'
        '再核对时间线。\n\n'
        '最后按五区块写正文，时间沿用上轮格式。';
    final h = harness(
      copy: copy,
      reduceReasoningReplay: true,
      script: [
        AiCallResult(
          content: '',
          reasoningContent: long,
          reasoningItems: const [AiReasoningItem(id: 'r1', text: long)],
          toolCalls: [readCall('p1', AgentStateSection.memorySummary)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_prep',
        ),
        lv1HistoryTurn('h1'),
        lv1StoryTurn(),
      ],
    );
    await h.runner.run(
      initialInputItems: const [{'role': 'user', 'content': 'hi'}],
      stream: true,
    );

    final reasoning =
        h.requests[1].items.firstWhere((i) => i['type'] == 'reasoning');
    expect(
      reasoning['text'],
      '先读一遍历史确定锚点。\n\n最后按五区块写正文，时间沿用上轮格式。',
    );
    // 中间段不得出现在回传里。
    expect('${reasoning['text']}', isNot(contains('再核对时间线')));
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
          toolCalls: [readCall('p1', AgentStateSection.memorySummary)],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_prep',
        ),
        lv1HistoryTurn('h1'),
        lv1StoryTurn(),
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
    final h = harness(copy: copy, script: [
      lv1PrepareReadTurn('p1'),
      lv1HistoryTurn('h1'),
      lv1StoryTurn(),
    ]);
    await run(h.runner);

    expect(h.requests, hasLength(3));
    for (final r in h.requests) {
      expect(r.previousResponseId, isNull);
    }
    final first = h.requests[0].items;
    // 历史 1 条 + 调研指令；状态**不预置**（模型应自行调用读取器获取）。
    expect(first, hasLength(2));
    expect(first.first['role'], 'user');
    expect('${first.last['content']}', startsWith('【调研回合】'));
    // 每帧开始时都没有「应用塞入」的状态结果（工具输出只来自模型自己调用）。
    expect(
      first.where((i) => i['type'] == 'function_call_output'),
      isEmpty,
      reason: '状态由模型自取，应用不做预置',
    );
    // 第 2 帧：调研帧的读取结果已回传（旧缺陷：续接帧「失忆」）。
    expect(
      h.requests[1].items.any(
        (i) =>
            i['type'] == 'function_call_output' &&
            '${i['output']}'.contains('<memorySummary'),
      ),
      isTrue,
    );
    // 正文帧指令是最后一条 user 消息（五区块、不要记忆区块）。
    final last = h.requests[2].items.last;
    expect(last['role'], 'user');
    expect('${last['content']}', startsWith('【正文回合】'));
    expect('${last['content']}', contains('5 个二级标题'));
  });

  test('有状态链式：续接帧只发新增 item + previous_response_id', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      chaining: true,
      script: [lv1PrepareReadTurn('p1'), lv1HistoryTurn('h1'), lv1StoryTurn()],
    );
    await run(h.runner);

    expect(h.requests[0].previousResponseId, isNull);
    expect(h.requests[0].items, hasLength(2));
    // 记忆帧只发「调研帧新增的读取条目 + 记忆指令」。
    expect(h.requests[1].previousResponseId, 'resp_read');
    expect(h.requests[1].items, hasLength(4));
    expect('${h.requests[1].items.last['content']}', startsWith('【记忆回合】'));
    // 正文帧只发「记忆帧新增的编辑条目 + 正文指令」。
    expect(h.requests[2].previousResponseId, 'resp_2');
    expect(h.requests[2].items, hasLength(4));
    expect('${h.requests[2].items.last['content']}', startsWith('【正文回合】'));
  });

  test('维护轮空手帧不再提前止损：保留修复机会（帧数上限兜底）', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxStateFrames: 2, script: [
      lv1PrepareReadTurn('p1'),
      lv1EmptyTurn('（记忆帧 1：只回文本）'),
      lv1EmptyTurn('（记忆帧 2：只回文本）'),
      lv1EmptyTurn('（记忆帧 3：只回文本）'),
      lv1StoryTurn(),
      // 维护帧 0：只回文本（空手，不应结束整轮）。
      lv1EmptyTurn('（维护帧 0：空手）'),
      lv1HistoryTurn('m1'),
    ]);

    final result = await run(h.runner);

    expect(h.requests, hasLength(7));
    expect(h.requests[5].stage, AgentStage.state);
    expect(h.requests[6].stage, AgentStage.state);
    expect(result.stateTurnUsed, isTrue);
    // 空手帧后仍把缺口补上 → 无警告。
    expect(result.warnings, isEmpty);
    expect(copy.memorySummary, contains('第2轮'));
  });

  test('维护轮用尽仍有缺项 → 警告钳制（正文照常返回）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      maxMemoryFrames: 1,
      maxStateFrames: 2,
      script: [
        lv1PrepareReadTurn('p1'),
        lv1EmptyTurn('（记忆帧没落条目）'),
        lv1StoryTurn(),
        badHistoryTurn('call_1'),
        badHistoryTurn('call_2'),
      ],
    );

    final result = await run(h.runner);

    expect(result.content, contains('正文'));
    expect(result.frames, 5); // 调研 1 + 记忆 1 + 正文 1 + 维护 2
    expect(result.warnings, isNotEmpty);
    expect(result.warnings.join(), contains('记忆总结'));
    // 记忆总结未被污染（noChange 被拒）。
    expect(copy.memorySummary, isEmpty);
  });

  test('锚点未命中 → 回传该栏目当前全文供重锚', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxMemoryFrames: 1, script: [
      lv1PrepareReadTurn('p1'),
      // 记忆帧：锚点打在不存在的行上 → 失败并回传历史栏当前全文。
      AiCallResult(
        content: '',
        toolCalls: [
          editCall('h_bad', AgentStateSection.memorySummary, [
            {
              'op': 'set',
              'before': '- 完全不存在的行',
              'newLine': '- 第2轮｜日期：第二天 申时｜主角前往主峰',
            },
          ]),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_bad',
      ),
      lv1StoryTurn(),
      lv1HistoryTurn('m1'),
    ]);
    await run(h.runner);

    final outputs = h.requests[3].items
        .where((i) => i['type'] == 'function_call_output')
        .map((i) => '${i['output']}')
        .join('\n');
    expect(outputs, contains('未找到与 before 匹配的行'));
    expect(outputs, contains('当前全文'));
    expect(outputs, contains('<memorySummary>'));
    // 维护轮把失败项一并列出（点名对应栏目编辑器）。
    expect(
      '${h.requests[3].items.last['content']}',
      contains(kEditHistoryToolName),
    );
  });

  test('工具参数被截断 → 不执行，下一帧按回传说明重试', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxMemoryFrames: 2, script: [
      lv1PrepareReadTurn('p1'),
      AiCallResult(
        content: '',
        toolCalls: [
          const AiToolCall(
            id: 'call_1',
            name: kEditHistoryToolName,
            arguments: {},
            argumentsUnparsable: true,
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'resp_trunc',
      ),
      lv1HistoryTurn('h1'),
      lv1StoryTurn(),
    ]);

    final result = await run(h.runner);

    final truncated = result.outcomes.firstWhere((o) => o.callId == 'call_1');
    expect(truncated.applied, isFalse);
    expect(truncated.message, contains('截断'));
    // 截断帧什么都没改；拒绝回传（英文要求 + 中文概述）进入下一帧上下文。
    final truncatedOutput = '${h.requests[2].items.firstWhere(
      (i) => i['type'] == 'function_call_output' && i['call_id'] == 'call_1',
    )['output']}';
    expect(truncatedOutput, contains('TRUNCATED'));
    expect(truncatedOutput, contains('工具参数被截断'));
    for (final marker in const ['[EN]', '【中】']) {
      expect(truncatedOutput, isNot(contains(marker)), reason: marker);
    }
    // 下一帧按说明重试，条目落地、整轮无警告。
    expect(copy.memorySummary, contains('第2轮'));
    expect(result.warnings, isEmpty);
  });

  /// 被输出上限截断的维护帧：历史编辑器参数没写完（JSON 不闭合）。
  AiCallResult truncatedStateTurn(String id) => AiCallResult(
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

  test('维护帧被截断：不判失败，下一帧带「拆短调用」指令重发', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxMemoryFrames: 1, maxStateFrames: 2, script: [
      lv1PrepareReadTurn('p1'),
      lv1EmptyTurn('（记忆帧没落条目）'),
      lv1StoryTurn(),
      truncatedStateTurn('a'),
      lv1HistoryTurn('b'),
    ]);

    final result = await run(h.runner);

    expect(h.requests, hasLength(5));
    // 补救只走提示词：请求体里的 max_output_tokens 与思考强度都由用户设置决定，
    // 执行器一概不擅自改动（帧间差异只有 input 与续接基点）。
    expect(
      h.requests.map((r) => r.stage).toList(),
      [
        AgentStage.prepare,
        AgentStage.memory,
        AgentStage.story,
        AgentStage.state,
        AgentStage.state,
      ],
    );
    final capDirective = '${h.requests[4].items.last['content']}';
    expect(capDirective, contains('TRUNCATED'));
    // 「拆短调用」提示：中文概述紧跟英文要求之后，无 [EN] / 【中】 语言标记。
    expect(capDirective, contains('上一帧在输出上限处被截断'));
    expect(capDirective, isNot(contains('[EN]')));
    expect(capDirective, isNot(contains('【中】')));
    expect(capDirective, contains('拆短'));
    // 末帧未截断 → 不再对用户提示截断。
    expect(result.incomplete, isFalse);
    expect(result.incompleteReason, isEmpty);
    expect(copy.memorySummary, contains('第2轮'));
    expect(result.warnings, isEmpty);
  });

  test('维护帧末帧仍截断 → 给用户一条可操作的「调高最大 token」提示', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, maxMemoryFrames: 1, maxStateFrames: 2, script: [
      lv1PrepareReadTurn('p1'),
      lv1EmptyTurn('（记忆帧没落条目）'),
      lv1StoryTurn(),
      truncatedStateTurn('a'),
      truncatedStateTurn('b'),
    ]);

    final result = await run(h.runner);

    expect(result.incomplete, isTrue);
    expect(result.incompleteReason, kIncompleteMaxOutputTokens);
    expect(result.warnings.first, contains('最大 token'));
    // 正文照常产出：截断只影响状态，不再赔掉整轮。
    expect(result.content, contains('正文'));
    expect(copy.memorySummary, isEmpty);
  });

  test('被截断的帧不作为续接基点：下一帧改为全量重发', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      chaining: true,
      maxMemoryFrames: 1,
      maxStateFrames: 2,
      script: [
        lv1PrepareReadTurn('p1'),
        lv1EmptyTurn('（记忆帧没落条目）'),
        lv1StoryTurn(),
        truncatedStateTurn('a'),
        lv1HistoryTurn('b'),
      ],
    );

    await run(h.runner);

    // 维护帧 1 走续接（只发新增项）。
    expect(h.requests[3].previousResponseId, 'resp_1');
    // 维护帧 1 被截断 → 帧 2 不能作为基点：全量重发且不带 previous_response_id。
    expect(h.requests[4].previousResponseId, isNull);
    expect(
      h.requests[4].items.length,
      greaterThan(h.requests[3].items.length),
    );
    expect(copy.memorySummary, contains('第2轮'));
  });

  test('服务商拒绝用户设置的思考强度 → 不重试、不做任何强度回落', () async {
    final copy = workingCopy();
    final h = harness(copy: copy, script: [
      lv1PrepareReadTurn('p1'),
      const AiException(
        "Unsupported parameter: 'reasoning.effort' is not supported",
        kind: AiExceptionKind.api,
      ),
    ]);

    // 该帧就是「用户设置」的那一帧：没有可回落的覆盖，因此直接失败（不重发）。
    await expectLater(run(h.runner), throwsA(isA<AiException>()));
    expect(h.requests, hasLength(2));
    expect(h.requests[1].stage, AgentStage.memory);
  });

  // ---------------------------------------------------------------------------
  // Lv.1 三段流程专项（准备 / 记忆 / 正文 / 记忆合并）
  // ---------------------------------------------------------------------------

  test('Lv.1：准备(读史) → 记忆(条目先落地) → 正文(5 区块，剥离记忆)', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      // 无需 maxPrepFrames 限制：本帧只调了读取器（读史）→ 调研阶段立即结束。
      script: [
        lv1PrepareReadTurn('p1'),
        lv1HistoryTurn('h1'),
        // 模型违规多写了记忆区块：采纳时必须剥离（历史只走工具）。
        lv1StoryTurn(extra: '\n\n## 记忆总结\n- 第2轮｜日期：第二天 申时｜正文里偷写的'),
      ],
    );

    final result = await run(h.runner);

    // 三帧固定顺序：调研 → 记忆 → 正文（思考强度无覆盖，全帧沿用户设置）。
    expect(
      h.requests.map((r) => r.stage).toList(),
      [AgentStage.prepare, AgentStage.memory, AgentStage.story],
    );
    // 调研帧指令：本阶段只做调研（读历史一次），不产出大纲。
    expect(
      '${h.requests[0].items.last['content']}',
      contains('【调研回合】'),
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

  test('Lv.1：调研阶段——本帧只读史即结束（无联网一轮恰好 3 帧）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [lv1PrepareReadTurn('p1'), lv1HistoryTurn('h1'), lv1StoryTurn()],
    );

    final result = await run(h.runner);

    // 只读帧（读完历史、没有联网意图）⇒ 不再等模型「收手」：中间那一帧
    // 正是模型复述大纲的地方，现在直接进入记忆阶段。
    expect(
      h.requests.map((r) => r.stage).toList(),
      [AgentStage.prepare, AgentStage.memory, AgentStage.story],
      reason: '无联网一轮 = 调研 1 帧 + 记忆 1 帧 + 正文 1 帧',
    );
    expect(result.frames, 3);
    expect(result.warnings, isEmpty);
    expect(copy.memorySummary, contains('第2轮'));
  });

  test('Lv.1：调研阶段——含联网调用的帧把阶段留住，直到本帧不再调工具', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
      script: [
        // 调研帧 1：读史 + 发起搜索（搜索不是读取器 → 调研阶段继续）。
        AiCallResult(
          content: '',
          toolCalls: [
            readCall('p1', AgentStateSection.memorySummary),
            const AiToolCall(
              id: 'w1',
              name: 'narrchat_webSearch',
              arguments: {'query': '青云宗'},
            ),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'resp_w',
        ),
        // 调研帧 2：不再调工具（联网结束）→ 调研阶段收束。
        lv1PrepareTurn(),
        lv1HistoryTurn('h1'),
        lv1StoryTurn(),
      ],
    );

    await run(h.runner);

    expect(
      h.requests.map((r) => r.stage).toList(),
      [
        AgentStage.prepare,
        AgentStage.prepare,
        AgentStage.memory,
        AgentStage.story,
      ],
      reason: '联网帧不结束调研阶段：留给模型多步搜索 / 打开页面',
    );
  });

  test('Lv.1：会话累积顺序——记忆条目先于正文 assistant 回传（续写帧可见）', () async {
    final copy = workingCopy();
    final h = harness(
      copy: copy,
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
    expect(result.frames, 6);
    expect(result.stateTurnUsed, isTrue);
    // 帧间差异只有 input：执行器不为任何帧覆盖思考强度
    //（请求体层面的锁定见 agent_over_chat_test「思考强度全程沿用用户设置」）。
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
      script: [
        // 调研帧：工具**全是编辑器** → 调研阶段立即闭环（该帧文本不上屏）。
        lv1HistoryTurn('p1', entry: '- 第2轮｜日期：第二天 申时｜准备帧写入'),
        lv1StoryTurn(),
      ],
    );

    final result = await run(h.runner);

    // 进入记忆阶段时本轮条目已在准备帧落地 → [_memorySatisfied] 成立 →
    // **不再发**记忆帧（否则会逼模型重复 `op=append`，第二条条目让
    // applyEdits 整栏失败并多烧两帧修复）。
    expect(
      h.requests.map((r) => r.stage).toList(),
      [AgentStage.prepare, AgentStage.story],
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
    final profile = AgentModeProfile.lv1;
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

  test('Lv.1：调研阶段漏读历史时，记忆阶段仍允许补读一次（合并没有锚点就落不了地）', () async {
    final copy = mergeCopy();
    final h = harness(
      copy: copy,
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

  test('Lv.1：调研阶段已读过历史 → 记忆帧的重复读取仍被拒（护栏不变）', () async {
    final copy = mergeCopy();
    final h = harness(
      copy: copy,
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

/// 一次帧调用的记录（阶段 / input 快照 / 有状态续接基点）。
///
/// **不含思考强度**：执行器不为任何阶段覆盖它，帧上下文只有这三项
/// （见 [AgentTurnRequest]）。
typedef _Request = ({
  AgentStage stage,
  List<Map<String, dynamic>> items,
  String? previousResponseId,
});

/// 联网搜索工具替身：只回固定文本、不发起任何网络请求（帧序测试用）。
class _StubWebSearchTool implements NarrAgentTool {
  const _StubWebSearchTool();

  @override
  String get name => 'narrchat_webSearch';

  @override
  String get description => '测试用联网搜索替身：返回固定结果。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
      };

  @override
  bool get isReadOnly => false;

  @override
  AgentActivityType get activityType => AgentActivityType.searching;

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async =>
      AgentToolResult(
        success: true,
        content: '搜索「${arguments['query']}」的结果：\n1. 结果。',
      );
}
