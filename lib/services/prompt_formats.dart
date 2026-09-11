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
library;

import 'agent/state/state_tool_names.dart';

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
      '- 每个角色类别使用一级标题 `# 类别名`（如 `# 主角`），'
      '类别顺序必须与下方「角色层级排序规则」完全一致；\n'
      '- 类别下的每个角色使用二级标题 `## 角色名`；\n'
      '- 每个角色下列出属性，每行一个，格式为 `- 属性名：属性值`；\n'
      '- 必须包含该类别设定格式（见下方「角色类别描述格式」）中的全部属性项，'
      '不得缺项；属性值没有变化的一律保持上一轮原样，只更新确实变化的属性；\n'
      '- 本轮未登场的角色也必须保留其条目与全部属性，'
      '仅将状态类属性标注为“未登场（本轮未出现）”，不得删除该角色；\n'
      '- 新增登场角色按所属类别格式补全属性项。';

  /// 角色状态围栏形态示例（模型照此形状输出；围栏是解析契约的一部分）。
  static const List<String> characterStateFormatExample = [
    '形态示例：',
    '',
    '```markdown',
    '# 主角',
    '## {name}',
    '- 姓名：{name}',
    '- 当前状态：…',
    '```',
    '',
  ];

  static const String memoryFormatHeader =
      '【记忆总结格式】`## 记忆总结` 区块必须严格遵循以下格式'
      '（这是历史记录的核心结构，优先级最高）：';

  static const String memoryRuleLines =
      '- 每条记忆独占一行，格式为：`- 第N轮｜日期：该轮当前时间｜概括内容`；'
      '「轮数」「日期」「概括内容」三者必须绑定在一条内，'
      '严禁拆行、严禁分块、严禁只写其中一项。\n'
      '- 从第 1 轮到本轮，每一轮都必须保留一条记忆条目，'
      '条目按轮数从小到大顺序排列、不得缺轮。\n'
      '- 每条条目的「日期」必须使用该轮 `## 当前时间` 的内容'
      '（剧情内时间，如「第三天 午时」），不得使用真实日期。\n'
      '- 「概括内容」用一句话概括该轮发生的核心事件与关键进展；'
      '若该轮无重要事件则写「无重要事件」。\n'
      '- 轮次增多时可压缩、精简旧条目的措辞以控制篇幅，'
      '但不得删除任何轮次条目、不得调换顺序、不得将多条合并为一条。\n'
      '- 上一轮 AI 返回（最后一条 assistant 消息）中的 `## 记忆总结`'
      '为已确认的历史记忆，必须完整继承并在此基础上追加本轮条目，'
      '不得凭空改写、丢失或重排。';

  static const String memoryFormatUserNote =
      '【记忆总结格式】`## 记忆总结` 必须按 `- 第N轮｜日期：xxx｜概括内容` '
      '逐轮输出：每条一行，轮数、日期、概括内容三者绑定在一条内；'
      '从第 1 轮至本轮每轮一条，'
      '日期一律使用该轮 `## 当前时间`（详见系统指令【记忆总结格式】）。';

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
/// 纪律与角色状态格式），只有「历史」改为工具维护：
/// - 正文回合：先调 [kReadHistoryToolName] 读到历史（正文唯一依据），
///   再输出 5 个区块，且**禁止**输出 `## 记忆总结`；
/// - 维护回合（正文轮之后必发）：**直接复用**正文回合读到的历史做锚点，
///   调 [kEditHistoryToolName] 追加本轮条目（不再重复读取）。
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

  /// 历史工具契约（`- ` 项目符号；英文在前、中文一行摘要在后）。
  static const List<String> historyContract = [
    '- [History lives in tools ONLY] Call $kReadHistoryToolName FIRST to see '
        'the past rounds (the ONLY source of history — previous assistant '
        'messages carry no memory section), then write the story\'s five '
        'sections. NEVER output `## 记忆总结` in your reply: that block exists '
        'ONLY as a tool result. Read history ONCE: the state-maintenance turn '
        'that follows MUST reuse that result (it will not read again — copy '
        '`before` anchors from the history text already in this conversation). '
        'Do NOT call $kEditHistoryToolName in the story turn — history edits '
        'belong exclusively to the maintenance turn.',
    '- 【历史先读后写】先调用 $kReadHistoryToolName 读取历史（历史的**唯一**来源，'
        '此前各轮的 assistant 消息里没有记忆区块），再写正文五个区块。'
        '**禁止**在回复里输出 `## 记忆总结`——该区块只以工具结果形式出现。'
        '历史**只读一次**：随后的「状态维护回合」必须复用这次结果'
        '（不会再次读取——`before` 锚点从对话中已有的历史全文里复制）。'
        '正文回合**不要**调用 $kEditHistoryToolName：历史修改只属于维护回合。',
    '- [Every round · one entry] The maintenance turn must append EXACTLY ONE '
        'memory entry for this round with $kEditHistoryToolName: '
        '`- 第N轮｜日期：<时间>｜<一句话概括>` (op=append; N = this round; the '
        'date = the `## 当前时间` value of THIS round\'s story). op=noChange is '
        'NOT accepted for history; a missing entry is a failure. Write that '
        'call DIRECTLY in your first maintenance response — never spend a turn '
        'on reading.',
    '- 【每轮义务】维护回合必须用 $kEditHistoryToolName 追加**恰好一条**本轮记忆条目：'
        '`- 第N轮｜日期：<时间>｜<一句话概括>`（op=append；N = 本轮；'
        '日期 = 本轮正文 `## 当前时间` 的取值）。历史栏**不接受** op=noChange；'
        '漏掉条目即失败。**第一个维护帧就直接写**，不要花一轮去读取。',
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
            'the past rounds), then write the STORY: output `## 剧情演绎` → '
            '`## 推荐行动` → `## 当前时间` → `## 世界状态` → `## 角色状态` (five '
            'sections; do NOT output `## 记忆总结`, do not echo the history '
            'tool result, do not restate these instructions). History '
            '(`## 记忆总结`) is maintained in the separate '
            'state-maintenance turn that follows — it reuses this read. '
            'Start with $kReadHistoryToolName, then ## 剧情演绎 immediately.',
        '',
        '【指令执行】[Agent 模式] 先调用 $kReadHistoryToolName **一次**'
            '（正文必须基于以往轮次的历史），再输出正文五个区块：'
            '`## 剧情演绎` → `## 推荐行动` → '
            '`## 当前时间` → `## 世界状态` → `## 角色状态`。**不要**输出 `## 记忆总结`、'
            '不要复述历史工具结果、不要复述指令。历史的修改都在随后的'
            '「状态维护回合」完成，且**复用这次读取结果**（不再重复读取）。'
            '从 $kReadHistoryToolName 开始，然后立即输出 ## 剧情演绎。',
      ];
}

/// Agent **Lv.2** 的格式生成要求：全 Agent 流契约（正文三小节——剧情 /
/// 推荐行动 / 当前时间——+ 六个状态工具按栏目读写）、双语规则与用户消息的
/// 双语【指令执行】。
///
/// 状态工具契约引用的工具名见 [stateToolNames]（真源
/// `lib/services/agent/state/state_tool_names.dart`，与 `state_tools.dart` 一致）。
class AgentLv2PromptFormat implements PromptFormatSpec {
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
          '`- 第N轮｜日期：<时间>｜<一句话概括>` via $kEditHistoryToolName '
          '(op=append, N = this round, the date = the `## 当前时间` value of '
          'THIS round\'s story — keep the entry to ONE short sentence). Time is '
          'part of the story body: there is NO time tool. op=noChange must '
          'carry a `reason` and is NOT accepted for history; silently omitting '
          'a section is a failure, not a no-op.',
      '- 【每轮义务】每轮必须用 $kEditHistoryToolName 写出**恰好一条**本轮记忆条目 '
          '`- 第N轮｜日期：<时间>｜<一句话概括>`（op=append；N = 本轮；'
          '日期 = 本轮正文 `## 当前时间` 的取值；一句话概括，别写长）。'
          '时间只存在于正文里（**没有时间工具**）。op=noChange 必须附 reason，'
          '且历史栏**不接受** op=noChange；直接省略某个栏目算失败。',
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
