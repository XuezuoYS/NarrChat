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

  /// 快照块标签（与 [id] 同义，单独留出以便渲染格式将来调整时解耦）。
  String get tag => id;

  static AgentStateSection? parse(String? raw) {
    for (final s in AgentStateSection.values) {
      if (s.id == raw) return s;
    }
    return null;
  }
}

/// 单条锚定式行级编辑指令（编辑文件式，但**不用行号**）。
///
/// 定位的唯一依据是 [before]：当前状态快照（`narrchat_readState` 输出）中的
/// 某行（或连续多行）。应用侧按下述优先级匹配（见 `AgentStateWorkingCopy`
/// 的 `_findAnchor`）：整行逐字 → 归一化整行 → 归一化行内子串，并要求**唯一**
/// 命中。模型不需要（也不应该）计算行号。
class AgentLineEdit {
  /// op：
  /// - `append`：把 [newLine] 追加到栏目**末尾**（记忆条目等追加场景首选，
  ///   无需任何定位）；
  /// - `set`：以 [before] 锚定（唯一匹配）整段行后替换为 [newLine]；
  /// - `insertAfter`：以 [before] 锚定后在其后插入 [newLine]；
  /// - `delete`：以 [before] 锚定后删除该段行；
  /// - `noChange`：声明本轮无变化（[reason] 必填）；
  /// - `reset`：整栏目替换（仅限空栏目 / 首次填入 / 明确重排）。
  final String op;

  /// 锚点：必须与快照中某行（或连续多行，用 `\n` 连接）**逐字相同**
  /// （空白与全半角标点宽容；`set / insertAfter / delete` 必备）。
  final String before;

  /// 新内容：`append` / `insertAfter` 为新增行文本；`set` 为替换后文本；
  /// `reset` 为栏目新全文（均可含 `\n`）。
  final String newLine;

  /// `noChange` 的理由（一句话）：未变更必须**声明原因**，
  /// 不再允许用空 `noChange` 蒙过完整性检查。
  final String reason;

  const AgentLineEdit({
    required this.op,
    this.before = '',
    this.newLine = '',
    this.reason = '',
  });
}

/// 行级状态修改结果。
class StateLineResult {
  /// 是否应用成功。
  final bool applied;

  /// **UI 摘要**（工具卡片一行展示用，短）。
  final String message;

  /// **回传模型**的完整内容（含编辑后的栏目当前全文，供后续锚点逐字复制）。
  final String detail;

  const StateLineResult({
    required this.applied,
    required this.message,
    String? detail,
  }) : detail = detail ?? message;
}

/// 锚点匹配结果：命中的行区间（含）。
typedef _AnchorMatch = ({int start, int end});

/// 本轮 AGENT 生成的状态「工作副本」。
///
/// 以最新一轮快照（[lastRound]）为基座；所有 `narrchat_*` 状态工具只作用于
/// 本副本；本轮成功时由应用侧取 [mergedSnapshot] 落库，失败 / 取消时整体丢弃。
///
/// 【锚定式编辑】模型只提供**变更的行**（op=set/insertAfter/delete 以 `before`
/// 原文锚定 + 唯一匹配校验；op=append 追加到栏目末尾），未触及的行一字不动。
/// 匹配按「整行逐字 → 归一化整行 → 归一化行内子串」三级放宽（归一化 = 折叠
/// 空白 + 全半角标点统一 + 列表前导符统一），**仅用于比较**，存储仍保留原文
/// 字节。失败时回传该栏目当前全文，让下一帧的锚点必然命中。
///
/// 【结构性校验】记忆总结每轮必须**恰好一条**本轮（第 N 轮）条目；
/// `noChange` 必须附 `reason`（记忆总结不允许 noChange）。
class AgentStateWorkingCopy {
  AgentStateWorkingCopy({
    required this.roundIndex,
    Round? lastRound,
    List<String> categoryNames = const [],
  })  : worldState = lastRound?.worldState ?? '',
        characterState = lastRound?.characterState ?? '',
        memorySummary = lastRound?.memorySummary ?? '',
        currentTime = lastRound?.currentTime ?? '',
        baseWorldState = lastRound?.worldState ?? '',
        baseCharacterState = lastRound?.characterState ?? '',
        baseMemorySummary = lastRound?.memorySummary ?? '',
        baseCurrentTime = lastRound?.currentTime ?? '',
        categories = List.unmodifiable(categoryNames);

  final int roundIndex;
  final List<String> categories;

  String worldState;
  String characterState;
  String memorySummary;
  String currentTime;

  /// 上一轮的原始快照（懒修改覆盖度检查的比对基线，不随编辑变化）。
  final String baseWorldState;
  final String baseCharacterState;
  final String baseMemorySummary;
  final String baseCurrentTime;

  /// 本轮被「触及」的栏目（编辑或 noChange 声明均计入；完整性检查用）。
  final Set<AgentStateSection> touchedSections = {};

  /// 以 `op=noChange` 声明无变化的栏目 → 理由（空理由不计入 touched）。
  final Map<AgentStateSection, String> declaredUnchanged = {};

  /// 本轮编辑失败的栏目（锚点未命中 / 不唯一 / 校验不过）；
  /// 修复反馈只重发这些栏目的当前全文。
  final Set<AgentStateSection> failedSections = {};

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

  String sectionBaseText(AgentStateSection section) => switch (section) {
        AgentStateSection.worldState => baseWorldState,
        AgentStateSection.characterState => baseCharacterState,
        AgentStateSection.memorySummary => baseMemorySummary,
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

  // ---------------------------------------------------------------------------
  // 快照渲染（readState 工具结果；时间属于正文，快照不含时间块）
  // ---------------------------------------------------------------------------

  /// 渲染当前状态快照（readState 工具的返回；也是模型复制 `before` 锚点的
  /// 唯一来源）。**不含时间**——时间在正文 `## 当前时间` 小节里，
  /// 上一轮时间经用户消息的【上轮时间】前置提供。
  String renderSnapshot() => _renderSnapshot(
        roundIndex: roundIndex,
        sections: {
          for (final s in AgentStateSection.values) s: sectionText(s),
        },
      );

  /// 渲染某轮数据库快照为同一格式（与工作副本渲染同源）。
  static String renderSnapshotOf({required int roundIndex, Round? lastRound}) =>
      _renderSnapshot(
        roundIndex: roundIndex,
        sections: {
          AgentStateSection.worldState: lastRound?.worldState ?? '',
          AgentStateSection.characterState: lastRound?.characterState ?? '',
          AgentStateSection.memorySummary: lastRound?.memorySummary ?? '',
        },
      );

  static String _renderSnapshot({
    required int roundIndex,
    required Map<AgentStateSection, String> sections,
  }) {
    final buf = StringBuffer();
    buf.writeln('<<<NARRCHAT_STATE round=$roundIndex>>>');
    buf.writeln('[EN] This is the app-side state truth, just read back. Copy '
        '`before` anchors VERBATIM from it; NEVER echo this block in your '
        'reply (it is input, not an output format).');
    buf.writeln('【中】这是应用侧状态真值（刚读取回来的）。before 锚点必须从本块'
        '逐字复制；**禁止**把本块重复输出到回复里（它是输入，不是输出格式）。');
    void block(String tag, String text) {
      if (text.trim().isEmpty) {
        buf.writeln('<$tag empty="true"></$tag>');
        return;
      }
      buf.writeln('<$tag>');
      buf.writeln(text.trim());
      buf.writeln('</$tag>');
    }

    for (final s in AgentStateSection.values) {
      block(s.tag, sections[s] ?? '');
    }
    buf.write('<<<END_NARRCHAT_STATE>>>');
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // 编辑应用
  // ---------------------------------------------------------------------------

  /// 应用一组锚定式编辑（按数组顺序逐条应用；每条锚点在**应用时刻**的
  /// 当前文本中唯一匹配，先插入的内容可被后续编辑引用；事务化：
  /// 任一失败则整体不提交，并把该栏目登记为失败栏目）。
  StateLineResult applyEdits(
    AgentStateSection section,
    List<AgentLineEdit> edits,
  ) {
    if (edits.isEmpty) {
      return _fail(section, '${section.label}：edits 不能为空。');
    }
    if (edits.every((e) => e.op == 'noChange')) {
      if (section == AgentStateSection.memorySummary) {
        return _fail(
          section,
          '${section.label}每轮必须补充本轮条目，不能声明 noChange；'
          '请用 op=append 追加 `- 第N轮｜日期：<当前时间>｜<一句话概括>`'
          '（N = $roundIndex）。',
        );
      }
      final reason = edits.map((e) => e.reason.trim()).firstWhere(
            (r) => r.isNotEmpty,
            orElse: () => '',
          );
      if (reason.isEmpty) {
        return _fail(
          section,
          '${section.label}：op=noChange 必须给出 reason（一句话说明为何本轮'
          '确实无变化）。若本轮剧情涉及该栏目内容变化，请改用 op=set / '
          'op=append 更新对应行。',
        );
      }
      touchedSections.add(section);
      declaredUnchanged[section] = reason;
      return StateLineResult(
        applied: true,
        message: '${section.label}：本轮无变化（${_clip(reason, 40)}）',
        detail: '${section.label}：已记录本轮无变化（reason=$reason）。'
            '如后续帧需要修改该栏目，锚点仍从状态快照块复制。',
      );
    }
    final lines = <String>[...sectionText(section).split('\n')];
    try {
      for (final edit in edits) {
        _applyOne(section, lines, edit);
      }
    } on StateEditException catch (e) {
      return _fail(section, '${section.label}：${e.message}');
    }
    final result = _join(lines);
    if (section == AgentStateSection.memorySummary) {
      final count = memoryEntryCount(result, roundIndex);
      if (count == 0) {
        return _fail(
          section,
          '${section.label}变更后必须包含本轮（第 $roundIndex 轮）条目，'
          '格式：`- 第N轮｜日期：<当前时间>｜<一句话概括>`；'
          '追加条目请用 op=append（自动追加到栏目末尾）。',
        );
      }
      if (count > 1) {
        return _fail(
          section,
          '${section.label}中本轮（第 $roundIndex 轮）条目出现 $count 条：'
          '每轮**恰好一条**。请删除多余条目（op=delete 锚定重复行），'
          '或用 op=set 把它们合并为一行；不要再次 op=append。',
        );
      }
    }
    _setSection(section, result);
    touchedSections.add(section);
    declaredUnchanged.remove(section);
    failedSections.remove(section);
    return StateLineResult(
      applied: true,
      message: '${section.label}已更新（${edits.length} 条编辑）',
      // 回传该栏目当前全文：同轮后续帧的锚点必须打在**已改过**的文本上，
      // 否则会出现「锚点未命中 → 修复 → reset 兜底」的无谓循环。
      detail: '${section.label}已更新（${edits.length} 条编辑）。'
          '当前全文（后续锚点请从这里逐字复制）：\n'
          '<${section.tag}>\n${_clipForModel(result)}\n</${section.tag}>',
    );
  }

  StateLineResult _fail(AgentStateSection section, String message) {
    failedSections.add(section);
    // 失败时回传该栏目**当前全文**：把「重新逐字复制锚点」的成本降到零
    // （否则模型要跨几千 token 的正文去回忆原文，必然再错一次）。
    final current = sectionText(section);
    return StateLineResult(
      applied: false,
      message: message,
      detail: '$message\n${section.label}当前全文（请从这里逐字复制 before 锚点；'
          '仍无法定位时改用 op=reset 整栏目重写）：\n'
          '<${section.tag}>\n${_clipForModel(current)}\n</${section.tag}>',
    );
  }

  /// 回传模型时的长度上限保护（异常巨大的栏目不该整块灌进上下文）。
  static String _clipForModel(String text, {int maxLines = 400}) {
    if (text.trim().isEmpty) return '（空）';
    final lines = text.split('\n');
    if (lines.length <= maxLines) return text;
    return '${lines.take(maxLines).join('\n')}\n…（共 ${lines.length} 行，已截断；'
        '请改用 op=append 或更小的锚点粒度）';
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  /// 记忆总结中第 [roundIndex] 轮条目的数量（每轮恰好一条的校验依据）。
  static int memoryEntryCount(String memory, int roundIndex) {
    final re = RegExp(r'第\s*(\d+)\s*轮');
    var count = 0;
    for (final line in memory.split('\n')) {
      if (line.trim().isEmpty) continue;
      for (final m in re.allMatches(line)) {
        if (int.tryParse(m.group(1)!) == roundIndex) {
          count++;
          break;
        }
      }
    }
    return count;
  }

  // ---------------------------------------------------------------------------
  // 内部：单条锚定编辑（字节级保留）
  // ---------------------------------------------------------------------------

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
  /// 三级放宽（都要求唯一命中）：
  /// 1. 整行逐字（仅行尾空白宽容）；
  /// 2. 归一化整行（折叠空白 + 全半角标点统一 + 列表前导符统一）；
  /// 3. 归一化**行内子串**（单行锚点命中某行的一部分 → 视为命中该行）。
  /// 命中层级越靠后越宽松，但一律拒绝多命中（歧义时报出命中行原文）。
  _AnchorMatch _findAnchor(
    AgentStateSection section,
    List<String> lines,
    String before,
  ) {
    if (before.trim().isEmpty) {
      throw const StateEditException(
        'before 不能为空：请从状态快照块（narrchat_readState 输出）中逐字复制要修改的行。',
      );
    }
    final anchor = [for (final l in before.split('\n')) l.trimRight()];
    final exact = <int>[];
    final loose = <int>[];
    for (var i = 0; i <= lines.length - anchor.length; i++) {
      if (_linesMatch(lines, i, anchor, _rawLine)) {
        exact.add(i);
      } else if (_linesMatch(lines, i, anchor, _normalizeLine)) {
        loose.add(i);
      }
    }
    final wholeLine = exact.isNotEmpty ? exact : loose;
    if (wholeLine.isNotEmpty) {
      if (wholeLine.length > 1) throw _ambiguous(section, lines, wholeLine);
      return (start: wholeLine.single, end: wholeLine.single + anchor.length);
    }
    // 行内子串（仅单行锚点）：模型常只抄半句，允许命中其所在整行。
    if (anchor.length == 1) {
      final needle = _normalizeLine(anchor.single);
      if (needle.isNotEmpty) {
        final hits = <int>[];
        for (var i = 0; i < lines.length; i++) {
          if (_normalizeLine(lines[i]).contains(needle)) hits.add(i);
        }
        if (hits.length == 1) {
          return (start: hits.single, end: hits.single + 1);
        }
        if (hits.length > 1) throw _ambiguous(section, lines, hits);
      }
    }
    throw StateEditException(
      '未找到与 before 匹配的行（已尝试逐字 / 空白与全半角归一 / 行内子串三级匹配）。'
      '请从状态快照块**逐字复制**要修改的行（注意列表前导符与标点）；'
      '当前栏目共 ${_addressableLineCount(lines)} 行。',
    );
  }

  StateEditException _ambiguous(
    AgentStateSection section,
    List<String> lines,
    List<int> hits,
  ) {
    final detail = hits
        .map((i) => '  第 ${i + 1} 行：${lines[i].trim()}')
        .join('\n');
    return StateEditException(
      'before 不唯一：匹配到第 ${hits.map((i) => i + 1).join('、')} 行'
      '（当前 ${_addressableLineCount(lines)} 行）。\n$detail\n'
      '请改用其中某一行的**完整原文**作为 before，或把连续多行一起写入 before'
      '（用 \\n 连接）以消除歧义。',
    );
  }

  /// 可寻址行数：忽略「结尾换行」产生的尾部空行。
  static int _addressableLineCount(List<String> lines) {
    var count = lines.length;
    if (count > 0 && lines.last.isEmpty) count--;
    return count;
  }

  static bool _linesMatch(
    List<String> lines,
    int start,
    List<String> anchor,
    String Function(String) map,
  ) {
    for (var k = 0; k < anchor.length; k++) {
      if (map(lines[start + k]) != map(anchor[k])) return false;
    }
    return true;
  }

  static String _rawLine(String line) => line.trimRight().replaceAll('\r', '');

  /// 归一化：折叠空白 + 全半角标点统一 + 列表前导符统一（仅用于比较）。
  static String _normalizeLine(String line) {
    final s = _foldPunctuation(line.trim().replaceAll(RegExp(r'\s+'), ' '));
    if (s.length > 1 && (s.startsWith('- ') || s.startsWith('* ') || s.startsWith('+ '))) {
      return '- ${s.substring(2)}';
    }
    return s;
  }

  static const Map<String, String> _punctFolds = {
    '：': ':', '，': ',', '；': ';', '！': '!', '？': '?', '（': '(', '）': ')',
    '【': '[', '】': ']', '“': '"', '”': '"', '‘': "'", '’': "'",
    '—': '-', '–': '-', '－': '-', '　': ' ', '、': ',', '｜': '|',
  };

  static String _foldPunctuation(String s) {
    var out = s;
    _punctFolds.forEach((from, to) {
      out = out.replaceAll(from, to);
    });
    return out;
  }

  /// append 语义：移除结尾空行占位后追加（保证追加发生在真实末行之后）。
  static void _appendLines(List<String> lines, String newLine) {
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    lines.addAll(newLine.split('\n'));
  }

  static String _join(List<String> lines) => lines.join('\n');
}

/// `## 角色名` 小节（只为**校验覆盖度**而读，不参与编辑寻址）。
class CharacterBlock {
  final String name;

  /// 小节全文（含标题行，直到下一个 `##` 或栏目结束）。
  final String text;

  const CharacterBlock({required this.name, required this.text});
}

/// 把角色状态栏目按 `## 角色名` 切成小节（`#` 类别标题不参与切分）。
List<CharacterBlock> splitCharacterBlocks(String characterState) {
  final lines = characterState.split('\n');
  final result = <CharacterBlock>[];
  var start = -1;
  String? name;
  void flush(int end) {
    if (name == null) return;
    result.add(
      CharacterBlock(
        name: name,
        text: lines.sublist(start, end).join('\n').trim(),
      ),
    );
  }

  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trimRight();
    final m = RegExp(r'^##\s+(\S.*?)\s*$').firstMatch(t);
    if (m != null) {
      flush(i);
      name = m.group(1)!.trim();
      start = i;
    }
  }
  flush(lines.length);
  return result;
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
