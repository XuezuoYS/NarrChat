/// AI 回复解析结果（对应 6 个二级标题区块）。
class ParsedAiResponse {
  const ParsedAiResponse({
    this.aiNarrative = '',
    this.worldState = '',
    this.characterState = '',
    this.memorySummary = '',
    this.currentTime = '',
    this.recommendedAction = '',
  });

  final String aiNarrative;
  final String worldState;
  final String characterState;
  final String memorySummary;
  final String currentTime;
  final String recommendedAction;

  bool get isEmpty =>
      aiNarrative.isEmpty &&
      worldState.isEmpty &&
      characterState.isEmpty &&
      memorySummary.isEmpty &&
      currentTime.isEmpty &&
      recommendedAction.isEmpty;
}

/// 按二级标题（##）解析 AI 回复的容错解析器（核心逻辑）。
///
/// AI 必须严格返回以下 Markdown 结构，App 按 `##` 标题提取对应区块：
/// ```
/// ## 剧情演绎   -> ai_narrative
/// ## 世界状态   -> world_state
/// ## 角色状态   -> character_state（纯文本块，绝不解析内部结构）
/// ## 记忆总结   -> memory_summary
/// ## 当前时间   -> current_time
/// ## 推荐行动   -> recommended_action
/// ```
///
/// 容错策略：
/// - 某个标题缺失时，对应字段存为空字符串，绝不崩溃；
/// - 标题前多余空白、`#` 与标题之间缺少空格（如 `##剧情演绎`）、
///   标题层级不是严格的 `##`（如 `#` 或 `###`）均可容忍；
/// - 首个标题之后未匹配的杂散内容将被丢弃；首个标题之前的无标题内容
///   会被保留，仅在剧情演绎缺失时作为正文兜底。
///
/// 剧情演绎缺失时的正文兜底（应对 AI 幻觉放弃输出 `## 剧情演绎`）：
/// 1. 存在 `正文` 标题区块时，将其内容视为正文（优先级次之）；
/// 2. 否则若响应开头存在「无标题直接开始生成」的内容，将其视为正文。
///
/// 反解析（[serialize]）：与 [parse] 互逆，将 [ParsedAiResponse] 还原为
/// 「原生返回」格式的 Markdown 文本（6 个 `##` 区块齐全）。
class AiResponseParser {
  AiResponseParser._();

  static const List<String> _sections = [
    '剧情演绎',
    '世界状态',
    '角色状态',
    '记忆总结',
    '当前时间',
    '推荐行动',
    '正文',
  ];

  /// 「正文」标题区块的内部标记字段名（不属于 [ParsedAiResponse] 的公开字段）。
  static const String _bodyField = '__body__';

  static const Map<String, String> _sectionToField = {
    '剧情演绎': 'aiNarrative',
    '世界状态': 'worldState',
    '角色状态': 'characterState',
    '记忆总结': 'memorySummary',
    '当前时间': 'currentTime',
    '推荐行动': 'recommendedAction',
    // 「正文」为内部兜底区块：仅在剧情演绎缺失时用作正文（见 [parse]）。
    '正文': _bodyField,
  };

  /// 字段 → 区块标题（反解析用），由 [_sectionToField] 派生，保持单一映射来源；
  /// 内部兜底区块（[_bodyField]）不属于 [ParsedAiResponse]，不参与反解析。
  static final Map<String, String> _fieldToSection = {
    for (final e in _sectionToField.entries)
      if (e.value != _bodyField) e.value: e.key,
  };

  static ParsedAiResponse parse(String raw) {
    final buffers = <String, StringBuffer>{
      for (final field in _sectionToField.values) field: StringBuffer(),
    };

    if (raw.trim().isEmpty) {
      return const ParsedAiResponse();
    }

    // 当前正在写入的字段；未匹配到任何区块前为 null。
    String? currentField;
    // 响应开头、首个标题之前的无标题内容（可能为「无标题直接开始生成的正文」）。
    final preamble = StringBuffer();
    // 是否已遇到第一个标题：此后内容不再计入 [preamble]。
    var encounteredHeading = false;

    for (final line in raw.split('\n')) {
      final heading = _tryParseHeading(line);
      if (heading != null) {
        encounteredHeading = true;
        final field = _matchSection(heading);
        if (field != null) {
          currentField = field;
          continue;
        }
        // 未知标题：不重置当前区块（角色状态内部结构需原样保留），
        // 标题行随之下沉写入当前区块；若尚未进入任何区块则继续丢弃。
      }
      if (currentField != null) {
        buffers[currentField]!.writeln(line);
      } else if (!encounteredHeading) {
        preamble.writeln(line);
      }
    }

    String fieldValue(String key) => buffers[key]!.toString().trim();

    // 剧情演绎正文兜底：剧情演绎 → 正文区块 → 无标题开头内容。
    var aiNarrative = fieldValue('aiNarrative');
    if (aiNarrative.isEmpty) {
      aiNarrative = fieldValue(_bodyField);
    }
    if (aiNarrative.isEmpty) {
      aiNarrative = preamble.toString().trim();
    }

    return ParsedAiResponse(
      aiNarrative: aiNarrative,
      worldState: fieldValue('worldState'),
      characterState: fieldValue('characterState'),
      memorySummary: fieldValue('memorySummary'),
      currentTime: fieldValue('currentTime'),
      recommendedAction: fieldValue('recommendedAction'),
    );
  }

  /// 反解析：将 [ParsedAiResponse] 还原为「原生返回」格式的 Markdown 文本。
  ///
  /// 区块顺序为 AI 被要求的输出顺序（与 PromptBuilder.sectionOrder 一致）：
  /// 剧情演绎 → 推荐行动 → 当前时间 → 世界状态 → 角色状态 → 记忆总结。
  /// 空字段也输出对应的空 `## 标题` 区块，保持 6 区块齐全形态；
  /// 字段值原样写入（[parse] 的产物字段均已 trim），因此
  /// `parse(serialize(x))` 可还原出相同的 [ParsedAiResponse]（round-trip）。
  static String serialize(ParsedAiResponse parsed) {
    final blocks = <(String, String)>[
      ('aiNarrative', parsed.aiNarrative),
      ('recommendedAction', parsed.recommendedAction),
      ('currentTime', parsed.currentTime),
      ('worldState', parsed.worldState),
      ('characterState', parsed.characterState),
      ('memorySummary', parsed.memorySummary),
    ];
    final buf = StringBuffer();
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) {
        buf.write('\n\n');
      }
      final (field, value) = blocks[i];
      buf.write('## ${_fieldToSection[field]!}');
      if (value.isNotEmpty) {
        buf.write('\n$value');
      }
    }
    return buf.toString();
  }

  /// 尝试把一行解析为 Markdown 标题，返回标题文本；非标题行返回 null。
  static String? _tryParseHeading(String line) {
    final trimmed = line.trimLeft();
    final match = RegExp(r'^(#{1,6})\s*(.+)$').firstMatch(trimmed);
    if (match == null) return null;
    return match.group(2)!.trim();
  }

  /// 将标题文本与已知区块名匹配（忽略所有空白，提高容错性）。
  static String? _matchSection(String heading) {
    final normalized = heading.replaceAll(RegExp(r'\s+'), '');
    for (final section in _sections) {
      if (normalized == section) {
        return _sectionToField[section];
      }
    }
    return null;
  }
}
