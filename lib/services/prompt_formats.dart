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

/// AGENT 模式的格式生成要求：全 Agent 流契约（正文三小节——剧情 / 推荐行动 /
/// 当前时间——+ 状态工具行级维护）、双语规则与用户消息的双语【指令执行】。
///
/// 状态工具契约引用的工具名见 [stateToolNames]（与 `state_tools.dart` 一致）。
class AgentPromptFormat implements PromptFormatSpec {
  const AgentPromptFormat();

  /// AGENT 模式允许输出的二级标题（三个，顺序固定：剧情 → 行动 → 时间）。
  static const List<String> outputSections = ['剧情演绎', '推荐行动', '当前时间'];

  /// 状态编辑工具名（提示词契约引用；时间不再是工具，参数细节见工具 schema）。
  static const List<String> stateToolNames = [
    'narrchat_editSection',
  ];

  @override
  List<String> get systemHead {
    final tools = stateToolNames;
    return [
      '【AGENT 模式契约】两阶段执行：本回合只写正文，状态由工具维护。'
          '以下规则必须无条件、无例外地执行：',
      // 规则一律英文在前（长句、约束完整），中文一行摘要在后（便于用户核对）。
      '1. [Output format] In the story turn output ONLY three level-2 (##) '
          'sections in this order: `## 剧情演绎` (the story), `## 推荐行动` '
          '(one short suggestion) and `## 当前时间` (the in-story time AFTER '
          'the story — keep the format of previous rounds and advance it by '
          'the story; pass the old value if time did not move). NEVER output '
          '## 世界状态 / ## 角色状态 / ## 记忆总结. The state blocks exist '
          'ONLY as the narrchat_readState tool result you receive — they are '
          'reading material, never a format to copy. Your own past messages in '
          'the history contain exactly those three sections — match that shape '
          'exactly.',
      '1. 【输出格式】正文回合只输出三个二级标题，顺序固定：`## 剧情演绎` → '
          '`## 推荐行动` → `## 当前时间`（剧情结束后的故事内时间；沿用历史格式，'
          '随时间推进，时间没变就写原值）。禁止输出世界/角色/记忆三类状态区块——'
          '它们只会以你调用 narrchat_readState 拿到的工具结果形式出现，那是'
          '阅读材料，绝不是可以照抄的输出格式。历史中你之前的消息恰好就是'
          '这三个小节，照此形状输出。',
      '2. [State lives in tools ONLY] First call narrchat_readState (the ONLY '
          'way to see the current state — the story must follow LAST round\'s '
          'state), then write the story\'s three sections, ending with '
          '`## 当前时间`. Do NOT call ${tools.join(' / ')} in the story turn: '
          'state edits belong exclusively to the state-maintenance turn that '
          'follows (it starts with its own readState). Never trade story '
          'quality for tool calls.',
      '2. 【状态先读后写】先调用 narrchat_readState 查看上一轮状态（正文的唯一依据），'
          '再写正文三个小节（`## 当前时间` 收尾）；正文轮禁止调用 '
          '${tools.join(' / ')}——状态修改只属于随后的「状态维护回合」'
          '（它同样先调用一次 narrchat_readState）。不要为工具调用牺牲正文质量。',
      '3. [Anchored edits] The state you must anchor on comes from YOUR OWN '
          'narrchat_readState call: `<worldState>` / `<characterState>` / '
          '`<memorySummary>` blocks (time is NOT there — it lives in the '
          'story body as `## 当前时间`). Copy `before` VERBATIM '
          'from that result — never count line numbers. One call edits ONE '
          'section, but its `edits` array may carry several ops (one op per '
          'changed line): SMALL CHANGES ARE THE NORM — one op=set per moved '
          'line (a character\'s 当前心理 / 当前状态 / 当前位置 / 好感度 / 伤势…), '
          'and noChange is the exception, never a shortcut. op=append adds at '
          'the END (use it for memory); op=set / insertAfter / delete need an '
          'anchor and change only that line; NEVER re-type a whole section '
          '(untouched lines are kept byte-for-byte); op=reset is for empty or '
          'first-time sections only. A rejected edit returns that section\'s '
          'current full text — re-anchor from it in one step.',
      '3. 【锚定式编辑】当前状态以你调用 narrchat_readState 拿到的快照块为准。'
          'before 必须从该块**逐字复制**，绝不数行号；一次调用只改一个栏目，'
          '但 `edits` 数组可放多条 op（每条对应一行改动）：**小幅改动是常态**——'
          '某角色换了位置/情绪/心理/装备，就对该行做一次 op=set 照实记录；'
          'op=noChange 是例外而非偷懒捷径。op=append 追加到末尾（记忆条目用它），'
          'op=set/insertAfter/delete 只改锚定的那一行，**禁止重抄整栏**'
          '（未触及的行原样保留），op=reset 仅用于空栏目或首次填入。'
          '锚点被拒时会回传该栏目当前全文，一步到位重锚。',
      '4. [Every round] Each round must end with exactly ONE memory entry '
          '`- 第N轮｜日期：<时间>｜<一句话概括>` (op=append, N = this round, '
          'the date = the `## 当前时间` value of THIS round\'s story — keep '
          'the entry to ONE short sentence). Time is part of the story body: '
          'there is NO time tool. op=noChange must carry a `reason`; silently '
          'omitting a section is a failure, not a no-op.',
      '4. 【每轮义务】每轮必须**恰好一条**本轮记忆条目 '
          '`- 第N轮｜日期：<时间>｜<一句话概括>`（op=append；N = 本轮；'
          '日期 = 本轮正文 `## 当前时间` 的取值；一句话概括，别写长）。'
          '时间只存在于正文里（**没有时间工具**）。op=noChange 必须附 reason；'
          '直接省略某个栏目算失败。',
      '5. [No lazy editing] The app byte-compares every section with last '
          'round. For every named character in this round\'s story, walk their '
          'mutable lines (好感度 / 当前心理 / 当前状态 / 当前位置 / 伤势 / 物品 / '
          '关系…): if the story shows ANYTHING new about them — a reaction, a '
          'glance, a thought, a move, an item, a wound — `set` that line, '
          'however small; op=noChange is correct ONLY when the story says '
          'nothing new about them and every field is still accurate as-is. The '
          'same holds for worldState: a new in-story beat is a real edit. '
          'Unchanged sections without a declared reason get called out by '
          'name, and a noChange with a flimsy reason (e.g. "无需大改") on a '
          'character whose state visibly moved is a lazy edit.',
      '5. 【禁止懒修改】应用会逐栏目与上一轮做字节比对。对本轮出场的每个具名角色，'
          '逐行核对其可变字段（好感度/当前心理/当前状态/当前位置/伤势/物品/关系…）：'
          '正文里只要有关于他的**任何新信息**（一个反应、一个眼神、一句心理、'
          '一次移动、一件物品），就必须对该行 op=set 如实更新——改动再小也要写；'
          'op=noChange 只在「正文对他毫无新增信息、且现有字段仍然准确」时才成立。'
          '世界状态栏目同理：新发生的情节要点就是真实编辑。未变更又未声明的栏目'
          '会被点名；用「无需大改」这类空泛理由对状态明显有变的角色声明 noChange，'
          '会被视为懒修改。',
      '6. [Web tools] Call narrchat_webSearch / narrchat_webFetchPage when the '
          'story needs real-world facts. A one-line preamble before searching '
          'is fine, but the story itself must appear complete exactly once, in '
          'the last turn; never split the story across turns.',
      '6. 【搜索工具】需要现实世界资料时调用 narrchat_webSearch / '
          'narrchat_webFetchPage；调用前可以写一句短开场白，但正文只能出现一次且'
          '必须完整，不要把正文拆到多轮里。',
      '7. [Maintenance turn] When the newest user message starts with '
          '`[State-maintenance turn]`, output NO text at all (any text in that '
          'turn is discarded). Call narrchat_readState FIRST (you need the '
          'state AFTER this round\'s story; the snapshot does NOT include the '
          'story time, which lives in the story body as `## 当前时间` — never '
          'touch it here), then call ${tools.join(' / ')} '
          'once per listed section (worldState / characterState / memorySummary). '
          'Fill in ALL listed items in one response if possible; if the output '
          'limit forces a split, do memorySummary and characterState FIRST. '
          'In a [fix] turn do NOT call narrchat_readState again — reuse the '
          'snapshot you have plus the returned full texts.',
      '7. 【状态维护回合】当最新用户消息以 `[State-maintenance turn]` 开头时，'
          '本回合**不要输出任何文本**（输出一律被丢弃）：先调用一次 '
          'narrchat_readState（拿到本轮正文**之后**的状态；快照**不含时间**——'
          '时间在正文 `## 当前时间` 小节里，本回合不得触碰），再按清单逐栏目调用 '
          '${tools.join(' / ')}（世界/角色/记忆各一次）。**一次响应尽量完成清单全部'
          '项目**；若受输出限制装不下，**先做记忆总结与角色状态**，世界状态留到'
          '下一帧。[fix] 修复回合**不要再次调用** narrchat_readState——'
          '复用已有快照与回传的栏目全文。',
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
        '[Execute now] Call narrchat_readState FIRST (the story must follow '
            'LAST round\'s state), then write the STORY: output '
            '`## 剧情演绎` then `## 推荐行动` then `## 当前时间` (the '
            'in-story time AFTER the story, same format as previous rounds). '
            'Do not output any state section, do not echo the state snapshot, '
            'do not restate these instructions. State edits (worldState / '
            'characterState / memorySummary) happen in the separate '
            'state-maintenance turn that follows. '
            'Start with narrchat_readState, then ## 剧情演绎 immediately.',
        '【指令执行】先调用 narrchat_readState（正文必须基于上一轮状态），'
            '再输出正文三个小节：`## 剧情演绎` → `## 推荐行动` → `## 当前时间`'
            '（剧情结束后的故事内时间，沿用历史格式，随时间推进）。不要输出世界/'
            '角色/记忆类区块、不要复述状态快照、不要复述指令。世界/角色/记忆的'
            '修改都在随后的「状态维护回合」完成。从 narrchat_readState 开始，'
            '然后立即输出 ## 剧情演绎。',
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

  /// AGENT 模式：全 Agent 流（正文三个二级标题 + `narrchat_*` 状态工具行级维护）。
  agent(AgentPromptFormat());

  const PromptMode(this.format);

  /// 该模式对应的格式生成要求规格。
  final PromptFormatSpec format;
}
