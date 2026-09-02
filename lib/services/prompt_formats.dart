/// 模式格式生成要求：Chat / AGENT 各自特有的提示词文案与规则，单一真源。
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
/// 空行（保持各模式原有的空行节奏），空列表表示该槽位不存在。
library;

/// 一种生成模式的「格式生成要求」规格。
abstract class PromptFormatSpec {
  const PromptFormatSpec();

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
}

/// Chat 模式的格式生成要求：6 个二级标题区块纪律、状态快照规则、
/// 角色状态输出格式、记忆总结格式，以及用户消息的格式要求与【指令执行】。
///
/// Chat 模式输出与历史版本**逐字节一致**：本类各槽位与 `PromptSections`
/// 的固定组装流程一一对应，改变任一槽位内容即改变 Chat 文案（唯一维护点）。
class ChatPromptFormat implements PromptFormatSpec {
  const ChatPromptFormat();

  /// 6 个二级标题区块及其固定顺序（单一真源，见 [PromptBuilder.sectionOrder]）。
  static const List<String> sectionOrder = [
    '剧情演绎',
    '推荐行动',
    '当前时间',
    '世界状态',
    '角色状态',
    '记忆总结',
  ];

  static const String obedienceHeader =
      '【绝对服从】以下规则必须无条件、无例外地严格执行，'
      '不得拒绝、不得询问、不得省略：';

  static const String chatSectionsIntro =
      '1. 你必须完整输出以下 6 个二级标题（##）区块，'
      '顺序固定、不得遗漏、不得调换、不得改名：';

  static const String headingDiscipline =
      '2. 【二级标题纪律】输出中只允许出现上述 6 个二级标题，'
      '以及 ## 角色状态 区块内部用于标注单个角色的 ## 角色名'
      '（见【角色状态输出格式】）；除此之外的任何位置一律禁止使用 ##（二级标题），'
      '内部子结构请使用 #、###、列表或加粗。';

  static const String snapshotRule =
      '3. 【状态快照规则】你必须把上一轮的角色状态与世界状态完整复制到输出的'
      ' ## 角色状态 与 ## 世界状态 中，只修改确实发生变化的条目；'
      '未变化的设定一个字都不能丢、不能改写。';

  static const String characterStateFormatHeader =
      '【角色状态输出格式】## 角色状态 区块必须使用以下结构化 Markdown（严格遵循）：';

  static const String characterStateFormatLines =
      '- 每个角色类别使用一级标题 `# 类别名`（如 `# 主角`），'
      '类别顺序必须与下方「角色层级排序规则」完全一致；\n'
      '- 类别下的每个角色使用二级标题 `## 角色名`（这是允许的二级标题）；\n'
      '- 每个角色下列出属性，每行一个，格式为 `- 属性名：属性值`；\n'
      '- 必须包含该类别设定格式（见下方「角色类别描述格式」）中的全部属性项，'
      '不得缺项；属性值没有变化的一律保持上一轮原样，只更新确实变化的属性；\n'
      '- 本轮未登场的角色也必须保留其条目与全部属性，'
      '仅将状态类属性标注为“未登场（本轮未出现）”，不得删除该角色；\n'
      '- 新增登场角色按所属类别格式补全属性项。';

  static const String memoryFormatHeader =
      '【记忆总结格式】## 记忆总结 区块必须严格遵循以下格式'
      '（这是历史记录的核心结构，优先级最高）：';

  static const String memoryRuleLines =
      '1. 每条记忆独占一行，格式为：`- 第N轮｜日期：该轮当前时间｜概括内容`；'
      '「轮数」「日期」「概括内容」三者必须绑定在一条内，'
      '严禁拆行、严禁分块、严禁只写其中一项。\n'
      '2. 从第 1 轮到本轮，每一轮都必须保留一条记忆条目，'
      '条目按轮数从小到大顺序排列、不得缺轮。\n'
      '3. 每条条目的「日期」必须使用该轮 ## 当前时间 的内容'
      '（剧情内时间，如「第三天 午时」），不得使用真实日期。\n'
      '4. 「概括内容」用一句话概括该轮发生的核心事件与关键进展；'
      '若该轮无重要事件则写「无重要事件」。\n'
      '5. 轮次增多时可压缩、精简旧条目的措辞以控制篇幅，'
      '但不得删除任何轮次条目、不得调换顺序、不得将多条合并为一条。\n'
      '6. 上一轮 AI 返回（最后一条 assistant 消息）中的「## 记忆总结」'
      '为已确认的历史记忆，必须完整继承并在此基础上追加本轮条目，'
      '不得凭空改写、丢失或重排。';

  static const String memoryFormatUserNote =
      '【记忆总结格式】## 记忆总结 必须按「- 第N轮｜日期：xxx｜概括内容」逐轮输出：'
      '每条一行，轮数、日期、概括内容三者绑定在一条内；从第 1 轮至本轮每轮一条，'
      '日期一律使用该轮 ## 当前时间（详见系统指令【记忆总结格式】）。';

  @override
  List<String> get systemHead => [
        obedienceHeader,
        chatSectionsIntro,
        for (final section in sectionOrder) '   ## $section',
        headingDiscipline,
        snapshotRule,
      ];

  @override
  List<String> get systemAfterIdentity => [
        characterStateFormatHeader,
        characterStateFormatLines,
        '',
      ];

  @override
  List<String> get systemTail => [
        memoryFormatHeader,
        memoryRuleLines,
        '',
      ];

  @override
  List<String> get userHead => [
        '【格式要求】本次输出必须严格遵循系统指令中的 6 个二级标题（##）区块，'
            '顺序为：${sectionOrder.join(' → ')}；严禁在其它任何位置使用二级标题（##）。',
        memoryFormatUserNote,
      ];

  @override
  List<String> get userExecuteNote => [
        '【指令执行】现在请直接开始创作并完整输出 6 个二级标题区块。'
            '不要复述指令、不要解释、不要添加任何区块以外的内容；'
            '## 剧情演绎 应充分推进剧情，其余区块按要求依次给出。'
            '立即从 ## 剧情演绎 开始输出。',
      ];
}

/// AGENT 模式的格式生成要求：全 Agent 流契约（仅两标题 + 状态工具行级维护）、
/// 双语规则与用户消息的双语【指令执行】。
///
/// 状态工具契约引用的工具名见 [stateToolNames]（与 `state_tools.dart` 一致）。
class AgentPromptFormat implements PromptFormatSpec {
  const AgentPromptFormat();

  /// AGENT 模式允许输出的二级标题（仅这两个，顺序固定）。
  static const List<String> outputSections = ['剧情演绎', '推荐行动'];

  /// 状态工具名（提示词契约引用；参数细节见工具 schema）。
  static const List<String> stateToolNames = [
    'narrchat_editSection',
    'narrchat_advanceTime',
  ];

  @override
  List<String> get systemHead {
    final tools = stateToolNames;
    return [
      '【AGENT 模式契约】本模式为全 Agent 流，以下规则必须无条件执行：',
      '1. 【输出格式】仅输出两个二级标题（##）区块：`## 剧情演绎`（剧情正文）'
          '与 `## 推荐行动`（一行简短建议），顺序固定；除此之外的任何位置'
          '一律禁止使用 ##（二级标题），内部子结构请使用 #、###、列表或加粗。',
      '1. [Output format] Output ONLY two level-2 headings (##): '
          '`## 剧情演绎` (the story) and `## 推荐行动` (one short suggestion), in this order. '
          'NEVER use ## anywhere else; use #, ###, lists or bold for inner structure. '
          'NEVER output ## 世界状态 / ## 角色状态 / ## 记忆总结 / ## 当前时间 in the text.',
      '2. 【状态由工具维护，正文先行】先输出 `## 剧情演绎` 正文，'
          '随后（同一次响应内）调用状态工具写入本轮变更——应用的执行顺序为'
          '「正文 → 工具结果」，正文必须完整、不得因工具调用而中断。'
          '世界状态、角色状态、记忆总结、当前时间由应用侧维护，'
          '你**不得**在文本中输出这些区块（禁止输出 ## 世界状态 / ## 角色状态 / '
          '## 记忆总结 / ## 当前时间）；对状态的任何修改必须调用 ${tools.join(' / ')}'
          ' 等工具完成。',
      '2. [State tools come after the story] Write the full `## 剧情演绎` first, '
          'then (in the SAME response) call the state tools to apply this round\'s changes. '
          'The story must be complete and never interrupted by tool calls. '
          'All state (world characters memory time) is maintained ONLY through the '
          '${tools.join(' / ')} tools — NEVER output state sections as text.',
      '3. 【锚定式编辑（不用行号）】用 ${tools[0]} 修改栏目时：'
          '**不要计算行号**，只提供**变更的行**——必须基于上下文中的'
          '**最后一条 assistant 消息**（上一轮快照的反解析六区块），'
          '从中**逐字复制**要修改的行原文作为 before（可含换行，即连续多行），'
          '应用侧做唯一匹配校验：未命中 / 不唯一会返回错误与命中行号，'
          '按提示调整锚点（补充唯一上下文）后重试即可。'
          '新增内容到栏目**末尾**用 op=append（无需定位）；'
          'op=set 替换 / op=insertAfter 插入 / op=delete 删除均以 before 锚定；'
          'op=noChange 声明无变化；op=reset 仅限空栏目或明确重排。'
          '**不得从头到尾重抄整个栏目**；未触及的行由应用侧原样保留。'
          '每个需要提及的栏目都必须出现在 edits 中'
          '（本轮无变化用 op=noChange 声明，不得直接省略栏目）。'
          '提交前**逐栏目对照上一轮快照自检**：本轮剧情中发生或提及的'
          '地点 / 时间 / 设定 / 属性 / 人物状态变化是否已写入对应栏目；'
          '若剧情有明显进展而某栏目未做变更，将被视为懒修改并触发修正。',
      '3. [Anchored edits — never line numbers] When editing a section with '
          '${tools[0]}: DO NOT count lines. Provide ONLY the changed lines — '
          'copy the line text VERBATIM from the previous snapshot (the last '
          'message) as `before` (\\n joins consecutive lines). The tool validates a '
          'UNIQUE match and returns a precise error (with hit line numbers) on '
          'miss or ambiguity; adjust the anchor to make it unique and retry. '
          'Use op=append to ADD to the END of a section (no locating needed); '
          'op=set replaces / op=insertAfter inserts after / op=delete removes, all '
          'anchored by `before`; op=noChange declares no change; op=reset is for '
          'empty sections or explicit restructure only. NEVER re-type the whole '
          'section — unchanged lines are kept verbatim. Every section must appear '
          'in the round\'s edits (declare op=noChange when unchanged; do NOT omit '
          'a section). Before calling, self-check section by section: did every '
          'place/time/setting/attribute/state change of this round get written? '
          'If the story clearly progressed but a section was not edited, you will '
          'be treated as a LAZY editor and asked to fix it.',
      '4. 【空状态与首轮】栏目为空或首次填入时，直接给出本轮完整内容；'
          '角色类别名与角色名按既定约定组织（沿用书籍角色类别设定）。',
      '4. [Empty/initial sections] If a section is empty or first-time, just provide '
          'this round\'s full content; organize category/character names per the book '
          'role-category settings.',
      '5. 【每轮完整维护】每轮都必须调用**两个状态工具**：'
          '${tools[0]}（edits 必须覆盖三个栏目：世界状态 / 角色状态 / '
          '记忆总结，无变化栏目用 op=noChange）+ ${tools[1]}（时间未变'
          '可传原值）。记忆总结**必须追加**本轮条目'
          ' `- 第N轮｜日期：<当前时间>｜<一句话概括>`（用 op=append，N = 本轮轮数，'
          '与 advanceTime 一致），未包含将校验失败并返回修复。',
      '5. [Full round maintenance] Call BOTH state tools every round: '
          '${tools[0]} with edits covering ALL THREE sections '
          '(op=noChange for sections that truly did not change) plus '
          '${tools[1]} (same time if unchanged). ALWAYS APPEND this '
          'round\'s entry to memory: `- 第N轮｜日期：<time>｜<summary>` (use '
          'op=append); otherwise validation fails and you must fix it.',
      '6. 【修改可见性】每个工具的调用都会被应用记录并展示给用户；'
          '仅在确实需要变更状态时调用，避免无意义的重复写入。',
      '6. [Visibility] Every tool call is recorded and shown to the user; call tools '
          'only when state really changes, avoid meaningless repeated writes.',
      '7. 【修复轮纪律】只有收到「状态维护反馈」的响应才是修复轮：'
          '正文（## 剧情演绎 / ## 推荐行动）已完整，**禁止再次输出**——'
          '重复正文会被应用**丢弃**不计入本轮正文；修复轮只做一件事：'
          '按反馈调用工具修正状态，然后直接结束。',
      '7. [Fixup discipline] A response preceded by "[State feedback]" is a '
          'FIXUP turn: the story (## 剧情演绎 / ## 推荐行动) is already complete — '
          'NEVER output it again (repeated story is DISCARDED). In a fixup turn do '
          'one thing only: call the state tools to fix the flagged items, then stop.',
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
        '【指令执行】现在请直接按 AGENT 模式契约创作：输出 `## 剧情演绎`'
            ' 与 `## 推荐行动` 两个标题区块，并在同一次响应中调用'
            ' ${stateToolNames.join(' / ')} 全部四个状态工具维护状态。'
            '不要复述指令、不要解释、不要输出任何状态类区块。'
            '立即从 ## 剧情演绎 开始输出。',
        '[Execute now] Follow the AGENT contract: output `## 剧情演绎` and '
            '`## 推荐行动`, and in the same response call ALL FOUR state tools '
            '(${stateToolNames.join(', ')}). Do not restate instructions, do not explain, '
            'do not output any state section. Start with ## 剧情演绎 immediately.',
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

  /// AGENT 模式：全 Agent 流（仅两个二级标题 + `narrchat_*` 状态工具行级维护）。
  agent(AgentPromptFormat());

  const PromptMode(this.format);

  /// 该模式对应的格式生成要求规格。
  final PromptFormatSpec format;
}
