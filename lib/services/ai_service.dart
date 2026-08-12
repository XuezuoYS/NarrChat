import 'dart:async';
import 'dart:convert';

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

  const AiStreamChunk({
    this.contentDelta = '',
    this.reasoningDelta = '',
    this.done = false,
  });
}

/// AI 调用结果。
class AiCallResult {
  final String content;

  /// 思考内容（思考模式下由 API 返回的 `reasoning_content`）。
  final String reasoningContent;
  final int promptTokens;
  final int completionTokens;

  const AiCallResult({
    required this.content,
    this.reasoningContent = '',
    required this.promptTokens,
    required this.completionTokens,
  });
}

/// AI 请求异常。
class AiException implements Exception {
  final String message;
  const AiException(this.message);

  @override
  String toString() => message;
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
  /// `stream` / 各模式参数），由 `AiRequestBodyBuilder` 按模型预设规则或
  /// 自定义模板预先构建——本类不负责参数组装，只负责传输与解析。
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
      final usage = data['usage'] as Map<String, dynamic>?;
      final promptTokens = (usage?['prompt_tokens'] as num?)?.toInt() ?? 0;
      final completionTokens = (usage?['completion_tokens'] as num?)?.toInt() ?? 0;
      return AiCallResult(
        content: content,
        reasoningContent: reasoningContent,
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
        throw const AiException('请求超时，请检查网络或稍后重试。');
      } on http.ClientException catch (e) {
        if (isCancelled?.call() ?? false) {
          throw const AiCancelledException();
        }
        throw AiException('网络请求失败：${e.message}');
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
            cancelSignal.completeError(e, st);
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
        throw const AiException('请求超时，请检查网络或稍后重试。');
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
      throw const AiException('请求超时，请检查网络或稍后重试。');
    } on http.ClientException catch (e) {
      throw AiException('网络请求失败：${e.message}');
    }

    if (response.statusCode != 200) {
      final errBody = await response.stream.bytesToString();
      throw AiException('API 请求失败（HTTP ${response.statusCode}）：$errBody');
    }

    final contentSb = StringBuffer();
    final reasoningSb = StringBuffer();
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
          if (isCancelled?.call() ?? false) {
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
            // 部分服务商在最后一个 chunk 附带 usage。
            final usage = json['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              promptTokens =
                  (usage['prompt_tokens'] as num?)?.toInt() ?? promptTokens;
              completionTokens = (usage['completion_tokens'] as num?)?.toInt() ??
                  completionTokens;
            }
          } catch (_) {
            // 忽略无法解析的行，保证容错。
          }
        },
        onError: (Object e, StackTrace st) {
          if (doneSignal.isCompleted) return;
          if (e is TimeoutException) {
            // 空闲超时（服务器挂起）：统一转为请求超时错误。
            doneSignal.completeError(
              const AiException('请求超时，请检查网络或稍后重试。'),
              st,
            );
          } else if (isCancelled?.call() ?? false) {
            // 连接被取消（用户中断）中止时，流会以错误结束。
            doneSignal.completeError(const AiCancelledException(), st);
          } else {
            doneSignal.completeError(e, st);
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
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
  }

  void dispose() {
    _client.close();
  }
}
