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
/// - 未匹配到任何已知标题的杂散内容将被丢弃。
class AiResponseParser {
  AiResponseParser._();

  static const List<String> _sections = [
    '剧情演绎',
    '世界状态',
    '角色状态',
    '记忆总结',
    '当前时间',
    '推荐行动',
  ];

  static const Map<String, String> _sectionToField = {
    '剧情演绎': 'aiNarrative',
    '世界状态': 'worldState',
    '角色状态': 'characterState',
    '记忆总结': 'memorySummary',
    '当前时间': 'currentTime',
    '推荐行动': 'recommendedAction',
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

    for (final line in raw.split('\n')) {
      final heading = _tryParseHeading(line);
      if (heading != null) {
        final field = _matchSection(heading);
        if (field != null) {
          currentField = field;
          continue;
        }
      }
      if (currentField != null) {
        buffers[currentField]!.writeln(line);
      }
    }

    String fieldValue(String key) => buffers[key]!.toString().trim();

    return ParsedAiResponse(
      aiNarrative: fieldValue('aiNarrative'),
      worldState: fieldValue('worldState'),
      characterState: fieldValue('characterState'),
      memorySummary: fieldValue('memorySummary'),
      currentTime: fieldValue('currentTime'),
      recommendedAction: fieldValue('recommendedAction'),
    );
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
