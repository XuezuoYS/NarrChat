/// 一次「请求体 → AI 返回」的 RAW 交换记录（RAW 时间线中的一对）。
///
/// [requestBody] 为实际发出的请求体 JSON（pretty 格式化文本）；
/// [thinking] / [toolCalls] / [content] 为从 AI 返回中解析出的三个块
///（思考 / 工具调用 tool_calls / 正文），响应返回后回填；空串表示该块缺失。
/// [error] 为该次请求**失败**时的原因（HTTP / 协议报错原文）：非空即表示这次
/// 交换没有返回（例如协议兼容降级前的探测帧被服务商拒绝，随后同一帧会重发）。
///
/// 工具调用块对 Chat 与 Response 协议等价：均为 `tool_calls` JSON 文本
///（含状态工具 `narrchat_*`），RAW 对话框统一以「工具调用块」展示。
class RawExchange {
  /// 请求原始 JSON（pretty 格式化文本）。
  final String requestBody;

  /// 思考块：`reasoning_content` 聚合文本（空 = 无）。
  String thinking;

  /// 工具调用块：原始 `tool_calls` JSON 文本（空 = 无）。
  String toolCalls;

  /// 正文块：`content` 聚合文本（空 = 无）。
  String content;

  /// 失败原因（空 = 该次请求正常返回）；用于 RAW 展示「为什么这一次没有返回」。
  String error;

  RawExchange({
    required this.requestBody,
    this.thinking = '',
    this.toolCalls = '',
    this.content = '',
    this.error = '',
  });
}
