import '../agent_activity.dart';
import '../narr_agent_tool.dart';
import 'agent_state_working_copy.dart';

/// 锚定式状态工具（`narrchat_readState` / `narrchat_editSection`）。
///
/// 编辑采用文件式语义，但**不用行号**：模型提供 `before` 原文锚点（来自本轮
/// `narrchat_readState` 调用返回的状态快照块），应用侧做唯一匹配校验
/// （逐字 → 归一化 → 行内子串三级放宽），命中则只替换该段行，未触及的行
/// 字节级保留；`append` 直接追加到栏目末尾；`noChange` 必须附 `reason`。
///
/// **当前时间不属于工具**：它是正文的一部分（`## 当前时间` 小节），
/// 由模型在正文轮直接输出、应用从正文解析写入工作副本。
///
/// 提示词一律 **EN 在前、中文一行摘要在后**（Agent 相关规则英文遵从率更高）。

/// 状态编辑工具名（单一真源：schema、缺口判定、状态轮指令都引用这里）。
const String kEditSectionToolName = 'narrchat_editSection';

/// 状态快照**读取**工具名（真实注册：模型主动调用后才能拿到当前状态）。
///
/// 幂等只读、无副作用：正文轮动笔前调用 = 读到上一轮库内状态；
/// 状态维护轮调用 = 读到工作副本当前态（上一轮 + 本轮正文之后）。
/// 返回值语义统一（工作副本当前渲染），应用侧无需区分调用时机。
const String kReadStateToolName = 'narrchat_readState';

abstract class _StateTool implements NarrAgentTool {
  _StateTool(this.workingCopy);

  final AgentStateWorkingCopy workingCopy;

  @override
  AgentActivityType get activityType => AgentActivityType.tooling;

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async {
    final result = apply(arguments);
    return AgentToolResult(
      success: result.applied,
      content: result.detail,
      summary: result.message,
    );
  }

  StateLineResult apply(Map<String, dynamic> arguments);
}

/// `narrchat_editSection`：对任一栏目做锚定式行级编辑。
class NarrchatEditSectionTool extends _StateTool {
  NarrchatEditSectionTool(super.workingCopy);

  @override
  String get name => 'narrchat_editSection';

  @override
  String get description =>
      'Line-edit ONE section of story state. Provide ONLY changed lines; '
      'unchanged lines are kept byte-for-byte, so NEVER re-type a whole '
      'section. Locate with a verbatim anchor, NEVER line numbers: `before` '
      'must be copied CHARACTER-BY-CHARACTER from the state snapshot block '
      '(`<worldState>` / `<characters>` / `<memory>` in the readState output) '
      '— the tool requires a unique match and returns the section\'s current '
      'full text on any failure, so you can re-anchor in one step. '
      'ops: append (add newLine at the END of the section — always used for '
      'memory entries) / set (before -> newLine) / insertAfter / delete / '
      'noChange (requires `reason`) / reset (whole-section replace: empty '
      'section or explicit restructure only). One call = one section, but '
      '`edits` may carry one op PER CHANGED LINE (a small move, a reaction, a '
      'new thought: pack them as `set` ops). IMPORTANT: noChange is the LAST '
      'RESORT and only correct when nothing in this section really changed — '
      'if the story showed the character or situation moving, write the '
      'changed lines as `set` ops instead; a noChange that sidesteps a '
      'visible change is itself a failure.\n'
      '【中】按行编辑**一个**栏目：只提交变更行，未触及行原样保留，禁止重抄整栏；'
      '定位只用逐字锚点 `before`（从状态快照块复制，不准数行号），'
      '匹配失败会回传该栏当前全文供你重锚；一次调用 = 一个栏目，但 `edits` 可放'
      '**多条 op（每条对应一行改动）**——小动作、一句反应、一段新心理，都用 `set` '
      '如实写入。**op=noChange 是最后手段**：仅当该栏目本轮确实毫无变化时才能用；'
      '正文里角色/局势有明显动向却用 noChange 回避，视为失败。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'section': {
            'type': 'string',
            'enum': [
              for (final s in AgentStateSection.values) s.id,
            ],
            'description': 'Target section / 目标栏目：'
                'worldState / characterState / memorySummary',
          },
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
        'required': ['section', 'edits'],
      };

  @override
  StateLineResult apply(Map<String, dynamic> arguments) {
    final section = AgentStateSection.parse(arguments['section'] as String?);
    if (section == null) {
      return const StateLineResult(
        applied: false,
        message: 'section 取值必须为 worldState / characterState / memorySummary。',
      );
    }
    final rawEdits = arguments['edits'];
    if (rawEdits is! List) {
      return const StateLineResult(applied: false, message: 'edits 必须是数组。');
    }
    final edits = <AgentLineEdit>[];
    for (final e in rawEdits) {
      if (e is! Map) continue;
      // 旧版行号参数（line / after）：明确报错引导改用 before 锚点。
      if (e['line'] != null) {
        return const StateLineResult(
          applied: false,
          message: '行号参数（line）已弃用：行号编辑易错位，'
              '请改用 op=set/insertAfter/delete + before（从状态快照逐字复制原行）'
              '或 op=append（追加到栏目末尾）。',
        );
      }
      edits.add(AgentLineEdit(
        op: '${e['op'] ?? ''}',
        before: '${e['before'] ?? ''}',
        newLine: '${e['newLine'] ?? ''}',
        reason: '${e['reason'] ?? ''}'.trim(),
      ));
    }
    return workingCopy.applyEdits(section, edits);
  }
}

/// `narrchat_readState`：读取工作副本**当前态**（正文轮 = 上一轮库内状态；
/// 状态轮 = 上一轮 + 本轮正文之后的状态）。纯读、幂等，无任何副作用。
class NarrchatReadStateTool implements NarrAgentTool {
  NarrchatReadStateTool(this.workingCopy);

  final AgentStateWorkingCopy workingCopy;

  @override
  String get name => kReadStateToolName;

  @override
  AgentActivityType get activityType => AgentActivityType.tooling;

  @override
  String get description =>
      'Read back the CURRENT in-story state snapshot: `<worldState>` / '
      '`<characterState>` / `<memorySummary>` blocks (time is NOT included — '
      'it lives in the story body as `## 当前时间`). It is the ONLY correct '
      'state base for this round — call it FIRST: in the story turn before '
      'you write the story (the story must follow LAST round\'s state), and '
      'in the state-maintenance turn before any edit (anchors must copy from '
      'the state AFTER this round\'s story). '
      'DO NOT echo these blocks in your reply: they are tool results, not an '
      'output format.\n'
      '【中】读取当前状态快照（`<worldState>` / `<characterState>` / '
      '`<memorySummary>` 块；**不含时间**——时间在正文 `## 当前时间` 小节里）。'
      '这是本轮唯一正确的状态依据。正文轮动笔前**先调用**'
      '（正文基于上一轮状态）；状态维护轮也**先调用**（锚点必须来自本轮正文之后的'
      '状态）。返回的区块只是工具结果，禁止写进你的回复。';

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
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async {
    final snapshot = workingCopy.renderSnapshot();
    return AgentToolResult(
      success: true,
      content: snapshot,
      summary: workingCopy.currentTime.trim().isEmpty
          ? '已读取当前状态快照'
          : '已读取状态快照（${workingCopy.currentTime.trim()}）',
    );
  }
}

/// AGENT 模式默认的状态工具集（顺序即注册顺序：读取器在最前，便于模型养成
/// 「先读再写」的习惯）。
List<NarrAgentTool> buildStateTools(AgentStateWorkingCopy workingCopy) => [
      NarrchatReadStateTool(workingCopy),
      NarrchatEditSectionTool(workingCopy),
    ];
