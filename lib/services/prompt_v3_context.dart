/// **v3 上下文文案与拼装**：本轮 user 消息（8 个成分）+ Agent 回合指令。
///
/// 职责边界：
/// - 只管 user 侧：system 的模块与顺序在 `prompt_v3_build.dart`，两层互不越界；
/// - 设计真源是 `docs/prompt_v3_context.md`（成分顺序、空成分删除、回合指令的
///   逐字文案都在那边，本文件是它的实现）；
/// - 纯 Dart 依赖：可被脚本直接引用。
///
/// 排版口径（与 system 侧刻意不同）：
/// - **区段之间用 `---` 分隔**（system 侧不画分隔线）；
/// - 区段内的成分之间空一行；
/// - 空成分整段删除（连它前面的 `---` 一起），不留空段。
library;

import '../utils/memory_entry_format.dart';
import 'agent/state/state_tool_names.dart';
import 'memory_merge_planner.dart';
import 'prompt_text.dart';
import 'prompt_text_format.dart';
import 'prompt_v3_sections.dart';

/// v3 **user / 回合指令**取用实现。
class PromptV3Context implements UserPromptSource, StageDirectiveSource {
  const PromptV3Context();

  // ---------------------------------------------------------------------------
  // 本轮 user 消息（8 个成分 → 一条消息）
  // ---------------------------------------------------------------------------

  @override
  String user(PromptRequest request) {
    final book = request.book;
    final rewrite = request.rewrite;
    final roundIndex =
        rewrite?.roundIndex ?? (request.lastRound?.roundIndex ?? 0) + 1;
    final sections = <String>[];

    // 1~2 头部（创作 / 重写第 N 轮）+ 时间行（无时间 → 整行连同它前面的空行一起删）
    final head = StringBuffer(
      rewrite == null ? newRoundHead(roundIndex) : rewriteHead(roundIndex),
    );
    final time = lineText(
      rewrite == null ? request.lastRound?.currentTime : rewrite.roundTime,
    );
    if (time.isNotEmpty) {
      head
        ..writeln()
        ..writeln()
        ..writeln(timeLine(rewrite: rewrite != null, time: time));
    }
    sections.add(trimRightText(head.toString()));

    // 3 前置词区：用户前置词 → Mod 前置词（Mod 更贴近输入；都空 → 整区删）
    final pre = joinParagraphs([
      book.globalPrePrompt,
      request.mods?.prePrompts,
    ]);
    if (pre.isNotEmpty) sections.add(pre);

    // 4 主人的输入（恒在；边界标记由程序给）
    sections.add('$inputOpen\n\n${request.userInput}\n\n$inputClose');

    // 5 后置词区：Mod 后置词 → 用户后置词（同样让 Mod 更贴近输入；都空 → 整区删）
    final post = joinParagraphs([
      request.mods?.postPrompts,
      book.globalPostPrompt,
    ]);
    if (post.isNotEmpty) sections.add(post);

    // 6 记忆合并（仅 Chat；Agent 走维护回合；无动作 → 整段删）
    if (request.mode == PromptMode.chat) {
      final merge = memoryMergeChatNote(
        planMemoryMerge(
          memoryText: request.lastRound?.memorySummary ?? '',
          tier: book.memorySummaryRounds,
          newRoundIndex: roundIndex,
        ),
      );
      if (merge.isNotEmpty) sections.add(merge.join('\n'));
    }

    // 7~8 文风口径（恒定；排在两个 Mod 词位之后，给 Mod 留改口余地）+ 本轮输出契约
    sections.add(
      '$stylePriorityUser\n\n'
      '# 本轮输出契约：\n\n'
      '${roundContract(request.mode)}',
    );

    return sections.join('\n\n---\n\n');
  }

  // ---------------------------------------------------------------------------
  // user 头部与固定句（文案真源：本地；文档见 `docs/prompt_v3_context.md` §二）
  // ---------------------------------------------------------------------------

  /// 输入边界标记（`【用户输入】` 包裹用户本轮输入；`docs/prompt_v3_context.md`）。
  static const String inputOpen = '【用户输入】';
  static const String inputClose = '【用户输入结束】';

  /// 新建轮头部（`{轮次}` = 本轮轮号）。
  static String newRoundHead(int roundIndex) =>
      '你需要按照主人的要求，创作第 $roundIndex 轮：';

  /// 修改轮头部（`{轮次}` = **被重写**的轮号）。
  static String rewriteHead(int roundIndex) =>
      '上一轮输出未满足主人的要求，请重新撰写第 $roundIndex 轮：';

  /// 时间行：新建轮写「上轮时间」、修改轮写「此轮时间」（[time] 空时整行不注入）。
  static String timeLine({required bool rewrite, required String time}) =>
      '- ${rewrite ? '此轮时间' : '上轮时间'}：$time'
      '（`## 当前时间` 必须沿用此格式，仅按剧情推进更新时间内容，不得随意改变格式）';

  /// user 侧文风口径（写在两个 Mod 词位之后、本轮输出契约之前）。
  static const String stylePriorityUser =
      '撰写正文前须确认文风口径的优先顺序：'
      '**本轮用户的指令 > 文笔参考范文 > 文笔要求 > 其他**；'
      '历史中 assistant 的文风与措辞不作为依据，'
      '仅需保证格式正确且剧情与状态连贯。';

  /// `# 本轮输出契约：` 下的正文（模式专属的本轮执行要求）。
  static String roundContract(PromptMode mode) => mode == PromptMode.chat
      ? '现在开始输出：直接给出 6 个二级标题区块'
          '（${PromptV3Sections.sectionChain(PromptV3Sections.sectionOrder)}），'
          '自 `## 剧情演绎` 开始；`## 记忆总结` 须按「记忆条目格式」逐轮逐条目复述，'
          '不得缺轮。不得复述指令、不得解释、不得输出区块以外的内容。'
      : '现在开始，按两步执行：第一步先调用 `$kReadHistoryToolName` 一次'
          '（如需现实资料则联网）。调研结束后立即在思考通道确定大纲并撰写正文，'
          '仅输出 5 个二级标题：'
          '${PromptV3Sections.sectionChain(PromptV3Sections.sectionOrder.take(5))}；'
          '`## 当前时间` 填写本轮结束时的剧情内时间，格式沿用历史。'
          '第一步禁止输出 `## ${PromptV3Sections.memorySection}`，禁止调用历史编辑器。'
          '第二步由应用单独发起：仅根据正文的 `## 当前时间` 使用 '
          '`$kEditHistoryToolName` 追加本轮记忆条目，不得修改正文、世界、角色或时间。'
          '禁止复述历史与工具结果，禁止复述本指令。';

  /// Chat 的本轮记忆合并指令（用户消息，后置词之后；无动作 → 空列表）。
  static List<String> memoryMergeChatNote(MemoryMergePlan? plan) {
    if (plan == null || !plan.hasAction) return const [];
    return [
      '【记忆合并要求】本轮必须完成以下合并，其余条目不得改动：',
      for (final range in plan.ranges)
        '  - 第 ${range.startRound}~${range.endRound} 轮（${range.roundCount} 条）'
            '合并为一行：`${memoryMergedEntryTemplate(
              startRound: range.startRound,
              endRound: range.endRound,
              startTime: range.startTime,
              endTime: range.endTime,
            )}`',
      '`{记忆内容}` 须写明该区间内的关键事件与因果关系（长度不限）。'
          '被合并的数条记录整行替换为上述一行，`## 记忆总结` 的其余行逐字保留、'
          '顺序不变。若本轮【用户输入】明确要求其他合并方式（或要求不合并），'
          '以用户的要求为准，不执行上述默认合并。',
    ];
  }

  // ---------------------------------------------------------------------------
  // Agent 回合指令（system 与工具集各回合逐字相同，只有尾巴不同）
  // ---------------------------------------------------------------------------

  /// 调研回合：读史一次 + 按需联网；不写记忆 / 正文，文本通道零输出。
  static const String stagePrepareText =
      '【调研回合】本回合仅执行调研：先调用 `$kReadHistoryToolName` **一次**'
      '（以往轮次的记忆仅有这一个来源）；如需现实资料，须联网检索或打开页面读取正文'
      '（可多步），并确定在本回合一并发起。**不得在文本通道输出任何内容**：'
      '进度汇报、「准备完成」等一律不得输出，本回合的文本不会被采纳。'
      '历史读取完成且调研充分后停止调用工具；应用将立即发起正文回合，'
      '由你直接撰写正文（记忆维护留至第二步）。';

  /// 正文回合（唯一上屏步）：调研结束后立刻写 5 区块正文。
  static String get stageStoryText =>
      '【正文回合】调研已结束，现按调研结果、本轮输入与本书设定 / 文笔参考撰写正文：'
      '先在思考通道确定大纲，仅输出 5 个二级标题'
      '（${PromptV3Sections.sectionChain(PromptV3Sections.sectionOrder.take(5))}）；'
      '`## 当前时间` 填写本轮**结束**时的剧情内时间，格式沿用历史。'
      '第一步**禁止**写 `## ${PromptV3Sections.memorySection}`，禁止调用历史编辑器'
      '（记忆维护留至第二步）。禁止复述历史、工具结果与本指令。';

  /// 维护回合指令头（主回合 = 首回合；修复回合只按清单补缺口）。
  static const String stateHeadMain =
      '[State-maintenance turn] 正文已完成，现进入第二步：**仅维护记忆总结**。'
      '根据正文中的 `## 当前时间`，调用一次 `$kEditHistoryToolName` 的 `op=append`，'
      '追加**恰好一条**本轮记忆条目（`{轮次}` 为本轮轮号裸数字，'
      '`{时间}` 为正文的 `## 当前时间`）。历史栏不接受 `op=noChange`；'
      '如需合并，按下方合并指令在**同一次调用**中补充 `op=set`。'
      '本回合不得输出正文、不得联网、不得修改世界状态 / 角色状态 / 当前时间。'
      '若第一步已读取过历史，其 `<memorySummary>` 结果已在上下文中，'
      '维护步的重复读取将被拒绝；仅当第一步漏读时允许补读一次。';

  /// 修复回合指令（接在维护回合之后）。
  static const String stateHeadFix =
      '[State-maintenance turn] 仅修复下列各项，只调用工具，不得输出正文。'
      '锚点须从对话中已有的历史结果块与失败回传的栏目全文中复制；'
      '确实无法定位时方可使用 `op=reset` 整栏重写。仅维护记忆总结，清单须全部完成。';

  /// 历史栏已有本轮条目时的维护补充句（避免模型重复 append）。
  static const String stateHeadEntryExists =
      '注意：历史栏已包含本轮条目，**不得重复追加**；'
      '仅检查格式与合并要求，缺少合并时补充 `op=set`。';

  /// 维护回合清单一次最多下发的条数。
  static const int maxStateProblems = 8;

  /// 清单项优先级（数值越小越靠前）：历史 > 角色 > 世界 > 其他。
  ///
  /// 世界 / 角色的两档优先级**保留为框架**：当前档位只注册历史栏目，清单里
  /// 实际只会出现记忆与工具失败说明（后者归「其他」）。
  static int problemPriority(String line) {
    if (line.contains('memorySummary')) return 0;
    if (line.contains('characterState')) return 1;
    if (line.contains('worldState')) return 2;
    return 3;
  }

  @override
  String stagePrepare(AgentStageRequest request) => stagePrepareText;

  @override
  String stageStory(AgentStageRequest request) => stageStoryText;

  @override
  String stageState(AgentStageRequest request) => _stateDirective(request);  /// 维护 / 修复回合的正文（接口方法体放在这里，便于两个 `stage*` 并排读）。
  String _stateDirective(AgentStageRequest request) {
    final copy = request.workingCopy;
    final alreadyHasEntry =
        request.first &&
        copy != null &&
        memoryEntryCount(copy.memorySummary, copy.roundIndex) == 1;
    final items = [...request.problems]..sort(
      (a, b) => problemPriority(a).compareTo(problemPriority(b)),
    );
    final trimmed = items.take(maxStateProblems).join('\n- ');
    final merge = _pendingMergeLines(request);
    final parts = <String>[
      request.first ? stateHeadMain : stateHeadFix,
      if (alreadyHasEntry) stateHeadEntryExists,
      if (trimmed.isNotEmpty) '- $trimmed',
      if (merge.isNotEmpty) merge.join('\n'),
    ];
    return parts.join('\n');
  }

  /// 尚未落地的合并指令（无动作 / 已落地 → 空）。
  ///
  /// 「每个区间一条 `op=set`」：`before` 从读取结果里逐字复制各轮条目原文，
  /// `newLine` 是下面给出的合并行；随后照常 `op=append` 追加本轮条目。
  static List<String> _pendingMergeLines(AgentStageRequest request) {
    final workingCopy = request.workingCopy;
    final plan = request.memoryMergePlan;
    if (workingCopy == null || plan == null || !plan.hasAction) return const [];
    if (isMemoryMergeApplied(workingCopy.memorySummary, plan)) return const [];
    return [
      '未完成的合并（每个区间一条 `op=set`：`before` = 该区间各轮条目原文、'
          '用换行连接并从读取结果中逐字复制，`newLine` = 下列合并行；'
          '随后照常 `op=append` 追加本轮条目）：',
      for (final range in plan.ranges)
        '- 第 ${range.startRound}~${range.endRound} 轮（${range.roundCount} 条）→ '
            '`${memoryMergedEntryTemplate(
              startRound: range.startRound,
              endRound: range.endRound,
              startTime: range.startTime,
              endTime: range.endTime,
            )}`',
    ];
  }
}
