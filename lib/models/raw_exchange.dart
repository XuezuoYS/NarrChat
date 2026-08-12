/// 一次「请求体 → AI 返回」的 RAW 交换记录（RAW 时间线中的一对）。
///
/// [requestBody] 为实际发出的请求体 JSON（pretty 格式化文本）；
/// [thinking] / [search] / [content] 为从 AI 返回中解析出的三个块
///（思考 / 搜索 tool_calls / 正文），响应返回后回填；空串表示该块缺失。
class RawExchange {
  /// 请求原始 JSON（pretty 格式化文本）。
  final String requestBody;

  /// 思考块：`reasoning_content` 聚合文本（空 = 无）。
  String thinking;

  /// 搜索块：原始 `tool_calls` JSON 文本（空 = 无）。
  String search;

  /// 正文块：`content` 聚合文本（空 = 无）。
  String content;

  RawExchange({
    required this.requestBody,
    this.thinking = '',
    this.search = '',
    this.content = '',
  });
}
