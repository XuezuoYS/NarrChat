import 'package:flutter/foundation.dart';

import '../services/html_search_service.dart';

/// Agent 过程事件类型。
enum AgentEventType {
  /// 一轮思考（模型推理内容）。
  thinking,

  /// 一次联网搜索。
  search,
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

  /// 事件完成（思考结束 / 搜索完成）。
  final bool done;

  const AgentEvent({
    required this.type,
    this.content = '',
    this.searching = false,
    this.results = const [],
    this.done = false,
  });

  AgentEvent copyWith({
    String? content,
    bool? searching,
    List<SearchResult>? results,
    bool? done,
  }) {
    return AgentEvent(
      type: type,
      content: content ?? this.content,
      searching: searching ?? this.searching,
      results: results ?? this.results,
      done: done ?? this.done,
    );
  }
}
