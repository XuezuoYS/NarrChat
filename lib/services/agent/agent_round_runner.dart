import 'dart:convert';

import '../../models/agent_mode_level.dart';
import '../../utils/memory_entry_format.dart';
import '../ai_response_parser.dart';
import '../ai_service.dart';
import '../memory_merge_planner.dart';
import '../prompt_formats.dart';
import 'agent_activity.dart';
import 'agent_mode_profile.dart';
import 'agent_stage_directives.dart';
import 'narr_agent_tool.dart';
import 'reasoning_replay.dart';
import 'state/agent_state_working_copy.dart';
import 'state/state_coverage.dart';
import 'state/state_tools.dart';
import 'wire_adapters.dart';

/// 维护轮（代码旧称「状态轮」，含其修复帧）的最大帧数：1 主帧 + 3 修复帧。
const int kAgentMaxStateFrames = 4;

/// **准备阶段**的最大帧数（仅 Lv.1）：读史 → 联网搜索 / 打开页 → 大纲，
/// 联网一次典型消耗 3 帧（读史 + 搜索 + 打开页），再留空间给搜索上的重试。
const int kAgentMaxPrepFrames = 6;

/// **记忆阶段**的最大帧数（仅 Lv.1）：1 主帧 + 2 次提醒。
/// 每帧都以 `tool_choice = required` 强制调用历史编辑器，正常 1 帧即完成。
const int kAgentMaxMemoryFrames = 3;

/// 正文轮的最大帧数（联网搜索会消耗多帧：开场白 → 搜索 → 打开页 → 正文）。
const int kAgentMaxStoryFrames = 8;

/// 维护轮的思考强度覆盖值：用户开启思考时，维护帧不硬关思考（`none`），
/// 而是降到 `low`——状态维护需要理解正文与快照，完全关闭会让模型「看不懂」
/// 缺项清单与锚点；同时思考 token 计入输出上限，`low` 把预算尽量留给参数。
const String kAgentStateThinkingEffort = 'low';

/// 输出触顶的原因标识（Responses `incomplete_details.reason`）。
const String kIncompleteMaxOutputTokens = 'max_output_tokens';

/// 执行器运行阶段。
enum AgentStage {
  /// **准备阶段**（仅 Lv.1，`tool_choice = auto`）：读历史（`narrchat_readHistory`
  /// 一次）+ 按需联网，随后在思考通道写出本轮大纲。文本通道在此阶段**不上屏、
  /// 不采纳**（无标题的开场白 / 大纲一律丢弃）。
  prepare,

  /// **记忆阶段**（仅 Lv.1，`tool_choice = required`）：按大纲用
  /// `narrchat_editHistory`（`op=append`）追加本轮**恰好一条**记忆条目。
  /// 记忆条目**先于正文**落地，成为正文的既定约束；文本通道同样关闭
  /// （模型若在本帧抢写正文，一律丢弃，交给正文阶段重写）。
  memory,

  /// 维护轮（旧称状态轮）：只调工具维护状态，**文本通道对界面完全关闭**。
  /// Lv.2 仅在有缺口时发起；Lv.1 仅作兜底（记忆阶段未把历史补齐时）。
  state,

  /// 正文阶段：产出本轮正文（唯一的正文采纳与上屏阶段）。
  story,
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

  /// `tool_choice`（准备 / 正文阶段 `auto`；记忆 / 维护轮 `required`；
  /// null = 不发送）。
  final String? toolChoice;

  /// 思考强度**覆盖**（[kAgentStateThinkingEffort] = `low`；null = 沿用用户
  /// 设置）。仅当用户开启了思考模式时生效：思考 token 占用输出上限，但记忆 /
  /// 维护帧需要读懂大纲与最新状态，`low` 在「不完全关掉理解力」与「省预算」
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

  /// 是否应用成功（状态工具校验失败 → 工具帧 / 维护轮反馈）。
  final bool applied;

  /// **UI** 结果说明（一行摘要）。
  final String message;

  /// **回传模型**的结果全文（状态工具含该栏目当前全文）。
  final String modelOutput;

  /// 是否状态类工具（校验失败走工具帧 / 维护轮语义）。
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

  /// 是否发起过维护轮（正文之后仍有缺口 / 编辑失败时才发起）。
  final bool stateTurnUsed;

  /// 本轮**最后一帧**是否被服务端提前结束（截断）。
  final bool incomplete;

  /// 截断原因（`max_output_tokens` / `content_filter` / …；空 = 未截断）。
  final String incompleteReason;

  /// 本轮总帧数（准备 + 记忆 + 正文 + 维护，含修复帧）。
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
    required this.stateTurnUsed,
    required this.frames,
    this.incomplete = false,
    this.incompleteReason = '',
  });
}

/// AGENT 单轮执行器（Responses 协议 + 状态自取 + 分阶段）。
///
/// ## 档位（[AgentModeProfile]）
///
/// 同一执行器服务两个档位，差异全部来自 [profile]（不在本类里散落档位判断）：
/// - **Lv.2**：正文阶段输出三小节（剧情 / 推荐行动 / 当前时间），
///   世界 / 角色 / 历史三栏全部由六个状态工具维护；
/// - **Lv.1**：**四步流程**（读史 → 大纲 → 记忆 → 正文）。世界状态 / 角色状态
///   随正文文本携带，**只有历史（记忆总结）走工具**：
///   1. [AgentStage.prepare]（`auto`）：`narrchat_readHistory` 读一次 + 按需联网，
///      随后在思考通道写本轮大纲（不上屏、不采纳）；
///   2. [AgentStage.memory]（`required`）：按大纲 `op=append` **恰好一条**本轮
///      记忆条目——**先于正文落地**，成为正文的既定约束；
///   3. [AgentStage.story]（`auto`）：按大纲输出五区块正文
///      （严格执行提示词给出的输出格式；`## 记忆总结` 仍被剥离）。
///   维护轮退化为**兜底**：记忆阶段没把历史补齐（校验失败 / 空手帧 / 截断）
///   时才发起——合规流程下 Lv.1 **零额外请求**。
///
/// ## 为什么分阶段
///
/// 旧版把「写正文」与「调状态工具」塞进同一响应，靠提示词命令模型
/// 「正文先行、工具随后」——这与工具型模型「先调工具、再答」的先验相反；
/// 加上续接帧不回传模型自己刚写的正文，导致一次请求里反复生成多份正文。
/// 现在每个阶段各自只有一个正确动作：
///
/// 1. **准备阶段**（[AgentStage.prepare]，仅 Lv.1）：读史 + 联网 + 大纲。
/// 2. **记忆阶段**（[AgentStage.memory]，仅 Lv.1）：只调历史编辑器，不输出文本
///    （模型抢写正文也会被丢弃，正文只在正文阶段产生）。
/// 3. **正文阶段**（[AgentStage.story]，`tool_choice = auto`）：基于**上一轮
///    状态 + 已落地的记忆 + 大纲**写正文；`## 当前时间` 是正文小节
///    （时间不属于工具）。
/// 4. **完整性判定**（[inspectState]，范围 = [AgentModeProfile.toolSections]）：
///    栏目是否都处理、本轮是否恰好一条记忆、正文提及的角色小节是否一动未动。
/// 5. **维护轮**（[AgentStage.state]，`tool_choice = required`；两档位都在有
///    缺口时发起）：按缺口清单逐栏目编辑；该阶段模型输出的任何文本
///    **不会到达界面**——「一次请求多份正文」在新结构下不可能发生。
///
/// ## 状态自取（快照不作预置）
///
/// 早期版本由应用把状态快照预置成「工具输出」喂给模型，模型把 `<time>` /
/// `<worldState>` 等 md 块当成**可模仿的输出格式**——要么照格式堆进正文
/// （Chat 式预期表现），要么写完正文又调工具，困惑「我不是都写了吗」。
/// 现在读取器是**真实注册的只读工具**（每个栏目一个），模型必须主动调用才
/// 拿得到状态：
///
/// - 调用时机由模型承担，但**返回值语义统一** = 工作副本当前渲染（准备 / 正文
///   阶段调用 → 上一轮库内状态；维护轮调用 → 正文之后的状态），应用侧不需要
///   从调用序列推断「这是哪个阶段」；
/// - 读取结果以 `function_call_output` 形态进入上下文（**工具结果，
///   不是输出格式**，不再诱发格式模仿）；
/// - 每栏**只保留最新一份**读取结果（[_pruneStaleReadState]，按工具名剔除），
///   修复帧不再重复读取（指令明示复用已有结果与失败回传全文），
///   每轮输入不会随修复帧数线性膨胀；
/// - 非正文阶段（准备 / 记忆 / 维护）对「本轮已提供全文的栏目」的读取一律被拒
///   （[_refusedRepeatRead]）：写正文不改变状态，准备阶段那一份就是唯一正确的
///   锚点来源；
/// - 正文采纳时还会**剥离**正文里出现的、由工具维护的状态类二级标题段
///   （模型违规模仿格式的兜底清洗，见 [_stripStateSectionsIn]；
///   Lv.1 只剥离 `## 记忆总结`，世界 / 角色本就是正文的一部分）。
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
/// **只有 [AgentStage.story] 参与分类**：准备 / 记忆帧的正文（模型跳步抢写）
/// 一律丢弃，且进入正文阶段前会清空候选，保证采纳的正文与已落地的记忆同源。
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
/// [supportsToolChoice] / [supportsThinkingEffort] 是能力**初值**，运行中遇到
/// 协议类失败就地重发同一帧（同一帧至多连降 3 项）：
/// 拒绝 `tool_choice` → 去掉该字段；拒绝 `previous_response_id` → 本轮全量
/// 重发；拒绝中途调整思考强度 → 该帧回落用户设置。
/// 只有内容校验类失败才走修复帧。
///
/// ## 截断（`response.incomplete`）
///
/// 记忆 / 维护轮输出的是逐字锚点的工具参数 JSON，而思考 token 同样计入输出
/// 上限，极易触顶。触顶**不是失败**：底层保留截断前的部分结果并标记
/// [AiCallResult.incomplete]，本执行器据此（1）给下一帧补一条「拆短输出」
/// 指令，（2）记忆 / 维护轮思考降为 `low`（用户开启思考时，不硬关——维护状态
/// 需要理解正文与快照），（3）末帧仍截断时
/// 给用户一条可操作提示（由用户在设置里调高「最大 token」，程序不擅自改动
/// 请求体的 `max_output_tokens`）。绝不因一帧截断赔掉整轮正文。
class AgentRoundRunner {
  AgentRoundRunner({
    required this.buildBody,
    required this.call,
    required this.tools,
    required this.workingCopy,
    required this.profile,
    this.memoryMergePlan,
    this.chaining = false,
    this.supportsToolChoice = true,
    this.supportsThinkingEffort = true,
    this.maxPrepFrames = kAgentMaxPrepFrames,
    this.maxMemoryFrames = kAgentMaxMemoryFrames,
    this.maxStoryFrames = kAgentMaxStoryFrames,
    this.maxStateFrames = kAgentMaxStateFrames,
    this.reduceReasoningReplay = false,
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

  /// 档位档案（决定正文契约、参与缺口的栏目、是否走 Lv.1 四步流程）。
  final AgentModeProfile profile;

  /// 本轮应执行的「记忆总结轮次合并」动作（档位 0 / 无动作时为 null）。
  ///
  /// 由调用方在生成前算定（输入 = 上一轮落库的记忆总结 + 本书档位，见
  /// `memory_merge_planner.dart`）：Lv.1 并入记忆阶段帧指令并计入
  /// [_memorySatisfied] 门槛；Lv.2 并入维护轮问题清单；终态未落地转常驻警告。
  final MemoryMergePlan? memoryMergePlan;

  final bool chaining;
  bool supportsToolChoice;

  /// 服务商是否接受「工具帧思考强度覆盖」（[AgentTurnRequest.stateThinkingEffort]）。
  /// 部分服务商不允许中途调整推理强度 → 就地回落用户设置重发同一帧。
  bool supportsThinkingEffort;

  /// 准备阶段（仅 Lv.1）的最大帧数：读史 + 联网 + 大纲。
  final int maxPrepFrames;

  /// 记忆阶段（仅 Lv.1）的最大帧数：`required` 强制调用历史编辑器。
  final int maxMemoryFrames;

  final int maxStoryFrames;
  final int maxStateFrames;

  /// 回传思考时是否精简（默认关 = 逐字节回传原文）。规则见 `reasoning_replay.dart`。
  final bool reduceReasoningReplay;
  final void Function(AgentActivity activity)? onActivity;
  final void Function(AgentToolOutcome outcome)? onToolStarted;
  final void Function(AgentToolOutcome outcome)? onToolFinished;

  /// 阶段帧指令的**唯一真源**（与 `prompt_interface` 的实现共用同一份文案）：
  /// 执行器只决定「何时发哪一帧」，文案构建全部收敛在 [AgentStageDirectives]。
  static const AgentStageDirectives _stageDirectives = AgentStageDirectives();

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

  /// 正文轮截断的补救说明——**不参与**「是否需要维护轮」的判定，只在确实
  /// 进入维护轮时随首轮指令下发（为一个截断额外发一帧 `required` 只会逼模型
  /// 重复调工具）。
  final List<String> _truncationNotes = [];

  /// 本帧已产出、尚未随工具调用发出的思考块（见 [_appendCallItems]）。
  List<AiReasoningItem> _frameReasoning = const [];

  /// 最后一帧是否被服务端提前结束（决定要不要给用户一条可操作提示）。
  bool _lastFrameTruncated = false;
  String _truncateReason = '';

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
    _history = List<Map<String, dynamic>>.from(initialInputItems);
    _sink = onChunk;
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
    _frameReasoning = const [];
    _sectionsProvided.clear();

    // Lv.1 = 四步流程（准备 → 记忆 → 正文）；Lv.2 = 正文 → （缺口时）维护轮。
    // 记忆条目在 Lv.1 **先于正文落地**（计划要求）：大纲决定本轮结束时间与
    // 关键事件，记忆条目按大纲先行写入，正文再受它约束。
    if (profile.level == AgentModeLevel.lv1) {
      await _runPrepareStage(stream, onRequestBody, isCancelled);
      await _runMemoryStage(stream, onRequestBody, isCancelled);
    }
    await _runStoryStage(stream, onRequestBody, isCancelled);
    final story = _adopted.isNotEmpty ? _adopted : _lastFallback;

    // 正文之后仍存在缺口（Lv.1 多为记忆未落地 / 校验失败 / 截断）→ 维护轮兜底；
    // 合规流程下缺项为空 → **零额外请求**。
    var gaps = _gaps(story);
    final problems = [
      ..._modelProblems,
      for (final g in gaps) g.modelText,
      // 档位驱动的记忆合并：正文之后仍未落地 → 并入维护轮问题清单
      //（即使无缺口，也会因此强制发起一次维护轮）。
      ..._pendingMemoryMergeLines(),
    ];
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
            ? '模型输出触顶被截断（工具帧思考已降为 low 并要求拆短调用重试）：'
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

    return AgentRoundResult(
      content: story,
      reasoningContent: _reasoning.toString(),
      promptTokens: _promptTokens,
      completionTokens: _completionTokens,
      cachedTokensIn: _cachedTokensIn,
      outcomes: _outcomes,
      warnings: _warnings,
      responseId: _lastResponseId,
      stateTurnUsed: needStateTurn,
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
        // 只判定本档位由工具维护的栏目（Lv.1 = 仅历史）。
        sections: profile.toolSections,
        // 懒修改检查只对「角色状态由工具维护」的档位有意义（Lv.2）。
        checkLazy:
            profile.toolSections.contains(AgentStateSection.characterState),
      );

  // ---------------------------------------------------------------------------
  // 准备阶段（仅 Lv.1：读史 + 联网 + 大纲）
  // ---------------------------------------------------------------------------

  /// 准备阶段：模型读历史（一次）、按需联网，最后在思考通道写本轮大纲。
  ///
  /// 文本通道在此阶段**不上屏、不采纳**（[_FrameGate] 只对正文阶段放行，
  /// [_absorbFrame] 也只对正文阶段做分类）：搜索 / 读取帧的「我先查一下…」
  /// 与大纲都不该出现在正文块里。
  ///
  /// 首帧先追加 [AgentLv1PromptFormat.prepareNote]（与系统契约同一真源），
  /// 把「本轮先做什么」说在最近处。
  ///
  /// 退出条件：本帧没有工具调用（= 模型给出大纲，准备完成）；或本帧工具
  /// **全是编辑器**（模型跳步抢写记忆 / 状态）——那一帧的文本一律丢弃，
  /// 「记忆是否已落地」交给随后的记忆阶段判定（[_memorySatisfied]），
  /// 已落地就直接跳过记忆阶段，没落地才重发记忆指令。
  Future<void> _runPrepareStage(
    bool stream,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  ) async {
    _items.add({
      'role': 'user',
      'content': const AgentLv1PromptFormat().prepareNote().join('\n'),
    });
    for (var i = 0; i < maxPrepFrames; i++) {
      final gate = _FrameGate(stage: AgentStage.prepare, sink: _sink);
      final result = await _callFrame(
        stage: AgentStage.prepare,
        toolChoice: supportsToolChoice ? 'auto' : null,
        gate: gate,
        stream: stream,
        onRequestBody: onRequestBody,
        isCancelled: isCancelled,
      );
      _absorbFrame(result, AgentStage.prepare);
      await _executeTools(result, isCancelled, AgentStage.prepare);
      if (result.toolCalls.isEmpty) return;
      if (result.toolCalls.every(_isEditToolCall)) return;
    }
  }

  // ---------------------------------------------------------------------------
  // 记忆阶段（仅 Lv.1：按大纲先写本轮记忆条目）
  // ---------------------------------------------------------------------------

  /// 记忆阶段：`required` 强制模型调用历史编辑器，把本轮条目**先于正文**落地。
  ///
  /// 进入阶段先判一次 [_memorySatisfied]（准备阶段已跳步落地时**零帧**直接跳过）；
  /// 否则每帧追加 [_memoryDirective]（恰一条、只调工具不输出文本）再给一帧，
  /// 帧后再判一次。判定完全基于工作副本事实，不采信模型自述。
  /// 用尽仍失败 → 缺口 / 失败栏目由维护轮兜底。
  Future<void> _runMemoryStage(
    bool stream,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  ) async {
    // 正文只在正文阶段产生：进入记忆阶段先清空准备阶段的兜底候选。
    _adopted = '';
    _adoptedByHeading = false;
    _lastFallback = '';
    // 历史锚点来源：**准备阶段已读过**（`_noteSectionsProvided` 已登记）时，本阶段
    // 与维护阶段的重复读取一律被拒，锚点用对话中已有的 `<memorySummary>` 块；
    // 模型**跳步漏读**时不在登记之列，本阶段仍允许读一次（[memoryMergeAgentDirectiveLines]
    // 会点名这一情形）——否则「合并」这类需要逐字锚点的动作将无从落地。
    // 准备阶段若已把本轮条目落地（模型跳步抢写、或上一帧的编辑已生效），
    // **直接跳过本阶段**：再发一帧 `required` 只会逼模型重复 `op=append`
    // ——第二条条目会让 applyEdits 整栏失败并多烧两帧修复。
    if (_memorySatisfied()) return;
    for (var i = 0; i < maxMemoryFrames; i++) {
      _items.add(_memoryDirective(first: i == 0));
      _modelProblems.clear();
      final gate = _FrameGate(stage: AgentStage.memory, sink: _sink);
      final result = await _callFrame(
        stage: AgentStage.memory,
        toolChoice: supportsToolChoice ? 'required' : null,
        stateThinkingEffort: kAgentStateThinkingEffort,
        gate: gate,
        stream: stream,
        onRequestBody: onRequestBody,
        isCancelled: isCancelled,
      );
      _absorbFrame(result, AgentStage.memory);
      await _executeTools(result, isCancelled, AgentStage.memory);
      if (_memorySatisfied()) {
        // 记忆已落地：清掉本阶段的失败说明，避免它们把随后的正文阶段
        // 误判成「有缺项」而多发起一轮维护。
        _modelProblems.clear();
        return;
      }
      // 不重复回传上一帧的失败说明：编辑失败时工具**已把该栏目当前全文**回传
      // 到对话里（模型据此重锚），再塞一遍只会推高输入。
    }
  }

  /// 记忆阶段完成判定（应用侧事实）：历史栏被真实编辑过、当前没有失败登记、
  /// **恰好一条**本轮（轮次 = N）条目，且档位要求的合并已落地。
  bool _memorySatisfied() {
    const section = AgentStateSection.memorySummary;
    if (!workingCopy.touchedSections.contains(section) ||
        workingCopy.failedSections.contains(section) ||
        memoryEntryCount(workingCopy.memorySummary, workingCopy.roundIndex) != 1) {
      return false;
    }
    final plan = memoryMergePlan;
    return plan == null ||
        isMemoryMergeApplied(workingCopy.memorySummary, plan);
  }

  /// 尚未落地的「记忆合并」指令行（无动作 / 已落地 → 空）。
  ///
  /// 判定真源 = [AgentStageDirectives.pendingMemoryMergeLines]：Lv.1 记忆阶段帧与
  /// Lv.2 维护轮问题清单共用同一判定（以工作副本当前文本为准）。
  List<String> _pendingMemoryMergeLines() =>
      _stageDirectives.pendingMemoryMergeLines(
        workingCopy: workingCopy,
        memoryMergePlan: memoryMergePlan,
      );

  /// 记忆阶段指令（真源 = [AgentStageDirectives.memoryDirective]，与系统契约、
  /// 用户消息、`prompt_interface` 的实现同一份文案）。
  Map<String, dynamic> _memoryDirective({required bool first}) =>
      _stageDirectives.memoryDirective(
        first: first,
        workingCopy: workingCopy,
        memoryMergePlan: memoryMergePlan,
      );

  // ---------------------------------------------------------------------------
  // 正文阶段
  // ---------------------------------------------------------------------------

  Future<void> _runStoryStage(
    bool stream,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  ) async {
    // 正文只在正文阶段产生：清空准备 / 记忆阶段可能留下的候选（模型跳步抢写
    // 的正文一律作废），保证采纳的正文与已落地的记忆同源。记忆阶段的失败说明
    // 同样清掉——「记忆是否缺」由 [_gaps] / [AgentStateWorkingCopy.failedSections]
    // 在正文之后重新判定，不靠上一阶段残留的诊断文本触发维护轮。
    _adopted = '';
    _adoptedByHeading = false;
    _lastFallback = '';
    _modelProblems.clear();
    // Lv.1：把「历史与记忆条目已就位、现在只写五个区块」说在最近处
    // （文案真源 = [AgentLv1PromptFormat.storyNote]，与系统契约口径一致）。
    // Lv.2 保持原样：其正文契约已在系统指令里，不额外追加帧指令。
    if (profile.level == AgentModeLevel.lv1) {
      _items.add({
        'role': 'user',
        'content': const AgentLv1PromptFormat().storyNote().join('\n'),
      });
    }
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
      await _executeTools(result, isCancelled, AgentStage.story);
      // 正文阶段退出条件（一次请求即闭环，不为「等模型停手」多花一帧）：
      // - 本帧没有工具调用 → 就是终帧；
      // - 已采纳标题正文，且本帧工具**全是状态编辑器** → 正文已完成，
      //   补齐与否交给维护轮判定；
      // - 含搜索 / 打开页面等**喂正文**的工具 → 继续下一帧（结果必须
      //   回到上下文，模型要在下一帧写出完整正文）。
      if (result.toolCalls.isEmpty) return;
      if (_adoptedByHeading && result.toolCalls.every(_isEditToolCall)) return;
    }
  }

  /// 该调用是否为状态**编辑**工具（执行完即闭环；读取器是只读查阅，
  /// 不算编辑，也不参与「本帧工具全是编辑器 → 阶段闭环」的判定）。
  bool _isEditToolCall(AiToolCall tc) {
    final tool = _byName(tc.name);
    return tool != null &&
        !tool.isReadOnly &&
        tool.activityType == AgentActivityType.tooling;
  }

  // ---------------------------------------------------------------------------
  // 维护轮（兜底）
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
      // 快照不再是应用预置：维护轮指令要求模型**先调用读取器**（此时
      // 工作副本 = 上一轮 + 本轮正文之后的状态），再按返回的最新块复制锚点；
      // 修复帧则复用上一帧读取结果与失败回传的「栏目当前全文」，
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
      await _executeTools(result, isCancelled, AgentStage.state);
      pending = List<String>.from(_modelProblems);
      if (pending.isEmpty) {
        final gaps = _gaps(_storyForChecks);
        pending = [for (final g in gaps) g.modelText];
      }
      // 档位要求的记忆合并仍未落地 → 继续修复帧（与缺口同一循环、同一帧数上限）。
      pending.addAll(_pendingMemoryMergeLines());
      if (pending.isEmpty) return;
      // 只要清单还有缺项就继续下一帧修复：模型「空手帧」（只回文本/只回读
      // 取器）不再提前结束整轮——记忆/角色这类缺项应得到补修机会，帧数
      // 上限（maxStateFrames）兜底。
    }
  }

  String get _storyForChecks =>
      _adopted.isNotEmpty ? _adopted : _lastFallback;

  /// 本档位读取器名 → 栏目（维护轮重复读取护栏用）。
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

  /// 维护轮指令（英文详细要求在前、简短中文概述在后，**不加语言标记**；
  /// 工具名按档位的栏目清单生成）。
  ///
  /// Lv.1 与 Lv.2 的维护轮语义不同，文案分开（不在同一段里塞两档位都无关的
  /// 说明）：Lv.2 要逐栏目编辑世界 / 角色 / 历史；**Lv.1 只有历史这一件事**
  /// （世界 / 角色由正文携带、正文已产出，本阶段不得改写正文），且它是
  /// 「记忆条目没落地」的兜底。
  Map<String, dynamic> _stateDirective(
    List<String> problems, {
    required bool first,
  }) =>
      _stageDirectives.stateDirective(
        problems: problems,
        first: first,
        level: profile.level,
      );

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
    // 工具帧（记忆 / 维护）：进本帧反馈通道（下一帧指令与维护轮清单）；
    // 正文 / 准备帧：只登记，避免仅因一次截断就额外触发一帧 `required`
    // （那会逼模型重复调工具）。
    if (stage == AgentStage.state || stage == AgentStage.memory) {
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
  /// 剥离范围 = [AgentModeProfile.bannedStoryHeadings]（Lv.2 = 世界/角色/记忆
  /// 三栏；Lv.1 = 仅记忆总结——世界与角色状态正是 Lv.1 正文的合法组成部分）。
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

  /// 执行一帧的全部工具调用（并行语义：逐个执行，条目按调用顺序回传）。
  ///
  /// [stage] 决定一条护栏：**非正文阶段**对「本轮已提供全文的栏目」的重复读取
  /// 不执行（[_refusedRepeatRead]）——写正文 / 写大纲都不改变状态，准备阶段读到的
  /// 那一份就是记忆帧与维护帧唯一正确的锚点来源。
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
              ? _refusedReadOutcome(tc, summary, subject, stage)
              : await _runTool(tc, tool, summary, subject, isStateTool);
      _outcomes.add(outcome);
      // 工具卡片收口：完成 / 失败状态与一行结果说明（缺少这一步，UI 的
      // 工具框会永远停在「正在执行…」）。
      onToolFinished?.call(outcome);
      if (!outcome.applied && isStateTool) {
        _modelProblems.add('${tc.name} → ${outcome.modelOutput}');
      }
      // 本次调用带给模型的栏目全文（读取成功 / 编辑回传）：登记后，非正文阶段
      // 对这些栏目的重复读取会被拒绝（[_refusedRepeatRead]）。
      _noteSectionsProvided(tc, outcome, executed: !refusedRead);
      _appendCallItems(
        tc,
        outcome,
        callIndex: callIndex,
        frameContent: result.content,
      );
    }
  }

  /// 非正文阶段护栏：**本轮已提供过全文的栏目**不再重复读取。
  ///
  /// 写正文 / 写大纲不改变状态（只有编辑会），所以准备阶段读到的快照就是记忆帧
  /// 与维护帧唯一正确的锚点来源——它们已在上下文中（`_pruneStaleReadState`
  /// 之前不会失效）。模型习惯「写完再查一遍再改」时，这一次多余查询本身要花掉
  /// 一个帧：这里直接不执行并回传一句方向性说明（下一帧指令还会再次点名），
  /// 促使它直接用已有全文的锚点编辑。
  ///
  /// 未提供过的栏目（准备阶段漏读、或读取被截断）照常执行——非合规流程仍能
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
    AgentStage stage,
  ) {
    final section = _readSectionByTool[tc.name]!;
    final editTool = agentEditToolName(section);
    // 阶段不同，「该干什么」不同：记忆帧只接受历史编辑器；维护帧接受清单里的
    // 编辑器（Lv.1 只有历史，Lv.2 可能是其一）。
    final onlyHistory = stage == AgentStage.memory;
    final action = onlyHistory
        ? 'then call $editTool NOW in this same turn ($editTool is the only '
            'call accepted here)'
        : 'then call the editor for each listed section NOW in this same turn '
            '($editTool for this one)';
    final actionZh = onlyHistory
        ? '并在本回合直接调用 $editTool（本回合只接受编辑器调用）'
        : '并在本回合直接按清单调用对应编辑器（本栏用 $editTool）';
    return AgentToolOutcome(
      name: tc.name,
      callId: tc.id,
      argsSummary: summary,
      subject: subject,
      applied: false,
      message: '本轮已提供该栏目全文，本阶段不再重复读取',
      modelOutput:
          'You ALREADY have this section\'s full text in this '
              'conversation — it was returned by your own read earlier this '
              'round (writing the story / the outline changed nothing), and the '
              'section never changes except through your edits. Nothing was '
              'read again: copy `before` anchors VERBATIM from the '
              '`<${section.tag}>` block already above, $action. '
              '该栏目的全文**已在对话中**（你本轮早先自己读取的结果；'
              '写正文 / 写大纲不会改变状态，只有编辑会），本次不再重复读取：'
              '请直接从上面已有的 `<${section.tag}>` 块**逐字复制** `before` 锚点，'
              '$actionZh。',
      // 非状态缺口：不写入缺项清单（它属于流程违规，不是待修栏目）。
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
/// - **正文阶段**：帧内容先缓冲，出现 `## 剧情演绎` 标题才开始上屏（从标题处起），
///   开场白永不可见；每帧首次上屏前先发 [AiStreamChunk.narrativeReset]，
///   使「后到的完整标题帧覆盖前一帧」在界面上表现为正文块重置重流；
/// - **准备 / 记忆 / 维护阶段**：文本通道关闭，正文增量一律丢弃——准备阶段的
///   大纲与搜索开场白、记忆阶段的抢写正文、维护阶段的工具说明都不该出现在
///   正文块里。
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
