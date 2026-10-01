/// 模式格式生成要求：Chat / Agent Lv.1 / Agent Lv.2 各自特有的提示词文案与
/// 规则，单一真源。
///
/// 共享提示词的文案与组装流程在 `PromptSections`（见 `prompt_sections.dart`），
/// 模式特有段一律由 [PromptFormatSpec] 按固定槽位提供、由共享组装插入：
///
/// - [systemHead]：系统指令「引擎身份」之后、「身份锁定」之前（若为空则跳过）；
/// - [systemAfterIdentity]：「Markdown 兼容」规则之后、Mod 系统提示词之前；
/// - [systemTail]：世界书 / Mod 世界书之后、共性收尾【警告】之前；
/// - [userHead]：用户消息开头（分隔线之前）；
/// - [userExecuteNote]：用户消息【指令执行】段（后置词之后、收尾之前）。
///
/// 各槽位返回行列表，Composer 逐行 `writeln`；行列表中的 `''` 表示输出一个
/// 空行（块内空行；末尾的空行由 `PromptSections._writeSlot` 统一折叠为一个，
/// 避免出现连续空行），空列表表示该槽位不存在。
///
/// 【文案约定（只写在源码注释里，不写进提示词）】
/// - 本文件与 `prompt_sections.dart` 的提示词文案**不使用 `#` / `##` 作为结构
///   标记**（唯一例外 = 输出契约的区块名与角色状态围栏内的形态示例）：
///   正文契约已用「只允许出现 N 个二级标题」的正向表述限定标题集合，
///   文案自身再出现 `#`/`##` 只会与区块标题混淆，并把提示词层级搅乱；
///   需要结构时统一用【】标签、`- ` 项目符号与空行。
/// - **不使用数字序号**：Markdown 有序列表在渲染时会重新编号（且只有 `1.`
///   能中断段落），「规则 N」的中英对照会因此失去对应关系；需要分条一律用
///   `- `（bullet 可中断段落，每条都能成为独立列表项）。
/// - 用户填写的文本（书籍设定 / 文笔参考 / 世界书 / Mod 文案）里的 `#`/`##`
///   由 UI 灰字提示（`PromptInputHint`）规避，同样不写进提示词。
/// - **可填取值一律用占位符，不写具体案例**：模型面向文案里的占位符统一写作
///   `{中文名}`（`{轮次}` / `{时间}` / `{记忆内容}` / `{当前时间}` / `{类别名}` /
///   `{角色名}` / `{属性名}` / `{属性值}`）——示例只表达**形状**，写死某本书的
///   角色名、类别名或日期取值会被模型当成设定照抄，也与用户实际设定冲突。
///   记忆条目的模板与「格式优先」行是跨文件共用的常量（真源 =
///   `lib/utils/memory_entry_format.dart` 的 `kMemoryEntryFormat` /
///   `kMemoryEntryFormatPrecedence`）：提示词与工具描述一律引用，不再硬编码
///   字面量；旧写法 `- 第N轮｜日期：…｜…` 只作**兼容解析**（UI 渲染与校验计数）。
///   例外（不算占位符，不改写）：`<worldState>` / `<characterState>` /
///   `<memorySummary>` 是读取结果的**字面块标签**。
library;

import '../utils/memory_entry_format.dart';
import 'agent/state/state_tool_names.dart';
import 'memory_merge_planner.dart';

/// 一种生成模式的「格式生成要求」规格。
abstract class PromptFormatSpec {
  const PromptFormatSpec();

  /// 模式标记：写入系统指令首行（`当前模式：Chat` / `当前模式：Agent`）。
  ///
  /// 只区分「Chat 模式」与「Agent 模式」，Agent 各档位不写等级
  /// （档位差异由各槽位的规则文案本身表达）。
  String get modeLabel;

  /// 槽位 1：系统指令头部格式要求（引擎身份之后、身份锁定之前）。
  List<String> get systemHead;

  /// 槽位 2：Markdown 兼容规则之后、Mod 系统提示词之前。
  List<String> get systemAfterIdentity;

  /// 槽位 3：世界书 / Mod 世界书之后、共性收尾之前。
  List<String> get systemTail;

  /// 用户消息开头（分隔线之前）。
  List<String> get userHead;

  /// 用户消息【指令执行】段（后置词之后、收尾之前）。
  List<String> get userExecuteNote;

  /// 本轮记忆总结合并指令（注入用户消息）。
  ///
  /// 默认空实现：Agent 档位的合并指令由记忆 / 维护阶段的帧指令承载
  /// （见 `agent_round_runner.dart`），只有 Chat 走用户消息注入。
  List<String> memoryMergeUserNote(MemoryMergePlan? plan) => const [];
}

/// Chat 模式的格式生成要求：二级标题区块纪律、状态快照规则、
/// 角色状态输出格式、记忆总结格式，以及用户消息的格式要求与【指令执行】。
///
/// Chat 模式（[includeMemory] = true，默认）输出与历史版本**语义一致**：
/// 本类各槽位与 `PromptSections` 的固定组装流程一一对应，改变任一槽位内容即
/// 改变 Chat 文案（唯一维护点）。
///
/// [includeMemory] = false 供 **Agent Lv.1** 复用（见 [AgentLv1PromptFormat]）：
/// 区块清单去掉「记忆总结」（该栏目在 Lv.1 由 `narrchat_editHistory` 维护），
/// 其余文案按实际区块数派生——区块数与顺序都取自 [sections]，不写死数字。
class ChatPromptFormat implements PromptFormatSpec {
  const ChatPromptFormat({this.includeMemory = true});

  /// 是否要求输出 `## 记忆总结` 区块（Lv.1 = false：历史由工具维护）。
  final bool includeMemory;

  @override
  String get modeLabel => 'Chat';

  /// 6 个二级标题区块及其固定顺序（单一真源，见 [PromptBuilder.sectionOrder]）。
  static const List<String> sectionOrder = [
    '剧情演绎',
    '推荐行动',
    '当前时间',
    '世界状态',
    '角色状态',
    '记忆总结',
  ];

  /// 记忆总结区块名（[includeMemory] = false 时从 [sections] 中排除）。
  static const String memorySection = '记忆总结';

  /// 角色状态区块正文的围栏开启标记（输出契约的一部分）。
  ///
  /// `## 角色状态` 内部用 `# 类别名` / `## 角色名` 组织属性，若不围栏就会与
  /// 正文的二级标题契约混在一起（层级倒挂）；围栏后该段在 Markdown 里是代码块，
  /// 解析侧由 `AiResponseParser` 在提取时剥离（无围栏同样兼容）。
  static const String characterStateFence = '```markdown';

  /// 本模式实际要求的区块顺序（Chat = 6 区块；Lv.1 = 排除记忆总结的 5 区块）。
  List<String> get sections => includeMemory
      ? sectionOrder
      : [
          for (final section in sectionOrder)
            if (section != memorySection) section,
        ];

  static const String obedienceHeader =
      '【绝对服从】以下规则必须无条件、无例外地严格执行，'
      '不得拒绝、不得询问、不得省略：';

  /// 区块清单引导行（按实际区块数派生：Chat = 6，Lv.1 = 5）。
  static String sectionsIntro(int count) =>
      '你必须完整输出以下 $count 个二级标题（##）区块，'
      '顺序固定、不得遗漏、不得调换、不得改名：';

  /// 二级标题纪律（区块数派生）。
  ///
  /// 只保留正向表述「只允许出现」；「其它位置禁止 #/##」这类约束不写进提示词
  /// （见文件头文案约定），仅在源码注释与输入框灰字提示中体现。
  static String headingDiscipline(int count) =>
      '【二级标题纪律】全文只允许出现上述 $count 个二级标题（##），'
      '以及 `## 角色状态` 围栏内部的一级标题 `# 类别名` 与二级标题 `## 角色名`；'
      '需要内部子结构时使用 `###`、列表或加粗。';

  static const String snapshotRule =
      '【状态快照规则】你必须把上一轮的角色状态与世界状态完整复制到输出的'
      ' `## 角色状态` 与 `## 世界状态` 中，只修改确实发生变化的条目；'
      '未变化的设定一个字都不能丢、不能改写。';

  static const String characterStateFormatHeader =
      '【角色状态输出格式】`## 角色状态` 区块的正文必须整体包在一个 '
      '```markdown 围栏内（围栏内不得再出现围栏标记），'
      '围栏内严格遵循以下结构：';

  static const String characterStateFormatLines =
      '- 每个角色类别使用一级标题 `# 类别名`，'
      '类别顺序必须与下方「角色层级排序规则」完全一致；\n'
      '- 类别下的每个角色使用二级标题 `## 角色名`；\n'
      '- 每个角色下列出属性，每行一个，格式为 `- 属性名：属性值`；\n'
      '- 必须包含该类别设定格式（见下方「角色类别描述格式」）中的全部属性项，'
      '不得缺项；属性值没有变化的一律保持上一轮原样，只更新确实变化的属性；\n'
      '- 本轮未登场的角色也必须保留其条目与全部属性，'
      '仅将状态类属性标注为“未登场（本轮未出现）”，不得删除该角色；\n'
      '- 新增登场角色按所属类别格式补全属性项。';

  /// 角色状态围栏形态示例（模型照此形状输出；围栏是解析契约的一部分）。
  ///
  /// 示例**全部为占位符**（见文件头文案约定）：只表达「类别 → 角色 → 属性行」
  /// 的形状，取值一律由本书的「角色层级排序规则」与「角色类别描述格式」决定。
  static const List<String> characterStateFormatExample = [
    '形态示例：',
    '',
    '```markdown',
    '# {类别名}',
    '## {角色名}',
    '- {属性名}：{属性值}',
    '```',
    '',
  ];

  static const String memoryFormatHeader =
      '【记忆总结格式】`## 记忆总结` 区块必须严格遵循以下格式'
      '（这是历史记录的核心结构，优先级最高）：';

  static const String memoryRuleLines =
      '- 每条记忆独占一行，格式为：`$kMemoryEntryFormat`'
      '（每条以 `- ` 列表符开头）；'
      '「轮次」「时间」「记忆内容」三者必须绑定在一条内，'
      '严禁拆行、严禁分块、严禁只写其中一项。\n'
      '- 「轮次」写本轮轮号的**裸数字**（如 34），不要写「第34轮」。\n'
      '- 从第 1 轮到本轮，每一轮都必须被一条记忆条目覆盖'
      '（单轮条目 = 一条一轮；合并区间条目 = 一条覆盖多轮，'
      '仅按下方【记忆总结·轮次合并】的档位规则生成），'
      '条目按轮次从小到大顺序排列、不得缺轮。\n'
      '- 每条条目的「时间」必须使用该轮 `## 当前时间` 的内容'
      '（剧情内时间），不得使用真实日期；写法沿用历史条目的时间写法'
      '（公历或本书自定历法皆可）。\n'
      '- 「记忆内容」用一句话概括该轮发生的核心事件与关键进展；'
      '若该轮无重要事件则写「无重要事件」。\n'
      '- 轮次增多时可压缩、精简旧条目的措辞以控制篇幅，'
      '但不得删除任何轮次条目、不得调换顺序；'
      '合并只按【记忆总结·轮次合并】的档位规则执行。\n'
      '- 上一轮 AI 返回（最后一条 assistant 消息）中的 `## 记忆总结`'
      '为已确认的历史记忆，必须完整继承并在此基础上追加本轮条目；'
      '按档位规则合并时只改写被合并的那几行，'
      '不得凭空改写、丢失或重排其它条目。\n'
      '$kMemoryEntryFormatPrecedence';

  static const String memoryFormatUserNote =
      '【记忆总结格式】`## 记忆总结` 必须按 '
      '`$kMemoryEntryFormat` '
      '逐轮输出：每条一行（以 `- ` 列表符开头），'
      '轮次、时间、记忆内容三者绑定在一条内；'
      '从第 1 轮至本轮每轮都要有覆盖'
      '（合并区间条目按【记忆总结·轮次合并】的档位规则生成），'
      '时间一律使用该轮 `## 当前时间`（详见系统指令【记忆总结格式】）。';

  @override
  List<String> get systemHead => [
        '当前模式：$modeLabel',
        '',
        obedienceHeader,
        '',
        '- ${sectionsIntro(sections.length)}',
        for (final section in sections) '  - `## $section`',
        '- ${headingDiscipline(sections.length)}',
        '- $snapshotRule',
      ];

  @override
  List<String> get systemAfterIdentity => [
        characterStateFormatHeader,
        '',
        characterStateFormatLines,
        ...characterStateFormatExample,
      ];

  @override
  List<String> get systemTail => [
        if (includeMemory) ...[
          memoryFormatHeader,
          '',
          memoryRuleLines,
          '',
        ],
      ];

  @override
  List<String> get userHead => [
        '【格式要求】本次输出必须严格遵循系统指令中的 ${sections.length} 个'
            '二级标题（##）区块，顺序为：'
            '${sections.map((s) => '`## $s`').join(' → ')}；'
            '只输出这些区块，不要添加任何其它区块。',
        // 记忆格式提醒仅 Chat 有（Lv.1 历史由工具维护，不含该段）。
        if (includeMemory) ...[
          '',
          memoryFormatUserNote,
        ],
      ];

  @override
  List<String> get userExecuteNote => [
        '【指令执行】[$modeLabel 模式] 现在请直接开始创作并完整输出 '
            '${sections.length} 个二级标题区块。'
            '不要复述指令、不要解释、不要添加任何区块以外的内容；'
            '`## 剧情演绎` 应充分推进剧情，其余区块按要求依次给出。'
            '立即从 `## 剧情演绎` 开始输出。',
      ];

  /// 本轮记忆合并指令只对**输出记忆区块**的 Chat 形态注入；
  /// Lv.1（[includeMemory] = false）继承本类但自动为空白
  /// （其合并指令由记忆阶段帧承载）。
  @override
  List<String> memoryMergeUserNote(MemoryMergePlan? plan) =>
      includeMemory ? memoryMergeDirectiveLines(plan) : const [];
}

/// 记忆总结「轮次合并」的**策略文案**（跨模式共享，单一真源）。
///
/// [tier] = 本书 `Book.memorySummaryRounds`（0 = 关闭，5 / 10 = 每个合并项
/// 包含的轮次数；受支持取值见 `Book.memorySummaryRoundTiers`）。由
/// [PromptSections.buildSystemPrompt] 按档位注入系统指令：
/// - 档位 0：明确「不主动合并、已有区间条目原样保留」；
/// - 档位 > 0：给出合并行格式（[kMemoryMergedEntryFormat]）、`2×档位` 触发规则、
///   已合并条目冻结、本轮条目不并入、用户显式要求优先。
///
/// 合并算法真源 = `lib/services/memory_merge_planner.dart`；本函数只负责文案。
List<String> memoryMergePolicyLines(int tier) {
  if (tier <= 0) {
    return const [
      '- [Memory merge · off] The tier is 0: do NOT merge memory entries '
          '(keep one entry per round). Keep any existing range entry EXACTLY as '
          'it is — never rewrite, split or drop it.',
      '- 【记忆总结·轮次合并】档位 0（关闭）：不要主动合并记忆条目，保持每轮一条；'
          '历史中已有的合并条目（区间写法）原样保留，不改写、不拆分、不删除。',
    ];
  }
  final cap = 2 * tier;
  return [
    '- [Memory merge · tier $tier] The memory section keeps one entry per '
        'round, but the UNMERGED entries (single-round entries not covered by '
        'any range entry) must never exceed $cap (= 2 × $tier). Once they '
        'reach $cap, rewrite the OLDEST $tier of them as ONE range entry '
        '`$kMemoryMergedEntryFormat` (rounds and both times filled in; '
        '{记忆内容} = what must be remembered from that span — length is up to '
        'you), and repeat until fewer than $cap unmerged entries remain. '
        'NEVER rewrite, split or reorder an existing range entry; NEVER merge '
        'the entry of the round being written. If this round\'s user input '
        'explicitly asks for another merge (or no merge), follow the user '
        'instead.',
    '- 【记忆总结·轮次合并】档位 $tier：记忆栏保持「一轮一条」，但**未合并条目**'
        '（未被任何区间条目覆盖的单轮条目）不得超过 $cap（= 2 × $tier）条。'
        '达到 $cap 条时，把**最旧的 $tier 条**未合并条目合并为一条区间条目 '
        '`$kMemoryMergedEntryFormat`（轮次与首末时间都填实；'
        '{记忆内容} = 这期间需要记住的事，长度不限），'
        '并重复到剩余未合并条目少于 $cap 条为止；'
        '已合并条目一律不改写、不拆分、不重排，'
        '**本轮正在写的那一条永不并入区间**。'
        '若本轮用户输入明确要求别的合并方式（或要求不要合并），以用户要求为准。',
  ];
}

/// 待合并区间的逐条清单（Chat 指令与 Agent 指令共用同一形状）。
List<String> _mergeRangeLines(MemoryMergePlan plan) => [
      for (final r in plan.ranges)
        '  - 第 ${r.startRound}~${r.endRound} 轮（${r.roundCount} 条）合并为一行：'
            '`${memoryMergedEntryTemplate(
              startRound: r.startRound,
              endRound: r.endRound,
              startTime: r.startTime,
              endTime: r.endTime,
            )}`',
    ];

/// **Chat 模式**的本轮合并指令：把待合并区间写进 `## 记忆总结` 区块。
///
/// 由 [ChatPromptFormat.memoryMergeUserNote] 注入用户消息（无动作时返回空列表；
/// Agent 档位由各阶段帧指令承载，不用本函数）。
List<String> memoryMergeDirectiveLines(MemoryMergePlan? plan) {
  if (plan == null || !plan.hasAction) return const [];
  return [
    '【本轮记忆合并】本轮必须完成以下合并，其余条目一字不改：',
    ..._mergeRangeLines(plan),
    '{记忆内容} 写成能记住这期间关键事件与因果的内容（长度不限）。'
        '被合并的那几行整行替换为上面这一行，`## 记忆总结` 的其它行逐字保留、'
        '顺序不变。若本轮【用户输入内容】明确要求别的合并方式（或要求不要合并），'
        '以用户要求为准，不做上面的默认合并。',
  ];
}

/// **Agent 档位**（Lv.1 / Lv.2）的本轮合并指令：给出锚定式编辑的落地手法。
///
/// [kEditHistoryToolName] 一次调用即可同时完成「合并」与「追加本轮条目」：
/// 每个区间一条 `op=set`（`before` = 该区间的 T 行原文，用 `\n` 连接、
/// 从读取结果逐字复制），最后一条 `op=append` 追加本轮条目。
List<String> memoryMergeAgentDirectiveLines(MemoryMergePlan? plan) {
  if (plan == null || !plan.hasAction) return const [];
  return [
    '- [Memory merge · tools] Apply these merges with '
        '$kEditHistoryToolName BEFORE anything else (every other line stays '
        'byte-identical); the ranges and their target lines are:',
    ..._mergeRangeLines(plan),
    '  Use ONE op=set per range: `before` = that range\'s entry lines copied '
        'VERBATIM from the $kReadHistoryToolName result (joined with \\n), '
        '`newLine` = the merged line above. Then append this round\'s entry as '
        'usual (op=append) — one call may carry all of it. If the '
        '`<memorySummary>` block is NOT in this conversation yet, call '
        '$kReadHistoryToolName ONCE first (do NOT re-read when it is already '
        'there). '
        '【本轮记忆合并】每个区间一条 op=set：`before` = 该区间各轮条目原文'
        '（用 \\n 连接，从 $kReadHistoryToolName 的结果里逐字复制），'
        '`newLine` = 上面的合并行；随后照常 op=append 追加本轮条目，'
        '以上可以放在同一次调用里。**若会话里还没有 `<memorySummary>` 全文，'
        '先调用一次 $kReadHistoryToolName**（已在上下文中就不要重复读取）。'
        '{记忆内容} 写成能记住这期间关键事件与因果的'
        '内容（长度不限）。',
  ];
}

/// Agent 档位通用规则：**思考（reasoning / thinking）一律用英文书写**。
///
/// 仅 Agent 档位注入（Chat 文案不变）：思考通道是中英混排噪声与转义问题的
/// 高发区，统一英文便于直接阅读模型推理；正文与工具参数**不受影响**（保持原有
/// 语言，字面量与标题名永不翻译）。
///
/// 以 `- ` 项目符号给出（英文在前、中文摘要在后），不使用数字序号——有序列表在
/// Markdown 渲染时会重新编号，中英对照的两条会失去对应关系（见文件头约定）。
const List<String> agentReasoningRules = [
  '- [Reasoning language] Write ALL of your reasoning / thinking in '
      'ENGLISH. This rule constrains the thinking channel ONLY: the story '
      'text and every tool argument keep their original language '
      '(Chinese) — never translate story content or anchors.',
  '- 【思考语言】思考（reasoning）一律用**英文**书写。本规则只约束思考'
      '通道：正文与工具参数保持原有语言（中文），**不要**翻译正文或锚点。',
];

/// Agent **Lv.1** 的格式生成要求：Chat 的 5 区块契约（排除 `## 记忆总结`）
/// + 历史（记忆总结）工具契约 + 思考语言规则。
///
/// Lv.1 只有历史相关工具（[kReadHistoryToolName] / [kEditHistoryToolName]）
/// 与联网工具：世界状态与角色状态仍由**正文文本**携带（故复用 Chat 的区块
/// 纪律与角色状态格式），只有「历史」改为工具维护。每轮固定四步：
/// - 准备阶段（[prepareNote]）：[kReadHistoryToolName] 读**一次**历史
///   （正文唯一依据）+ 需要时联网，随后在思考里写出本轮**大纲**
///   （关键事件 / 出场角色 / **本轮结束**时的剧情内时间），文本不上屏；
/// - 记忆阶段（[memoryNote]）：按大纲用 [kEditHistoryToolName] 追加
///   **恰好一条**本轮条目（`op=append`），单独一帧、只调工具、不输出文本；
///   档位 > 0 且本轮指令要求合并时，**同一次调用**再加每个区间一条 `op=set`
///   （锚点取自准备阶段读到的 `<memorySummary>`，见
///   [memoryMergeAgentDirectiveLines]）；
/// - 正文阶段（[storyNote]）：按大纲输出 5 个区块，**禁止**输出
///   `## 记忆总结`（该区块只以工具结果形式出现）；
/// - 维护回合降级为**兜底**（仅当记忆条目未落地时才补写），不再是每轮必发。
class AgentLv1PromptFormat extends ChatPromptFormat {
  const AgentLv1PromptFormat() : super(includeMemory: false);

  /// Agent 档位不写等级：模式标记统一为 `Agent`。
  @override
  String get modeLabel => 'Agent';

  /// 正文回合允许的二级标题（5 个，顺序固定；单一真源 = Chat 区块顺序去掉
  /// 记忆总结，即 [ChatPromptFormat.sections] 的 `includeMemory: false` 形态）。
  static List<String> get outputSections =>
      const ChatPromptFormat(includeMemory: false).sections;

  /// Lv.1 启用的状态工具（历史一读一写）。
  static const List<String> stateToolNames = [
    kReadHistoryToolName,
    kEditHistoryToolName,
  ];

  /// 输出区块的 `## 区块名` 箭头清单（正文阶段指令与【指令执行】共用同一形状）。
  static String _sectionsArrow() =>
      outputSections.map((s) => '`## $s`').join(' → ');

  /// 记忆阶段的编辑行（**单行**）：怎么调 [kEditHistoryToolName]。
  ///
  /// 记忆阶段指令与执行器（`agent_round_runner.dart`）的修复指令共用本行，
  /// 改名即同时改两处文案口径。「合并」的 op 只在**本轮指令要求时**才加
  /// （见 [memoryMergePolicyLines] / [memoryMergeAgentDirectiveLines]）。
  static const String memoryEditLine =
      'Call $kEditHistoryToolName with op=append and EXACTLY ONE entry: '
      '`$kMemoryEntryFormat` — {轮次} = this round as a bare number; '
      '{时间} = the end-of-round in-story time of your outline (the story\'s '
      '`## 当前时间` must match it). Add ONE op=set per range ONLY when this '
      'round\'s instructions require a merge (in the SAME call). '
      '用 $kEditHistoryToolName 的 op=append 追加**恰好一条**本轮记忆条目'
      '（{轮次} = 本轮轮号（裸数字）；{时间} = 大纲里本轮结束时的剧情内时间，'
      '正文 `## 当前时间` 必须与之一致）；'
      '仅当本轮指令要求合并时，才在**同一次调用**里为每个区间加一条 op=set。';

  /// 准备阶段指令（英文要求在前、中文概述在后，与维护轮指令同一形态）。
  ///
  /// 记忆阶段提前结束、需要整体补做准备时，指令会带上本段以避免模型误解时序。
  List<String> prepareNote() => [
        '[Prepare] Call $kReadHistoryToolName ONCE — the ONLY source of history '
            '(earlier assistant messages carry no memory block). Search the web '
            '(narrchat_webSearch / narrchat_webFetchPage) only when real-world '
            'facts are needed. Then settle THIS round\'s outline in your '
            'reasoning: key events, characters, and the in-story time at which '
            'the round ENDS (keep the time format used in history). The outline '
            'is thinking, not output: do NOT write the story here and do NOT '
            'call $kEditHistoryToolName in this step — the memory entry and the '
            'story come AFTER it, in that order.',
        '',
        '【准备阶段】先调用 $kReadHistoryToolName **一次**（历史的**唯一**来源，'
            '此前各轮的 assistant 消息里没有记忆区块）；只有需要现实世界资料时'
            '才联网（narrchat_webSearch / narrchat_webFetchPage）。'
            '随后在心里定下**本轮大纲**：关键事件、出场角色、'
            '本轮**结束**时的剧情内时间（沿用历史的时间格式）。'
            '大纲只是思考、不是输出：本阶段不写正文，也不要调用 '
            '$kEditHistoryToolName——记忆条目与正文都在本阶段之后，'
            '且**先记忆、后正文**，顺序不要误解。',
      ];

  /// 记忆阶段指令（调用 [kEditHistoryToolName] 的 `op=append` 恰好一条）。
  ///
  /// 该阶段是**独立一帧**（`tool_choice = required`）：只调工具、不输出文本，
  /// 记忆条目先于正文落地，成为正文的既定约束。
  List<String> memoryNote() => [
        '[Memory FIRST · tool call only] This turn emits NO text; the story '
            'comes in the NEXT step. $memoryEditLine '
            'This is the ONLY history CALL for this round — its ops are one '
            'op=append plus (only when the instructions require a merge) the '
            'merge op=set list.',
        '',
        '【记忆阶段】本回合**只调工具、不输出任何文本**（正文在下一步）：'
            '$memoryEditLine 本轮历史**只此一次调用**——其中的 op 为「追加一条」，'
            '外加（仅当指令要求合并时）各区间对应的 op=set。',
      ];

  /// 正文阶段指令（5 区块、禁止 `## 记忆总结`）。
  ///
  /// 本阶段是唯一采纳文本的阶段：只写正文，不复述工具结果与指令。
  List<String> storyNote() => [
        '[Story] History and this round\'s memory entry are already in place '
            '($kEditHistoryToolName ran before this turn). Write the story NOW, '
            'following your outline, this round\'s user input and the book\'s '
            'settings / style references: output exactly the five sections — '
            '${_sectionsArrow()}. NEVER output `## 记忆总结`, never echo the '
            'history or tool results, never restate these instructions.',
        '',
        '【正文阶段】历史与本轮记忆条目都已就位（$kEditHistoryToolName 已先执行），'
            '现在按大纲、本轮用户输入与本书设定/文笔参考写正文，'
            '只输出五个区块：${_sectionsArrow()}；'
            '`## 当前时间` 用大纲里本轮结束时的剧情内时间。'
            '**禁止**输出 `## 记忆总结`、不要复述历史或工具结果、不要复述指令。',
      ];

  /// 四步流程契约（`- ` 项目符号；英文详述在前、中文概述在后）。
  ///
  /// 顺序即执行顺序：准备（读史 → 大纲）→ 记忆（先写条目）→ 正文（5 区块）
  /// → 禁止输出记忆区块。维护回合只作兜底，不在本契约内展开。
  static const List<String> historyContract = [
    '- [Flow · step 1 · prepare] Call $kReadHistoryToolName ONCE in this '
        'round\'s preparation: it is the ONLY source of history (earlier '
        'assistant messages carry no memory block). Search the web only when '
        'real-world facts are needed. Then settle THIS round\'s OUTLINE in your '
        'reasoning — key events, characters, and the in-story time at which the '
        'round ENDS (keep the time format used in history). The outline is '
        'thinking, not output: never write the story in this step. '
        '【第一步·准备】本轮准备时先调用 $kReadHistoryToolName **一次**'
        '（历史的**唯一**来源，此前各轮的 assistant 消息里没有记忆区块）；'
        '需要现实世界资料时才联网；随后在心里定下**本轮大纲**——关键事件、'
        '出场角色、本轮**结束**时的剧情内时间（沿用历史的时间格式）。'
        '大纲只是思考、不是输出：本步绝不写正文。',
    '- [Flow · step 2 · memory FIRST] BEFORE the story, write this round\'s '
        'memory entry with ONE $kEditHistoryToolName call (op=append): exactly '
        'one entry `$kMemoryEntryFormat` ({轮次} = this round as a bare number; '
        '{时间} = the outline\'s end-of-round in-story time — the story\'s '
        '`## 当前时间` must match it). When this round\'s instructions require a '
        'memory merge (tier > 0), the SAME call also rewrites each target range '
        'as one range entry — one op=set per range, `before` = that range\'s '
        'entry lines copied VERBATIM from the read result. Do it in its own '
        'turn: that turn carries the tool call ONLY — no text at all. The '
        'history section accepts NO op=noChange; a missing or duplicated entry '
        'is a failure. '
        '【第二步·记忆先写】正文**之前**先用 $kEditHistoryToolName 写本轮记忆条目'
        '（op=append）：**恰好一条** `$kMemoryEntryFormat`'
        '（{轮次} = 本轮轮号（裸数字）；{时间} = 大纲里本轮结束时的剧情内时间，'
        '正文 `## 当前时间` 必须与之一致）；'
        '**本轮指令要求合并时**，同一次调用还要把每个目标区间改写成一条合并条目'
        '——每个区间一条 op=set，`before` = 该区间条目原文（从读取结果逐字复制）。'
        '单独一回合完成，该回合**只调工具、不输出任何文本**。'
        '历史栏**不接受** op=noChange；漏写或重复即失败。',
    kMemoryEntryFormatPrecedence,
    '- [Flow · step 3 · story] Only THEN write the story\'s five sections, '
        'following the outline, this round\'s user input and the book\'s '
        'settings / style references: `## 剧情演绎` → `## 推荐行动` → '
        '`## 当前时间` → `## 世界状态` → `## 角色状态`. '
        '【第三步·正文】然后才写正文五个区块，依据 = 大纲 + 本轮用户输入 + '
        '本书设定/文笔参考（顺序固定，同上）。',
    '- [Flow · step 4 · never the memory block] NEVER output `## 记忆总结`: '
        'that block exists ONLY as a tool result. Do NOT echo the history or '
        'any tool result, and do NOT restate these instructions. '
        '【第四步·禁止输出记忆区块】**禁止**输出 `## 记忆总结`——该区块只以'
        '工具结果形式出现；不要复述历史或任何工具结果，不要复述本指令。',
    '',
  ];

  /// 系统指令头部：Chat 的 5 区块契约 + 思考语言规则。
  @override
  List<String> get systemHead => [
        ...super.systemHead,
        '',
        ...agentReasoningRules,
      ];

  @override
  List<String> get systemTail => historyContract;

  @override
  List<String> get userExecuteNote => [
        '[Execute now] Call $kReadHistoryToolName ONCE (the story must follow '
            'the past rounds) and settle THIS round\'s outline (key events, '
            'characters and the end-of-round in-story time). Then write the '
            'memory entry with ONE $kEditHistoryToolName call (op=append, '
            'exactly one entry, date = the outline\'s end-of-round time; plus '
            'the merge op=set list when this round\'s instructions require a '
            'merge). Only '
            'then write the STORY: output ${_sectionsArrow()} (five sections; '
            'do NOT output `## 记忆总结`, do not echo the history tool result, '
            'do not restate these instructions). '
            'Start with $kReadHistoryToolName, then the history edit, then '
            '## 剧情演绎 immediately.',
        '',
        '【指令执行】[Agent 模式] 先调用 $kReadHistoryToolName **一次**'
            '（正文必须基于以往轮次的历史），并定下本轮大纲（关键事件、出场角色、'
            '本轮结束时的剧情内时间）；随后先用 $kEditHistoryToolName 写记忆条目'
            '（op=append，**恰好一条**，日期 = 大纲里本轮结束时的剧情内时间；'
            '若本轮指令要求合并，同一次调用再加每个区间一条 op=set）；'
            '最后才输出正文五个区块：${_sectionsArrow()}。'
            '**不要**输出 `## 记忆总结`、不要复述历史工具结果、不要复述指令。'
            '从 $kReadHistoryToolName 开始，再到历史编辑，'
            '然后立即输出 ## 剧情演绎。',
      ];
}

/// Agent **Lv.2** 的格式生成要求：全 Agent 流契约（正文三小节——剧情 /
/// 推荐行动 / 当前时间——+ 六个状态工具按栏目读写）、双语规则与用户消息的
/// 双语【指令执行】。
///
/// 状态工具契约引用的工具名见 [stateToolNames]（真源
/// `lib/services/agent/state/state_tool_names.dart`，与 `state_tools.dart` 一致）。
class AgentLv2PromptFormat extends PromptFormatSpec {
  const AgentLv2PromptFormat();

  /// Agent 档位不写等级：模式标记统一为 `Agent`。
  @override
  String get modeLabel => 'Agent';

  /// AGENT 模式允许输出的二级标题（三个，顺序固定：剧情 → 行动 → 时间）。
  static const List<String> outputSections = ['剧情演绎', '推荐行动', '当前时间'];

  /// 六个状态工具名（读取器在前；时间不是工具，参数细节见工具 schema）。
  static const List<String> stateToolNames = kStateToolNames;

  @override
  List<String> get systemHead {
    final edits = kEditStateToolNames.join(' / ');
    final reads = kReadStateToolNames.join(' / ');
    return [
      '当前模式：$modeLabel',
      '',
      '【AGENT 模式契约】两阶段执行：本回合只写正文，状态由工具维护。'
          '以下规则必须无条件、无例外地执行：',
      '',
      // 规则一律英文在前（长句、约束完整），中文一行摘要在后（便于用户核对）；
      // 分条统一用 `- `（不用数字序号：渲染会重编号，中英对照会错位）。
      '- [Output format] In the story turn output ONLY three level-2 (##) '
          'sections in this order: `## 剧情演绎` (the story), `## 推荐行动` '
          '(one short suggestion) and `## 当前时间` (the in-story time AFTER '
          'the story — keep the format of previous rounds and advance it by '
          'the story; pass the old value if time did not move). NEVER output '
          '## 世界状态 / ## 角色状态 / ## 记忆总结. The state blocks exist '
          'ONLY as the narrchat_read* tool results you receive — they are '
          'reading material, never a format to copy. Your own past messages in '
          'the history contain exactly those three sections — match that shape '
          'exactly.',
      '- 【输出格式】正文回合只输出三个二级标题，顺序固定：`## 剧情演绎` → '
          '`## 推荐行动` → `## 当前时间`（剧情结束后的故事内时间；沿用历史格式，'
          '随时间推进，时间没变就写原值）。禁止输出世界/角色/记忆三类状态区块——'
          '它们只会以你调用 $reads 拿到的工具结果形式出现，那是阅读材料，'
          '绝不是可以照抄的输出格式。历史中你之前的消息恰好就是这三个小节，'
          '照此形状输出。',
      '- [State lives in tools ONLY] Call the readers ($reads) ONCE, in the '
          'story turn, before you write the story — they are the ONLY way to '
          'see the current state, and the story must follow LAST round\'s '
          'state. The state does not change while you write (only your own '
          'edits change it), so the maintenance turn reuses THESE results and '
          'NEVER reads again. Do NOT call $edits in the story turn: state '
          'edits belong exclusively to the state-maintenance turn that follows. '
          'Never trade story quality for tool calls.',
      '- 【状态先读后写】读取工具（$reads）在正文回合**只读一次**（正文的唯一依据，'
          '必须在动笔前拿到）；写正文不会改变状态（只有你自己的编辑会），'
          '因此维护回合**复用这次结果、绝不重复读取**。正文轮禁止调用 $edits'
          '——状态修改只属于随后的维护回合。不要为工具调用牺牲正文质量。',
      '- [Anchored edits] The state you must anchor on comes from YOUR OWN '
          'read-tool results: each editor targets exactly ONE section, and its '
          '`before` anchors must be copied from THAT section\'s read result '
          '(`<worldState>` / `<characterState>` / `<memorySummary>`; time is '
          'NOT there — it lives in the story body as `## 当前时间`). Copy '
          '`before` VERBATIM from that result — never count line numbers. One '
          'call edits ONE section, but its `edits` array may carry several ops '
          '(one op per changed line): SMALL CHANGES ARE THE NORM — one op=set '
          'per moved line (a character\'s 当前心理 / 当前状态 / 当前位置 / 好感度 / '
          '伤势…), and noChange is the exception, never a shortcut. op=append '
          'adds at the END (use it for memory); op=set / insertAfter / delete '
          'need an anchor and change only that line; NEVER re-type a whole '
          'section (untouched lines are kept byte-for-byte); op=reset is for '
          'empty or first-time sections only. A rejected edit returns that '
          'section\'s current full text — re-anchor from it in one step.',
      '- 【锚定式编辑】当前状态以你调用读取工具拿到的结果块为准：每个编辑器只针对'
          '**一个**栏目，before 必须从**该栏目**的读取结果（`<worldState>` / '
          '`<characterState>` / `<memorySummary>`）中逐字复制，绝不数行号；'
          '一次调用只改一个栏目，但 `edits` 数组可放多条 op（每条对应一行改动）：'
          '**小幅改动是常态**——某角色换了位置/情绪/心理/装备，'
          '就对该行做一次 op=set 照实记录；op=noChange 是例外而非偷懒捷径。'
          'op=append 追加到末尾（记忆条目用它），op=set/insertAfter/delete '
          '只改锚定的那一行，**禁止重抄整栏**（未触及的行原样保留），'
          'op=reset 仅用于空栏目或首次填入。'
          '锚点被拒时会回传该栏目当前全文，一步到位重锚。',
      '- [Every round] Each round must end with exactly ONE memory entry '
          '`$kMemoryEntryFormat` via $kEditHistoryToolName '
          '(op=append, {轮次} = this round as a bare number, {时间} = the '
          '`## 当前时间` value of THIS round\'s story — keep the entry to ONE '
          'short sentence). When this round\'s instructions require a memory '
          'merge, that SAME call also rewrites each target range as one range '
          'entry (one op=set per range, anchor copied from the history read '
          'result). Time is '
          'part of the story body: there is NO time tool. op=noChange must '
          'carry a `reason` and is NOT accepted for history; silently omitting '
          'a section is a failure, not a no-op.',
      '- 【每轮义务】每轮必须用 $kEditHistoryToolName 写出**恰好一条**本轮记忆条目 '
          '`$kMemoryEntryFormat`（op=append；{轮次} = 本轮轮号（裸数字）；'
          '{时间} = 本轮正文 `## 当前时间` 的取值；一句话概括，别写长）。'
          '**本轮指令要求合并时**，同一次调用还要把每个目标区间改成一条合并条目'
          '（每个区间一条 op=set，锚点从历史读取结果逐字复制）。'
          '时间只存在于正文里（**没有时间工具**）。op=noChange 必须附 reason，'
          '且历史栏**不接受** op=noChange；直接省略某个栏目算失败。',
      kMemoryEntryFormatPrecedence,
      '- [No lazy editing] The app byte-compares every section with last '
          'round. For every named character in this round\'s story, walk their '
          'mutable lines (好感度 / 当前心理 / 当前状态 / 当前位置 / 伤势 / 物品 / '
          '关系…): if the story shows ANYTHING new about them — a reaction, a '
          'glance, a thought, a move, an item, a wound — `set` that line with '
          '$kEditCharacterStateToolName, however small; op=noChange is correct '
          'ONLY when the story says nothing new about them and every field is '
          'still accurate as-is. The same holds for world state '
          '($kEditWorldStateToolName): a new in-story beat is a real edit. '
          'Unchanged sections without a declared reason get called out by '
          'name, and a noChange with a flimsy reason (e.g. "无需大改") on a '
          'character whose state visibly moved is a lazy edit.',
      '- 【禁止懒修改】应用会逐栏目与上一轮做字节比对。对本轮出场的每个具名角色，'
          '用 $kEditCharacterStateToolName 逐行核对其可变字段'
          '（好感度/当前心理/当前状态/当前位置/伤势/物品/关系…）：'
          '正文里只要有关于他的**任何新信息**（一个反应、一个眼神、一句心理、'
          '一次移动、一件物品），就必须对该行 op=set 如实更新——改动再小也要写；'
          'op=noChange 只在「正文对他毫无新增信息、且现有字段仍然准确」时才成立。'
          '世界状态栏目（$kEditWorldStateToolName）同理：新发生的情节要点就是'
          '真实编辑。未变更又未声明的栏目会被点名；用「无需大改」这类空泛理由对'
          '状态明显有变的角色声明 noChange，会被视为懒修改。',
      '- [Web tools] Call narrchat_webSearch / narrchat_webFetchPage when the '
          'story needs real-world facts. A one-line preamble before searching '
          'is fine, but the story itself must appear complete exactly once, in '
          'the last turn; never split the story across turns.',
      '- 【搜索工具】需要现实世界资料时调用 narrchat_webSearch / '
          'narrchat_webFetchPage；调用前可以写一句短开场白，但正文只能出现一次且'
          '必须完整，不要把正文拆到多轮里。',
      '- [Maintenance turn] When the newest user message starts with '
          '`[State-maintenance turn]`, output NO text at all (any text in that '
          'turn is discarded). The readers are DISABLED in this turn: their '
          'results from the story turn are ALREADY in this conversation — do '
          'NOT call them again. Copy `before` anchors VERBATIM from those '
          'results (or from the full text returned by a previous edit call; '
          'they do NOT include the story time, which lives in the story body '
          'as `## 当前时间` — never touch it here), then call $edits '
          'once per listed section. '
          'Fill in ALL listed items in your FIRST response: edit directly, '
          'never spend a turn on reading; if the output '
          'limit forces a split, do history (memory) and character state FIRST.',
      '- 【状态维护回合】当最新用户消息以 `[State-maintenance turn]` 开头时，'
          '本回合**不要输出任何文本**（输出一律被丢弃）：本回合**读取工具已禁用**'
          '——正文回合的读取结果**已在对话中**，不要再调用它们。'
          '`before` 锚点从那些结果（或此前编辑调用回传的栏目全文）中**逐字复制**'
          '（结果**不含时间**——时间在正文 `## 当前时间` 小节里，本回合不得触碰），'
          '然后按清单逐栏目调用 $edits（每栏一次）。'
          '**第一个响应就把清单全部做完**：直接编辑，不要花一轮去读取；'
          '若受输出限制装不下，**先做历史（记忆）与角色状态**，世界状态留到下一帧。',
      '',
      ...agentReasoningRules,
      '',
    ];
  }

  @override
  List<String> get systemAfterIdentity => const [];

  @override
  List<String> get systemTail => const [];

  @override
  List<String> get userHead => const [];

  @override
  List<String> get userExecuteNote => [
        '[Execute now] Call the readers ONCE '
            '(${kReadStateToolNames.join(' / ')}) — the story must follow '
            'LAST round\'s state — then write the STORY: output '
            '`## 剧情演绎` then `## 推荐行动` then `## 当前时间` (the '
            'in-story time AFTER the story, same format as previous rounds). '
            'Do not output any state section, do not echo the tool results, '
            'do not restate these instructions. State edits (world / '
            'character / history) happen in the separate '
            'state-maintenance turn that follows, and that turn REUSES this '
            'single read (it never reads again). '
            'Start with the readers, then ## 剧情演绎 immediately.',
        '',
        '【指令执行】[Agent 模式] 先调用读取工具（${kReadStateToolNames.join(' / ')}）'
            '**一次**（正文必须基于上一轮状态），再输出正文三个小节：'
            '`## 剧情演绎` → `## 推荐行动` → `## 当前时间`'
            '（剧情结束后的故事内时间，沿用历史格式，随时间推进）。不要输出世界/'
            '角色/记忆类区块、不要复述工具结果、不要复述指令。世界/角色/历史的修改'
            '都在随后的「状态维护回合」完成，且**复用这次读取结果**（不再重复读取）。'
            '从读取工具开始，然后立即输出 ## 剧情演绎。',
      ];
}

/// 生成模式：决定 [PromptBuilder] 以哪种格式生成要求组装共享提示词。
///
/// 每个模式聚合其对应的 [PromptFormatSpec]（格式生成要求的单一真源），
/// 共享组装流程与共享文案（`PromptSections`）与模式无关。
enum PromptMode {
  /// 聊天模式：6 个二级标题区块
  /// （剧情演绎 / 推荐行动 / 当前时间 / 世界状态 / 角色状态 / 记忆总结）。
  chat(ChatPromptFormat()),

  /// Agent **Lv.1**：5 个二级标题区块（排除 `## 记忆总结`）+
  /// 历史（记忆总结）工具契约。
  agentLv1(AgentLv1PromptFormat()),

  /// Agent **Lv.2**：全 Agent 流（正文三个二级标题 +
  /// 六个 `narrchat_*` 状态工具按栏目读写）。
  agentLv2(AgentLv2PromptFormat());

  const PromptMode(this.format);

  /// 该模式对应的格式生成要求规格。
  final PromptFormatSpec format;
}
