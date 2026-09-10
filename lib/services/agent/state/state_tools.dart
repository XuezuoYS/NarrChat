import '../agent_activity.dart';
import '../narr_agent_tool.dart';
import 'agent_state_working_copy.dart';
import 'state_tool_names.dart';

export 'state_tool_names.dart';

/// 六个锚定式状态工具（**每个栏目一读一写**），全部作用于本轮「工作副本」
/// （[AgentStateWorkingCopy]）：
///
/// | 栏目 | 读取 | 编辑 |
/// |---|---|---|
/// | 世界状态 | [kReadWorldStateToolName] | [kEditWorldStateToolName] |
/// | 角色状态 | [kReadCharacterStateToolName] | [kEditCharacterStateToolName] |
/// | 历史（记忆总结） | [kReadHistoryToolName] | [kEditHistoryToolName] |
///
/// 拆分动机（相对合并版 `narrchat_readState` / `narrchat_editSection`）：
/// - **读多少给多少**：读取器只回自己那一栏的 `<tag>` 块，模型不必先拿到整份
///   状态才能改一行；同栏旧读取结果自动剔除（每栏只保留最新一份）；
/// - **锚点归属唯一**：编辑器只改自己那一栏，`before` 必须来自**该栏**读取器
///   的结果，不再靠 `section` 参数对应关系；
/// - **档位可分**：Lv.1 只注册历史一对（世界 / 角色由正文携带），
///   Lv.2 注册全部六对（见 [buildStateTools]）。
///
/// 编辑仍是**锚定式文本替换**（不用行号）：`before` 原文锚点 + 唯一匹配校验
/// （逐字 → 归一化 → 行内子串三级放宽），命中只替换该段行，未触及的行字节级
/// 保留；`append` 追加到栏目末尾；`noChange` 必须附 `reason`。时间不属于任何
/// 工具：它是正文的 `## 当前时间` 小节，由应用从正文解析写入工作副本。
///
/// 提示词一律 **EN 在前、中文一行摘要在后**（Agent 相关规则英文遵从率更高）。

/// 栏目 → 读取工具名（单一真源：[state_tool_names.dart] 的常量）。
String agentReadToolName(AgentStateSection section) => switch (section) {
      AgentStateSection.worldState => kReadWorldStateToolName,
      AgentStateSection.characterState => kReadCharacterStateToolName,
      AgentStateSection.memorySummary => kReadHistoryToolName,
    };

/// 栏目 → 编辑工具名（单一真源：[state_tool_names.dart] 的常量）。
String agentEditToolName(AgentStateSection section) => switch (section) {
      AgentStateSection.worldState => kEditWorldStateToolName,
      AgentStateSection.characterState => kEditCharacterStateToolName,
      AgentStateSection.memorySummary => kEditHistoryToolName,
    };

/// 按 [sections] 组装状态工具集：**全部读取器在前、编辑器在后**（同一档位的
/// 顺序恒定，两阶段共用同一份 schema，服务商上下文缓存前缀不受影响）。
List<NarrAgentTool> buildStateTools(
  AgentStateWorkingCopy workingCopy, {
  required List<AgentStateSection> sections,
}) =>
    [
      for (final section in sections) _readTool(workingCopy, section),
      for (final section in sections) _editTool(workingCopy, section),
    ];

NarrAgentTool _readTool(AgentStateWorkingCopy copy, AgentStateSection section) =>
    switch (section) {
      AgentStateSection.worldState => NarrchatReadWorldStateTool(copy),
      AgentStateSection.characterState => NarrchatReadCharacterStateTool(copy),
      AgentStateSection.memorySummary => NarrchatReadHistoryTool(copy),
    };

NarrAgentTool _editTool(AgentStateWorkingCopy copy, AgentStateSection section) =>
    switch (section) {
      AgentStateSection.worldState => NarrchatEditWorldStateTool(copy),
      AgentStateSection.characterState => NarrchatEditCharacterStateTool(copy),
      AgentStateSection.memorySummary => NarrchatEditHistoryTool(copy),
    };

// -----------------------------------------------------------------------------
// 读取器
// -----------------------------------------------------------------------------

/// 状态读取器基类：纯只读、幂等、无副作用。
///
/// 返回值 = **该栏目**工作副本当前渲染（正文轮调用 = 上一轮库内状态；
/// 维护轮调用 = 上一轮 + 本轮正文之后的状态），应用侧无需区分调用时机。
abstract class _SectionReadTool implements NarrAgentTool {
  _SectionReadTool(this.workingCopy, this.section);

  final AgentStateWorkingCopy workingCopy;
  final AgentStateSection section;

  @override
  String get name => agentReadToolName(section);

  @override
  bool get isReadOnly => true;

  @override
  AgentActivityType get activityType => AgentActivityType.tooling;

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'round': {
            'type': 'integer',
            'description': 'Current story round number (used for verification '
                'only). / 本轮轮号（仅供核对，可不传）。',
          },
        },
        'required': <String>[],
      };

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async =>
      AgentToolResult(
        success: true,
        content: workingCopy.renderSection(section),
        summary: '已读取${section.label}（<${section.tag}> 块）',
      );
}

/// `narrchat_readWorldState`：读取 `<worldState>` 块。
class NarrchatReadWorldStateTool extends _SectionReadTool {
  NarrchatReadWorldStateTool(AgentStateWorkingCopy workingCopy)
      : super(workingCopy, AgentStateSection.worldState);

  @override
  String get description =>
      'Read back the CURRENT `<worldState>` block ONLY — the world/scene state '
      'as of now. It is the ONLY correct anchor source for '
      '$kEditWorldStateToolName: copy `before` VERBATIM from this result. '
      'DO NOT echo the block in your reply (it is input, not an output '
      'format).\n'
      '【中】只读取当前 `<worldState>` 块（截至此刻的世界/场景状态）。'
      '它是 $kEditWorldStateToolName 唯一正确的锚点来源，`before` 必须从中'
      '**逐字复制**。禁止把该块写进你的回复（它是输入，不是输出格式）。';
}

/// `narrchat_readCharacterState`：读取 `<characterState>` 块。
class NarrchatReadCharacterStateTool extends _SectionReadTool {
  NarrchatReadCharacterStateTool(AgentStateWorkingCopy workingCopy)
      : super(workingCopy, AgentStateSection.characterState);

  @override
  String get description =>
      'Read back the CURRENT `<characterState>` block ONLY — every character '
      'with their `## 角色名` sub-block and attributes. It is the ONLY correct '
      'anchor source for $kEditCharacterStateToolName: copy `before` VERBATIM '
      'from this result. DO NOT echo the block in your reply.\n'
      '【中】只读取当前 `<characterState>` 块（各角色 `## 角色名` 小节与属性）。'
      '它是 $kEditCharacterStateToolName 唯一正确的锚点来源，`before` 必须从中'
      '**逐字复制**。禁止把该块写进你的回复。';
}

/// `narrchat_readHistory`：读取 `<memorySummary>` 块（历史 / 记忆总结）。
class NarrchatReadHistoryTool extends _SectionReadTool {
  NarrchatReadHistoryTool(AgentStateWorkingCopy workingCopy)
      : super(workingCopy, AgentStateSection.memorySummary);

  @override
  String get description =>
      'Read back the CURRENT `<memorySummary>` block ONLY — the history: one '
      'entry per round (`- 第N轮｜日期：…｜…`). Call it FIRST in the story '
      'turn (the past rounds are the story\'s basis) and again in the '
      'maintenance turn before editing; copy `before` anchors VERBATIM from '
      'this result (the ONLY correct anchor source for '
      '$kEditHistoryToolName). DO NOT echo the block in your reply.\n'
      '【中】只读取当前 `<memorySummary>` 块（历史/记忆总结：每轮一条 '
      '`- 第N轮｜日期：…｜…`）。正文回合动笔前**先调用**（剧本基于以往轮次），'
      '维护回合编辑前再调用一次；`before` 锚点必须从中**逐字复制**'
      '（$kEditHistoryToolName 唯一正确的锚点来源）。禁止把该块写进你的回复。';
}

// -----------------------------------------------------------------------------
// 编辑器
// -----------------------------------------------------------------------------

/// 状态编辑器基类：锚定式文本替换（一次调用只改自己那一栏）。
abstract class _SectionEditTool implements NarrAgentTool {
  _SectionEditTool(this.workingCopy, this.section);

  final AgentStateWorkingCopy workingCopy;
  final AgentStateSection section;

  @override
  String get name => agentEditToolName(section);

  @override
  AgentActivityType get activityType => AgentActivityType.tooling;

  /// 编辑器会改动工作副本：非只读（参与正文轮闭环判定与状态失败反馈）。
  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'edits': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'op': {
                  'type': 'string',
                  'enum': const [
                    'append',
                    'set',
                    'insertAfter',
                    'delete',
                    'noChange',
                    'reset',
                  ],
                },
                'before': {
                  'type': 'string',
                  'description':
                      'Verbatim anchor line(s) copied from the state snapshot '
                          '("\\n" joins consecutive lines). Required by '
                          'set/insertAfter/delete. 锚点：从状态快照逐字复制的行。',
                },
                'newLine': {
                  'type': 'string',
                  'description':
                      'append/insertAfter: new line text; set: replacement; '
                          'reset: the whole new section. '
                          '新内容（append/insertAfter 新增行；set 替换文本；'
                          'reset 整栏新全文）。',
                },
                'reason': {
                  'type': 'string',
                  'description':
                      'Required for op=noChange: one short sentence why this '
                          'section really did not change. '
                          'op=noChange 必填：一句话说明本轮确实无变化的原因。',
                },
              },
              'required': ['op'],
            },
          },
        },
        'required': ['edits'],
      };

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async {
    final rawEdits = arguments['edits'];
    if (rawEdits is! List) {
      return const AgentToolResult(
        success: false,
        content: 'edits 必须是数组。',
        summary: 'edits 必须是数组。',
      );
    }
    final edits = <AgentLineEdit>[];
    for (final e in rawEdits) {
      if (e is! Map) continue;
      // 旧版行号参数（line / after）：明确报错引导改用 before 锚点。
      if (e['line'] != null) {
        return const AgentToolResult(
          success: false,
          content: '行号参数（line）已弃用：行号编辑易错位，'
              '请改用 op=set/insertAfter/delete + before（从状态快照逐字复制原行）'
              '或 op=append（追加到栏目末尾）。',
          summary: '行号参数（line）已弃用',
        );
      }
      edits.add(AgentLineEdit(
        op: '${e['op'] ?? ''}',
        before: '${e['before'] ?? ''}',
        newLine: '${e['newLine'] ?? ''}',
        reason: '${e['reason'] ?? ''}'.trim(),
      ));
    }
    final result = workingCopy.applyEdits(section, edits);
    return AgentToolResult(
      success: result.applied,
      content: result.detail,
      summary: result.message,
    );
  }
}

/// `narrchat_editWorldState`：世界状态栏目的锚定式行编辑。
class NarrchatEditWorldStateTool extends _SectionEditTool {
  NarrchatEditWorldStateTool(AgentStateWorkingCopy workingCopy)
      : super(workingCopy, AgentStateSection.worldState);

  @override
  String get description =>
      'Line-edit the WORLD STATE section (`<worldState>`). Provide ONLY '
      'changed lines; unchanged lines are kept byte-for-byte, so NEVER '
      're-type the whole section. Locate with a verbatim anchor, NEVER line '
      'numbers: `before` must be copied CHARACTER-BY-CHARACTER from the '
      '$kReadWorldStateToolName result — the tool requires a unique match and '
      'returns this section\'s current full text on any failure, so you can '
      're-anchor in one step. ops: append (add newLine at the END) / '
      'set (before -> newLine) / insertAfter / delete / noChange (requires '
      '`reason`) / reset (whole-section replace: empty section or explicit '
      'restructure only). `edits` may carry one op PER CHANGED LINE — a new '
      'in-story beat is a real edit, so pack the affected lines as `set` ops '
      'instead of declaring noChange.\n'
      '【中】按行编辑**世界状态**栏目（`<worldState>`）：只提交变更行，未触及行'
      '原样保留，禁止重抄整栏；定位只用逐字锚点 `before`'
      '（从 $kReadWorldStateToolName 的结果复制，不准数行号），'
      '匹配失败会回传该栏当前全文供你重锚；`edits` 可放**多条 op**'
      '（每条对应一行改动）——正文里新发生的情节要点就是真实编辑，'
      '不要用 noChange 回避。';
}

/// `narrchat_editCharacterState`：角色状态栏目的锚定式行编辑。
class NarrchatEditCharacterStateTool extends _SectionEditTool {
  NarrchatEditCharacterStateTool(AgentStateWorkingCopy workingCopy)
      : super(workingCopy, AgentStateSection.characterState);

  @override
  String get description =>
      'Line-edit the CHARACTER STATE section (`<characterState>`). Provide '
      'ONLY changed lines; unchanged lines (and untouched characters) are '
      'kept byte-for-byte, so NEVER re-type the whole section. Locate with a '
      'verbatim anchor, NEVER line numbers: `before` must be copied '
      'CHARACTER-BY-CHARACTER from the $kReadCharacterStateToolName result '
      '(one op per changed line). ops: append / set (before -> newLine) / '
      'insertAfter / delete / noChange (requires `reason`) / reset (empty '
      'section or explicit restructure only). IMPORTANT: for every named '
      'character in this round\'s story walk their mutable lines (好感度 / '
      '当前心理 / 当前状态 / 当前位置 / 伤势 / 物品 / 关系…): if the story shows '
      'ANYTHING new — a reaction, a glance, a thought, a move, an item — `set` '
      'that line as an op in ONE call; op=noChange is the LAST RESORT and only '
      'correct for a character the story merely mentions with no new '
      'information at all. A rejected edit returns the section\'s current '
      'full text so you can re-anchor in one step.\n'
      '【中】按行编辑**角色状态**栏目（`<characterState>`）：只提交变更行，'
      '未触及的行与角色原样保留，禁止重抄整栏；`before` 必须从 '
      '$kReadCharacterStateToolName 的结果**逐字复制**（一条 op 对应一行改动）。'
      '**禁止懒修改**：对本轮出场的每个具名角色逐行核对可变字段'
      '（好感度/当前心理/当前状态/当前位置/伤势/物品/关系…），正文里有任何新信息'
      '（一个反应、一句心理、一次移动）就要用 op=set 如实写入；'
      'op=noChange 是最后手段，仅当该角色只是被提及、毫无新信息时才可用'
      '（必须附 reason）。锚点被拒时会回传该栏当前全文，一步到位重锚。';
}

/// `narrchat_editHistory`：历史（记忆总结）栏目的锚定式行编辑。
class NarrchatEditHistoryTool extends _SectionEditTool {
  NarrchatEditHistoryTool(AgentStateWorkingCopy workingCopy)
      : super(workingCopy, AgentStateSection.memorySummary);

  @override
  String get description =>
      'Line-edit the HISTORY section (`<memorySummary>`): one memory entry per '
      'round, format `- 第N轮｜日期：<时间>｜<一句话概括>`. Every round must end '
      'with EXACTLY ONE entry for this round — add it with op=append (the date '
      'is this round\'s `## 当前时间` value). op=noChange is NOT accepted here; '
      'op=set / delete are for correcting existing entries only. Locate with a '
      'verbatim anchor copied CHARACTER-BY-CHARACTER from the '
      '$kReadHistoryToolName result — NEVER line numbers. A rejected edit '
      'returns this section\'s current full text so you can re-anchor in one '
      'step.\n'
      '【中】按行编辑**历史/记忆总结**栏目（`<memorySummary>`）：每轮一条 '
      '`- 第N轮｜日期：<时间>｜<一句话概括>`。每轮必须**恰好一条**本轮条目——'
      '用 op=append 追加（日期 = 本轮正文 `## 当前时间` 的取值）；'
      '本栏**不接受** op=noChange；op=set / delete 只用于修正既有条目。'
      '锚点必须从 $kReadHistoryToolName 的结果**逐字复制**，绝不数行号；'
      '匹配失败会回传该栏当前全文供你重锚。';
}
