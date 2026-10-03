/// Agent **阶段帧指令**的纯构建器（单一真源）。
///
/// 分工：执行器（`AgentRoundRunner`）决定「什么时候发哪一帧、帧预算用在哪」，
/// 本类只决定「这一帧说什么」。文案搬迁自 `AgentRoundRunner` 的私有构建逻辑，
/// **逐字节未变**；开放出来是为了让 `prompt_interface.dart` 的实现与执行器
/// 读同一份文案（替换提示词时不会漏掉阶段帧）。
///
/// 输出统一为 `{'role': 'user', 'content': ...}` 的帧指令消息：Chat 与 Responses
/// 两条线路共用同一形态，线路差异由执行器的报文层处理。
library;

import '../../models/agent_mode_level.dart';
import '../../utils/memory_entry_format.dart';
import '../memory_merge_planner.dart';
import '../prompt_formats.dart';
import 'agent_mode_profile.dart';
import 'state/agent_state_working_copy.dart';
import 'state/state_tools.dart';

class AgentStageDirectives {
  const AgentStageDirectives();

  /// 维护 / 修复帧一次最多下发的清单条数（其余留给后续修复帧）。
  static const int maxStateProblems = 8;

  // ---------------------------------------------------------------------------
  // 记忆阶段（仅 Lv.1）
  // ---------------------------------------------------------------------------

  /// 记忆阶段帧指令：正文取自 [AgentLv1PromptFormat.memoryNote]（与系统契约、
  /// 用户消息同一真源），前面加一行阶段说明，后面接尚未落地的合并指令行。
  ///
  /// [first] = 主帧（false = 重试帧）；[workingCopy] 用于判定本轮条目 / 合并
  /// 是否已落地——判定只看工作副本事实，不采信模型自述。
  Map<String, dynamic> memoryDirective({
    required bool first,
    required AgentStateWorkingCopy workingCopy,
    MemoryMergePlan? memoryMergePlan,
  }) {
    const format = AgentLv1PromptFormat();
    final note = format.memoryNote().join('\n');
    final mergeLines = pendingMemoryMergeLines(
      workingCopy: workingCopy,
      memoryMergePlan: memoryMergePlan,
    );
    final entryWritten = memoryEntryCount(
          workingCopy.memorySummary,
          workingCopy.roundIndex,
        ) ==
        1;
    final lead = first
        ? '[History entry · before the story] Your outline for this round is '
            'already in this conversation. '
            '记忆阶段（正文之前）：本轮大纲已在上方。'
        : entryWritten
            ? '[History entry · merge still missing] This round\'s entry is in '
                'place, but the memory merge required above is NOT done yet. '
                '历史栏已有本轮条目，但上面要求的合并还没完成。'
            : '[History entry · still missing] The history section still does '
                'not hold this round\'s single entry. '
                '历史栏仍没有本轮那一条。';
    return {
      'role': 'user',
      'content': [lead, note, ...mergeLines].join('\n'),
    };
  }

  /// 尚未落地的「记忆合并」指令行（无动作 / 已落地 → 空）。
  ///
  /// Lv.1 记忆帧与 Lv.2 维护帧清单共用同一判定：以**工作副本当前文本**为准，
  /// 模型一旦合并成功即不再重复要求。
  List<String> pendingMemoryMergeLines({
    required AgentStateWorkingCopy workingCopy,
    MemoryMergePlan? memoryMergePlan,
  }) {
    final plan = memoryMergePlan;
    if (plan == null || !plan.hasAction) return const [];
    if (isMemoryMergeApplied(workingCopy.memorySummary, plan)) return const [];
    return memoryMergeAgentDirectiveLines(plan);
  }

  // ---------------------------------------------------------------------------
  // 维护 / 修复帧（Lv.1 / Lv.2）
  // ---------------------------------------------------------------------------

  /// 维护帧指令：Lv.1 只补历史条目，Lv.2 逐栏目编辑世界 / 角色 / 历史。
  ///
  /// [problems] = 应用侧缺口清单（`StateGap.modelText` 等），按
  /// 记忆 → 角色 → 世界 → 其他 排序后至多取 [maxStateProblems] 条；
  /// [first] = 主帧（false = 修复帧）。清单为空时只发指令头（不出现空条目）。
  Map<String, dynamic> stateDirective({
    required List<String> problems,
    required bool first,
    required AgentModeLevel level,
  }) {
    final head = level == AgentModeLevel.lv1
        ? _lv1StateHead(first: first)
        : _lv2StateHead(first: first, level: level);
    // 优先级排序：记忆（轮次义务）→ 角色 → 世界 → 其余（裁短提示也可以）：
    // 模型按清单顺序执行，把最不该漏的项放最前。
    final ordered = List<String>.from(problems)
      ..sort((a, b) => _directivePriority(a).compareTo(_directivePriority(b)));
    final trimmed = ordered.take(maxStateProblems).join('\n- ');
    if (trimmed.isEmpty) return {'role': 'user', 'content': head};
    return {
      'role': 'user',
      'content': '$head\n- $trimmed',
    };
  }

  /// Lv.1 维护帧指令头：**只补历史条目**（记忆阶段没落地时的兜底）。
  ///
  /// 记忆条目的写法取自 [AgentLv1PromptFormat.memoryEditLine]（与系统契约、
  /// 记忆阶段指令同一真源），这里只补「为什么还在问这件事」与阶段纪律。
  String _lv1StateHead({required bool first}) {
    const reads = kReadHistoryToolName;
    const edits = kEditHistoryToolName;
    const entryLine = AgentLv1PromptFormat.memoryEditLine;
    if (!first) {
      return '[State-maintenance turn · fix] Fix ONLY the listed items, tool '
          'calls only (no text). The reader ($reads) is DISABLED — the '
          '<memorySummary> text is already in this conversation: copy `before` '
          'anchors VERBATIM from there (op=append needs no anchor at all). '
          '$entryLine '
          '只修复下列各项，只调工具、不要输出文本。**读取器（$reads）已禁用**'
          '——`<memorySummary>` 全文已在对话中，`before` 锚点从那里逐字复制'
          '（op=append 本就不需要锚点）。$entryLine';
    }
    return '[State-maintenance turn] The story is FINISHED above and the '
        'history (memory) section still does not hold this round\'s single '
        'entry. This turn has NO text channel — emit nothing but tool calls. '
        'The reader ($reads) is DISABLED here: its `<memorySummary>` result is '
        'ALREADY in this conversation (writing the story changed nothing), so '
        'do NOT read again — call $edits ONCE, copying its date from the '
        'outline you already made. op=noChange is NOT accepted for history. Do '
        'NOT touch world state or character state — they live in the story '
        'text, and the story is already finished. '
        '$entryLine '
        '状态维护轮：正文已完成，但历史（记忆总结）栏仍没有本轮那一条。本回合'
        '**不输出任何文本**，只调工具。**读取器（$reads）已禁用**：它的 '
        '`<memorySummary>` 结果**已在对话中**（写正文不改变状态），不要重复读取'
        '——直接调用**一次** $edits，时间用你已经定好的大纲。'
        '历史栏**不接受** op=noChange。**不要**改动世界状态 / 角色状态——'
        '它们在正文里，而正文已经写完。$entryLine';
  }

  /// Lv.2 维护帧指令头：逐栏目编辑世界 / 角色 / 历史（缺口驱动）。
  String _lv2StateHead({
    required bool first,
    required AgentModeLevel level,
  }) {
    final reads = _readToolsText(level);
    final edits = _editToolsText(level);
    return first
        ? '[State-maintenance turn] The story is FINISHED above. This turn '
            'has NO text channel — emit nothing but tool calls. '
            'The readers ($reads) are DISABLED here: their results from the '
            'story turn are ALREADY in this conversation (writing the story '
            'changed nothing), so do NOT read again — just call the editor '
            '($edits) once per listed section, copying `before` anchors '
            'VERBATIM from those results (or from the full text returned by a '
            'previous edit call). The read results do NOT include the story '
            'time, which lives in the story body as `## 当前时间`. '
            'Fill in ALL listed items in this FIRST response; if the '
            'output limit forces a split, do history (memory) and character '
            'state FIRST, world state may follow in the next frame. '
            'Prefer REAL EDITS over noChange: every line the story moved '
            '(a reaction, a thought, a move) is one op=set; noChange is only '
            'for what truly did not change. '
            '状态维护轮：正文已在上方完成，本回合不产出任何文本，只调工具。'
            '**读取器（$reads）在本回合已禁用**：正文回合读到的结果**已在对话中**'
            '（写正文不改变状态），不要再读取——直接按清单逐栏目各调用一次对应'
            '编辑器（$edits），`before` 锚点从那些结果（或此前编辑回传的栏目全文）'
            '中逐字复制；结果**不含时间**——时间在正文 `## 当前时间` 小节里。'
            '**第一个响应就完成清单全部项目**；若受输出限制装不下，'
            '**先做历史（记忆）与角色状态**，世界状态留到下一帧。'
            '**优先真实编辑而非 noChange**：正文里动过的一行（一句反应、一段心理、'
            '一次移动）就是一条 op=set；noChange 只留给确实没变的内容。'
        : '[State-maintenance turn · fix] Fix ONLY the items below, tool calls '
            'only (no text). The readers ($reads) are DISABLED — reuse '
            'the results already in this conversation and the failure-reply '
            'full texts to re-copy anchors; only if an anchor cannot be '
            'located in them, rewrite that whole section with op=reset. Fill in '
            'ALL listed '
            'items (history/memory and character state first if the output '
            'limit forces a split). '
            '只修复下列各项，只调工具、不要输出文本。**读取器（$reads）已禁用**'
            '——锚点从对话中已有的结果块与失败回传的栏目全文中复制；'
            '确实定位不到才用 op=reset 整栏重写。**清单必须全部完成**'
            '（装不下时优先历史（记忆）与角色状态）。';
  }

  /// 本档位读取器名一览（维护帧指令与护栏文案共用）。
  static String _readToolsText(AgentModeLevel level) =>
      [for (final s in AgentModeProfile.of(level).toolSections)
        agentReadToolName(s)].join(' / ');

  /// 本档位编辑器名一览。
  static String _editToolsText(AgentModeLevel level) =>
      [for (final s in AgentModeProfile.of(level).toolSections)
        agentEditToolName(s)].join(' / ');

  /// 指令项的优先级（数值越小越靠前）：记忆 > 角色 > 世界 > 其他。
  static int _directivePriority(String line) {
    if (line.contains('memorySummary')) return 0;
    if (line.contains('characterState')) return 1;
    if (line.contains('worldState')) return 2;
    return 3;
  }
}
