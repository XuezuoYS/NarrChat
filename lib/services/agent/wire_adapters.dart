import 'dart:convert';

import '../ai_service.dart';
import 'narr_agent_tool.dart';

/// 协议线路适配（纯函数集合）。
///
/// AGENT 两阶段执行器（`AgentRoundRunner`）内部以「Responses 形状」的平铺
/// items 累积会话（`reasoning` / `function_call` / `function_call_output` /
/// 普通角色消息），线路协议（Chat Completions / Responses）在**组装请求体时**
/// 再转换为对应形态——执行器因此与线路协议完全解耦：
///
/// - Chat 线路：[chatItemsFromAgentItems] 把平铺 items 合并为合法的 Chat
///   messages（assistant 携带 `reasoning_content` + `tool_calls`、
///   `role: tool` 回传）；
/// - Responses 线路：[responsesItemsFromChatMessages] 把 Messages 形状
///   （含 `tool_calls` / `reasoning_content`）展开为 Responses input items
///   （`reasoning` / `function_call` / `function_call_output` +
///   `input_image` 视觉块）。
///
/// 两个方向均为纯函数，便于单测；协议选择由调用方（`RoundProvider`）决定。

/// 把「Responses 形状」的平铺 items 转换为 Chat messages。
///
/// 转换规则（与 OpenAI Chat Completions 消息约束对齐）：
/// - 普通角色消息（无 `type` 键，如 `{role, content}`）原样保留；
/// - `reasoning` 条目**并入**其紧随的 `assistant` 消息的 `reasoning_content`
///   （Chat 通道的思考回传形态）；
/// - `function_call` 条目**并入**其前一条 `assistant` 消息的 `tool_calls`
///   （参数 arguments 已是 JSON 字符串，保持原样）；
/// - `function_call_output` 条目转换为 `{role: 'tool', tool_call_id, content}`。
///
/// 若 `function_call` / `reasoning` 前没有 assistant 消息（如首帧即纯工具调用），
/// 自动补一条 `content: null` 的 assistant 消息承载它们。
List<Map<String, dynamic>> chatItemsFromAgentItems(
  List<Map<String, dynamic>> items,
) {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item['type'] == 'reasoning') {
      final text = item['text'] as String? ?? '';
      if (text.isEmpty) continue;
      // 紧随其后就是 assistant 消息时，思考挂到**那一条**上（不额外造占位，
      // 避免同一回合出现两条 assistant 消息）。
      final next = (i + 1 < items.length) ? items[i + 1] : null;
      if (next != null && next['role'] == 'assistant') {
        final assistant = Map<String, dynamic>.from(next);
        assistant['reasoning_content'] = text;
        out.add(assistant);
        i++;
        continue;
      }
      _ensureTrailingAssistant(out)['reasoning_content'] = text;
      continue;
    }
    if (item['type'] == 'function_call') {
      final assistant = _ensureTrailingAssistant(out);
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

/// 取末条 assistant 消息；末条不是 assistant 时新建一条 `content: null` 的占位。
Map<String, dynamic> _ensureTrailingAssistant(List<Map<String, dynamic>> out) {
  if (out.isNotEmpty && out.last['role'] == 'assistant') return out.last;
  final assistant = <String, dynamic>{
    'role': 'assistant',
    'content': null,
  };
  out.add(assistant);
  return assistant;
}

/// `AiReasoningItem` → AGENT 会话条目（Responses 形状的思考块）。
///
/// 两种线路共用同一份会话条目：[chatItemsFromAgentItems] 把它并入 assistant
/// 消息的 `reasoning_content`（Chat 通道），[reasoningResponseItem] 把它还原成
/// `reasoning` input item（Responses 通道）。
Map<String, dynamic> reasoningItemFrom(AiReasoningItem item) => {
      'type': 'reasoning',
      'id': item.id,
      'text': item.text,
      'summary': item.summary,
    };

/// AGENT 会话条目（Responses 形状）→ Responses input item。
///
/// 思考条目是 DeepSeek 思考模式的**硬要求**，且校验粒度是**逐块**的
///（实测于官方 Responses 线路）：
///
/// - 请求携带 `tools` 时，**每一个 `function_call` 都必须紧邻其前**各有一块
///   非空 `reasoning`；一帧调两个工具却只回传一块 → 整次 400
///   「The `reasoning_text` in the thinking mode must be passed back to the API」；
/// - 块内容与 id 形态无关（同 id / 异 id / 无 id 均通过），但**文本不能为空**；
/// - `assistant` 文本**不能**顶替思考块（只有正文、没有 reasoning 同样 400）。
///
/// 会话内部统一以 `{type: 'reasoning', id, text, summary}` 承载，这里还原成
/// 线路形态：纯文本内容用 `content` parts（OpenAI 侧该字段是加密形态，但文本
/// 形态被 DeepSeek 兼容实现接受），原响应来自 `summary` 时按 `summary` parts
/// 还原（OpenAI 侧纯文本只允许出现在 `summary`）。
Map<String, dynamic> reasoningResponseItem(Map<String, dynamic> item) {
  final id = item['id'] as String? ?? '';
  final text = item['text'] as String? ?? '';
  return {
    'type': 'reasoning',
    if (id.isNotEmpty) 'id': id,
    if (item['summary'] == true)
      'summary': [
        {'type': 'summary_text', 'text': text},
      ]
    else
      'content': [
        {'type': 'reasoning_text', 'text': text},
      ],
  };
}

/// 把 Chat messages 转换为 Responses input items（不含 system 消息）。
///
/// 转换规则：
/// - 普通 user / assistant 消息 → `{role, content}`（视觉 parts 同步转换，
///   `image_url` → `input_image`、`text` → `input_text`）；
/// - assistant 携带 `reasoning_content` 且带 `tool_calls` → **按每个工具调用**
///   先追加一条 `reasoning` 条目，再展开该消息与 `function_call`（服务端逐块
///   校验「每个 function_call 前各有非空思考」，见 [reasoningResponseItem]）；
///   不带工具调用时只追加一条；
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
    final reasoning = m['reasoning_content'];
    final toolCalls = m['tool_calls'];
    final callCount = toolCalls is List ? toolCalls.length : 0;
    if (reasoning is String && reasoning.isNotEmpty) {
      // 每个工具调用各配一块思考（无工具调用时只发一块）。
      for (var i = 0; i < (callCount > 0 ? callCount : 1); i++) {
        items.add(reasoningResponseItem({'text': reasoning}));
      }
    }
    items.add({
      'role': m['role'],
      'content': _responsesContent(m['content']),
    });
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

/// AGENT 会话条目（Responses 形状）→ Responses input items。
///
/// 执行器（`AgentRoundRunner`）累积的 `items` 已是 Responses 形状，**不能再走
/// [responsesItemsFromChatMessages]**（那会把思考条目当成无 `role` 的普通消息，
/// 产出 `{role: null, content: ...}` 的坏条目）。本函数按条目类型逐一还原：
///
/// - `reasoning` → [reasoningResponseItem]（思考条目必须**先于**其所属的
///   `function_call`，服务商按相邻关系把思考合并进紧随的 assistant 消息）；
/// - `function_call` → `{type, call_id, name, arguments}`（`arguments` 统一
///   JSON 字符串）；
/// - `function_call_output` → `{type, call_id, output}`；
/// - 其余（user / assistant 消息）→ `{role, content}`（视觉 parts 走
///   [responsesItemsFromChatMessages] 的同一转换，保证与首帧一致）。
List<Map<String, dynamic>> responsesItemsFromAgentItems(
  List<Map<String, dynamic>> items,
) {
  final out = <Map<String, dynamic>>[];
  for (final item in items) {
    final type = item['type'];
    if (type == 'reasoning') {
      final text = item['text'] as String? ?? '';
      if (text.isNotEmpty) out.add(reasoningResponseItem(item));
      continue;
    }
    if (type == 'function_call') {
      out.add({
        'type': 'function_call',
        'call_id': item['call_id'] ?? '',
        'name': item['name'] ?? '',
        'arguments': item['arguments'] ?? '{}',
      });
      continue;
    }
    if (type == 'function_call_output') {
      out.add({
        'type': 'function_call_output',
        'call_id': item['call_id'] ?? '',
        'output': item['output'] ?? '',
      });
      continue;
    }
    out.addAll(responsesItemsFromChatMessages([Map<String, dynamic>.from(item)]));
  }
  return out;
}

/// 从 Chat messages 拆分出系统指令（Instructions）与 responses input items。///
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
