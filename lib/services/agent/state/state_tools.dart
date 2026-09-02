import '../agent_activity.dart';
import '../narr_agent_tool.dart';
import 'agent_state_working_copy.dart';

/// 锚定式状态工具（`narrchat_editSection` / `narrchat_advanceTime`）。
///
/// 编辑文件式语义，但**不用行号**（对齐 DeepSeek Harness `edit` /
/// `str_replace_editor` 的定位机制）：模型提供 `before` 原文锚点
/// （整行 / 连续多行逐字复制），应用侧做**唯一匹配**校验——未命中 / 不唯一
/// 返回精确错误（含当前行数与命中行号），命中则只替换该段行，未触及的行
/// 字节级保留；`append` 直接追加到栏目末尾（无需任何定位）；
/// `noChange` 用于声明本轮无变化；`reset` 仅用于空栏目 / 明确重排。
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
      content: result.message,
    );
  }

  StateLineResult apply(Map<String, dynamic> arguments);

  static String _str(Map<String, dynamic> args, String key) =>
      (args[key] as String? ?? '').trim();
}

/// `narrchat_editSection`：对任一栏目做锚定式行级编辑。
class NarrchatEditSectionTool extends _StateTool {
  NarrchatEditSectionTool(super.workingCopy);

  @override
  String get name => 'narrchat_editSection';

  @override
  String get description =>
      '以「编辑文件」方式对单个栏目做行级修改：只提供**变更的行**（edits），'
      '未触及的行不要重新提供（应用侧原样保留）。'
      '**定位一律用原文锚点，不要计算行号**：'
      'before 必须是从当前快照（上一条消息）中**逐字复制**的行'
      '（可含 \\n 表示连续多行到整段），应用侧做唯一匹配校验。'
      'edits 每项：op=append（把 newLine 追加到栏目**末尾**，记忆条目固定用）/ '
      'op=set（before 锚定 → newLine 替换）/ op=insertAfter（before 锚定 → '
      'newLine 插入其后）/ op=delete（before 锚定 → 删除）/ '
      'op=noChange（栏目本轮无变化声明）/ op=reset（整栏目替换，'
      '仅限空栏目或明确重排）。\n'
      '[EN] Line-editing without line numbers: provide ONLY changed lines. '
      '`before` must be copied VERBATIM from the current snapshot (the last '
      'message; \\n joins consecutive lines up to a whole block); the tool '
      'requires a UNIQUE match and returns the exact error (with hit line '
      'numbers) otherwise. This guarantees you always modify the line you '
      'mean. ops: append (adds newLine at the END of the section — always '
      'use for memory entries) / set (before -> newLine) / insertAfter '
      '(before -> insert newLine after it) / delete / noChange / '
      'reset (whole-section replace, empty section or explicit restructure '
      'only).';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'section': {
            'type': 'string',
            'enum': [
              for (final s in AgentStateSection.values) s.id,
            ],
            'description': '目标栏目：worldState / characterState / memorySummary',
          },
          'edits': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'op': {
                  'type': 'string',
                  'enum': [
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
                      '锚点：从当前快照逐字复制的行（\\n 连接 = 连续多行）；'
                      'set/insertAfter/delete 必备',
                },
                'newLine': {
                  'type': 'string',
                  'description':
                      'append/insertAfter：新增行文本；set：替换后文本；'
                      'reset：栏目新全文',
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
              '请改用 op=set/insertAfter/delete + before（逐字复制原行）'
              '或 op=append（追加到栏目末尾）。',
        );
      }
      edits.add(AgentLineEdit(
        op: '${e['op'] ?? ''}',
        before: '${e['before'] ?? ''}',
        newLine: '${e['newLine'] ?? ''}',
      ));
    }
    return workingCopy.applyEdits(section, edits);
  }
}

/// `narrchat_advanceTime`：推进当前时间（仅校验存在）。
class NarrchatAdvanceTimeTool extends _StateTool {
  NarrchatAdvanceTimeTool(super.workingCopy);

  @override
  String get name => 'narrchat_advanceTime';

  @override
  String get description =>
      '推进剧情当前时间（如「第三天 午时」→「第三天 申时」）：'
      '每轮必须调用（时间未变可传原值），格式由你按剧情自行组织、'
      '保持一致即可；本轮记忆条目的日期必须与之一致。\n'
      '[EN] Advance the in-story time (e.g. Day-3 noon -> Day-3 afternoon). '
      'Call EVERY round (pass the same value if unchanged); format is free but '
      'consistent; this round\'s memory entry date must match it.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'time': {'type': 'string', 'description': '更新后的剧情时间'},
        },
        'required': ['time'],
      };

  @override
  StateLineResult apply(Map<String, dynamic> arguments) {
    return workingCopy.setTime(_StateTool._str(arguments, 'time'));
  }
}

/// AGENT 模式默认的状态工具集（顺序即注入顺序）。
List<NarrAgentTool> buildStateTools(AgentStateWorkingCopy workingCopy) => [
      NarrchatEditSectionTool(workingCopy),
      NarrchatAdvanceTimeTool(workingCopy),
    ];
