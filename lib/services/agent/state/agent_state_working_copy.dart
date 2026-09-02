import '../../../models/round.dart';

/// 状态节区（工具 `section` 参数的合法取值）。
enum AgentStateSection {
  worldState,
  characterState,
  memorySummary;

  String get id => switch (this) {
        AgentStateSection.worldState => 'worldState',
        AgentStateSection.characterState => 'characterState',
        AgentStateSection.memorySummary => 'memorySummary',
      };

  String get label => switch (this) {
        AgentStateSection.worldState => '世界状态',
        AgentStateSection.characterState => '角色状态',
        AgentStateSection.memorySummary => '记忆总结',
      };

  static AgentStateSection? parse(String? raw) {
    for (final s in AgentStateSection.values) {
      if (s.id == raw) return s;
    }
    return null;
  }
}

/// 单条锚定式行级编辑指令（编辑文件式，但**不用行号**）。
///
/// 定位的唯一依据是 [before]：必须与当前栏目中的某行（或连续多行）
/// **逐字相同**，应用侧做「唯一匹配」校验。模型不需要（也不应该）计算行号，
/// 只需从上一条消息的快照中复制要修改的行原文——这是 DeepSeek Harness /
/// Claude 系工具采用的机制：锚点唯一性保证「修改的就是想要的那一行」。
class AgentLineEdit {
  /// op：
  /// - `append`：把 [newLine] 追加到栏目**末尾**（记忆条目等追加场景首选，
  ///   无需任何定位）；
  /// - `set`：以 [before] 锚定（唯一匹配）整段行后替换为 [newLine]；
  /// - `insertAfter`：以 [before] 锚定后在其后插入 [newLine]；
  /// - `delete`：以 [before] 锚定后删除该段行；
  /// - `noChange`：声明本轮无变化；
  /// - `reset`：整栏目替换（仅限空栏目 / 首次填入 / 明确重排）。
  final String op;

  /// 锚点：必须与栏目中某行（或连续多行，用 `\n` 连接）**逐字相同**
  /// （行尾空白宽容）；`set / insertAfter / delete` 必备。
  final String before;

  /// 新内容：`append` / `insertAfter` 为新增行文本；`set` 为替换后文本；
  /// `reset` 为栏目新全文（均可含 `\n`）。
  final String newLine;

  const AgentLineEdit({
    required this.op,
    this.before = '',
    this.newLine = '',
  });
}

/// 行级状态修改结果。
class StateLineResult {
  final bool applied;
  final String message;

  const StateLineResult({required this.applied, required this.message});
}

/// 锚点匹配结果：命中的行区间（含）。
typedef _AnchorMatch = ({int start, int end});

/// 本轮 AGENT 生成的状态「工作副本」。
///
/// 以最新一轮快照（[lastRound]）为基座；所有 `narrchat_*` 状态工具只作用于
/// 本副本；本轮成功时由应用侧取 [mergedSnapshot] 落库，失败 / 取消时整体丢弃。
///
/// 【锚定式编辑】模型只提供**变更的行**（op=set/insertAfter/delete 以 `before`
/// 原文锚定 + 唯一匹配校验，未命中 / 不唯一返回精确错误；op=append 追加到
/// 栏目末尾，无需定位），未触及的行一字不动（字节级保留）；首轮 / 空栏目可
/// 用 `reset` 整体填入。
///
/// 【唯一结构性校验】记忆总结每次变更后必须包含本轮（第 N 轮）条目。
class AgentStateWorkingCopy {
  AgentStateWorkingCopy({
    required this.roundIndex,
    Round? lastRound,
    List<String> categoryNames = const [],
  })  : worldState = lastRound?.worldState ?? '',
        characterState = lastRound?.characterState ?? '',
        memorySummary = lastRound?.memorySummary ?? '',
        currentTime = lastRound?.currentTime ?? '',
        categories = List.unmodifiable(categoryNames);

  final int roundIndex;
  final List<String> categories;

  String worldState;
  String characterState;
  String memorySummary;
  String currentTime;

  /// 本轮被「触及」的栏目（编辑或 noChange 声明均计入；完整性检查用）。
  final Set<AgentStateSection> touchedSections = {};

  /// 合并后的快照（aiNarrative / recommendedAction 由调用方从正文解析）。
  RoundSnapshot mergedSnapshot() => RoundSnapshot(
        worldState: worldState,
        characterState: characterState,
        memorySummary: memorySummary,
        currentTime: currentTime,
      );

  String sectionText(AgentStateSection section) => switch (section) {
        AgentStateSection.worldState => worldState,
        AgentStateSection.characterState => characterState,
        AgentStateSection.memorySummary => memorySummary,
      };

  void _setSection(AgentStateSection section, String value) {
    switch (section) {
      case AgentStateSection.worldState:
        worldState = value;
      case AgentStateSection.characterState:
        characterState = value;
      case AgentStateSection.memorySummary:
        memorySummary = value;
    }
  }

  /// 应用一组锚定式编辑（按数组顺序逐条应用；每条锚点在**应用时刻**的
  /// 当前文本中唯一匹配，先插入的内容可被后续编辑引用；事务化：
  /// 任一失败则整体不提交）。
  ///
  /// 记忆总结编辑后校验「第 N 轮条目」；空栏目允许 `append` 或 `reset`。
  StateLineResult applyEdits(AgentStateSection section, List<AgentLineEdit> edits) {
    if (edits.isEmpty) {
      return const StateLineResult(applied: false, message: 'edits 不能为空');
    }
    if (edits.every((e) => e.op == 'noChange')) {
      if (section == AgentStateSection.memorySummary) {
        return const StateLineResult(
          applied: false,
          message: '记忆总结每轮必须补充本轮条目，不能声明 noChange；'
              '请用 op=append 追加 `- 第N轮｜日期：<当前时间>｜<一句话概括>`。',
        );
      }
      touchedSections.add(section);
      return StateLineResult(
        applied: true,
        message: '${section.label}：本轮无变化（已记录）',
      );
    }
    final lines = <String>[...sectionText(section).split('\n')];
    try {
      for (final edit in edits) {
        _applyOne(section, lines, edit);
      }
    } on StateEditException catch (e) {
      return StateLineResult(applied: false, message: e.message);
    }
    final result = _join(lines);
    if (section == AgentStateSection.memorySummary &&
        !result.contains('第$roundIndex轮')) {
      return StateLineResult(
        applied: false,
        message: '记忆总结变更后必须包含本轮（第 $roundIndex 轮）条目，'
            '格式：`- 第N轮｜日期：<当前时间>｜<一句话概括>`；'
            '追加条目请用 op=append（自动追加到栏目末尾）。',
      );
    }
    _setSection(section, result);
    touchedSections.add(section);
    return StateLineResult(
      applied: true,
      message: '${section.label}已更新（${edits.length} 条编辑）',
    );
  }

  /// 更新当前时间（仅校验存在）。
  StateLineResult setTime(String time) {
    final t = time.trim();
    if (t.isEmpty) {
      return const StateLineResult(applied: false, message: '当前时间不能为空。');
    }
    currentTime = t;
    return StateLineResult(applied: true, message: '当前时间已更新为：$t');
  }

  // ---------------------------------------------------------------------------
  // 内部：单条锚定编辑（字节级保留）
  // ---------------------------------------------------------------------------

  /// 可寻址行数：忽略「结尾换行」产生的尾部空行。
  static int _addressableLineCount(List<String> lines) {
    var count = lines.length;
    if (count > 0 && lines.last.isEmpty) count--;
    return count;
  }

  void _applyOne(
    AgentStateSection section,
    List<String> lines,
    AgentLineEdit edit,
  ) {
    switch (edit.op) {
      case 'reset':
        if (edit.newLine.trim().isEmpty) {
          throw const StateEditException('reset 的 newLine 不能为空');
        }
        lines
          ..clear()
          ..addAll(edit.newLine.split('\n'));
      case 'noChange':
        break;
      case 'append':
        if (edit.newLine.trim().isEmpty) {
          throw const StateEditException('append 的 newLine 不能为空');
        }
        _appendLines(lines, edit.newLine);
      case 'set':
        final m = _findAnchor(section, lines, edit.before);
        lines.removeRange(m.start, m.end);
        lines.insertAll(m.start, edit.newLine.split('\n'));
      case 'insertAfter':
        final m = _findAnchor(section, lines, edit.before);
        lines.insertAll(m.end, edit.newLine.split('\n'));
      case 'delete':
        final m = _findAnchor(section, lines, edit.before);
        lines.removeRange(m.start, m.end);
      default:
        throw StateEditException(
          '未知 op：${edit.op}（可用 append / set / insertAfter / delete / '
          'noChange / reset）。',
        );
    }
  }

  /// 锚点查找：`before`（可含 `\n`，即连续多行）在 [lines] 中的**唯一**匹配。
  ///
  /// 匹配策略（对齐 DeepSeek Harness `edit` / `str_replace` 工具语义）：
  /// 1. 先按「整行逐字」匹配（仅行尾空白宽容）；
  /// 2. 精确无命中时回退「首尾 trim + 内部空白折叠」的宽松匹配（兼容抄录
  ///    时的空格差异）；
  /// 3. 匹配数 > 1 → 报错并列出命中行号（引导补充唯一上下文）；
  /// 4. 匹配数 = 0 → 报错并提示逐字复制（含当前行数）。
  _AnchorMatch _findAnchor(
    AgentStateSection section,
    List<String> lines,
    String before,
  ) {
    if (before.trim().isEmpty) {
      throw const StateEditException(
        'before 不能为空：请从上一条消息（上一轮快照）中逐字复制要修改的行。',
      );
    }
    final anchor = [for (final l in before.split('\n')) l.trimRight()];
    final exact = <int>[];
    final loose = <int>[];
    for (var i = 0; i <= lines.length - anchor.length; i++) {
      if (_linesMatchExact(lines, i, anchor)) {
        exact.add(i);
      } else if (_linesMatchLoose(lines, i, anchor)) {
        loose.add(i);
      }
    }
    // 精确优先：精确有命中时忽略宽松命中（宽松仅作兜底且同样要求唯一）。
    final hits = exact.isNotEmpty ? exact : loose;
    if (hits.isEmpty) {
      throw StateEditException(
        '${section.label}中未找到与 before 逐字匹配的（连续）行。'
        '请从上一条消息（上一轮快照）**逐字复制**要修改的行'
        '（注意列表前导符、标点与空格）；当前栏目共 '
        '${_addressableLineCount(lines)} 行。',
      );
    }
    if (hits.length > 1) {
      throw StateEditException(
        '${section.label}中 before 不唯一：匹配到第 '
        '${hits.map((i) => i + 1).join('、')} 行（当前 '
        '${_addressableLineCount(lines)} 行）。'
        '请补充唯一上下文（如包含角色名 / 标题行的连续多行）。',
      );
    }
    return (start: hits.single, end: hits.single + anchor.length);
  }

  /// 精确整行匹配（右侧 trim 宽容；`\r` 一并去除）。
  static bool _linesMatchExact(List<String> lines, int start, List<String> anchor) {
    for (var k = 0; k < anchor.length; k++) {
      if (lines[start + k].trimRight() != anchor[k]) return false;
    }
    return true;
  }

  /// 宽松匹配：首尾 trim + 内部空白折叠（锚点与目标行同时规范化）。
  static bool _linesMatchLoose(List<String> lines, int start, List<String> anchor) {
    for (var k = 0; k < anchor.length; k++) {
      if (_normalizeLine(lines[start + k]) != _normalizeLine(anchor[k])) {
        return false;
      }
    }
    return true;
  }

  static String _normalizeLine(String line) =>
      line.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// append 语义：移除结尾空行占位后追加（保证追加发生在真实末行之后）。
  static void _appendLines(List<String> lines, String newLine) {
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    lines.addAll(newLine.split('\n'));
  }

  static String _join(List<String> lines) => lines.join('\n');
}

/// 锚定定位失败（携带回传模型的错误消息）。
class StateEditException implements Exception {
  final String message;
  const StateEditException(this.message);
}

/// 合并后的快照（aiNarrative / recommendedAction 由调用方另行解析）。
class RoundSnapshot {
  final String worldState;
  final String characterState;
  final String memorySummary;
  final String currentTime;

  const RoundSnapshot({
    required this.worldState,
    required this.characterState,
    required this.memorySummary,
    required this.currentTime,
  });
}
