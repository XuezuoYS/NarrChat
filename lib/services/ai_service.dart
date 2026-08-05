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

/// 大模型 API 客户端（OpenAI 兼容格式：`POST {baseUrl}/chat/completions`）。
///
/// 兼容 DeepSeek / OpenAI / Claude 兼容网关 / 本地 Ollama 等。
/// 支持：
/// - 思考模式（`thinking: {"type": "enabled"}`，返回 `reasoning_content`）
/// - 流式输出（SSE，`stream: true`，通过 [onChunk] 回调增量）
/// - 自定义模型、温度
class AiService {
  AiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// 发送对话请求并返回解析后的内容与 Token 用量。
  ///
  /// [stream] 为 true 时启用 SSE 流式，增量内容通过 [onChunk] 回调；
  /// 即使流式，本方法也会在结束后返回聚合后的完整 [AiCallResult]。
  ///
  /// 参数遵循 DeepSeek 官方文档：
  /// - `thinking.type` 为 `enabled` / `disabled`（官方默认开启，因此始终显式下发）；
  /// - 思考模式下官方不支持 `temperature`，故开启思考时不发送温度；
  /// - `reasoning_effort`：low / high / max，仅思考模式下生效。
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required String systemPrompt,
    required String userPrompt,
    List<Map<String, String>> historyMessages = const [],
    String? model,
    double temperature = 1.0,
    bool thinking = false,
    String reasoningEffort = 'high',
    int? maxTokens,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
  }) async {
    final baseUrl = apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$baseUrl/chat/completions');

    // 按 API 要求以原生 messages 数组传递对话历史：
    // system → 历史(user/assistant 交替) → 当前 user。
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      ...historyMessages,
      {'role': 'user', 'content': userPrompt},
    ];

    final body = jsonEncode({
      'model': (model ?? AppConfig.defaultModelNameEffective).trim(),
      'messages': messages,
      // 思考模式官方默认开启，必须显式声明开/关。
      'thinking': {'type': thinking ? 'enabled' : 'disabled'},
      if (thinking) 'reasoning_effort': reasoningEffort,
      // 思考模式下官方不支持 temperature（设置不报错但不生效），故不发送。
      if (!thinking)
        'temperature': temperature.clamp(
          AppConfig.minTemperature,
          AppConfig.maxTemperature,
        ),
      if (maxTokens != null && maxTokens > 0) 'max_tokens': maxTokens,
      'stream': stream,
      // 流式时携带 usage，以便统计 Token。
      if (stream) 'stream_options': {'include_usage': true},
    });

    // 暴露实际发出的请求 JSON（供“调试”功能展示）。
    onRequestBody?.call(body);

    if (stream) {
      return _chatStreaming(
        uri: uri,
        apiKey: apiKey,
        body: body,
        onChunk: onChunk,
      );
    }
    return _chatOnce(uri: uri, apiKey: apiKey, body: body);
  }

  // ---------------------------------------------------------------------------
  // 非流式
  // ---------------------------------------------------------------------------
  Future<AiCallResult> _chatOnce({
    required Uri uri,
    required String apiKey,
    required String body,
  }) async {
    late final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: body,
          )
          .timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw const AiException('请求超时，请检查网络或稍后重试。');
    } on http.ClientException catch (e) {
      throw AiException('网络请求失败：${e.message}');
    }

    final rawBody = utf8.decode(response.bodyBytes);
    if (response.statusCode != 200) {
      throw AiException('API 请求失败（HTTP ${response.statusCode}）：$rawBody');
    }

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

  // ---------------------------------------------------------------------------
  // 流式（SSE）
  // ---------------------------------------------------------------------------
  Future<AiCallResult> _chatStreaming({
    required Uri uri,
    required String apiKey,
    required String body,
    required void Function(AiStreamChunk chunk)? onChunk,
  }) async {
    late final http.StreamedResponse response;
    try {
      final request = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..body = body;
      response = await _client.send(request).timeout(AppConfig.requestTimeout);
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

    try {
      await for (final line
          in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final data = trimmed.substring(5).trim();
        if (data == '[DONE]') break;
        if (data.isEmpty) continue;

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final choices = (json['choices'] as List<dynamic>?) ?? const [];
          if (choices.isEmpty) continue;
          final delta = (choices.first as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;

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

          // 部分服务商在最后一个 chunk 附带 usage
          final usage = json['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? promptTokens;
            completionTokens = (usage['completion_tokens'] as num?)?.toInt() ?? completionTokens;
          }
        } catch (_) {
          // 忽略无法解析的行，保证容错。
        }
      }
    } finally {
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
