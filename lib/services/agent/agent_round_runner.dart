import 'dart:convert';

import '../../utils/memory_entry_format.dart';
import '../ai_response_parser.dart';
import '../ai_service.dart';
import '../memory_merge_planner.dart';
import '../prompt_interface.dart';
import '../request_frame_outline.dart';
import 'agent_activity.dart';
import 'agent_mode_profile.dart';
import 'narr_agent_tool.dart';
import 'reasoning_replay.dart';
import 'state/agent_state_working_copy.dart';
import 'state/state_coverage.dart';
import 'state/state_tools.dart';
import 'wire_adapters.dart';

/// 维护步（含其修复回合）的最大回合数：1 主回合 + 3 修复回合。
const int kAgentMaxStateFrames = 4;

/// **第一步·调研**的最大回合数：读史 → 联网搜索 / 打开页（可多步），
/// 联网一次典型消耗 3 个回合（读史 + 搜索 + 打开页），再留空间给搜索上的重试。
const int kAgentMaxPrepFrames = 6;

/// 第一步·正文的最大回合数（联网搜索会消耗多回合：开场白 → 搜索 → 打开页 → 正文）。
const int kAgentMaxStoryFrames = 8;

/// 输出触顶的原因标识（Responses `incomplete_details.reason`）。
const String kIncompleteMaxOutputTokens = 'max_output_tokens';

/// 执行器运行阶段。
///
/// 一轮 = 两步，步下面是**回合**（一次请求—响应，执行器内部旧称「帧」）：
/// - 第一步：调研（[prepare]）→ 正文（[story]）；
/// - 第二步：状态维护（[state]，正文完成后单独发新请求）。
enum AgentStage {
  /// **第一步·调研**：读历史（`narrchat_readHistory` 一次）+
  /// 按需联网搜索 / 打开页（可多步）。**不写记忆、不写正文**；
  /// 本阶段文本一律不采纳。
  ///
  /// 退出条件：本回合没有工具调用（调研结束）；或本回合工具**只有读取器**
  /// （读完历史、没有联网意图 → 立刻进入正文；或本回合工具全是编辑器
  /// （模型跳步抢写状态，编辑会被拒绝，正文照样继续））。
  prepare,

  /// **第一步·正文**：产出本轮正文（唯一的正文采纳与上屏阶段）。
  /// 状态编辑在第一步一律被拒绝，记忆维护留到第二步。
  story,

  /// **第二步·状态维护**：正文完成后**单独发新请求**，只调工具维护
  /// **记忆总结**；文本通道只进维护流式框，绝不进入正文。
  /// 维护失败 / 取消不丢正文，最终由调用方落库并挂黄框提示。
  state,
}

/// 一次帧请求的上下文（由 `buildBody` 组装成实际请求体）。
///
/// **思考强度不在帧上下文中**：本执行器不为任何阶段覆盖 `reasoning_effort` /
/// 思考开关，全部帧一律沿用用户设置（帧间差异只有 [items] 与
/// [previousResponseId]，见类文档「前缀一致性」）。
class AgentTurnRequest {
  const AgentTurnRequest({
    required this.stage,
    required this.items,
    this.previousResponseId,
  });

  final AgentStage stage;

  /// 本次要发送的 input（无状态平台 = 全量累积；有状态续接 = 仅新增项）。
  final List<Map<String, dynamic>> items;
  final String? previousResponseId;
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

  /// 是否应用成功（状态工具校验失败 → 工具框 / 维护回合反馈）。
  final bool applied;

  /// **UI** 结果说明（一行摘要）。
  final String message;

  /// **回传模型**的结果全文（状态工具含该栏目当前全文）。
  final String modelOutput;

  /// 是否状态类工具（校验失败走工具框 / 维护回合语义）。
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
  /// 本轮正文：**正文阶段**最后一个**标题帧**的原始内容（无标题帧时以
  /// 「无标题 + 无工具」帧兜底；正文阶段整段没产出内容时为空）。
  final String content;

  /// 聚合思考内容。
  final String reasoningContent;

  /// 聚合 Token 用量（各帧同桶累加；全帧都未带回该字段 → null = 无数据）。
  final int? promptTokens;
  final int? completionTokens;

  /// 聚合缓存命中输入 token（服务商未返回该字段 → null）。
  final int? cachedTokensIn;

  /// 全部工具调用结果（按执行顺序）。
  final List<AgentToolOutcome> outcomes;

  /// 状态轮跑满仍被跳过（钳制）的缺口说明（中文一行，UI 展示）。
  final List<String> warnings;

  /// 最后一次响应的 responseId（无状态平台为空）。
  final String responseId;

  /// 第二步维护是否真正完成：本轮记忆条目恰好一条、档位要求的合并已落地、
  /// 且维护期间没有失败 / 取消。
  final bool maintenanceCompleted;

  /// 第二步维护是否被用户取消（正文仍会由调用方落库并挂警告）。
  final bool maintenanceCancelled;

  /// 本轮**最后一回合**是否被服务端提前结束（截断）。
  final bool incomplete;

  /// 截断原因（`max_output_tokens` / `content_filter` / …；空 = 未截断）。
  final String incompleteReason;

  /// 本轮**所有步、所有回合**的总回合数（调研 + 正文 + 维护，含修复回合）。
  final int frames;

  const AgentRoundResult({
    required this.content,
    required this.reasoningContent,
    required this.promptTokens,
    required this.completionTokens,
    required this.cachedTokensIn,
    required this.outcomes,
    required this.warnings,
    required this.responseId,
    required this.maintenanceCompleted,
    required this.maintenanceCancelled,
    required this.frames,
    this.incomplete = false,
    this.incompleteReason = '',
  });
}

/// AGENT 单轮执行器（Responses 协议 + 状态自取 + 两步流程）。
///
/// ## 术语：轮 → 步 → 回合
///
/// - **轮**：一次用户发送到最终落库的一条 `Round`；
/// - **步**：一轮内的两个生成步骤；
/// - **回合**：一次 AI 请求—响应（代码里的 frame），是最基础单元。
///
/// ## 档位（[AgentModeProfile]）
///
/// 当前唯一的 Agent 档位（Lv.1）为**两步流程**，差异全部来自 [profile]
/// （不在本类里散落档位判断）。世界状态 / 角色状态随正文文本携带，
/// **只有历史（记忆总结）走工具**：
/// 1. **第一步·调研**（[AgentStage.prepare]）：`narrchat_readHistory` 读一次 +
///    按需联网搜索 / 打开页（可多步）；**不写记忆、不写正文**，本步文本一律
///    不采纳。读完历史那一回合即结束（无联网意图时不必再等模型收手）。
/// 2. **第一步·正文**（[AgentStage.story]）：调研结束后**立刻**写 5 区块正文；
///    状态编辑在第一步一律被拒绝，记忆维护留到第二步。
/// 3. **第二步·状态维护**（[AgentStage.state]）：正文完成后**单独发新请求**，
///    只根据正文的 `## 当前时间` 用 `op=append` 落**恰好一条**本轮记忆条目；
///    维护失败 / 取消不丢正文，由调用方统一落库并挂黄框。
///
/// 所有步都只累积在内存里；调用方在 [run] 返回后**统一入库一次**，token 取
/// 所有回合的总和。历史上的完整 Agent（Lv.2：正文三小节 + 六个状态工具）已移除。
///
/// ## 为什么分两步
///
/// 旧版把「写正文」与「调状态工具」塞进同一响应，靠提示词命令模型
/// 「正文先行、工具随后」——这与工具型模型「先调工具、再答」的先验相反；
/// 加上续接帧不回传模型自己刚写的正文，导致一次请求里反复生成多份正文。
/// 现在每步各自只有一个正确动作：
///
/// 1. **第一步·调研**（[AgentStage.prepare]）：读史 + 联网，只备事实依据。
/// 2. **第一步·正文**（[AgentStage.story]）：基于调研结果写正文；
///    `## 当前时间` 是正文小节（时间不属于工具）。
/// 3. **第二步·维护**（[AgentStage.state]）：正文已写完，单独维护记忆总结；
///    维护文本只进流式维护框，不会成为正文。
///
/// 记忆条目从正文派生（正文里的 `## 当前时间` 就是条目时间），不再要求模型
/// 先凭大纲写记忆、再让正文与大纲对齐；偏差更小，也省掉一次长上下文回读。
///
/// 工具调用完全靠**提示词纪律 + 工具描述**驱动（回合指令明确要求本回合直接调用
/// 对应编辑器），**不发送 `tool_choice`**：部分服务商在思考模式下以 400 拒绝该
/// 参数（`Thinking mode does not support this tool_choice`），而回合语义并不依赖
/// 它——缺项由完整性判定与维护修复回合兜底。
///
/// ## 状态自取（快照不作预置）
///
/// 早期版本由应用把状态快照预置成「工具输出」喂给模型，模型把 `<time>` /
/// `<worldState>` 等 md 块当成**可模仿的输出格式**——要么照格式堆进正文
/// （Chat 式预期表现），要么写完正文又调工具，困惑「我不是都写了吗」。
/// 现在读取器是**真实注册的只读工具**（每个栏目一个），模型必须主动调用才
/// 拿得到状态：
///
/// - 调用时机由模型承担，但**返回值语义统一** = 工作副本当前渲染（第一步调用
///   → 上一轮库内状态；维护步调用 → 正文之后的状态），应用侧不需要从调用序列
///   推断「这是哪一步」；
/// - 读取结果以 `function_call_output` 形态进入上下文（**工具结果，
///   不是输出格式**，不再诱发格式模仿）；
/// - 每栏**只保留最新一份**读取结果（[_pruneStaleReadState]，按工具名剔除），
///   修复回合不再重复读取（指令明示复用已有结果与失败回传全文），
///   每轮输入不会随修复回合数线性膨胀；
/// - 维护步对「本轮已提供全文的栏目」的读取一律被拒
///   （[_refusedRepeatRead]）：写正文不改变状态，调研步那一份就是唯一正确的
///   锚点来源；第一步漏读时仍允许补读；
/// - 正文采纳时还会**剥离**正文里出现的、由工具维护的状态类二级标题段
///   （模型违规模仿格式的兜底清洗，见 [_stripStateSectionsIn]；
///   当前档位只剥离 `## 记忆总结`，世界 / 角色本就是正文的一部分）。
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
/// **只有 [AgentStage.story] 参与分类**：调研 / 维护回合的正文（模型跳步抢写）
/// 一律丢弃，且进入正文步前会清空候选，保证采纳的正文与维护内容互不污染。
/// 门控在每帧正文首次上屏前发 [AiStreamChunk.narrativeReset]，界面重置正文块。
///
/// ## 会话累积（修复帧不再「失忆」）
///
/// 每帧结束后把 `reasoning`（思考块）+ `assistant(正文)` + `function_call` +
/// `function_call_output` 追加进 `_items`：续接帧因此看得见自己刚写过的正文
/// ——这是旧版多份正文的直接病根（只重放 function_call）。
///
/// 思考块按**每个工具调用各一块**回传（[_appendCallItems]）：请求携带 `tools`
/// 时服务商逐块校验，任何 `function_call` 少了紧邻其前的非空 `reasoning` 即
/// 整次 400（DeepSeek 思考模式返回「The `reasoning_text` in the thinking mode
/// must be passed back to the API」）。
///
/// ## 前缀一致性（成本）
///
/// 各阶段共用完全相同的 `instructions` 与 `tools`（超集），只在尾部追加
/// item，服务商的上下文缓存前缀保持命中（读取结果替换同栏旧份发生在
/// 共享前缀之后，不影响命中）。
///
/// ## 兼容性降级（绝不消耗用户的整轮预算）
///
/// 运行中遇到协议类失败就地重发同一帧（同一帧至多连降 3 项）：
/// 拒绝 `previous_response_id` → 本轮全量重发。
/// 只有内容校验类失败才走修复帧。
///
/// **思考强度全程沿用用户设置**：本执行器不覆盖 `reasoning_effort` / 思考开关
/// （历史上记忆 / 维护回合曾降到 `low`，现取消——用户设置就是唯一真源），
/// 因此也不存在「服务商拒绝中途调整强度」这类降级分支。
///
/// ## 截断（`response.incomplete`）
///
/// 维护回合输出的是逐字锚点的工具参数 JSON，而思考 token 同样计入输出
/// 上限，极易触顶。触顶**不是失败**：底层保留截断前的部分结果并标记
/// [AiCallResult.incomplete]，本执行器据此（1）给下一帧补一条「拆短输出」
/// 指令，（2）末帧仍截断时给用户一条可操作提示（由用户在设置里调高
/// 「最大 token」，程序不擅自改动请求体的 `max_output_tokens`，也不擅自改
/// 思考强度）。绝不因一帧截断赔掉整轮正文。
class AgentRoundRunner {
  AgentRoundRunner({
    required this.buildBody,
    required this.call,
    required this.tools,
    required this.workingCopy,
    required this.profile,
    this.memoryMergePlan,
    this.chaining = false,
    this.maxPrepFrames = kAgentMaxPrepFrames,
    this.maxStoryFrames = kAgentMaxStoryFrames,
    this.maxStateFrames = kAgentMaxStateFrames,
    this.reduceReasoningReplay = false,
    this.onStageStarted,
    this.onTurnStarted,
    this.onActivity,
    this.onToolStarted,
    this.onToolFinished,
  });

  /// 组装一次帧请求体（各阶段共用同一 instructions / tools 超集）。
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

  /// 档位档案（决定正文契约、参与缺口的栏目；当前唯一档位走两步流程）。
  final AgentModeProfile profile;

  /// 本轮应执行的「记忆总结轮次合并」动作（档位 0 / 无动作时为 null）。
  ///
  /// 由调用方在生成前算定（输入 = 上一轮落库的记忆总结 + 本书档位，见
  /// `memory_merge_planner.dart`）：Agent 期间并入第二步维护指令并计入
  /// [_maintenanceSatisfied] 门槛，终态未落地转常驻警告。
  final MemoryMergePlan? memoryMergePlan;

  final bool chaining;

  /// 调研步的最大回合数：读史 + 联网搜索 / 打开页。
  final int maxPrepFrames;

  /// 正文步的最大回合数。
  final int maxStoryFrames;

  /// 维护步的最大回合数：1 主回合 + 修复回合。
  final int maxStateFrames;

  /// 回传思考时是否精简（默认关 = 逐字节回传原文）。规则见 `reasoning_replay.dart`。
  final bool reduceReasoningReplay;

  /// 某个步开始时回调（UI 据此显示「状态维护中」等状态）。
  final void Function(AgentStage stage)? onStageStarted;

  /// 某个**回合**真正开始调用前回调：`stage` + 该步内第几回合（1-based）。
  /// 供 RAW 记录「轮 → 步 → 回合」；重试 / 协议降级不会重复回调。
  final void Function(AgentStage stage, int turnIndex)? onTurnStarted;

  final void Function(AgentActivity activity)? onActivity;
  final void Function(AgentToolOutcome outcome)? onToolStarted;
  final void Function(AgentToolOutcome outcome)? onToolFinished;

  /// 阶段回合指令 / 工具集的**唯一取用入口**（`prompt_interface.dart`，当前绑定 v2）：
  /// 执行器只决定「何时发哪一帧」，帧指令文案与工具清单都由接口层给出。
  static const PromptInterface _prompt = promptInterface;

  // ---- 运行期状态（每次 [run] 重置）----
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _history = const [];
  int _sentCursor = 0;
  final List<AgentToolOutcome> _outcomes = [];
  final List<String> _warnings = [];
  final List<String> _modelProblems = [];
  final StringBuffer _reasoning = StringBuffer();
  int? _promptTokens;
  int? _completionTokens;
  int? _cachedTokensIn;
  int _frames = 0;
  String _lastResponseId = '';
  String? _previousResponseId;
  String _adopted = '';
  bool _adoptedByHeading = false;
  String _lastFallback = '';
  void Function(AiStreamChunk chunk)? _sink;

  /// 正文回合截断的补救说明——**不参与**「是否需要维护回合」的判定，只在确实
  /// 进入维护回合时随首回合指令下发（为一个截断额外发一回合 `required` 只会逼模型
  /// 重复调工具）。
  final List<String> _truncationNotes = [];

  /// 本帧已产出、尚未随工具调用发出的思考块（见 [_appendCallItems]）。
  List<AiReasoningItem> _frameReasoning = const [];

  /// 最后一帧是否被服务端提前结束（决定要不要给用户一条可操作提示）。
  bool _lastFrameTruncated = false;
  String _truncateReason = '';

  /// 第二步维护是否被用户取消 / 是否发生异常（正文仍会落库）。
  bool _maintenanceCancelled = false;
  String? _maintenanceError;

  /// 开始一轮：设定输入起点并重置全部运行期状态。
  ///
  /// [run] 与 [outlineFrames] 共用——预览的首帧因此与实发首帧同源。
  void _beginRound(List<Map<String, dynamic>> initialInputItems) {
    _history = List<Map<String, dynamic>>.from(initialInputItems);
    _resetItems();
    _outcomes.clear();
    _warnings.clear();
    _modelProblems.clear();
    _reasoning.clear();
    _promptTokens = null;
    _completionTokens = null;
    _cachedTokensIn = null;
    _frames = 0;
    _lastResponseId = '';
    _previousResponseId = null;
    _adopted = '';
    _adoptedByHeading = false;
    _lastFallback = '';
    _truncationNotes.clear();
    _lastFrameTruncated = false;
    _truncateReason = '';
    _maintenanceCancelled = false;
    _maintenanceError = null;
    _frameReasoning = const [];
    _sectionsProvided.clear();
    _firstStepTurns = 0;
    _maintenanceTurns = 0;
  }

  /// 运行一轮 AGENT 生成。
  ///
  /// [initialInputItems]：本轮 input 的**历史 + 当前用户消息**部分；
  /// 状态不做预置，由模型调用各栏目读取器（[AgentModeProfile.toolSections]）
  /// 自取。
  Future<AgentRoundResult> run({
    required List<Map<String, dynamic>> initialInputItems,
    required bool stream,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    _beginRound(initialInputItems);
    _sink = onChunk;

    // 当前唯一的 Agent 档位（Lv.1）= 两步流程：
    // 第一步「调研 → 正文」；第二步「状态维护」作为单独的新请求。
    // 所有步都只累积在内存里，由调用方在 [run] 返回后统一落库。
    onStageStarted?.call(AgentStage.prepare);
    await _runPrepareStage(stream, onRequestBody, isCancelled);
    onStageStarted?.call(AgentStage.story);
    await _runStoryStage(stream, onRequestBody, isCancelled);
    final story = _adopted.isNotEmpty ? _adopted : _lastFallback;

    // 第二步：维护记忆总结。**无条件**发起（合规流程也要写本轮条目）；
    // 维护失败 / 取消都只转成警告，不丢正文。
    if (story.isNotEmpty) {
      final problems = [..._modelProblems, ..._truncationNotes];
      _truncationNotes.clear();
      onStageStarted?.call(AgentStage.state);
      try {
        await _runStateStage(
          stream: stream,
          onRequestBody: onRequestBody,
          isCancelled: isCancelled,
          problems: problems,
        );
      } on AiCancelledException {
        _maintenanceCancelled = true;
      } catch (e) {
        // 维护是正文之后的独立步骤：失败不能让整轮正文作废。
        _maintenanceError = '$e';
      }
    }

    // 终态复检：维护失败 / 取消 + 仍存在的缺口 + 未修复的编辑失败 → 警告。
    _warnings.clear();
    if (_maintenanceCancelled) {
      _warnings.add('状态维护已中断（本轮正文已保存，记忆总结未补全）');
    } else if (_maintenanceError != null) {
      _warnings.add('状态维护未完成（本轮正文已保存）：$_maintenanceError');
    }
    // 末回合仍被截断 → 先给用户一条可操作的根因提示（下面的缺项多是它的后果）。
    if (_lastFrameTruncated) {
      _warnings.add(
        _truncateReason == kIncompleteMaxOutputTokens
            ? '模型输出触顶被截断（已要求模型拆短调用重试）：'
                  '请在设置里调高「最大 token」'
            : '模型响应被服务端提前结束（$_truncateReason）',
      );
    }
    for (final g in _gaps(story)) {
      _warnings.add(g.uiText);
    }
    // 记忆合并终态仍未落地 → 常驻警告（不阻断本轮正文）。
    final mergePlan = memoryMergePlan;
    if (mergePlan != null &&
        !isMemoryMergeApplied(workingCopy.memorySummary, mergePlan)) {
      _warnings.add(mergePlan.uiText);
    }
    // 失败提示只保留**终态仍未修复**的栏目（`failedSections` 记录的正是
    // 「该栏目最后一次尝试失败」，同栏目后续成功会自动撤销登记）；
    // 已被缺口点名的栏目不重复提示。
    for (final s in workingCopy.failedSections) {
      if (_warnings.any((w) => w.startsWith(s.label))) continue;
      _warnings.add('${s.label}最后一次编辑未成功，本轮该项未落地');
    }

    final maintenanceCompleted = story.isNotEmpty &&
        !_maintenanceCancelled &&
        _maintenanceError == null &&
        _maintenanceSatisfied();

    return AgentRoundResult(
      content: story,
      reasoningContent: _reasoning.toString(),
      promptTokens: _promptTokens,
      completionTokens: _completionTokens,
      cachedTokensIn: _cachedTokensIn,
      outcomes: _outcomes,
      warnings: List.unmodifiable(_warnings),
      responseId: _lastResponseId,
      maintenanceCompleted: maintenanceCompleted,
      maintenanceCancelled: _maintenanceCancelled,
      frames: _frames,
      incomplete: _lastFrameTruncated,
      incompleteReason: _truncateReason,
    );
  }

  /// 本轮 items 起点：历史 + 用户消息（不含状态——状态由模型**主动调用
  /// 各栏读取器**获取；见类文档「状态自取」）。
  void _resetItems() {
    _items = List<Map<String, dynamic>>.from(_history);
    _sentCursor = 0;
  }

  List<StateGap> _gaps(String story) => inspectState(
        copy: workingCopy,
        story: story,
        // 只判定本档位由工具维护的栏目（当前档位 = 仅历史）。
        sections: profile.toolSections,
        // 懒修改检查只对「角色状态由工具维护」的档位有意义；当前档位不注册
        // 角色栏目，故恒为 false（角色工具与检查保留为框架）。
        checkLazy:
            profile.toolSections.contains(AgentStateSection.characterState),
      );

  // ---------------------------------------------------------------------------
  // 调研阶段（读史 + 按需联网）
  // ---------------------------------------------------------------------------

  /// 调研步：模型读历史（一次）、按需联网搜索 / 打开页（可多步）。
  ///
  /// **不产出记忆、不产出正文**：本步只负责把「事实依据」（历史锚点 +
  /// 现实资料）备齐，模型在该步写什么都一律丢弃——文本通道在此
  /// **不上屏、不采纳**（[_FrameGate] 只对正文回合放行，[_absorbFrame] 也只对
  /// 正文回合做分类）。调研结束后由 `run` 立刻进入正文步。
  ///
  /// 首回合先追加 `promptInterface.stagePrepare`（与系统契约同一真源），
  /// 把「本步只做调研」说在最近处。
  ///
  /// 退出条件（三者任一）：
  /// 1. 本回合**没有工具调用**（调研结束）；
  /// 2. 本回合工具**只有读取器**（`narrchat_readHistory`）——读完历史且没有联网
  ///    意图，立刻进入正文；若模型读完史才发现要联网，它可以在正文回合调搜索
  ///    工具（工具集是超集，执行器照常执行，随后正文继续）；
  /// 3. 本回合工具**全是编辑器**（模型跳步抢写状态）——编辑器在第一步一律被
  ///    拒绝，本回合文本同样丢弃，随后照常进入正文。
  Future<void> _runPrepareStage(
    bool stream,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  ) async {
    _appendStageDirective(AgentStage.prepare);
    for (var i = 0; i < maxPrepFrames; i++) {
      final gate = _FrameGate(stage: AgentStage.prepare, sink: _sink);
      final result = await _callFrame(
        stage: AgentStage.prepare,
        gate: gate,
        stream: stream,
        onRequestBody: onRequestBody,
        isCancelled: isCancelled,
      );
      _absorbFrame(result, AgentStage.prepare);
      await _executeTools(result, isCancelled, AgentStage.prepare);
      if (result.toolCalls.isEmpty) return;
      if (result.toolCalls.every(_isEditToolCall)) return;
      if (result.toolCalls.every(_isReadToolCall)) return;
    }
  }

  // ---------------------------------------------------------------------------
  // 正文阶段
  // ---------------------------------------------------------------------------

  /// 正文只在正文阶段产生：清空调研阶段可能留下的候选（模型跳步抢写的正文
  /// 一律作废）。状态编辑在第一步被拒绝，记忆是否齐全由维护步判定。
  Future<void> _runStoryStage(
    bool stream,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  ) async {
    _adopted = '';
    _adoptedByHeading = false;
    _lastFallback = '';
    _modelProblems.clear();
    // 把「调研已结束、现在只写五个区块、记忆留到下一步」说在最近处
    // （文案真源 = `promptInterface.stageStory`，与系统契约口径一致）。
    _appendStageDirective(AgentStage.story);
    for (var i = 0; i < maxStoryFrames; i++) {
      final gate = _FrameGate(stage: AgentStage.story, sink: _sink);
      final result = await _callFrame(
        stage: AgentStage.story,
        gate: gate,
        stream: stream,
        onRequestBody: onRequestBody,
        isCancelled: isCancelled,
      );
      _absorbFrame(result, AgentStage.story);
      await _executeTools(result, isCancelled, AgentStage.story);
      // 正文步退出条件（一次请求即闭环，不为「等模型停手」多花回合）：
      // - 本回合没有工具调用 → 就是终回合；
      // - 已采纳标题正文，且本回合工具**全是状态编辑器** → 正文已完成，
      //   编辑器已被拒绝，补齐记忆交给第二步判定；
      // - 含搜索 / 打开页面等**喂正文**的工具 → 继续下一回合（结果必须
      //   回到上下文，模型要在下一回合写出完整正文）。
      if (result.toolCalls.isEmpty) return;
      if (_adoptedByHeading && result.toolCalls.every(_isEditToolCall)) return;
    }
  }

  /// 该调用是否为状态**编辑**工具（执行完即闭环；读取器是只读查阅，
  /// 不算编辑，也不参与「本回合工具全是编辑器 → 步闭环」的判定）。
  bool _isEditToolCall(AiToolCall tc) {
    final tool = _byName(tc.name);
    return tool != null &&
        !tool.isReadOnly &&
        tool.activityType == AgentActivityType.tooling;
  }

  /// 该调用是否为**只读读取器**（调研步的结束信号：本回合只读了历史 =
  /// 调研结束，立刻进入正文；搜索 / 打开页不是读取器，会把调研步留住）。
  bool _isReadToolCall(AiToolCall tc) => _byName(tc.name)?.isReadOnly ?? false;

  // ---------------------------------------------------------------------------
  // 第二步：状态维护（正文之后单独的新请求）
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
      // 维护步只维护记忆总结：读取结果优先复用第一步；第一步漏读时才允许补读。
      // 修复回合复用上一回合的失败回传与栏目全文，不重复读取。
      _appendStageDirective(AgentStage.state, first: i == 0, problems: pending);
      _modelProblems.clear();
      final gate = _FrameGate(stage: AgentStage.state, sink: _sink);
      final result = await _callFrame(
        stage: AgentStage.state,
        gate: gate,
        stream: stream,
        onRequestBody: onRequestBody,
        isCancelled: isCancelled,
      );
      _absorbFrame(result, AgentStage.state);
      await _executeTools(result, isCancelled, AgentStage.state);
      pending = List<String>.from(_modelProblems);
      if (pending.isEmpty) {
        final gaps = _gaps(_storyForChecks);
        pending = [for (final g in gaps) g.modelText];
      }
      // 档位要求的记忆合并仍未落地 → 继续修复回合（与缺口同一循环、同一上限）。
      if (pending.isEmpty && !_hasPendingMemoryMerge && _maintenanceSatisfied()) {
        return;
      }
      // 只要清单还有缺项 / 记忆仍不完整就继续下一回合修复：模型「空手回合」
      // （只回文本 / 只试探读取）不再提前结束维护——上限兜底。
    }
  }

  /// 维护完成判定（应用侧事实）：历史栏被真实编辑过、当前没有失败登记、
  /// **恰好一条**本轮（轮次 = N）条目，且档位要求的合并已落地。
  bool _maintenanceSatisfied() {
    const section = AgentStateSection.memorySummary;
    if (!workingCopy.touchedSections.contains(section) ||
        workingCopy.failedSections.contains(section) ||
        memoryEntryCount(workingCopy.memorySummary, workingCopy.roundIndex) != 1) {
      return false;
    }
    final plan = memoryMergePlan;
    return plan == null || isMemoryMergeApplied(workingCopy.memorySummary, plan);
  }

  /// 是否仍有未落地的「记忆合并」要求（仅用于维护步**循环控制**）。
  bool get _hasPendingMemoryMerge {
    final plan = memoryMergePlan;
    if (plan == null || !plan.hasAction) return false;
    return !isMemoryMergeApplied(workingCopy.memorySummary, plan);
  }

  String get _storyForChecks =>
      _adopted.isNotEmpty ? _adopted : _lastFallback;

  /// 本档位读取器名 → 栏目（维护回合重复读取护栏用）。
  late final Map<String, AgentStateSection> _readSectionByTool = {
    for (final s in profile.toolSections) agentReadToolName(s): s,
  };

  /// 本档位编辑器名 → 栏目（编辑回传的栏目全文同样算「已提供」）。
  late final Map<String, AgentStateSection> _editSectionByTool = {
    for (final s in profile.toolSections) agentEditToolName(s): s,
  };

  /// 本轮已把**全文**交给模型的栏目（读取结果 / 编辑回传 / 编辑失败回传）：
  /// 非正文阶段对这些栏目的重复读取会被拒绝（[_refusedRepeatRead]）。
  final Set<AgentStateSection> _sectionsProvided = {};

  /// 第一步 / 第二步各自的回合序号（RAW 的「第 N 回合」）。
  /// 第一步的调研与正文共用一个序号；重试不重复计数。
  int _firstStepTurns = 0;
  int _maintenanceTurns = 0;

  /// 维护回合指令（简短中文概述；工具名按当前档位的栏目清单生成）。
  ///
  /// 当前档位只有历史这件事（世界 / 角色由正文携带、正文已产出，本阶段不得
  /// 改写正文），且它是「记忆条目没落地」的兜底。世界 / 角色栏目与编辑器仍保留
  /// 为框架，后续档位启用时会自动进入这里（文案由 [PromptV2Sections] 按栏目生成）。
  Map<String, dynamic> _stateDirective(
    List<String> problems, {
    required bool first,
  }) =>
      {
        'role': 'user',
        'content': _prompt.stageState(AgentStageRequest(
          workingCopy: workingCopy,
          memoryMergePlan: memoryMergePlan,
          first: first,
          problems: problems,
        )),
      };

  // ---------------------------------------------------------------------------
  // 帧调用（含协议兼容降级）
  // ---------------------------------------------------------------------------

  Future<AiCallResult> _callFrame({
    required AgentStage stage,
    required _FrameGate gate,
    required bool stream,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    // 一个逻辑回合只回调一次：协议兼容降级在同一回合内重发，不应多算回合。
    // 序号按「步」连续编号：调研与正文共用第一步的序号，维护单独从 1 开始。
    final turnIndex = stage == AgentStage.state
        ? ++_maintenanceTurns
        : ++_firstStepTurns;
    onTurnStarted?.call(stage, turnIndex);
    for (var attempt = 0;; attempt++) {
      if (isCancelled?.call() ?? false) throw const AiCancelledException();
      onActivity?.call(
        AgentActivity(
          type: AgentActivityType.turn,
          query: '',
          iteration: _frames,
        ),
      );
      final body = _frameBody(stage);
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
        // 不赔上整轮预算。当前唯一可降级项是「服务商不接受有状态续接」。
        if (attempt >= 3 || e is! AiException || e.kind != AiExceptionKind.api) {
          rethrow;
        }
        final msg = e.message.toLowerCase();
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

  /// 本阶段当前帧的请求体：**实发 [_callFrame] 与「预览请求体」共用**，
  /// 保证预览给出的首帧就是真正会发出的那一帧。
  ///
  /// 思考强度不在帧上下文里——所有帧一律沿用用户设置（见 [AgentTurnRequest]）。
  Map<String, dynamic> _frameBody(AgentStage stage) => buildBody(
        AgentTurnRequest(
          stage: stage,
          items: _sendItems(),
          previousResponseId: chaining ? _previousResponseId : null,
        ),
      );

  /// 追加本阶段首帧的**帧指令**（若有）。
  ///
  /// 各阶段回合指令的**唯一追加点**（文案真源仍由 [PromptInterface] 给出）：
  /// 实发各阶段与 [outlineFrames] 都经这里，预览因此不会与实发漂移。
  void _appendStageDirective(
    AgentStage stage, {
    bool first = true,
    List<String> problems = const [],
  }) {
    switch (stage) {
      case AgentStage.prepare:
        _items.add({
          'role': 'user',
          'content': _prompt.stagePrepare(const AgentStageRequest()),
        });
      case AgentStage.story:
        // 把「现在只写五个区块」说在最近处（与系统契约同一真源）。
        _items.add({
          'role': 'user',
          'content': _prompt.stageStory(const AgentStageRequest()),
        });
      case AgentStage.state:
        _items.add(_stateDirective(problems, first: first));
    }
  }

  /// 预览：本轮会发出 / 可能发出的帧骨架（**不发起任何调用**）。
  ///
  /// 首帧与实发**逐字节一致**（同一 [_beginRound] + [_appendStageDirective] +
  /// [_frameBody] 路径）；其余候选帧只保证形态——是否真的发出、以及缺口清单等
  /// 动态部分，取决于模型响应与工具返回，故由调用方标注为「后续可用帧」。
  ///
  /// 调用本方法会重置执行器运行期状态（与 [run] 同级语义）；预览请用一次性实例。
  List<RequestFrameOutline> outlineFrames(
    List<Map<String, dynamic>> initialInputItems,
  ) {
    _beginRound(initialInputItems);
    final frames = <RequestFrameOutline>[];
    _appendStageDirective(AgentStage.prepare);
    frames.add(
      RequestFrameOutline(
        label: '调研回合',
        note: '第一步·调研：读历史、按需联网搜索 / 打开页'
            '（遇工具调用会继续续回合，直到调研结束；随后立刻生成正文）。',
        body: _frameBody(AgentStage.prepare),
      ),
    );
    _appendStageDirective(AgentStage.story);
    frames.add(
      RequestFrameOutline(
        label: '正文回合',
        note: '第一步·正文：调研结束后发出，写本轮 5 区块正文'
            '（不写记忆总结、不调用历史编辑器）。',
        body: _frameBody(AgentStage.story),
      ),
    );
    _appendStageDirective(AgentStage.state);
    frames.add(
      RequestFrameOutline(
        label: '维护回合',
        note: '第二步·状态维护：正文完成后作为单独的新请求发出，'
            '只补本轮记忆总结 / 合并（思考强度沿用用户设置）。',
        body: _frameBody(AgentStage.state),
      ),
    );
    return frames;
  }

  /// 吸收一帧：聚合用量 / 思考、按帧分类采纳正文、把思考条目与 assistant 消息
  /// 追加进会话累积（工具条目在 [_executeTools] 中紧随其后追加）。
  void _absorbFrame(AiCallResult result, AgentStage stage) {
    // null = 该帧未带该用量字段（跳过）；全 null 时结果保持 null → 界面「（无）」。
    _promptTokens = addTokenUsage(_promptTokens, result.promptTokens);
    _completionTokens = addTokenUsage(_completionTokens, result.completionTokens);
    _cachedTokensIn = addTokenUsage(_cachedTokensIn, result.cachedTokensIn);
    if (result.reasoningContent.isNotEmpty) {
      _reasoning.write(result.reasoningContent);
    }
    if (result.responseId.isNotEmpty) {
      _lastResponseId = result.responseId;
      _previousResponseId = result.responseId;
    }
    if (stage == AgentStage.story) _classifyStoryFrame(result);
    _noteTruncation(result, stage);
    // 本帧思考先挂起，**不立即入队**：服务商要求每个 function_call 紧邻其前
    // 各有一个非空思考块（见 [_appendCallItems]），故思考在追加工具条目时
    // 逐个发出，而不是整帧共用一块。回传文本按设置精简（界面/聚合仍用原文）。
    _frameReasoning = [
      for (final item in result.reasoningItems)
        if (item.text.trim().isNotEmpty)
          AiReasoningItem(
            id: item.id,
            text: reasoningTextForReplay(
              item.text,
              reduce: reduceReasoningReplay,
            ),
            summary: item.summary,
          ),
    ];
    // 没有工具调用要发的思考（纯正文帧 / 无工具帧）在这里直接入队——先于正文，
    // 与模型原始输出顺序一致。
    if (result.toolCalls.isEmpty) {
      _flushReasoningItems();
    }
    if (result.content.trim().isNotEmpty) {
      _items.add({'role': 'assistant', 'content': result.content});
    }
  }

  /// 把挂起的思考条目追加进会话（[reasoningItemFrom] 形态）。
  void _flushReasoningItems() {
    for (final item in _frameReasoning) {
      _items.add(reasoningItemFrom(item));
    }
    _frameReasoning = const [];
  }

  /// 取本帧第 [index] 个工具调用的思考文本：优先用模型本帧产出的第 index 块
  /// （块数不足时回落最后一块——服务端只要求「非空且紧邻」，不校验内容归属）。
  ///
  /// **永不为空**：没有思考块时回落该帧正文（正文本身就是模型对本回合的说明），
  /// 再没有则给占位文本。服务端对「工具调用缺块」是硬 400，宁可回传一段不完美
  /// 的文本，也不能让整轮生成失败。回落文本同样按设置精简。
  String _reasoningTextFor(int index, {required String fallbackContent}) {
    if (_frameReasoning.isNotEmpty) {
      final at = index < _frameReasoning.length ? index : _frameReasoning.length - 1;
      final text = _frameReasoning[at].text.trim();
      if (text.isNotEmpty) return text;
    }
    final content = fallbackContent.trim();
    if (content.isNotEmpty) {
      return reasoningTextForReplay(content, reduce: reduceReasoningReplay);
    }
    return 'Continue by calling the requested tool.';
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
              'and SHORTER tool calls: one editor call per section, the '
              'minimum edits needed, never copy long text. '
              '上一帧在输出上限处被截断：请减少并拆短工具调用（一个栏目一次调用、'
              'edits 尽量少、不要复制长段文本）。'
        : 'The previous response ended early (${result.incompleteReason}). '
              'Re-issue only the missing tool calls. '
              '上一帧被提前结束（${result.incompleteReason}），只补齐缺失的工具调用。';
    // 维护回合：进本回合反馈通道（下一回合指令与维护清单）；
    // 正文 / 调研回合：只登记，避免仅因一次截断就额外触发一帧 `required`
    // （那会逼模型重复调工具）。
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

  /// 正文采纳后的兜底清洗：模型违规模仿 Chat 格式、把**由工具维护的**状态区块
  /// 写进正文时，剥离自该 `## 标题` 起、到下一个 `##` 标题为止的段落，
  /// 保住正文唯一性。
  ///
  /// 剥离范围 = [AgentModeProfile.bannedStoryHeadings]（当前档位 = 仅记忆总结；
  /// 世界与角色状态正是当前档位正文的合法组成部分。世界 / 角色栏目若将来被
  /// 某个档位的工具托管，会自动加入剥离范围）。
  String _stripStateSectionsIn(String content) {
    final banned = profile.bannedStoryHeadings;
    if (banned.isEmpty) return content;
    final lines = content.split('\n');
    final kept = <String>[];
    var skipping = false;
    for (final line in lines) {
      if (line.startsWith('## ')) {
        final head = line.substring(3).trim();
        skipping = banned.any(head.startsWith);
      }
      if (!skipping) kept.add(line);
    }
    return kept.join('\n');
  }

  /// 执行一回合的全部工具调用（并行语义：逐个执行，条目按调用顺序回传）。
  ///
  /// [stage] 决定护栏：
  /// - **第一步**（调研 / 正文）拒绝状态编辑器：记忆维护只允许在第二步做；
  /// - **第二步**只允许记忆编辑器与必要的历史读取：拒绝联网，重复读取按
  ///   [_refusedRepeatRead] 拒绝。
  Future<void> _executeTools(
    AiCallResult result,
    bool Function()? isCancelled,
    AgentStage stage,
  ) async {
    for (var callIndex = 0; callIndex < result.toolCalls.length; callIndex++) {
      final tc = result.toolCalls[callIndex];
      if (isCancelled?.call() ?? false) throw const AiCancelledException();
      final tool = _byName(tc.name);
      final summary = _argsSummary(tc.name, tc.arguments);
      final isStateTool = !(tool?.isReadOnly ?? false) &&
          tool?.activityType == AgentActivityType.tooling;
      final subject = _subject(tc, summary);
      final refusedRead = _refusedRepeatRead(tc, stage);
      final refusedEarlyEdit = _refusedEarlyStateEdit(tc, stage);
      final refusedMaintenanceSearch = _refusedMaintenanceSearch(tc, stage);
      final outcome = tc.argumentsUnparsable
          ? AgentToolOutcome(
              name: tc.name,
              callId: tc.id,
              argsSummary: summary,
              subject: subject,
              applied: false,
              message: '工具参数被截断（JSON 不完整），未执行',
              modelOutput:
                  'Your tool-call arguments were TRUNCATED (invalid '
                      'JSON), so nothing was applied. Call again with ONE '
                      'call per section and FEWER edits per call. '
                      '工具参数被截断（JSON 不完整），本次未执行：'
                      '请一次只改一个栏目、单次 edits 条数更少。',
              isStateTool: isStateTool,
            )
          : refusedRead
              ? _refusedReadOutcome(tc, summary, subject)
              : refusedEarlyEdit
                  ? _refusedEarlyEditOutcome(tc, summary, subject)
                  : refusedMaintenanceSearch
                      ? _refusedMaintenanceSearchOutcome(tc, summary, subject)
                      : await _runTool(tc, tool, summary, subject, isStateTool);
      _outcomes.add(outcome);
      // 工具卡片收口：完成 / 失败状态与一行结果说明（缺少这一步，UI 的
      // 工具框会永远停在「正在执行…」）。
      onToolFinished?.call(outcome);
      if (!outcome.applied && outcome.isStateTool) {
        _modelProblems.add('${tc.name} → ${outcome.modelOutput}');
      }
      // 本次调用带给模型的栏目全文（读取成功 / 编辑回传）：登记后，维护步
      // 对这些栏目的重复读取会被拒绝（[_refusedRepeatRead]）。
      _noteSectionsProvided(
        tc,
        outcome,
        executed: !refusedRead &&
            !refusedEarlyEdit &&
            !refusedMaintenanceSearch &&
            !tc.argumentsUnparsable,
      );
      _appendCallItems(
        tc,
        outcome,
        callIndex: callIndex,
        frameContent: result.content,
      );
    }
  }

  /// 第一步（调研 / 正文）拒绝所有状态编辑器：记忆维护只允许在第二步做。
  bool _refusedEarlyStateEdit(AiToolCall tc, AgentStage stage) {
    if (stage == AgentStage.state) return false;
    return _editSectionByTool.containsKey(tc.name);
  }

  /// 第二步只维护记忆总结：联网工具在维护步一律不执行。
  bool _refusedMaintenanceSearch(AiToolCall tc, AgentStage stage) {
    if (stage != AgentStage.state) return false;
    return tc.name == 'narrchat_webSearch' ||
        tc.name == 'narrchat_webFetchPage';
  }

  /// 非正文阶段护栏：**本轮已提供过全文的栏目**不再重复读取。
  ///
  /// 写正文不改变状态（只有编辑会），所以调研步读到的快照就是维护步唯一正确
  /// 的锚点来源——它们已在上下文中（`_pruneStaleReadState` 之前不会失效）。
  /// 模型习惯「写完再查一遍再改」时，这一次多余查询本身要花掉一个回合：
  /// 这里直接不执行并回传一句方向性说明（下一回合指令还会再次点名），
  /// 促使它直接用已有全文的锚点编辑。
  ///
  /// 未提供过的栏目（调研步漏读、或读取被截断）照常执行——非合规流程仍能
  /// 自我修复，不因护栏而失明。
  bool _refusedRepeatRead(AiToolCall tc, AgentStage stage) {
    if (stage == AgentStage.story || tc.argumentsUnparsable) return false;
    final section = _readSectionByTool[tc.name];
    if (section == null) return false;
    return _sectionsProvided.contains(section);
  }

  /// 登记一次调用带给模型的栏目全文。
  void _noteSectionsProvided(
    AiToolCall tc,
    AgentToolOutcome outcome, {
    required bool executed,
  }) {
    if (!executed) return;
    // 读取器成功 → 该栏目全文已在上下文。
    final readSection = _readSectionByTool[tc.name];
    if (readSection != null && outcome.applied) {
      _sectionsProvided.add(readSection);
      return;
    }
    // 编辑器（成功或失败）都会回传该栏目当前全文 → 同样视为「已提供」。
    final editSection = _editSectionByTool[tc.name];
    if (editSection != null) _sectionsProvided.add(editSection);
  }

  AgentToolOutcome _refusedReadOutcome(
    AiToolCall tc,
    String summary,
    String subject,
  ) {
    final section = _readSectionByTool[tc.name]!;
    final editTool = agentEditToolName(section);
    return AgentToolOutcome(
      name: tc.name,
      callId: tc.id,
      argsSummary: summary,
      subject: subject,
      applied: false,
      message: '本轮已提供该栏目全文，维护步不再重复读取',
      modelOutput:
          '该栏目的全文**已在对话中**（你本轮早先自己读取的结果；'
              '写正文不会改变状态，只有编辑会），本次不再重复读取：'
              '请直接从上面已有的 `<${section.tag}>` 块**逐字复制** `before` 锚点，'
              '并在本回合直接按清单调用对应编辑器（本栏用 $editTool）。',
      // 非状态缺口：不写入缺项清单（它属于流程违规，不是待修栏目）。
      isStateTool: false,
    );
  }

  /// 第一步调用状态编辑器：不执行，提示留到第二步维护。
  AgentToolOutcome _refusedEarlyEditOutcome(
    AiToolCall tc,
    String summary,
    String subject,
  ) {
    final section = _editSectionByTool[tc.name]!;
    return AgentToolOutcome(
      name: tc.name,
      callId: tc.id,
      argsSummary: summary,
      subject: subject,
      applied: false,
      message: '状态编辑只允许在第二步维护执行，本次未执行',
      modelOutput:
          '状态编辑只允许在第二步「状态维护」执行；第一步只做调研和正文。'
              '本轮 ${section.label} 的维护指令会在正文写完后单独下发，'
              '现在不要编辑状态，请继续完成正文。',
      isStateTool: false,
    );
  }

  /// 第二步调用联网工具：不执行，维护步只维护记忆总结。
  AgentToolOutcome _refusedMaintenanceSearchOutcome(
    AiToolCall tc,
    String summary,
    String subject,
  ) {
    return AgentToolOutcome(
      name: tc.name,
      callId: tc.id,
      argsSummary: summary,
      subject: subject,
      applied: false,
      message: '状态维护只维护记忆总结，维护步不联网',
      modelOutput:
          '这是第二步「状态维护」：只能维护记忆总结，不能联网搜索或打开页面。'
              '请直接根据正文的 `## 当前时间` 用 narrchat_editHistory 追加本轮条目。',
      isStateTool: false,
    );
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
  ///
  /// **每个工具调用前各发一块思考**（[callIndex] 为本帧内的第几个调用）：
  /// DeepSeek 思考模式对带 `tools` 的请求逐块校验——一个 `function_call` 少了
  /// 紧邻其前的非空 `reasoning` 块即整次 400（「The `reasoning_text` in the
  /// thinking mode must be passed back to the API」）。实测（官方 `/responses`）：
  /// 一帧调两个工具、只回传一块思考 → 400；每个调用各一块（块间内容异同、
  /// id 异同）→ 200；`assistant` 正文**不能**顶替思考块。故这里**绝不省略**：
  /// 模型没产出思考时回落该帧正文，再退化为占位文本。
  void _appendCallItems(
    AiToolCall tc,
    AgentToolOutcome outcome, {
    required int callIndex,
    required String frameContent,
  }) {
    _items.add(
      reasoningItemFrom(
        AiReasoningItem(
          id: '',
          text: _reasoningTextFor(callIndex, fallbackContent: frameContent),
          summary: false,
        ),
      ),
    );
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
    // 读取器：只保留**该栏**最新一份结果（旧结果失去时效）。
    // 只用**真正执行成功**的读取剔除旧份：被拒绝的重复读取（applied=false）
    // 不得把模型唯一可用的锚点来源（正文回合那一份）剔掉。
    if (outcome.applied && (_byName(tc.name)?.isReadOnly ?? false)) {
      _pruneStaleReadState(tc.name, tc.id);
    }
  }

  /// 只保留**同一读取器**最新一份结果：旧结果（上一轮 / 前一帧读取的）在新读取
  /// 生效后失去时效，继续留在上下文中只会推高输入并诱导模型用过时锚点。
  ///
  /// 按**工具名**逐栏剔除（每个栏目一个读取器，互不干扰）；读取结果条目成对
  /// 出现（`function_call` + `function_call_output`），且只可能存在于 `_history`
  /// 之后（历史消息不含工具结果），逐个剔除即可。
  ///
  /// 该调用**紧邻其前**的思考块一并剔除：否则思考会掉到会话最前面变成孤儿，
  /// 而它本该归属的那个 `function_call` 已不在会话里（服务端按相邻关系校验）。
  void _pruneStaleReadState(String toolName, String currentCallId) {
    final kept = <Map<String, dynamic>>[];
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item['type'] == 'function_call' &&
          item['name'] == toolName &&
          item['call_id'] != currentCallId) {
        // 紧随其后的 function_call_output 条目。
        i++;
        if (kept.isNotEmpty && kept.last['type'] == 'reasoning') {
          kept.removeLast();
        }
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
/// - **正文回合**：内容先缓冲，出现 `## 剧情演绎` 标题才开始上屏（从标题处起），
///   开场白永不可见；每回合首次上屏前先发 [AiStreamChunk.narrativeReset]，
///   使「后到的完整标题帧覆盖前一帧」在界面上表现为正文块重置重流；
/// - **调研回合**：文本通道关闭，增量一律丢弃；
/// - **维护回合**：文本不进入正文，转发给 UI 的维护流式框（由 provider 按
///   [AgentStage.state] 分流）。
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
    if (stage == AgentStage.state) {
      emit?.call(chunk);
      return;
    }
    if (stage != AgentStage.story) return;
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
