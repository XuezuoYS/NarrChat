import '../../../utils/memory_entry_format.dart';
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
/// 工具 `description` 一律**简明中文**（v2 口径：撤销中英双语，英文只保留工具名
/// `narrchat_*` 与状态块标签 `<worldState>` / `<characterState>` / `<memorySummary>`）。

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
/// 顺序恒定，各阶段共用同一份 schema，服务商上下文缓存前缀不受影响）。
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
/// 返回值 = **该栏目**工作副本当前渲染（准备 / 正文阶段调用 = 上一轮库内状态；
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
            'description': '本轮轮号（仅供核对，可不传）。',
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
      '只读回当前 `<worldState>` 块（截至此刻的世界 / 场景状态）。'
      '它是 $kEditWorldStateToolName 唯一正确的锚点来源，`before` 必须从这里逐字复制。'
      '不要把这个块写进回复——它是给你读的材料，不是你要输出的格式。';
}

/// `narrchat_readCharacterState`：读取 `<characterState>` 块。
class NarrchatReadCharacterStateTool extends _SectionReadTool {
  NarrchatReadCharacterStateTool(AgentStateWorkingCopy workingCopy)
      : super(workingCopy, AgentStateSection.characterState);

  @override
  String get description =>
      '只读回当前 `<characterState>` 块（每个角色的 `## 角色名` 小节与属性）。'
      '它是 $kEditCharacterStateToolName 唯一正确的锚点来源，'
      '`before` 必须从这里逐字复制。不要把这个块写进回复。';
}

/// `narrchat_readHistory`：读取 `<memorySummary>` 块（历史 / 记忆总结）。
class NarrchatReadHistoryTool extends _SectionReadTool {
  NarrchatReadHistoryTool(AgentStateWorkingCopy workingCopy)
      : super(workingCopy, AgentStateSection.memorySummary);

  @override
  String get description =>
      '只读回当前 `<memorySummary>` 块（历史 / 记忆总结：每轮一条 '
      '`$kMemoryEntryFormat`）。每轮**只在动笔前读一次**——以往轮次是本轮大纲与'
      '新记忆条目的依据；它是 $kEditHistoryToolName 唯一正确的锚点来源，'
      '`before` 必须从这里逐字复制。同一轮里重复读取会被拒绝，'
      '复用对话中已有的块；不要把这个块写进回复。\n$kMemoryEntryFormatPrecedence';
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
                  'description': '锚点：从该栏目读取结果里逐字复制的原文行'
                      '（`\\n` 连接连续多行）；`set` / `insertAfter` / `delete` 必填。',
                },
                'newLine': {
                  'type': 'string',
                  'description': '新内容：`append` / `insertAfter` 是新增行，'
                      '`set` 是替换文本，`reset` 是整栏新全文。',
                },
                'reason': {
                  'type': 'string',
                  'description': '`op=noChange` 必填：一句话说明本轮确实没变的原因。',
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
      '按行编辑**世界状态**栏目（`<worldState>`）：只提交变更行，没动的行原样保留，'
      '禁止重抄整栏；用原文锚点定位、**绝不数行号**：`before` 必须从 '
      '$kReadWorldStateToolName 的结果里逐字复制（要求唯一命中，失败会回传该栏目'
      '当前全文，让你一步重锚）。`edits` 可以放多条 `op`（每条对应一行改动）：'
      '`append`（末尾追加）/ `set`（`before` 换成 `newLine`）/ `insertAfter` / '
      '`delete` / `noChange`（必须写非空 `reason`）/ `reset`（仅空栏目或明确重排）。'
      '正文里新发生的情节要点就是真实编辑，不要用 `noChange` 回避。';
}

/// `narrchat_editCharacterState`：角色状态栏目的锚定式行编辑。
class NarrchatEditCharacterStateTool extends _SectionEditTool {
  NarrchatEditCharacterStateTool(AgentStateWorkingCopy workingCopy)
      : super(workingCopy, AgentStateSection.characterState);

  @override
  String get description =>
      '按行编辑**角色状态**栏目（`<characterState>`）：只提交变更行，'
      '没动的行与角色原样保留，禁止重抄整栏；用原文锚点定位、**绝不数行号**：'
      '`before` 必须从 $kReadCharacterStateToolName 的结果里逐字复制'
      '（一条 `op` 对应一行改动）。'
      '**禁止懒修改**：对本轮出场的每个具名角色逐行核对可变字段'
      '（好感度 / 当前心理 / 当前状态 / 当前位置 / 伤势 / 物品 / 关系…），'
      '正文里有任何新信息（一个反应、一句心理、一次移动）就用 `op=set` 如实写入；'
      '`noChange` 是最后手段，只有该角色只是被提及、毫无新信息时才用'
      '（必须写 `reason`）。`op` 取值同世界状态（`append` / `set` / `insertAfter` / '
      '`delete` / `noChange` / `reset`）。';
}

/// `narrchat_editHistory`：历史（记忆总结）栏目的锚定式行编辑。
class NarrchatEditHistoryTool extends _SectionEditTool {
  NarrchatEditHistoryTool(AgentStateWorkingCopy workingCopy)
      : super(workingCopy, AgentStateSection.memorySummary);

  @override
  String get description =>
      '按行编辑**历史 / 记忆总结**栏目（`<memorySummary>`）：每轮一条 '
      '`$kMemoryEntryFormat`，本轮必须用 `op=append` 追加**恰好一条**'
      '（`{轮次}` = 本轮轮号的裸数字；`{时间}` = 本轮计划的故事内时间，'
      '正文 `## 当前时间` 与它一致）；本栏**不接受** `op=noChange`；'
      '`op=set` / `delete` 用于修正既有条目，以及在本轮指令要求合并时'
      '把区间改成一条合并条目 `$kMemoryMergedEntryFormat`'
      '（一条 `op=set`，`before` = 那几行条目原文用 \\n 连接）——'
      '仅在本轮指令要求合并时才做。'
      '`before` 必须从 $kReadHistoryToolName 的结果里逐字复制，绝不数行号'
      '（匹配失败会回传该栏当前全文供你重锚）。\n$kMemoryEntryFormatPrecedence';
}
