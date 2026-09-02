import 'package:flutter/foundation.dart';

import '../services/html_search_service.dart';

/// Agent 过程事件类型。
enum AgentEventType {
  /// 一轮思考（模型推理内容）。
  thinking,

  /// 一次联网搜索。
  search,

  /// 一次打开网页（narrchat_webFetchPage）。
  fetch,

  /// 一次状态工具调用（narrchat_setLine / narrchat_advanceTime 等）。
  tool,
}

/// Agent 过程事件。
///
/// 按真实时间顺序**交错**排列（思考 → 搜索 → 思考 → 搜索…），
/// 而非「全部思考在前、全部搜索在后」。
@immutable
class AgentEvent {
  final AgentEventType type;

  /// 思考内容 或 搜索关键词。
  final String content;

  /// 搜索：是否进行中。
  final bool searching;

  /// 搜索：结果列表。
  final List<SearchResult> results;

  /// 抓取页面的跳转链（HTTP 重定向 / 应用级回退；仅 fetch 事件使用）。
  final List<FetchHop> hops;

  /// 状态工具名（仅 tool 事件使用）。
  final String toolName;

  /// 工具调用 id（流式预览事件与执行结果事件的匹配键）。
  final String callId;

  /// 状态工具结果说明（应用 / 校验拒绝原因；仅 tool 事件使用）。
  final String toolDetail;

  /// 事件完成（思考结束 / 搜索完成）。
  final bool done;

  /// 搜索失败 / 无结果（UI 显示 ✕，不报错截断）。
  final bool failed;

  /// 页面拒绝访问（HTTP 4xx/5xx）：非工具故障，UI 显示黄色 ✕，
  /// 不计入工具连续失败次数。
  final bool refused;

  const AgentEvent({
    required this.type,
    this.content = '',
    this.searching = false,
    this.results = const [],
    this.hops = const [],
    this.toolName = '',
    this.callId = '',
    this.toolDetail = '',
    this.done = false,
    this.failed = false,
    this.refused = false,
  });

  AgentEvent copyWith({
    String? content,
    bool? searching,
    List<SearchResult>? results,
    List<FetchHop>? hops,
    String? toolName,
    String? callId,
    String? toolDetail,
    bool? done,
    bool? failed,
    bool? refused,
  }) {
    return AgentEvent(
      type: type,
      content: content ?? this.content,
      searching: searching ?? this.searching,
      results: results ?? this.results,
      hops: hops ?? this.hops,
      toolName: toolName ?? this.toolName,
      callId: callId ?? this.callId,
      toolDetail: toolDetail ?? this.toolDetail,
      done: done ?? this.done,
      failed: failed ?? this.failed,
      refused: refused ?? this.refused,
    );
  }
}
