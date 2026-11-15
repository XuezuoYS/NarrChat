/// Agent RAW 的「步」：第一步（调研 + 正文）或第二步（状态维护）。
enum RawAgentStep {
  none,
  first,
  maintenance;

  /// RAW 分组标题。
  String get label => switch (this) {
        RawAgentStep.none => '',
        RawAgentStep.first => '第一步 · 调研与正文',
        RawAgentStep.maintenance => '第二步 · 状态维护',
      };
}

/// Agent RAW 的「回合」类型（回合是最基础单元）。
enum RawTurnKind {
  none,
  research,
  story,
  maintenance;

  /// RAW 回合标题。
  String get label => switch (this) {
        RawTurnKind.none => '',
        RawTurnKind.research => '调研回合',
        RawTurnKind.story => '正文回合',
        RawTurnKind.maintenance => '维护回合',
      };
}

/// 一次「请求体 → AI 返回」的 RAW 交换记录（RAW 时间线中的一对）。
///
/// [requestBody] 为实际发出的请求体 JSON（pretty 格式化文本）；
/// [thinking] / [toolCalls] / [content] 为从 AI 返回中解析出的三个块
///（思考 / 工具调用 tool_calls / 正文），响应返回后回填；空串表示该块缺失。
/// [error] 为该次请求**失败**时的原因（HTTP / 协议报错原文）：非空即表示这次
/// 交换没有返回（例如协议兼容降级前的探测帧被服务商拒绝，随后同一帧会重发）。
///
/// Agent 模式额外携带轨迹元数据，让 RAW 能按「轮 → 步 → 回合」分组：
/// [roundIndex] = 本轮轮号；[step] = 第一步 / 第二步；[turnKind] + [turnIndex]
/// = 该步内的第几个回合（调研 / 正文 / 维护）。Chat 模式保持 [RawAgentStep.none]，
/// 不显示额外分组头。
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

  /// Agent 模式：本轮轮号（Chat / 未知时 null）。
  final int? roundIndex;

  /// Agent 模式：所属步（Chat 为 [RawAgentStep.none]）。
  final RawAgentStep step;

  /// Agent 模式：回合类型。
  final RawTurnKind turnKind;

  /// Agent 模式：该步内的第几回合（1-based；Chat / 未知时 null）。
  final int? turnIndex;

  RawExchange({
    required this.requestBody,
    this.thinking = '',
    this.toolCalls = '',
    this.content = '',
    this.error = '',
    this.roundIndex,
    this.step = RawAgentStep.none,
    this.turnKind = RawTurnKind.none,
    this.turnIndex,
  });

  /// 是否带 Agent 轨迹元数据（决定 RAW 是否显示轮 / 步 / 回合头）。
  bool get isAgent => step != RawAgentStep.none;
}
