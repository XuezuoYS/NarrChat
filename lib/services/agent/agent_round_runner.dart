import 'dart:convert';

import '../ai_response_parser.dart';
import '../ai_service.dart';
import 'agent_activity.dart';
import 'narr_agent_tool.dart';
import 'state/agent_state_working_copy.dart';
import 'state/state_coverage.dart';
import 'state/state_tools.dart';

/// 状态轮（含其修复帧）的最大帧数：1 主帧 + 3 修复帧。
const int kAgentMaxStateFrames = 4;

/// 正文轮的最大帧数（联网搜索会消耗多帧：开场白 → 搜索 → 打开页 → 正文）。
const int kAgentMaxStoryFrames = 8;

/// 状态轮的思考强度覆盖值：用户开启思考时，状态帧不硬关思考（`none`），
/// 而是降到 `low`——状态维护需要理解正文与快照，完全关闭会让模型「看不懂」
/// 缺项清单与锚点；同时思考 token 计入输出上限，`low` 把预算尽量留给参数。
const String kAgentStateThinkingEffort = 'low';

/// 输出触顶的原因标识（Responses `incomplete_details.reason`）。
const String kIncompleteMaxOutputTokens = 'max_output_tokens';

/// 执行器运行阶段。
enum AgentStage {
  /// 正文轮：产出本轮正文（可同时提前改状态，但正确性不依赖它）。
  story,

  /// 状态轮：只调工具改状态，**文本通道对界面完全关闭**。
  state,
}

/// 一次帧请求的上下文（由 `buildBody` 组装成实际请求体）。
class AgentTurnRequest {
  const AgentTurnRequest({
    required this.stage,
    required this.items,
    this.previousResponseId,
    this.toolChoice,
    this.stateThinkingEffort,
  });

  final AgentStage stage;

  /// 本次要发送的 input（无状态平台 = 全量累积；有状态续接 = 仅新增项）。
  final List<Map<String, dynamic>> items;
  final String? previousResponseId;

  /// `tool_choice`（正文轮 `auto` / 状态轮 `required`；null = 不发送）。
  final String? toolChoice;

  /// 状态轮的思考强度**覆盖**（[kAgentStateThinkingEffort] = `low`；null =
  /// 沿用用户设置）。仅当用户开启了思考模式时生效：思考 token 占用输出上限，
  /// 但状态维护需要理解正文与快照，`low` 在「不完全关掉理解力」与「省预算」
  /// 之间折中；服务商不接受覆盖时由执行器就地回落用户设置。
  final String? stateThinkingEffort;
}

/// 单个工具调用的执行结果（UI 事件 + 回传模型依据）。
class AgentToolOutcome {
  final String name;

  /// 工具调用 id（与流式预览事件匹配）。
  final String callId;

  /// 参数短摘要（UI 展示）。
  final String argsSummary;

  /// 事件主体（UI 展示用）：搜索 = query、打开页 = url、其余 = [argsSummary]。
  final String subject;

  /// 是否应用成功（状态工具校验失败 → 状态轮反馈）。
  final bool applied;

  /// **UI** 结果说明（一行摘要）。
  final String message;

  /// **回传模型**的结果全文（状态工具含该栏目当前全文）。
  final String modelOutput;

  /// 是否状态类工具（校验失败走状态轮语义）。
  final bool isStateTool;

  const AgentToolOutcome({
    required this.name,
    this.callId = '',
    required this.argsSummary,
    this.subject = '',
    required this.applied,
    required this.message,
    required this.isStateTool,
    String? modelOutput,
  }) : modelOutput = modelOutput ?? message;
}

/// AGENT 轮运行的聚合结果。
class AgentRoundResult {
  /// 本轮正文：最后一个**标题帧**的原始内容（无标题帧时以「无标题 + 无工具」
  /// 帧兜底；整轮从未产出标题帧时回退最后的开场白）。
  final String content;

  /// 聚合思考内容。
  final String reasoningContent;

  /// 聚合 Token 用量。
  final int promptTokens;
  final int completionTokens;

  /// 全部工具调用结果（按执行顺序）。
  final List<AgentToolOutcome> outcomes;

  /// 状态轮跑满仍被跳过（钳制）的缺口说明（中文一行，UI 展示）。
  final List<String> warnings;

  /// 最后一次响应的 responseId（无状态平台为空）。
  final String responseId;

  /// 是否发起过状态轮（正文轮未把状态补齐时才会发起）。
  final bool stateTurnUsed;

  /// 本轮**最后一帧**是否被服务端提前结束（截断）。
  final bool incomplete;

  /// 截断原因（`max_output_tokens` / `content_filter` / …；空 = 未截断）。
  final String incompleteReason;

  /// 本轮总帧数（正文轮 + 状态轮，含修复帧）。
  final int frames;

  const AgentRoundResult({
    required this.content,
    required this.reasoningContent,
    required this.promptTokens,
    required this.completionTokens,
    required this.outcomes,
    required this.warnings,
    required this.responseId,
    required this.stateTurnUsed,
    required this.frames,
    this.incomplete = false,
    this.incompleteReason = '',
  });
}

/// AGENT 单轮执行器（Responses 协议 + 状态自取 + 两阶段）。
///
/// ## 为什么拆两阶段
///
/// 旧版把「写正文」与「调状态工具」塞进同一响应，靠提示词命令模型
/// 「正文先行、工具随后」——这与工具型模型「先调工具、再答」的先验相反；
/// 加上续接帧不回传模型自己刚写的正文，导致一次请求里反复生成多份正文。
/// 现在两阶段各自只有一个正确动作：
///
/// 1. **正文轮**（[AgentStage.story]，`tool_choice = auto`）：基于**上一轮
///    状态**写正文三小节（动笔前先调 [kReadStateToolName]），联网搜索在此
///    阶段完成。`narrchat_editSection` 在此阶段**禁止**（违规仍执行兼容，但
///    整轮正确性不依赖它）；`## 当前时间` 是正文第三小节（时间不属于工具）。
/// 2. **完整性判定**（[inspectState]）：栏目是否都处理、时间是否推进、
///    本轮是否恰好一条记忆、正文提及的角色小节是否一动未动。
/// 3. **状态轮**（[AgentStage.state]，仅在有需要时发起，`tool_choice =
///    required`）：先调 [kReadStateToolName]（返回 = 上一轮 + **本轮正文之后**
///    的状态，锚点唯一正确来源），再逐栏目编辑；该阶段模型输出的任何文本
///    **不会到达界面**——「一次请求多份正文」在新结构下不可能发生。
///
/// ## 状态自取（快照不作预置）
///
/// 早期版本由应用把状态快照预置成「工具输出」喂给模型，模型把 `<time>` /
/// `<worldState>` 等 md 块当成**可模仿的输出格式**——要么照格式堆进正文
/// （Chat 式预期表现），要么写完正文又调工具，困惑「我不是都写了吗」。
/// 现在 [kReadStateToolName] 是**真实注册的只读工具**，模型必须主动调用才
/// 拿得到状态：
///
/// - 调用时机由模型承担，但**返回值语义统一** = 工作副本当前渲染（正文轮
///   调用 → 上一轮库内状态；状态轮调用 → 正文之后的状态），应用侧不需要
///   从调用序列推断「这是正文次还是状态维护次」；
/// - readState 结果以 `function_call_output` 形态进入上下文（**工具结果，
///   不是输出格式**，不再诱发格式模仿）；
/// - 上下文里**只保留最新一份** readState 结果（[_pruneStaleReadState]），
///   修复帧不再重复读取（指令明示复用已有快照与失败回传全文），
///   每轮输入不会随修复帧数线性膨胀；
/// - 正文采纳时还会**剥离**正文里出现的状态类二级标题段（模型违规模仿
///   格式的兜底清洗，见 [_stripStateSectionsIn]）。
///
/// ## 帧级正文分类（单一真源）
///
/// 分类只在本类内做，界面只消费**已门控**的 [AiStreamChunk]：
///
/// | 含 `## 剧情演绎` | 含工具调用 | 分类 | 处置 |
/// |---|---|---|---|
/// | 否 | 是 | 开场白 / 读取帧 | 不上屏、不采纳、继续循环 |
/// | 否 | 否 | 无格式正文 | 兜底采纳（防格式不合规丢正文）|
/// | 是 | 否 | **正文帧** | 采纳，阶段结束 |
/// | 是 | 是 | 正文 + 工具 | 采纳为候选并继续，后续标题帧覆盖之 |
///
/// 采纳规则是「**最后一个标题帧胜出**」：模型写到一半去调工具、下一帧重写
/// 完整正文时取到完整版（旧版「首个采纳、后续丢弃」会留下半截正文）。
/// 门控在每帧正文首次上屏前发 [AiStreamChunk.narrativeReset]，界面重置正文块。
///
/// ## 会话累积（修复帧不再「失忆」）
///
/// 每帧结束后把 `assistant(正文)` + `function_call` + `function_call_output`
/// 追加进 `_items`：续接帧因此看得见自己刚写过的正文——这是旧版多份正文的
/// 直接病根（只重放 function_call）。
///
/// ## 前缀一致性（成本）
///
/// 两阶段共用完全相同的 `instructions` 与 `tools`（超集），只在尾部追加
/// item，服务商的上下文缓存前缀保持命中（readState 结果替换旧份发生在
/// 共享前缀之后，不影响命中）。
///
/// ## 兼容性降级（绝不消耗用户的整轮预算）
///
/// [supportsToolChoice] / [supportsThinkingEffort] 是能力**初值**，运行中遇到
/// 协议类失败就地重发同一帧（同一帧至多连降 3 项）：
/// 拒绝 `tool_choice` → 去掉该字段；拒绝 `previous_response_id` → 本轮全量
/// 重发；拒绝中途调整思考强度 → 状态轮回落用户设置。
/// 只有内容校验类失败才走修复帧。
///
/// ## 截断（`response.incomplete`）
///
/// 状态轮输出的是逐字锚点的工具参数 JSON，而思考 token 同样计入输出上限，
/// 极易触顶。触顶**不是失败**：底层保留截断前的部分结果并标记
/// [AiCallResult.incomplete]，本执行器据此（1）给下一帧补一条「拆短输出」
/// 指令，（2）状态轮思考降为 `low`（用户开启思考时，不硬关——状态维护
/// 需要理解正文与快照），（3）末帧仍截断时
/// 给用户一条可操作提示（由用户在设置里调高「最大 token」，程序不擅自改动
/// 请求体的 `max_output_tokens`）。绝不因一帧截断赔掉整轮正文。
class AgentRoundRunner {
  AgentRoundRunner({
    required this.buildBody,
    required this.call,
    required this.tools,
    required this.workingCopy,
    this.chaining = false,
    this.supportsToolChoice = true,
    this.supportsThinkingEffort = true,
    this.maxStoryFrames = kAgentMaxStoryFrames,
    this.maxStateFrames = kAgentMaxStateFrames,
    this.onActivity,
    this.onToolStarted,
    this.onToolFinished,
  });

  /// 组装一次帧请求体（两阶段共用同一 instructions / tools 超集）。
  final Map<String, dynamic> Function(AgentTurnRequest request) buildBody;

  /// 执行一次 LLM 调用（responses 通道）。
  final Future<AiCallResult> Function(
    Map<String, dynamic> requestBody,
    bool stream,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  ) call;

  final List<NarrAgentTool> tools;
  final AgentStateWorkingCopy workingCopy;

  final bool chaining;
  bool supportsToolChoice;

  /// 服务商是否接受「状态轮思考强度覆盖」（[AgentTurnRequest.stateThinkingEffort]）。
  /// 部分服务商不允许中途调整推理强度 → 就地回落用户设置重发同一帧。
  bool supportsThinkingEffort;

  final int maxStoryFrames;
  final int maxStateFrames;
  final void Function(AgentActivity activity)? onActivity;
  final void Function(AgentToolOutcome outcome)? onToolStarted;
  final void Function(AgentToolOutcome outcome)? onToolFinished;

  // ---- 运行期状态（每次 [run] 重置）----
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _history = const [];
  int _sentCursor = 0;
  final List<AgentToolOutcome> _outcomes = [];
  final List<String> _warnings = [];
  final List<String> _modelProblems = [];
  final StringBuffer _reasoning = StringBuffer();
  int _promptTokens = 0;
  int _completionTokens = 0;
  int _frames = 0;
  String _lastResponseId = '';
  String? _previousResponseId;
  String _adopted = '';
  bool _adoptedByHeading = false;
  String _lastFallback = '';
  void Function(AiStreamChunk chunk)? _sink;

  /// 正文轮截断的补救说明——**不参与**「是否需要状态轮」的判定，只在确实
  /// 进入状态轮时随首轮指令下发（为一个截断额外发一帧 `required` 只会逼模型
  /// 重复调工具）。
  final List<String> _truncationNotes = [];

  /// 最后一帧是否被服务端提前结束（决定要不要给用户一条可操作提示）。
  bool _lastFrameTruncated = false;
  String _truncateReason = '';

  /// 运行一轮 AGENT 生成。
  ///
  /// [initialInputItems]：本轮 input 的**历史 + 当前用户消息**部分；
  /// 状态快照不做预置，由模型调用 [kReadStateToolName] 自取。
  Future<AgentRoundResult> run({
    required List<Map<String, dynamic>> initialInputItems,
    required bool stream,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    _history = List<Map<String, dynamic>>.from(initialInputItems);
    _sink = onChunk;
    _resetItems();
    _outcomes.clear();
    _warnings.clear();
    _modelProblems.clear();
    _reasoning.clear();
    _promptTokens = 0;
    _completionTokens = 0;
    _frames = 0;
    _lastResponseId = '';
    _previousResponseId = null;
    _adopted = '';
    _adoptedByHeading = false;
    _lastFallback = '';
    _truncationNotes.clear();
    _lastFrameTruncated = false;
    _truncateReason = '';

    await _runStoryStage(stream, onRequestBody, isCancelled);
    final story = _adopted.isNotEmpty ? _adopted : _lastFallback;

    // 正文轮没把状态补齐 → 发起状态轮（全补齐时零额外请求）。
    var gaps = _gaps(story);
    final problems = [..._modelProblems, for (final g in gaps) g.modelText];
    final needStateTurn = story.isNotEmpty && problems.isNotEmpty;
    if (needStateTurn) {
      await _runStateStage(
        stream: stream,
        onRequestBody: onRequestBody,
        isCancelled: isCancelled,
        problems: problems,
      );
    }
    // 终态复检：仍存在的缺口 + 未修复的编辑失败，转为常驻警告。
    _warnings.clear();
    // 末帧仍被截断 → 先给用户一条可操作的根因提示（下面的缺项多是它的后果）。
    if (_lastFrameTruncated) {
      _warnings.add(
        _truncateReason == kIncompleteMaxOutputTokens
            ? '模型输出触顶被截断（状态轮思考已降为 low 并要求拆短调用重试）：'
                  '请在设置里调高「最大 token」'
            : '模型响应被服务端提前结束（$_truncateReason）',
      );
    }
    for (final g in _gaps(story)) {
      _warnings.add(g.uiText);
    }
    // 失败提示只保留**终态仍未修复**的栏目（`failedSections` 记录的正是
    // 「该栏目最后一次尝试失败」，同栏目后续成功会自动撤销登记）；
    // 已被缺口点名的栏目不重复提示。
    for (final s in workingCopy.failedSections) {
      if (_warnings.any((w) => w.startsWith(s.label))) continue;
      _warnings.add('${s.label}最后一次编辑未成功，本轮该项未落地');
    }

    return AgentRoundResult(
      content: story,
      reasoningContent: _reasoning.toString(),
      promptTokens: _promptTokens,
      completionTokens: _completionTokens,
      outcomes: _outcomes,
      warnings: _warnings,
      responseId: _lastResponseId,
      stateTurnUsed: needStateTurn,
      frames: _frames,
      incomplete: _lastFrameTruncated,
      incompleteReason: _truncateReason,
    );
  }

  /// 本轮 items 起点：历史 + 用户消息（不含状态快照——快照由模型**主动
  /// 调用 [kReadStateToolName]** 获取；见类文档「状态自取」）。
  void _resetItems() {
    _items = List<Map<String, dynamic>>.from(_history);
    _sentCursor = 0;
  }

  List<StateGap> _gaps(String story) => inspectState(
        copy: workingCopy,
        story: story,
      );

  // ---------------------------------------------------------------------------
  // 正文轮
  // ---------------------------------------------------------------------------

  Future<void> _runStoryStage(
    bool stream,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  ) async {
    for (var i = 0; i < maxStoryFrames; i++) {
      final gate = _FrameGate(stage: AgentStage.story, sink: _sink);
      final result = await _callFrame(
        stage: AgentStage.story,
        toolChoice: supportsToolChoice ? 'auto' : null,
        gate: gate,
        stream: stream,
        onRequestBody: onRequestBody,
        isCancelled: isCancelled,
      );
      _absorbFrame(result, AgentStage.story);
      await _executeTools(result, isCancelled);
      // 正文轮退出条件（一次请求即闭环，不为「等模型停手」多花一帧）：
      // - 本帧没有工具调用 → 就是终帧；
      // - 已采纳标题正文，且本帧工具**全是状态工具** → 正文已完成，
      //   补齐与否交给状态轮判定；
      // - 含搜索 / 打开页面等**喂正文**的工具 → 继续下一帧（结果必须
      //   回到上下文，模型要在下一帧写出完整正文）。
      if (result.toolCalls.isEmpty) return;
      if (_adoptedByHeading && result.toolCalls.every(_isStateCall)) return;
    }
  }

  /// 该调用是否为状态**编辑**工具（执行完即闭环；readState 是只读查阅，
  /// 不算编辑，也不参与「本帧工具全是状态工具 → 正文轮闭环」的判定）。
  bool _isStateCall(AiToolCall tc) =>
      tc.name != kReadStateToolName &&
      _byName(tc.name)?.activityType == AgentActivityType.tooling;

  // ---------------------------------------------------------------------------
  // 状态轮
  // ---------------------------------------------------------------------------

  Future<void> _runStateStage({
    required bool stream,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
    required List<String> problems,
  }) async {
    var pending = [...problems, ..._truncationNotes];
    _truncationNotes.clear();
    for (var i = 0; i < maxStateFrames; i++) {
      // 快照不再是应用预置：状态轮指令要求模型**先调用 readState**（此时
      // 工作副本 = 上一轮 + 本轮正文之后的状态），再按返回的最新块复制锚点；
      // 修复帧则复用上一帧 readState 结果与失败回传的「栏目当前全文」，
      // 不重复读取（见 [_stateDirective]）。
      _items.add(_stateDirective(pending, first: i == 0));
      _modelProblems.clear();
      final gate = _FrameGate(stage: AgentStage.state, sink: _sink);
      final result = await _callFrame(
        stage: AgentStage.state,
        toolChoice: supportsToolChoice ? 'required' : null,
        stateThinkingEffort: kAgentStateThinkingEffort,
        gate: gate,
        stream: stream,
        onRequestBody: onRequestBody,
        isCancelled: isCancelled,
      );
      _absorbFrame(result, AgentStage.state);
      await _executeTools(result, isCancelled);
      pending = List<String>.from(_modelProblems);
      if (pending.isEmpty) {
        final gaps = _gaps(_storyForChecks);
        if (gaps.isEmpty) return;
        pending = [for (final g in gaps) g.modelText];
      }
      // 只要清单还有缺项就继续下一帧修复：模型「空手帧」（只回文本/只回读
      // 取器）不再提前结束整轮——记忆/角色这类缺项应得到补修机会，帧数
      // 上限（maxStateFrames）兜底。
    }
  }

  String get _storyForChecks =>
      _adopted.isNotEmpty ? _adopted : _lastFallback;

  /// 状态轮指令（EN 在前、中文一行在后）。
  static Map<String, dynamic> _stateDirective(
    List<String> problems, {
    required bool first,
  }) {
    final head = first
        ? '[State-maintenance turn] The story is FINISHED above. This turn '
            'has NO text channel — emit nothing but tool calls. '
            'Step 1: call narrchat_readState (the returned blocks are the '
            'state AFTER this round\'s story — copy `before` anchors from '
            'them; the snapshot does NOT include the story time, which lives '
            'in the story body as `## 当前时间`). '
            'Step 2: one narrchat_editSection call per listed section. '
            'Fill in ALL listed items in one response if possible; if the '
            'output limit forces a split, do memorySummary and characterState '
            'FIRST, worldState may follow in the next frame. '
            'Prefer REAL EDITS over noChange: every line the story moved '
            '(a reaction, a thought, a move) is one op=set; noChange is only '
            'for what truly did not change. '
            '【中】状态维护轮：正文已在上方完成，本回合不产出任何文本，只调工具。'
            '第 1 步调用 narrchat_readState（返回的块 = 本轮正文**之后**的状态，'
            'before 锚点从这里复制；快照**不含时间**——时间在正文 '
            '`## 当前时间` 小节里）；'
            '第 2 步按清单逐栏目各一次 narrchat_editSection。'
            '**一次响应尽量完成清单全部项目**；若受输出限制装不下，'
            '**先做记忆总结与角色状态**，世界状态留到下一帧。'
            '**优先真实编辑而非 noChange**：正文里动过的一行（一句反应、一段心理、'
            '一次移动）就是一条 op=set；noChange 只留给确实没变的内容。'
        : '[State-maintenance turn · fix] Fix ONLY the items below, tool calls '
            'only (no text). Do NOT call narrchat_readState again — reuse the '
            'snapshot block you already have and the failure-reply full texts '
            'to re-copy anchors; only if an anchor cannot be located in them, '
            'rewrite that whole section with op=reset. Fill in ALL listed '
            'items (memorySummary and characterState first if the output '
            'limit forces a split).'
            '【中】只修复下列各项，只调工具、不要输出文本。**不要再次调用 '
            'narrchat_readState**——锚点从上一帧快照块与失败回传的栏目全文中复制；'
            '确实定位不到才用 op=reset 整栏重写。**清单必须全部完成**'
            '（装不下时优先记忆总结与角色状态）。';
    // 优先级排序：记忆（轮次义务）→ 角色 → 世界 → 其余（裁短提示也可以）：
    // 模型按清单顺序执行，把最不该漏的项放最前。
    final ordered = List<String>.from(problems)
      ..sort((a, b) => _directivePriority(a).compareTo(_directivePriority(b)));
    final trimmed = ordered.take(8).join('\n- ');
    return {
      'role': 'user',
      'content': '$head\n- $trimmed',
    };
  }

  /// 指令项的优先级（数值越小越靠前）：记忆 > 角色 > 世界 > 其他。
  static int _directivePriority(String line) {
    if (line.contains('memorySummary')) return 0;
    if (line.contains('characterState')) return 1;
    if (line.contains('worldState')) return 2;
    return 3;
  }

  // ---------------------------------------------------------------------------
  // 帧调用（含协议兼容降级）
  // ---------------------------------------------------------------------------

  Future<AiCallResult> _callFrame({
    required AgentStage stage,
    required String? toolChoice,
    required _FrameGate gate,
    required bool stream,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
    String? stateThinkingEffort,
  }) async {
    var choice = toolChoice;
    var effort = supportsThinkingEffort ? stateThinkingEffort : null;
    for (var attempt = 0;; attempt++) {
      if (isCancelled?.call() ?? false) throw const AiCancelledException();
      onActivity?.call(
        AgentActivity(
          type: AgentActivityType.turn,
          query: '',
          iteration: _frames,
        ),
      );
      final body = buildBody(
        AgentTurnRequest(
          stage: stage,
          items: _sendItems(),
          previousResponseId: chaining ? _previousResponseId : null,
          toolChoice: choice,
          stateThinkingEffort: effort,
        ),
      );
      final sentCursor = _items.length;
      try {
        final result = await call(
          body,
          stream,
          gate.process,
          onRequestBody,
          isCancelled,
        );
        _frames++;
        if (chaining) _sentCursor = sentCursor;
        return result;
      } on AiCancelledException {
        rethrow;
      } catch (e) {
        // 协议类失败：就地降级重发同一帧（同一帧至多连降 3 项），
        // 不赔上整轮预算。
        if (attempt >= 3 || e is! AiException || e.kind != AiExceptionKind.api) {
          rethrow;
        }
        final msg = e.message.toLowerCase();
        if (choice != null && msg.contains('tool_choice')) {
          supportsToolChoice = false;
          choice = null;
          continue;
        }
        if (effort != null &&
            (msg.contains('reasoning') ||
                msg.contains('thinking') ||
                msg.contains('effort'))) {
          // 服务商不接受中途调整思考强度 → 回落用户设置（不再覆盖）。
          effort = null;
          supportsThinkingEffort = false;
          continue;
        }
        if (_previousResponseId != null &&
            chaining &&
            msg.contains('previous_response_id')) {
          _previousResponseId = null;
          continue;
        }
        rethrow;
      }
    }
  }

  /// 本次要发送的 input：无状态平台全量重发；续接帧只发新增项。
  List<Map<String, dynamic>> _sendItems() =>
      (chaining && _previousResponseId != null)
          ? _items.sublist(_sentCursor)
          : _items;

  /// 吸收一帧：聚合用量 / 思考、按帧分类采纳正文、把 assistant 消息追加进
  /// 会话累积（工具条目在 [_executeTools] 中紧随其后追加）。
  void _absorbFrame(AiCallResult result, AgentStage stage) {
    _promptTokens += result.promptTokens;
    _completionTokens += result.completionTokens;
    if (result.reasoningContent.isNotEmpty) {
      _reasoning.write(result.reasoningContent);
    }
    if (result.responseId.isNotEmpty) {
      _lastResponseId = result.responseId;
      _previousResponseId = result.responseId;
    }
    if (stage == AgentStage.story) _classifyStoryFrame(result);
    _noteTruncation(result, stage);
    if (result.content.trim().isNotEmpty) {
      _items.add({'role': 'assistant', 'content': result.content});
    }
  }

  /// 帧被服务端提前结束（Responses `response.incomplete`）：记下原因并把
  /// 「拆短输出」的补救指令交给下一帧。**不改写请求体的 `max_output_tokens`**
  /// ——输出上限完全由用户在设置里决定，程序只提示、不擅改。
  void _noteTruncation(AiCallResult result, AgentStage stage) {
    _lastFrameTruncated = result.incomplete;
    if (!result.incomplete) {
      // 后续帧正常收尾 → 先前的截断原因不再对用户提示。
      _truncateReason = '';
      return;
    }
    if (chaining) {
      // 被截断的响应不能作为续接基点（服务端那半截输出本身不完整）：
      // 下一帧改为全量重发，避免服务商直接拒绝。
      _previousResponseId = null;
      _sentCursor = 0;
    }
    _truncateReason = result.incompleteReason;
    final hitCap = result.incompleteReason == kIncompleteMaxOutputTokens;
    final note = hitCap
        ? 'The previous response was TRUNCATED at the output limit. Emit FEWER '
              'and SHORTER tool calls: one editSection call per section, the '
              'minimum edits needed, never copy long text. '
              '【中】上一帧在输出上限处被截断：请减少并拆短工具调用（一个栏目一次调用、'
              'edits 尽量少、不要复制长段文本）。'
        : 'The previous response ended early (${result.incompleteReason}). '
              'Re-issue only the missing tool calls. '
              '【中】上一帧被提前结束（${result.incompleteReason}），只补齐缺失的工具调用。';
    // 状态轮：进本帧反馈通道（下一帧指令）；正文轮：只登记，避免仅因一次
    // 截断就额外触发一帧 `required`（那会逼模型重复调工具）。
    if (stage == AgentStage.state) {
      _modelProblems.add(note);
    } else {
      _truncationNotes.add(note);
    }
  }

  /// 帧级正文分类（见类文档表格）。
  void _classifyStoryFrame(AiCallResult result) {
    final content = result.content;
    if (content.trim().isEmpty) return;
    final hasHeading = AiResponseParser.storyHeadingStart(content) != null;
    if (hasHeading) {
      // 最后一个标题帧胜出（门控已在该帧正文首次出现时发出重置信号）。
      _adopted = _stripStateSectionsIn(content);
      _adoptedByHeading = true;
    } else if (result.toolCalls.isNotEmpty) {
      // 开场白（「Let me search …」/ 读取帧）：不上屏、不采纳、不阻塞真正正文。
      _lastFallback = content;
      return;
    } else if (!_adoptedByHeading && _adopted.isEmpty) {
      // 无标题 + 无工具：模型未按格式输出的正文 → 兜底采纳（防故事丢失）。
      _adopted = _stripStateSectionsIn(content);
    }
    // 当前时间属于正文：从采纳的正文解析 `## 当前时间` 写入工作副本
    // （缺失时沿用上一轮时间，不算缺口——时间不归工具管）。
    final storyTime =
        AiResponseParser.parse(_adopted).currentTime.trim();
    if (storyTime.isNotEmpty) {
      workingCopy.currentTime = storyTime;
    }
  }

  /// 状态类二级标题（正文里禁止出现的段；`## 当前时间` 是合法正文段）。
  static const List<String> _bannedStoryHeadings = [
    '世界状态',
    '角色状态',
    '记忆总结',
  ];

  /// 正文采纳后的兜底清洗：模型违规模仿 Chat 格式、把状态区块写进正文时，
  /// 剥离自状态类 `## 标题` 起、到下一个 `##` 标题为止的段落，保住正文唯一性。
  static String _stripStateSectionsIn(String content) {
    final lines = content.split('\n');
    final kept = <String>[];
    var skipping = false;
    for (final line in lines) {
      if (line.startsWith('## ')) {
        final head = line.substring(3).trim();
        skipping = _bannedStoryHeadings.any(head.startsWith);
      }
      if (!skipping) kept.add(line);
    }
    return kept.join('\n');
  }

  /// 执行一帧的全部工具调用（并行语义：逐个执行，条目按调用顺序回传）。
  Future<void> _executeTools(
    AiCallResult result,
    bool Function()? isCancelled,
  ) async {
    for (final tc in result.toolCalls) {
      if (isCancelled?.call() ?? false) throw const AiCancelledException();
      final tool = _byName(tc.name);
      final summary = _argsSummary(tc.name, tc.arguments);
      final isStateTool = tc.name != kReadStateToolName &&
          tool?.activityType == AgentActivityType.tooling;
      final subject = _subject(tc, summary);
      final outcome = tc.argumentsUnparsable
          ? AgentToolOutcome(
              name: tc.name,
              callId: tc.id,
              argsSummary: summary,
              subject: subject,
              applied: false,
              message: '工具参数被截断（JSON 不完整），未执行',
              modelOutput:
                  '[EN] Your tool-call arguments were TRUNCATED (invalid '
                      'JSON), so nothing was applied. Call again with ONE '
                      'call per section and FEWER edits per call. '
                      '【中】工具参数被截断（JSON 不完整），本次未执行：'
                      '请一次只改一个栏目、单次 edits 条数更少。',
              isStateTool: isStateTool,
            )
          : await _runTool(tc, tool, summary, subject, isStateTool);
      _outcomes.add(outcome);
      // 工具卡片收口：完成 / 失败状态与一行结果说明（缺少这一步，UI 的
      // 工具框会永远停在「正在执行…」）。
      onToolFinished?.call(outcome);
      if (!outcome.applied && isStateTool) {
        _modelProblems.add('${tc.name} → ${outcome.modelOutput}');
      }
      _appendCallItems(tc, outcome);
    }
  }

  Future<AgentToolOutcome> _runTool(
    AiToolCall tc,
    NarrAgentTool? tool,
    String summary,
    String subject,
    bool isStateTool,
  ) async {
    onActivity?.call(
      AgentActivity(
        type: tool?.activityType ?? AgentActivityType.searching,
        query: summary,
        iteration: _frames,
      ),
    );
    onToolStarted?.call(
      AgentToolOutcome(
        name: tc.name,
        callId: tc.id,
        argsSummary: summary,
        subject: subject,
        applied: false,
        message: '',
        isStateTool: isStateTool,
      ),
    );
    if (tool == null) {
      return AgentToolOutcome(
        name: tc.name,
        callId: tc.id,
        argsSummary: summary,
        subject: subject,
        applied: false,
        message: '未知工具：${tc.name}',
        isStateTool: isStateTool,
      );
    }
    final result = await tool.run(tc.arguments);
    return AgentToolOutcome(
      name: tc.name,
      callId: tc.id,
      argsSummary: summary,
      subject: subject,
      applied: result.success,
      message: result.summary.isEmpty ? _oneLine(result.content) : result.summary,
      modelOutput: result.content,
      isStateTool: isStateTool,
    );
  }

  /// 追加 `function_call` + `function_call_output` 条目（重放必须用 `call_id`）。
  void _appendCallItems(AiToolCall tc, AgentToolOutcome outcome) {
    _items.add({
      'type': 'function_call',
      'call_id': tc.id,
      'name': tc.name,
      'arguments': jsonEncode(tc.arguments),
    });
    _items.add({
      'type': 'function_call_output',
      'call_id': tc.id,
      'output': outcome.modelOutput,
    });
    if (tc.name == kReadStateToolName) _pruneStaleReadState(tc.id);
  }

  /// 只保留**最新一份** readState 结果：旧快照（上一轮 / 前一帧读取的）在
  /// 新读取生效后失去时效，继续留在上下文中只会推高输入并诱导模型用过时锚点。
  ///
  /// 快照条目成对出现（`function_call` + `function_call_output`），
  /// 且只可能存在于 `_history` 之后（历史消息不含状态快照），逐个剔除即可。
  void _pruneStaleReadState(String currentCallId) {
    final kept = <Map<String, dynamic>>[];
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item['type'] == 'function_call' &&
          item['name'] == kReadStateToolName &&
          item['call_id'] != currentCallId) {
        // 跳过紧随其后的 function_call_output 条目。
        i++;
        continue;
      }
      kept.add(item);
    }
    _items
      ..clear()
      ..addAll(kept);
  }

  /// 工具卡片摘要行（UI 不展示回传模型的整份栏目全文）。
  static String _oneLine(String text) {
    final t = text.trim();
    if (t.isEmpty) return '';
    final nl = t.indexOf('\n');
    return nl < 0 ? t : '${t.substring(0, nl)}…';
  }

  /// 事件主体：搜索工具取 query、打开页面取 url，其余回退参数摘要。
  static String _subject(AiToolCall tc, String fallback) {
    final query = tc.arguments['query'];
    if (query is String && query.trim().isNotEmpty) return query.trim();
    final url = tc.arguments['url'];
    if (url is String && url.trim().isNotEmpty) return url.trim();
    return fallback;
  }

  NarrAgentTool? _byName(String name) {
    for (final t in tools) {
      if (t.name == name) return t;
    }
    return null;
  }

  static String _argsSummary(String name, Map<String, dynamic> arguments) {
    if (arguments.isEmpty) return name;
    final parts = arguments.entries
        .map((e) => '${e.key}=${_short(e.value)}')
        .take(3)
        .join('；');
    return '$name（$parts）';
  }

  static String _short(Object? v) {
    final s = v is String ? v : v.toString();
    return s.length <= 20 ? s : '${s.substring(0, 20)}…';
  }
}

/// 帧级正文门控：把模型的原始 chunk 流转换成界面可安全消费的流。
///
/// - 正文轮：帧内容先缓冲，出现 `## 剧情演绎` 标题才开始上屏（从标题处起），
///   开场白永不可见；每帧首次上屏前先发 [AiStreamChunk.narrativeReset]，
///   使「后到的完整标题帧覆盖前一帧」在界面上表现为正文块重置重流；
/// - 状态轮：**文本通道关闭**，正文增量一律丢弃。
class _FrameGate {
  _FrameGate({required this.stage, required this.sink});

  final AgentStage stage;
  final void Function(AiStreamChunk chunk)? sink;

  final StringBuffer _buffer = StringBuffer();
  bool _published = false;

  void process(AiStreamChunk chunk) {
    final emit = sink;
    if (chunk.contentDelta.isEmpty) {
      emit?.call(chunk);
      return;
    }
    if (stage == AgentStage.state) return;
    _buffer.write(chunk.contentDelta);
    if (_published) {
      emit?.call(chunk);
      return;
    }
    final start = AiResponseParser.storyHeadingStart(_buffer.toString());
    if (start == null) return;
    _published = true;
    emit?.call(const AiStreamChunk(narrativeReset: true));
    emit?.call(
      AiStreamChunk(contentDelta: _buffer.toString().substring(start)),
    );
  }
}
