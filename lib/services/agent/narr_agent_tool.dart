import 'agent_activity.dart';

/// Agent 工具执行结果。
class AgentToolResult {
  /// 是否成功（false 表示失败/无结果，错误信息仍写入 [content] 回传模型继续执行）。
  final bool success;

  /// **回传模型**的完整内容（状态工具含编辑后的栏目全文，保证下一帧锚点可抄）。
  final String content;

  /// **UI 一行摘要**（空 = 回退 [content]）。工具卡片只展示这个，避免把
  /// 整份状态全文灌进事件框。
  final String summary;

  /// 页面拒绝访问（HTTP 4xx/5xx）：非工具故障，不计入工具连续失败次数，
  /// UI 显示黄色 ✕。
  final bool refused;

  const AgentToolResult({
    required this.success,
    required this.content,
    this.summary = '',
    this.refused = false,
  });
}

/// Agent 工具接口：模型通过 `tool_calls` 调用。
///
/// 新增工具只需实现本接口并注册进 `AgentRunner`。
abstract class NarrAgentTool {
  /// 工具名（模型调用时使用）。
  String get name;

  /// 工具说明（指导模型何时调用）。
  String get description;

  /// 参数 JSON Schema（`{"type":"object","properties":{...},"required":[...]}`）。
  Map<String, dynamic> get parameters;

  /// 执行工具并返回文本结果；失败时返回 `success:false` 的错误信息，
  /// 由 Agent 循环回传模型继续执行。
  Future<AgentToolResult> run(Map<String, dynamic> arguments);

  /// 工具的活动类型（决定 UI 展示为搜索框 / 打开页框 / 状态修改框）。
  ///
  /// 默认 [AgentActivityType.searching]（兼容既有测试假工具）；
  /// 打开网页工具应为 [AgentActivityType.fetching]，
  /// 状态工具应为 [AgentActivityType.tooling]。
  AgentActivityType get activityType => AgentActivityType.searching;
}
