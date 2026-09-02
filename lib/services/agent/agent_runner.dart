import 'dart:convert';

import 'agent_activity.dart';
import '../ai_service.dart';
import 'narr_agent_tool.dart';

export 'agent_activity.dart';

/// Agent 工具循环（research-then-generate）。
///
/// 流程：首轮带工具调用模型 → 若返回 `tool_calls` 则逐个执行工具、
/// 追加 `assistant(tool_calls)` + `tool` 消息再调用 → 直至模型返回最终
/// 内容（无 `tool_calls`）或达到 [maxIterations]。
///
/// 搜索失败等工具错误会作为 `tool` 结果**回传模型继续执行**（不中断本轮）；
/// 内容 / 思考 / Token 用量跨轮聚合。
class AgentRunner {
  AgentRunner({
    required this.buildBody,
    required this.call,
    this.tools = const [],
    this.maxIterations = 30,
    /// 线路协议定制的工具 schema 列表（如 Responses 顶层形态）；为 null 时
    /// 按 OpenAI Chat 兼容的嵌套形态（`function.function`）由 [tools] 生成。
    this.toolSchemas,
  });

  /// 根据当前 messages / tools 构建请求体（由调用方按预设规则实现）。
  final Map<String, dynamic> Function(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
  ) buildBody;

  /// 执行一次 LLM 调用。
  final Future<AiCallResult> Function(
    Map<String, dynamic> requestBody,
    bool stream,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  ) call;

  final List<NarrAgentTool> tools;
  final int maxIterations;

  /// 定制的工具 schema（协议形状由调用方决定；null = Chat 嵌套形态）。
  final List<Map<String, dynamic>>? toolSchemas;

  /// 运行 Agent 循环，返回聚合后的最终结果。
  Future<AiCallResult> run({
    required List<Map<String, dynamic>> initialMessages,
    required bool stream,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
    void Function(AgentActivity activity)? onActivity,
  }) async {
    final messages = List<Map<String, dynamic>>.from(initialMessages);
    var totalPrompt = 0;
    var totalCompletion = 0;
    final contentSb = StringBuffer();
    final reasoningSb = StringBuffer();
    // 本轮内各工具连续失败次数：达到 3 次后不再执行该工具，并告知模型停用。
    final toolFailures = <String, int>{};

    for (var i = 0; i < maxIterations; i++) {
      // 新一轮 LLM 调用：通知调用方（新一轮思考进入新块）。
      onActivity?.call(
        AgentActivity(type: AgentActivityType.turn, query: '', iteration: i),
      );
      final requestBody = buildBody(messages, _toolSchemas);
      final result = await call(
        requestBody,
        stream,
        onChunk,
        onRequestBody,
        isCancelled,
      );
      totalPrompt += result.promptTokens;
      totalCompletion += result.completionTokens;
      contentSb.write(result.content);
      reasoningSb.write(result.reasoningContent);

      if (result.toolCalls.isEmpty) {
        return AiCallResult(
          content: contentSb.toString(),
          reasoningContent: reasoningSb.toString(),
          promptTokens: totalPrompt,
          completionTokens: totalCompletion,
        );
      }

      // 追加 assistant(tool_calls) 消息（OpenAI 兼容：content 可为 null）。
      messages.add({
        'role': 'assistant',
        'content': result.content.isEmpty ? null : result.content,
        'tool_calls': [
          for (final tc in result.toolCalls)
            {
              'id': tc.id,
              'type': 'function',
              'function': {
                'name': tc.name,
                'arguments': jsonEncode(tc.arguments),
              },
            },
        ],
      });

      // 逐个执行工具；结果（含失败/空结果）追加 tool 消息。
      for (final tc in result.toolCalls) {
        if (isCancelled?.call() ?? false) {
          throw const AiCancelledException();
        }
        final tool = _byName(tc.name);
        // 已连续失败 3 次：不再执行该工具，直接告知模型停用，继续基于已有信息创作。
        if ((toolFailures[tc.name] ?? 0) >= 3) {
          messages.add({
            'role': 'tool',
            'tool_call_id': tc.id,
            'content': '工具 ${tc.name} 已连续失败 3 次，请勿再使用该工具，'
                '直接基于已有信息继续创作。',
          });
          continue;
        }
        // 活动主体：搜索为关键词、打开网页为链接、状态工具为工具名+参数摘要。
        final subject = tc.name == 'narrchat_webFetchPage'
            ? (tc.arguments['url'] as String? ?? '')
            : (tc.name.startsWith('narrchat_') &&
                    tc.name != 'narrchat_webSearch'
                ? '${tc.name} ${_shortArgs(tc.arguments)}'
                : (tc.arguments['query'] as String? ?? ''));
        onActivity?.call(
          AgentActivity(
            type: tool?.activityType ?? _activityTypeFor(tc.name),
            query: subject,
            iteration: i,
          ),
        );
        final toolResult = tool != null
            ? await tool.run(tc.arguments)
            : AgentToolResult(success: false, content: '未知工具：${tc.name}');
        // 仅「工具故障」（网络/超时/解析等）计入连续失败次数；
        // 页面拒绝访问（HTTP 4xx/5xx，refused）非工具故障，不计入。
        if (!toolResult.success && !toolResult.refused) {
          toolFailures[tc.name] = (toolFailures[tc.name] ?? 0) + 1;
        }
        messages.add({
          'role': 'tool',
          'tool_call_id': tc.id,
          'content': toolResult.content,
        });
      }
    }

    throw const AiException('Agent 工具调用超出最大迭代次数');
  }

  /// 工具名 → 活动类型兜底（未声明 [NarrAgentTool.activityType] 的旧工具）。
  static AgentActivityType _activityTypeFor(String toolName) {
    switch (toolName) {
      case 'narrchat_webFetchPage':
        return AgentActivityType.fetching;
      case 'narrchat_webSearch':
        return AgentActivityType.searching;
      default:
        return AgentActivityType.searching;
    }
  }

  /// 工具参数短摘要（含中文引号未转义的多值截断，供 UI 提示）。
  static String _shortArgs(Map<String, dynamic> args) {
    if (args.isEmpty) return '';
    return args.entries
        .take(3)
        .map((e) => '${e.key}=${_shortValue(e.value)}')
        .join('；');
  }

  static String _shortValue(Object? v) {
    final s = v is String ? v : v.toString();
    return s.length <= 24 ? s : '${s.substring(0, 24)}…';
  }

  /// 预览用：返回首轮实际会发出的请求体（当前 messages + 工具 schema）。
  ///
  /// 与 `run` 首帧走完全相同的 `buildBody(messages, _toolSchemas)`，
  /// 只构建、不发起任何调用，无副作用。
  Map<String, dynamic> previewFirstBody(List<Map<String, dynamic>> messages) =>
      buildBody(messages, _toolSchemas);

  /// 工具 schema 数组（调用方定制优先；缺省 Chat 嵌套形态）。
  List<Map<String, dynamic>> get _toolSchemas {
    if (toolSchemas != null) return toolSchemas!;
    return [
      for (final t in tools)
        {
          'type': 'function',
          'function': {
            'name': t.name,
            'description': t.description,
            'parameters': t.parameters,
          },
        },
    ];
  }

  NarrAgentTool? _byName(String name) {
    for (final t in tools) {
      if (t.name == name) return t;
    }
    return null;
  }
}
