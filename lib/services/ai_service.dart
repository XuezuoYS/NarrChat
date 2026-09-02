import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// AI 流式输出中的一个增量块。
class AiStreamChunk {
  /// 剧情正文增量。
  final String contentDelta;

  /// 思考内容增量（思考模式下由 `reasoning_content` 提供）。
  final String reasoningDelta;

  /// 流是否结束（[done] 为 true 时无内容增量）。
  final bool done;

  /// 工具调用**流式预览**（Responses 事件流）：`output_item.added`
  /// （function_call）到达时携带 [toolCallId] + [toolName]，
  /// `function_call_arguments.delta` 到达时携带 [toolArgsDelta]。
  /// 与思考块同语义：先流式预览，执行完成后展示执行结果。
  final String? toolCallId;
  final String? toolName;
  final String? toolArgsDelta;

  const AiStreamChunk({
    this.contentDelta = '',
    this.reasoningDelta = '',
    this.done = false,
    this.toolCallId,
    this.toolName,
    this.toolArgsDelta,
  });
}

/// AI 请求的工具调用（模型决定调用某个工具）。
class AiToolCall {
  /// 调用 id（回填 tool 消息时使用）。
  final String id;
  final String name;

  /// 工具参数（已解析为 JSON 对象）。
  final Map<String, dynamic> arguments;

  const AiToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

/// AI 调用结果。
class AiCallResult {
  final String content;

  /// 思考内容（思考模式下由 API 返回的 `reasoning_content`）。
  final String reasoningContent;

  /// 模型请求的工具调用（空列表 = 无工具调用，直接返回最终内容）。
  final List<AiToolCall> toolCalls;
  final int promptTokens;
  final int completionTokens;

  /// Responses API 的响应 id（`previous_response_id` 链式续接用；
  /// Chat 协议与不支持有状态续接时为空）。
  final String responseId;

  const AiCallResult({
    required this.content,
    this.reasoningContent = '',
    this.toolCalls = const [],
    required this.promptTokens,
    required this.completionTokens,
    this.responseId = '',
  });
}

/// AI 请求失败类别：决定是否自动重试。
///
/// - [network]：网络 / 连接 / 超时类失败，**可自动重试**；
/// - [api]：API 业务类失败（HTTP 非 200、响应解析失败等），不自动重试。
enum AiExceptionKind { network, api }

/// AI 请求异常。
class AiException implements Exception {
  final String message;

  /// 失败类别（默认 [AiExceptionKind.api]）。
  final AiExceptionKind kind;

  const AiException(this.message, {this.kind = AiExceptionKind.api});

  @override
  String toString() => message;
}

/// 将任意异常归类为 [AiExceptionKind]（自动重试策略的依据）。
///
/// 网络 / 超时 / 连接类异常归为 [AiExceptionKind.network]（可重试）；
/// [AiException] 使用自身携带的 [AiException.kind]；其余归为 api。
AiExceptionKind classifyAiErrorKind(Object error) {
  if (error is AiException) return error.kind;
  if (error is TimeoutException) return AiExceptionKind.network;
  if (error is http.ClientException) return AiExceptionKind.network;
  if (error is SocketException) return AiExceptionKind.network;
  return AiExceptionKind.api;
}

/// 把底层连接 / 流错误统一为网络类 [AiException]（可自动重试、提示友好）；
/// 已是 [AiException] 或非网络类错误原样返回。
Object _toNetworkException(Object e) {
  if (e is AiException) return e;
  if (e is http.ClientException || e is SocketException) {
    return AiException('网络请求中断：$e', kind: AiExceptionKind.network);
  }
  return e;
}

/// 用户主动中断请求时抛出的异常（与真实错误区分，不提示“请求失败”）。
class AiCancelledException implements Exception {
  const AiCancelledException();

  @override
  String toString() => '请求已中断';
}

/// 大模型 API 客户端（OpenAI 兼容格式：`POST {baseUrl}/chat/completions`）。
///
/// 兼容 DeepSeek / OpenAI / Claude 兼容网关 / 本地 Ollama 等。
/// 支持：
/// - 思考模式（`thinking: {"type": "enabled"}`，返回 `reasoning_content`）
/// - 流式输出（SSE，`stream: true`，通过 [onChunk] 回调增量）
/// - 自定义模型、温度
class AiService {
  AiService({
    http.Client? client,
    Duration requestTimeout = AppConfig.requestTimeout,
  })  : _client = client ?? http.Client(),
        // ignore: prefer_initializing_formals
        _requestTimeout = requestTimeout;

  final http.Client _client;

  /// 请求超时：非流式为「整段响应」限时；流式为「空闲超时」——
  /// 超过该时长未收到任何数据行即视为超时（避免服务器挂起导致流式永久卡住）。
  final Duration _requestTimeout;

  /// 发送对话请求并返回解析后的内容与 Token 用量。
  ///
  /// [requestBody] 为**完整**的 OpenAI 兼容请求体（含 `model` / `messages` /
  /// `stream` / 各模式参数），由 `AiRequestBodyBuilder` 按模型预设规则预先
  /// 构建——本类不负责参数组装，只负责传输与解析。
  ///
  /// [stream] 为 true 时启用 SSE 流式，增量内容通过 [onChunk] 回调；
  /// 即使流式，本方法也会在结束后返回聚合后的完整 [AiCallResult]。
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    /// 返回 true 表示用户已主动中断，流式将停止接收、非流式丢弃结果。
    bool Function()? isCancelled,
  }) async {
    final baseUrl = apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$baseUrl/chat/completions');
    final body = jsonEncode(requestBody);

    // 暴露实际发出的请求 JSON（供“调试”功能展示）。
    onRequestBody?.call(body);

    if (stream) {
      return _chatStreaming(
        uri: uri,
        apiKey: apiKey,
        body: body,
        onChunk: onChunk,
        isCancelled: isCancelled,
      );
    }
    return _chatOnce(
      uri: uri,
      apiKey: apiKey,
      body: body,
      isCancelled: isCancelled,
    );
  }

  // ---------------------------------------------------------------------------
  // 非流式
  // ---------------------------------------------------------------------------
  Future<AiCallResult> _chatOnce({
    required Uri uri,
    required String apiKey,
    required String body,
    bool Function()? isCancelled,
  }) async {
    final rawBody = utf8.decode(
      await _postAbortable(
        uri: uri,
        apiKey: apiKey,
        body: body,
        isCancelled: isCancelled,
      ),
    );

    try {
      final data = jsonDecode(rawBody) as Map<String, dynamic>;
      final choices = (data['choices'] as List<dynamic>?) ?? const [];
      if (choices.isEmpty) {
        throw AiException('API 返回内容为空：$rawBody');
      }
      final message = (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>?;
      final content = (message?['content'] as String?) ?? '';
      final reasoningContent = (message?['reasoning_content'] as String?) ?? '';
      final toolCalls = _parseToolCalls(message?['tool_calls']);
      final usage = data['usage'] as Map<String, dynamic>?;
      final promptTokens = (usage?['prompt_tokens'] as num?)?.toInt() ?? 0;
      final completionTokens = (usage?['completion_tokens'] as num?)?.toInt() ?? 0;
      return AiCallResult(
        content: content,
        reasoningContent: reasoningContent,
        toolCalls: toolCalls,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      );
    } on FormatException {
      throw AiException('API 响应解析失败：$rawBody');
    }
  }

  /// 发送非流式请求并读取完整响应体；支持用户中断。
  ///
  /// 非流式请求无法像流式那样「收到数据时才检查取消」——服务器在生成完成前
  /// 不会返回任何数据。因此这里：
  /// 1. 定时轮询 [isCancelled]（100ms 间隔），一旦为 true 立即抛
  ///    [AiCancelledException]——无论服务器处于「响应头未返回」还是
  ///    「正文生成中」状态，都不再等它返回
  ///    （修复「非流式下停止生成要等 AI 生成完才生效」的问题）；
  /// 2. 若响应体已在读取中，同时取消订阅以中止底层连接。
  /// 请求始终走注入的 [_client]，便于测试注入 mock。
  Future<List<int>> _postAbortable({
    required Uri uri,
    required String apiKey,
    required String body,
    bool Function()? isCancelled,
  }) async {
    // 取消信号：用户中断时 completeError(AiCancelledException)。
    final cancelSignal = Completer<void>();
    // 防止取消信号在未被 await 的异常路径上产生 unhandled error。
    cancelSignal.future.ignore();

    // 当前活跃的响应体订阅：中断时取消以中止底层连接。
    StreamSubscription<List<int>>? sub;

    late final Timer poll;
    poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if ((isCancelled?.call() ?? false) && !cancelSignal.isCompleted) {
        unawaited(sub?.cancel()); // 中止底层连接（若正文已在读取中）
        cancelSignal.completeError(const AiCancelledException());
      }
    });

    try {
      final request = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..body = body;

      late final http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(_requestTimeout);
      } on TimeoutException {
        throw const AiException(
          '请求超时，请检查网络或稍后重试。',
          kind: AiExceptionKind.network,
        );
      } on http.ClientException catch (e) {
        if (isCancelled?.call() ?? false) {
          throw const AiCancelledException();
        }
        throw AiException(
          '网络请求失败：${e.message}',
          kind: AiExceptionKind.network,
        );
      }

      // 响应头已返回后再检查一次（可能在 send 完成前用户已中断）。
      if (isCancelled?.call() ?? false) {
        throw const AiCancelledException();
      }
      if (response.statusCode != 200) {
        final errBody = await response.stream.bytesToString();
        throw AiException('API 请求失败（HTTP ${response.statusCode}）：$errBody');
      }

      final bytes = <int>[];
      sub = response.stream.listen(
        (chunk) => bytes.addAll(chunk),
        onError: (Object e, StackTrace st) {
          // 连接被取消（用户中断）中止时，流会以错误结束。
          if (isCancelled?.call() ?? false) {
            if (!cancelSignal.isCompleted) {
              cancelSignal.completeError(const AiCancelledException(), st);
            }
          } else if (!cancelSignal.isCompleted) {
            cancelSignal.completeError(_toNetworkException(e), st);
          }
        },
        onDone: () {
          if (!cancelSignal.isCompleted) cancelSignal.complete();
        },
        cancelOnError: true,
      );

      // 等待：响应读完（onDone）或用户中断（cancelSignal 报错）。
      // 保留原「整段响应（含正文）限时」语义。
      try {
        await cancelSignal.future.timeout(_requestTimeout);
      } on TimeoutException {
        throw const AiException(
          '请求超时，请检查网络或稍后重试。',
          kind: AiExceptionKind.network,
        );
      }
      return bytes;
    } finally {
      poll.cancel();
    }
  }

  // ---------------------------------------------------------------------------
  // 流式（SSE）
  // ---------------------------------------------------------------------------
  Future<AiCallResult> _chatStreaming({
    required Uri uri,
    required String apiKey,
    required String body,
    required void Function(AiStreamChunk chunk)? onChunk,
    bool Function()? isCancelled,
  }) async {
    late final http.StreamedResponse response;
    try {
      final request = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..body = body;
      response = await _client.send(request).timeout(_requestTimeout);
    } on TimeoutException {
      throw const AiException(
        '请求超时，请检查网络或稍后重试。',
        kind: AiExceptionKind.network,
      );
    } on http.ClientException catch (e) {
      throw AiException(
        '网络请求失败：${e.message}',
        kind: AiExceptionKind.network,
      );
    }

    if (response.statusCode != 200) {
      final errBody = await response.stream.bytesToString();
      throw AiException('API 请求失败（HTTP ${response.statusCode}）：$errBody');
    }

    final contentSb = StringBuffer();
    final reasoningSb = StringBuffer();
    // 流式工具调用按 index 累积（id/name/arguments 分块到达）。
    final toolCallAcc = <int, _ToolCallAccumulator>{};
    int promptTokens = 0;
    int completionTokens = 0;

    // 完成信号：正常读完（onDone）/ 用户中断 / 空闲超时 / 流错误。
    final doneSignal = Completer<void>();
    // 防止完成信号在未被 await 的异常路径上产生 unhandled error。
    doneSignal.future.ignore();

    StreamSubscription<String>? sub;

    // 挂起保护：服务器不再发送任何数据时，仍能及时响应用户中断
    //（await 卡在流上时无法检查 isCancelled，需轮询兜底）。
    late final Timer poll;
    poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if ((isCancelled?.call() ?? false) && !doneSignal.isCompleted) {
        unawaited(sub?.cancel()); // 中止底层连接
        doneSignal.completeError(const AiCancelledException());
      }
    });

    try {
      sub = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          // 空闲超时：超过 [_requestTimeout] 未收到任何数据行即视为超时，
          // 避免服务器挂起导致流式永久卡住（上游 _isSending 无法复位）。
          .timeout(_requestTimeout)
          .listen(
        (line) {
          // 每行先检查用户中断（正常流式下停止生成即时生效）。
          // 无论由轮询还是本行分支检测到取消，都必须中止底层连接订阅，
          // 否则订阅保持存活会继续消费服务器残留数据（僵尸流），
          // 导致上一轮的尾部增量被注入新一轮。
          if (isCancelled?.call() ?? false) {
            unawaited(sub?.cancel()); // 中止底层连接
            if (!doneSignal.isCompleted) {
              doneSignal.completeError(const AiCancelledException());
            }
            return;
          }
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) return;
          final data = trimmed.substring(5).trim();
          if (data == '[DONE]') {
            if (!doneSignal.isCompleted) doneSignal.complete();
            return;
          }
          if (data.isEmpty) return;
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            // 部分服务商在最后一个 chunk 附带 usage（此时 choices 为空数组），
            // 需在早退之前解析。
            final usage = json['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              promptTokens =
                  (usage['prompt_tokens'] as num?)?.toInt() ?? promptTokens;
              completionTokens =
                  (usage['completion_tokens'] as num?)?.toInt() ??
                  completionTokens;
            }
            final choices = (json['choices'] as List<dynamic>?) ?? const [];
            if (choices.isEmpty) return;
            final delta =
                (choices.first as Map<String, dynamic>)['delta']
                    as Map<String, dynamic>?;
            final content = delta?['content'] as String?;
            if (content != null && content.isNotEmpty) {
              contentSb.write(content);
              onChunk?.call(AiStreamChunk(contentDelta: content));
            }
            final reasoning = delta?['reasoning_content'] as String?;
            if (reasoning != null && reasoning.isNotEmpty) {
              reasoningSb.write(reasoning);
              onChunk?.call(AiStreamChunk(reasoningDelta: reasoning));
            }
            // 流式工具调用：`delta.tool_calls` 分块累积。
            final toolCalls = delta?['tool_calls'] as List<dynamic>?;
            if (toolCalls != null) {
              for (final raw in toolCalls) {
                if (raw is! Map) continue;
                final index = (raw['index'] as num?)?.toInt() ?? 0;
                final acc = toolCallAcc.putIfAbsent(
                  index,
                  () => _ToolCallAccumulator(),
                );
                final id = raw['id'] as String?;
                if (id != null && id.isNotEmpty) acc.id = id;
                final fn = raw['function'] as Map<String, dynamic>?;
                if (fn != null) {
                  final name = fn['name'] as String?;
                  if (name != null && name.isNotEmpty) acc.name = name;
                  final args = fn['arguments'] as String?;
                  if (args != null && args.isNotEmpty) {
                    acc.arguments.write(args);
                  }
                }
              }
            }
          } catch (_) {
            // 忽略无法解析的行，保证容错。
          }
        },
        onError: (Object e, StackTrace st) {
          if (doneSignal.isCompleted) return;
          if (e is TimeoutException) {
            // 空闲超时（服务器挂起）：统一转为请求超时错误（可自动重试）。
            doneSignal.completeError(
              const AiException(
                '请求超时，请检查网络或稍后重试。',
                kind: AiExceptionKind.network,
              ),
              st,
            );
          } else if (isCancelled?.call() ?? false) {
            // 连接被取消（用户中断）中止时，流会以错误结束。
            doneSignal.completeError(const AiCancelledException(), st);
          } else {
            // 底层连接中断等：统一为网络类 AiException（可重试、提示友好）。
            doneSignal.completeError(_toNetworkException(e), st);
          }
        },
        onDone: () {
          if (!doneSignal.isCompleted) doneSignal.complete();
        },
        cancelOnError: true,
      );

      // 等待：正常读完 / 用户中断 / 空闲超时 / 流错误。
      await doneSignal.future;
    } finally {
      poll.cancel();
      onChunk?.call(const AiStreamChunk(done: true));
    }

    return AiCallResult(
      content: contentSb.toString(),
      reasoningContent: reasoningSb.toString(),
      toolCalls: [
        for (final acc in toolCallAcc.values)
          AiToolCall(
            id: acc.id,
            name: acc.name,
            arguments: _parseToolArguments(acc.arguments.toString()),
          ),
      ],
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
  }

  // ---------------------------------------------------------------------------
  // Responses API（AGENT 模式）
  // ---------------------------------------------------------------------------

  /// 发送 Responses API 请求（`POST {baseUrl}/responses`）并返回解析结果。
  ///
  /// [requestBody] 为**完整**的 Response API 兼容请求体（含 `model` /
  /// `instructions` / `input` / 各模式参数），由调用方按平台预设规则构建。
  /// 响应（流式事件 / 非流式对象）统一映射为 [AiCallResult]：
  /// - 正文增量 → [AiStreamChunk.contentDelta]；
  /// - 思考增量 → [AiStreamChunk.reasoningDelta]；
  /// - `function_call` → [AiToolCall]（id / name / arguments 按 item 累积）。
  ///
  /// 事件流与响应对象以 OpenAI Responses API 格式为准，对 DeepSeek 等
  /// 兼容实现的形态差异做容错（未知事件 / 未知字段静默忽略）。
  Future<AiCallResult> responses({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    final baseUrl = apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$baseUrl/responses');
    final body = jsonEncode(requestBody);

    // 暴露实际发出的请求 JSON（供“调试”功能展示）。
    onRequestBody?.call(body);

    if (stream) {
      return _responsesStreaming(
        uri: uri,
        apiKey: apiKey,
        body: body,
        onChunk: onChunk,
        isCancelled: isCancelled,
      );
    }
    return _responsesOnce(
      uri: uri,
      apiKey: apiKey,
      body: body,
      isCancelled: isCancelled,
    );
  }

  /// 非流式：解析完整 response 对象（`output` 数组 + `usage`）。
  Future<AiCallResult> _responsesOnce({
    required Uri uri,
    required String apiKey,
    required String body,
    bool Function()? isCancelled,
  }) async {
    final rawBody = utf8.decode(
      await _postAbortable(
        uri: uri,
        apiKey: apiKey,
        body: body,
        isCancelled: isCancelled,
      ),
    );
    try {
      final data = jsonDecode(rawBody) as Map<String, dynamic>;
      final error = data['error'];
      if (error != null) {
        throw AiException('API 请求失败：$error');
      }
      final contentSb = StringBuffer();
      final reasoningSb = StringBuffer();
      final toolCalls = <AiToolCall>[];
      final output = (data['output'] as List<dynamic>?) ?? const [];
      for (final raw in output) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final type = item['type'] as String?;
        final text = _extractItemText(item);
        if (type == 'reasoning') {
          if (text.isNotEmpty) reasoningSb.write(text);
        } else if (type == 'message' || type == 'output_text') {
          if (text.isNotEmpty) contentSb.write(text);
        } else if (type == 'function_call') {
          toolCalls.add(_parseFunctionCallItem(item));
        }
      }
      final usage = data['usage'] as Map<String, dynamic>?;
      return AiCallResult(
        content: contentSb.toString(),
        reasoningContent: reasoningSb.toString(),
        toolCalls: toolCalls,
        promptTokens: _usageCount(usage ?? const {}, 'input_tokens'),
        completionTokens: _usageCount(usage ?? const {}, 'output_tokens'),
        responseId: (data['id'] as String?) ?? '',
      );
    } on FormatException {
      throw AiException('API 响应解析失败：$rawBody');
    }
  }

  /// 流式：解析 Responses API SSE 事件（`data:` 行为 event JSON）。
  Future<AiCallResult> _responsesStreaming({
    required Uri uri,
    required String apiKey,
    required String body,
    required void Function(AiStreamChunk chunk)? onChunk,
    bool Function()? isCancelled,
  }) async {
    late final http.StreamedResponse response;
    try {
      final request = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..body = body;
      response = await _client.send(request).timeout(_requestTimeout);
    } on TimeoutException {
      throw const AiException(
        '请求超时，请检查网络或稍后重试。',
        kind: AiExceptionKind.network,
      );
    } on http.ClientException catch (e) {
      throw AiException(
        '网络请求失败：${e.message}',
        kind: AiExceptionKind.network,
      );
    }

    if (response.statusCode != 200) {
      final errBody = await response.stream.bytesToString();
      throw AiException('API 请求失败（HTTP ${response.statusCode}）：$errBody');
    }

    final contentSb = StringBuffer();
    final reasoningSb = StringBuffer();
    // 工具调用按 output item 累积（OpenAI 事件流中 function_call 参数按
    // `response.function_call_arguments.delta` 分块到达，按 item_id 聚合）。
    final toolAcc = <String, _ToolCallAccumulator>{};
    // 已出现正文（用于流式结尾排序：工具列表按首次出现顺序输出）。
    final toolOrder = <String>[];
    int promptTokens = 0;
    int completionTokens = 0;
    String responseId = '';
    final doneSignal = Completer<void>();
    doneSignal.future.ignore();

    StreamSubscription<String>? sub;
    late final Timer poll;
    poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if ((isCancelled?.call() ?? false) && !doneSignal.isCompleted) {
        unawaited(sub?.cancel());
        doneSignal.completeError(const AiCancelledException());
      }
    });

    try {
      sub = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(_requestTimeout)
          .listen(
        (line) {
          if (isCancelled?.call() ?? false) {
            unawaited(sub?.cancel());
            if (!doneSignal.isCompleted) {
              doneSignal.completeError(const AiCancelledException());
            }
            return;
          }
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) return;
          final data = trimmed.substring(5).trim();
          if (data.isEmpty || data == '[DONE]') {
            if (data == '[DONE]' && !doneSignal.isCompleted) {
              doneSignal.complete();
            }
            return;
          }
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final type = json['type'] as String? ?? '';
            switch (type) {
              case 'response.output_text.delta':
                final delta = json['delta'] as String? ?? '';
                if (delta.isNotEmpty) {
                  contentSb.write(delta);
                  onChunk?.call(AiStreamChunk(contentDelta: delta));
                }
                break;
              case 'response.reasoning_summary_text.delta':
              case 'response.reasoning_text.delta':
                final rd = json['delta'] as String? ?? '';
                if (rd.isNotEmpty) {
                  reasoningSb.write(rd);
                  onChunk?.call(AiStreamChunk(reasoningDelta: rd));
                }
                break;
              case 'response.output_item.added':
                final item = json['item'] as Map<String, dynamic>?;
                final type2 = item?['type'] as String?;
                if (type2 == 'function_call') {
                  final itemId = (item?['id'] as String?) ??
                      (json['item_id'] as String? ?? '');
                  final acc = toolAcc.putIfAbsent(
                    itemId,
                    () => _ToolCallAccumulator()..name = (item?['name'] as String? ?? ''),
                  );
                  if (acc.id.isEmpty) {
                    acc.id = (item?['id'] as String?) ?? '';
                  }
                  if (!toolOrder.contains(itemId)) toolOrder.add(itemId);
                  // 流式预览：工具卡片即时出现（与思考块同语义）。
                  onChunk?.call(
                    AiStreamChunk(
                      toolCallId: itemId,
                      toolName: (item?['name'] as String?) ?? '',
                    ),
                  );
                }
                break;
              case 'response.function_call_arguments.delta':
                final itemId = json['item_id'] as String? ?? '';
                final acc = toolAcc[itemId];
                if (acc != null) {
                  acc.arguments.write(json['delta'] as String? ?? '');
                }
                onChunk?.call(
                  AiStreamChunk(
                    toolCallId: itemId,
                    toolName: null,
                    toolArgsDelta: json['delta'] as String?,
                  ),
                );
                break;
              case 'response.output_item.done':
              case 'response.function_call_arguments.done':
              case 'response.output_text.done':
              case 'response.reasoning_summary_text.done':
                break;
              case 'response.completed':
              case 'response.done':
                final resp = json['response'] as Map<String, dynamic>?;
                if (resp != null) {
                  responseId = (resp['id'] as String?) ?? responseId;
                }
                _mergeResponsesUsage(json, (p, c) {
                  promptTokens = p;
                  completionTokens = c;
                });
                if (!doneSignal.isCompleted) doneSignal.complete();
                break;
              case 'response.failed':
              case 'response.incomplete':
                final err = json['response']?['error'] ?? json['error'];
                doneSignal.completeError(
                  AiException('API 请求中断：$err'),
                );
                break;
              default:
                // 未知事件（response.created / in_progress / 各 done 事件等）忽略。
                _mergeResponsesUsage(json, (p, c) {
                  promptTokens = p == 0 ? promptTokens : p;
                  completionTokens = c == 0 ? completionTokens : c;
                });
            }
          } catch (_) {
            // 忽略无法解析的行，保证容错。
          }
        },
        onError: (Object e, StackTrace st) {
          if (doneSignal.isCompleted) return;
          if (e is TimeoutException) {
            doneSignal.completeError(
              const AiException(
                '请求超时，请检查网络或稍后重试。',
                kind: AiExceptionKind.network,
              ),
              st,
            );
          } else if (isCancelled?.call() ?? false) {
            doneSignal.completeError(const AiCancelledException(), st);
          } else {
            doneSignal.completeError(_toNetworkException(e), st);
          }
        },
        onDone: () {
          if (!doneSignal.isCompleted) doneSignal.complete();
        },
        cancelOnError: true,
      );

      await doneSignal.future;
    } finally {
      poll.cancel();
      onChunk?.call(const AiStreamChunk(done: true));
    }

    return AiCallResult(
      content: contentSb.toString(),
      reasoningContent: reasoningSb.toString(),
      toolCalls: [
        for (final id in toolOrder)
          _toolCallFrom(id, toolAcc),
      ],
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      responseId: responseId,
    );
  }

  /// 从事件中合并 usage（`response.completed` 的 `response.usage` 或顶层 `usage`）。
  static void _mergeResponsesUsage(
    Map<String, dynamic> json,
    void Function(int prompt, int completion) assign,
  ) {
    final usage = (json['response'] as Map<String, dynamic>?)?['usage']
            as Map<String, dynamic>? ??
        json['usage'] as Map<String, dynamic>?;
    if (usage == null) return;
    assign(
      _usageCount(usage, 'input_tokens'),
      _usageCount(usage, 'output_tokens'),
    );
  }

  /// 从响应对象 item 抽取文本（容错 content / summary / text 三种形态）。
  static String _extractItemText(Map<String, dynamic> item) {
    final sb = StringBuffer();
    for (final key in const ['content', 'summary']) {
      final raw = item[key];
      if (raw is String) {
        sb.write(raw);
      } else if (raw is List) {
        for (final part in raw) {
          if (part is! Map) continue;
          final t = part['text'];
          if (t is String && t.isNotEmpty) sb.write(t);
        }
      }
    }
    final text = item['text'];
    if (text is String && text.isNotEmpty) sb.write(text);
    return sb.toString();
  }

  /// 非流式 `function_call` item → [AiToolCall]。
  static AiToolCall _parseFunctionCallItem(Map<String, dynamic> item) {
    final id = (item['id'] as String?) ?? (item['call_id'] as String?) ?? '';
    final name = (item['name'] as String?) ?? '';
    var arguments = const <String, dynamic>{};
    final rawArgs = item['arguments'];
    if (rawArgs is String) {
      arguments = _parseToolArguments(rawArgs);
    } else if (rawArgs is Map) {
      arguments = Map<String, dynamic>.from(rawArgs);
    }
    return AiToolCall(id: id, name: name, arguments: arguments);
  }

  /// 流式累积器（[toolOrder] 中为 item_id）→ 最终 [AiToolCall]。
  static AiToolCall _toolCallFrom(
    String itemId,
    Map<String, _ToolCallAccumulator> acc,
  ) {
    final a = acc[itemId]!;
    return AiToolCall(
      id: a.id.isEmpty ? itemId : a.id,
      name: a.name,
      arguments: _parseToolArguments(a.arguments.toString()),
    );
  }

  static int _usageCount(Map<String, dynamic> usage, String key) =>
      (usage[key] as num?)?.toInt() ?? 0;

  /// 解析工具参数 JSON 字符串；非法时回退空 Map。
  ///
  /// 兼容两种转义形态：规范形态（`\\n` 双重转义，外层解码后仍为转义序列）
  /// 直接解析；个别服务商以单层转义输出（参数文本内是真实换行）时，
  /// 回退把真实换行转义后再解析。
  static Map<String, dynamic> _parseToolArguments(String raw) {
    if (raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return (decoded is Map<String, dynamic>) ? decoded : const {};
    } catch (_) {
      try {
        final escaped =
            raw.replaceAll('\r\n', r'\n').replaceAll('\n', r'\n').replaceAll('\r', '');
        final decoded = jsonDecode(escaped);
        return (decoded is Map<String, dynamic>) ? decoded : const {};
      } catch (_) {
        return const {};
      }
    }
  }

  /// 解析非流式响应中的 `message.tool_calls`。
  static List<AiToolCall> _parseToolCalls(Object? raw) {
    if (raw is! List) return const [];
    final result = <AiToolCall>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final fn = item['function'];
      if (fn is! Map) continue;
      final name = fn['name'] as String? ?? '';
      Map<String, dynamic> arguments = const {};
      final argsRaw = fn['arguments'];
      if (argsRaw is String) {
        arguments = _parseToolArguments(argsRaw);
      } else if (argsRaw is Map) {
        arguments = Map<String, dynamic>.from(argsRaw);
      }
      result.add(
        AiToolCall(
          id: (item['id'] as String?) ?? '',
          name: name,
          arguments: arguments,
        ),
      );
    }
    return result;
  }

  void dispose() {
    _client.close();
  }
}

/// 流式工具调用的增量累积器。
class _ToolCallAccumulator {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
