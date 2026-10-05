/// **v2 提示词实现**：按 `docs/ai_prompt_v2.md` 的「总模板」与「格式模板」拼装。
///
/// 职责边界：
/// - 本文件只负责**拼接顺序与空块删除**（无内容即删块、`#` 区域 + `---` 分隔）；
/// - 文案一律来自 `prompt_v2_sections.dart`；
/// - 工具清单一律来自 `prompt_v2_tools.dart`；
/// - **不涉及**历史 messages 数组、报文 / 线路 / 采样参数、vision 图片
///   （这些由 `RoundProvider` + `wire_adapters` 负责，见 `docs/prompt_interface.md`）。
///
/// 与 v1 的差异（v2 设计）：`#` 一级标题 + `---` 切分区域、口语化简明中文、
/// 空块整块删除、不举例、不约束思考链格式（但保留「定大纲」等功能性要求）。
library;

import '../models/role_category.dart';
import '../utils/memory_entry_format.dart';
import 'memory_merge_planner.dart';
import 'prompt_text.dart';
import 'prompt_v2_sections.dart';

/// v2 **文本**取用实现：system（总模板）/ user（新建轮注入）/ Agent 阶段帧指令。
///
/// 工具集不在这里——由 `prompt_v2_tools.dart` 与 `prompt_interface.dart` 的
/// [PromptV2] 聚合提供；本类只依赖纯 Dart 模块，可被脚本 / CLI 直接引用。
class PromptV2Build
    implements SystemPromptSource, UserPromptSource, StageDirectiveSource {
  const PromptV2Build();

  // ---------------------------------------------------------------------------
  // system（总模板）
  // ---------------------------------------------------------------------------

  @override
  String system(PromptRequest request) {
    final book = request.book;
    final mode = request.mode;
    final blocks = <String>[];

    // —— 头部：固定行 + 书籍信息 + Mod（Mod 抬升到 `# 总协议：` 之前）——
    final head = StringBuffer();
    head.writeln(PromptV2Sections.persona);
    head.writeln();
    head.writeln('- ${PromptV2Sections.sandboxPosition}');
    head.writeln('- 当前请求协议：${_modeLabel(mode)}。');
    head.writeln('- ${PromptV2Sections.obedience}');
    _writeField(head, '- 当前书籍名：', book.title);
    _writeField(head, '- 当前书籍分类：', book.category);
    // 文笔要求可能多行：保留换行（不折叠）；与「文笔参考范文」冲突时以本条为准。
    final writingRequirements = _block(book.writingRequirements);
    if (writingRequirements.isNotEmpty) {
      head.writeln(
        '- 文笔要求 *（冲突以此为准）*：$writingRequirements',
      );
    }
    // Mod 抬升：排在书籍信息（含文笔要求）之后、`# 总协议：` 之前。
    final modSystem = _block(request.mods?.systemPrompts);
    if (modSystem.isNotEmpty) {
      head.writeln();
      head.writeln(modSystem);
    }
    blocks.add(_trimRight(head.toString()));

    // —— # 总协议：共用部分 + 记忆格式 + 模式契约 +（Agent）工具契约 + 合并策略 ——
    final contract = <String>[
      ...PromptV2Sections.sharedContractLines,
      '',
      ...PromptV2Sections.memoryFormatLines(),
      '',
      ...PromptV2Sections.modeContractLines(mode),
      if (mode != PromptMode.chat) ...[
        '',
        ...PromptV2Sections.toolContractLines(),
      ],
      '',
      ...PromptV2Sections.memoryMergePolicyLines(book.memorySummaryRounds),
    ].join('\n');
    blocks.add('# 总协议：\n\n$contract');

    // —— 书籍设定 + 世界书（同一区域；各小节为空即整块删除）——
    final worldBook = _joinParagraphs([
      request.worldBookEntries,
      request.mods?.worldBooks ?? '',
    ]);
    final lore = <String>[
      if (_block(book.baseSetting).isNotEmpty)
        '# 书籍设定和要求：\n\n${_block(book.baseSetting)}',
      if (worldBook.isNotEmpty) '# 世界书：\n\n$worldBook',
    ];
    if (lore.isNotEmpty) blocks.add(lore.join('\n\n'));

    // —— 角色状态栏协议（层级 + 类别格式）+ 完整性要求 ——
    blocks.add(_roleStateBlock(book.roleHierarchy, book.roleCategories));

    // —— 文笔参考范文（无内容 → 整个 `#` 板块删除）——
    final style = _block(book.writingStyle);
    if (style.isNotEmpty) {
      blocks.add(
        '# 文笔参考范文：\n\n${PromptV2Sections.styleReferenceLead}\n\n$style',
      );
    }

    // —— 执行惩罚和奖励 ——
    blocks.add('# 执行惩罚和奖励：\n\n${PromptV2Sections.endNote}');

    return blocks.join('\n\n---\n\n');
  }

  // ---------------------------------------------------------------------------
  // user（新建轮 / 修改轮注入）
  // ---------------------------------------------------------------------------

  /// 本轮 user 注入模板：新建轮与**修改轮**（按意见重写某一轮）同构，只有头部两处
  /// 不同——标题「创作第 {轮次} 轮」↔「重写第 {轮次} 轮」、时间标签
  /// 「上轮时间」↔「此轮时间」（取自 [PromptRequest.rewrite]，见 v2 格式模板）。
  ///
  /// 修改轮的 [PromptRequest.lastRound] 是**被重写轮的上一轮**（生成基座），因此
  /// 记忆合并等一律以它为基准；`userInput` 是用户填写的修改意见。
  @override
  String user(PromptRequest request) {
    final book = request.book;
    final mode = request.mode;
    final rewrite = request.rewrite;
    final roundIndex =
        rewrite?.roundIndex ?? (request.lastRound?.roundIndex ?? 0) + 1;
    final blocks = <String>[];

    // —— 头部：轮次 + 上轮 / 此轮时间（无时间 → 整条不注入）——
    final head = StringBuffer(
      rewrite == null
          ? PromptV2Sections.newRoundHead(roundIndex)
          : PromptV2Sections.rewriteHead(roundIndex),
    );
    final time = _line(
      rewrite == null ? request.lastRound?.currentTime : rewrite.roundTime,
    );
    if (time.isNotEmpty) {
      head.writeln();
      head.writeln();
      head.writeln(
        PromptV2Sections.timeLine(rewrite: rewrite != null, time: time),
      );
    }
    blocks.add(_trimRight(head.toString()));

    // —— 前置词：用户前置词 → Mod 前置词（都空 → 整区删除）——
    final pre = _joinParagraphs([
      book.globalPrePrompt,
      request.mods?.prePrompts ?? '',
    ]);
    if (pre.isNotEmpty) blocks.add(pre);

    // —— 主人的输入（恒定注入）——
    blocks.add('【主人的输入】\n\n${request.userInput}\n\n【主人的输入stop】');

    // —— 后置词：Mod 后置词 → 用户后置词（都空 → 整区删除）——
    final post = _joinParagraphs([
      request.mods?.postPrompts ?? '',
      book.globalPostPrompt,
    ]);
    if (post.isNotEmpty) blocks.add(post);

    // —— Chat 的本轮记忆合并指令（后置词之后；Agent 走阶段帧）——
    if (mode == PromptMode.chat) {
      final merge = PromptV2Sections.memoryMergeChatNote(planMemoryMerge(
        memoryText: request.lastRound?.memorySummary ?? '',
        tier: book.memorySummaryRounds,
        newRoundIndex: roundIndex,
      ));
      if (merge.isNotEmpty) blocks.add(merge.join('\n'));
    }

    // —— 文风口径（恒定注入；写在两个 `{}` 词位之后，为 Mod 留出改口余地）——
    blocks.add(PromptV2Sections.stylePriorityUser);

    // —— # 总协议2：模式专属「现在开始做什么」——
    blocks.add('# 总协议2\n\n${PromptV2Sections.userContract(mode)}');

    return blocks.join('\n\n---\n\n');
  }

  // ---------------------------------------------------------------------------
  // Agent 阶段帧指令
  // ---------------------------------------------------------------------------

  @override
  String stagePrepare(AgentStageRequest request) => PromptV2Sections.stagePrepare;

  @override
  String stageMemory(AgentStageRequest request) {
    final workingCopy = request.workingCopy;
    if (workingCopy == null) {
      throw ArgumentError.notNull(
        'AgentStageRequest.workingCopy（记忆回合需要工作副本判定本轮条目 / 合并）',
      );
    }
    final entryWritten = memoryEntryCount(
          workingCopy.memorySummary,
          workingCopy.roundIndex,
        ) ==
        1;
    final lead = request.first
        ? PromptV2Sections.stageMemoryLeadFirst
        : entryWritten
            ? PromptV2Sections.stageMemoryLeadMergeMissing
            : PromptV2Sections.stageMemoryLeadEntryMissing;
    return [
      lead,
      '',
      PromptV2Sections.stageMemoryBody(),
      ..._pendingMergeLines(request),
    ].join('\n');
  }

  @override
  String stageStory(AgentStageRequest request) => PromptV2Sections.stageStory;

  @override
  String stageState(AgentStageRequest request) {
    final head = PromptV2Sections.stateHead(
      level: request.level,
      first: request.first,
    );
    final items = <String>[
      ...request.problems,
      ..._pendingMergeLines(request),
    ]..sort(
        (a, b) => PromptV2Sections.problemPriority(a)
            .compareTo(PromptV2Sections.problemPriority(b)),
      );
    final trimmed = items.take(PromptV2Sections.maxStateProblems).join('\n- ');
    if (trimmed.isEmpty) return head;
    return '$head\n- $trimmed';
  }

  // ---------------------------------------------------------------------------
  // 组装小工具
  // ---------------------------------------------------------------------------

  /// 尚未落地的「记忆合并」指令行（无动作 / 已落地 → 空）。
  static List<String> _pendingMergeLines(AgentStageRequest request) {
    final workingCopy = request.workingCopy;
    final plan = request.memoryMergePlan;
    if (workingCopy == null || plan == null || !plan.hasAction) return const [];
    if (isMemoryMergeApplied(workingCopy.memorySummary, plan)) return const [];
    return PromptV2Sections.memoryMergeAgentLines(plan);
  }

  /// 模式标记：Agent 两档都写 `Agent`（不写等级）。
  static String _modeLabel(PromptMode mode) =>
      mode == PromptMode.chat ? 'Chat' : 'Agent';

  /// 多行块值：只去首尾空白，**保留内部换行**。
  ///
  /// 书籍设定 / 世界书 / 文笔参考 / 角色类别格式 / Mod 文案 / 前后置词都是用户
  /// 填写的多行文本——折叠换行会把它们的结构压成一行（v2 曾有此缺陷）。
  static String _block(String? raw) => (raw ?? '').replaceAll('\r\n', '\n').trim();

  /// 单行字段值：折叠内部换行（书籍名 / 分类 / 上轮时间 / 角色层级这类
  /// 只能占一行的字段，换行会破坏 `- 字段：值` 的结构）。
  static String _line(String? raw) =>
      _block(raw).replaceAll(RegExp(r'\s*\n\s*'), ' ');

  /// 写入 `标签：值` 行（值为空时整行不注入）。
  static void _writeField(StringBuffer buf, String label, String? value) {
    final text = _line(value);
    if (text.isEmpty) return;
    buf.writeln('$label$text');
  }

  /// 多段文本拼接（跳过空段；段间空行；各段保留自身换行）。
  static String _joinParagraphs(List<String> parts) => parts
      .map(_block)
      .where((p) => p.isNotEmpty)
      .join('\n\n');

  /// 角色状态栏协议（层级 + 类别格式，无内容的小节整块删除）+ 完整性要求。
  ///
  /// 段与段之间只留**一个空行**（与总模板的排版一致；多余空行会被 AI 当成
  /// 结构噪声）。
  static String _roleStateBlock(
    String hierarchy,
    List<RoleCategory> categories,
  ) {
    final parts = <String>[];
    final hierarchyText = _line(hierarchy);
    if (hierarchyText.isNotEmpty) {
      parts.add('角色层级排序规则：`$hierarchyText`');
    }
    final used = [
      for (final c in categories)
        if (_block(c.format).isNotEmpty) c,
    ];
    if (used.isNotEmpty) {
      final buf = StringBuffer(
        '角色类别描述格式（`## 角色状态` 必须按此组织每个角色的属性项）：',
      );
      for (final c in used) {
        buf.writeln();
        buf.writeln();
        buf.writeln('【${c.name}】');
        buf.writeln();
        buf.writeln(_block(c.format));
      }
      parts.add(_trimRight(buf.toString()));
    }
    return [
      if (parts.isNotEmpty) '# 角色状态栏协议：\n\n${parts.join('\n\n')}',
      '# 角色状态完整性要求：\n\n'
          '${PromptV2Sections.characterStateCompleteness}',
    ].join('\n\n');
  }

  static String _trimRight(String raw) {
    final lines = raw.split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }
}
