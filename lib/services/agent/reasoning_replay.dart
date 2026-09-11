/// 思考（reasoning）**回传精简**（纯函数）。
///
/// 服务商要求带 `tools` 的每个 `function_call` 前都有一块非空思考，而 Agent
/// 每帧全量重发会话，整段回传会让输入随帧数线性膨胀，故提供精简选项：
///
/// - 按**段落**切分，丢弃纯空白行（`\n\n` 只是格式占位）；
/// - 只有 1 段 → 原样返回；2 段及以上 → 取**首段 + 末段**。
library;

/// 按段落切分并丢弃纯空白行（各段去掉首尾空白）。
List<String> splitReasoningSegments(String text) => [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];

/// 精简一段思考文本：单段原样返回；多段取首段 + 末段。
String reduceReasoningText(String text) {
  final segments = splitReasoningSegments(text);
  if (segments.length <= 1) return segments.isEmpty ? '' : segments.first;
  if (segments.first == segments.last) return segments.first;
  return '${segments.first}\n\n${segments.last}';
}

/// 回传用的思考文本：[reduce] 为 false 时逐字节返回原文（默认，与服务商
/// "完整回传思考"的要求一致）；空文本一律返回空串。
String reasoningTextForReplay(String text, {required bool reduce}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  return reduce ? reduceReasoningText(trimmed) : trimmed;
}
