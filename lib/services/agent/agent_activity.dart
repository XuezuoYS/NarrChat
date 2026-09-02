/// Agent 活动类型。
///
/// 独立文件承载：既被 [NarrAgentTool]（工具声明自身的活动类型）引用，
/// 也被 `AgentRunner` 与 UI 层引用，避免工具接口与执行器之间的环依赖。
enum AgentActivityType {
  /// 新一轮 LLM 调用开始（新一轮思考应新建思考块）。
  turn,

  /// 正在执行搜索工具（narrchat_webSearch）。
  searching,

  /// 正在执行打开网页工具（narrchat_webFetchPage）。
  fetching,

  /// 正在执行状态工具（narrchat_readState / narrchat_editSection 等）。
  tooling,
}

/// Agent 活动事件（回调给 UI 展示搜索 / 打开页面 / 状态修改等过程）。
class AgentActivity {
  final AgentActivityType type;

  /// 活动主体：搜索关键词、打开的链接或状态工具名。
  final String query;

  final int iteration;

  const AgentActivity({
    required this.type,
    required this.query,
    required this.iteration,
  });
}
