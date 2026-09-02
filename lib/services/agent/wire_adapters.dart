import 'dart:convert';

import 'narr_agent_tool.dart';

/// 协议线路适配（纯函数集合）。
///
/// AGENT 两阶段执行器（`AgentRoundRunner`）内部以「Responses 形状」的平铺
/// items 累积会话（`function_call` / `function_call_output` / 普通角色消息），
/// 线路协议（Chat Completions / Responses）在**组装请求体时**再转换为对应
/// 形态——执行器因此与线路协议完全解耦：
///
/// - Chat 线路：[chatItemsFromAgentItems] 把平铺 items 合并为合法的 Chat
///   messages（assistant 携带 `tool_calls` + `role: tool` 回传）；
/// - Responses 线路：[responsesItemsFromChatMessages] 把 Messages 形状
///   （含 `tool_calls`）展开为 Responses input items（`function_call` /
///   `function_call_output` + `input_image` 视觉块）。
///
/// 两个方向均为纯函数，便于单测；协议选择由调用方（`RoundProvider`）决定。

/// 把「Responses 形状」的平铺 items 转换为 Chat messages。
///
/// 转换规则（与 OpenAI Chat Completions 消息约束对齐）：
/// - 普通角色消息（无 `type` 键，如 `{role, content}`）原样保留；
/// - `function_call` 条目**并入**其前一条 `assistant` 消息的 `tool_calls`
///   （参数 arguments 已是 JSON 字符串，保持原样）；
/// - `function_call_output` 条目转换为 `{role: 'tool', tool_call_id, content}`。
///
/// 若 `function_call` 前没有 assistant 消息（如首帧即纯工具调用），
/// 自动补一条 `content: null` 的 assistant 消息承载 `tool_calls`。
List<Map<String, dynamic>> chatItemsFromAgentItems(
  List<Map<String, dynamic>> items,
) {
  final out = <Map<String, dynamic>>[];
  for (final item in items) {
    if (item['type'] == 'function_call') {
      final Map<String, dynamic> assistant;
      if (out.isNotEmpty && out.last['role'] == 'assistant') {
        assistant = out.last;
      } else {
        assistant = {'role': 'assistant', 'content': null, 'tool_calls': []};
        out.add(assistant);
      }
      // 复用已有 tool_calls（若有）追加，避免覆盖同帧其它工具调用。
      final toolCalls = <dynamic>[
        ...((assistant['tool_calls'] as List<dynamic>?) ?? const []),
      ];
      assistant['tool_calls'] = toolCalls;
      toolCalls.add({
        'id': item['call_id'] ?? '',
        'type': 'function',
        'function': {
          'name': item['name'] ?? '',
          'arguments': item['arguments'] ?? '{}',
        },
      });
      continue;
    }
    if (item['type'] == 'function_call_output') {
      out.add({
        'role': 'tool',
        'tool_call_id': item['call_id'] ?? '',
        'content': item['output'] ?? '',
      });
      continue;
    }
    out.add(Map<String, dynamic>.from(item));
  }
  return out;
}

/// 把 Chat messages 转换为 Responses input items（不含 system 消息）。
///
/// 转换规则：
/// - 普通 user / assistant 消息 → `{role, content}`（视觉 parts 同步转换，
///   `image_url` → `input_image`、`text` → `input_text`）；
/// - assistant 携带 `tool_calls` → 先展开为普通 assistant 消息 item，
///   再追加对应的 `function_call` items（`arguments` 统一 JSON 字符串）；
/// - `role: tool` 消息 → `function_call_output` item。
List<Map<String, dynamic>> responsesItemsFromChatMessages(
  List<Map<String, dynamic>> messages,
) {
  final items = <Map<String, dynamic>>[];
  for (final m in messages) {
    if (m['role'] == 'tool') {
      items.add({
        'type': 'function_call_output',
        'call_id': m['tool_call_id'] ?? '',
        'output': m['content'] ?? '',
      });
      continue;
    }
    items.add({
      'role': m['role'],
      'content': _responsesContent(m['content']),
    });
    final toolCalls = m['tool_calls'];
    if (toolCalls is List) {
      for (final raw in toolCalls) {
        if (raw is! Map) continue;
        final function =
            raw['function'] is Map ? (raw['function'] as Map).cast<String, dynamic>() : null;
        final args = function?['arguments'];
        items.add({
          'type': 'function_call',
          'call_id': raw['id'] ?? '',
          'name': function?['name'] ?? '',
          'arguments': args is String ? args : jsonEncode(args ?? {}),
        });
      }
    }
  }
  return items;
}

/// 从 Chat messages 拆分出系统指令（Instructions）与 responses input items。
///
/// 所有 `role: system` 消息内容合并为 `instructions`
/// （空则返回 null → 请求体省略该键）；其余消息经
/// [responsesItemsFromChatMessages] 转换为 items。
({String? instructions, List<Map<String, dynamic>> items})
    responsesPartsFromChatMessages(List<Map<String, dynamic>> messages) {
  final instructions = [
    for (final m in messages)
      if (m['role'] == 'system') '${m['content'] ?? ''}'.trim(),
  ].where((s) => s.isNotEmpty).join('\n\n');
  return (
    instructions: instructions.isEmpty ? null : instructions,
    items: responsesItemsFromChatMessages([
      for (final m in messages)
        if (m['role'] != 'system') m,
    ]),
  );
}

/// 自定义工具（[NarrAgentTool]）的 schema 列表，按线路协议选择形状：
///
/// - Chat 线路：OpenAI 兼容嵌套形态 `{'type': 'function', 'function': {...}}`；
/// - Responses 线路：顶层形态 `{'type': 'function', 'name', 'description',
///   'parameters'}`。
List<Map<String, dynamic>> agentToolSchemas(
  List<NarrAgentTool> tools, {
  required bool responses,
}) {
  return [
    for (final t in tools)
      responses
          ? {
              'type': 'function',
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            }
          : {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.parameters,
              },
            },
  ];
}

/// Chat 内容块 → Responses 内容块（`image_url` → `input_image`、
/// `text` → `input_text`；非列表原样返回）。
Object _responsesContent(Object? content) {
  if (content is! List) return content ?? '';
  return [
    for (final part in content)
      if (part is Map && part['type'] == 'image_url')
        {
          'type': 'input_image',
          'image_url':
              (part['image_url'] as Map<String, dynamic>?)?['url'] ?? '',
        }
      else if (part is Map && part['type'] == 'text')
        {'type': 'input_text', 'text': part['text']}
      else
        part,
  ];
}
