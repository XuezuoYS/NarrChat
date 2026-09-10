import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/services/ai_service.dart';

/// `AiService` 的 Token 用量解析：输入 / 输出 / **缓存命中输入**三桶，
/// 以及「响应未带该字段 → null（无数据）」的语义（不得回落成 0）。
///
/// 覆盖 Chat 与 Responses 两条线路的流式 / 非流式，以及 DeepSeek
/// （`prompt_cache_hit_tokens`）与 OpenAI（`*_tokens_details.cached_tokens`）
/// 两种缓存字段形态。
http.Response _json(String body) => http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _sse(List<String> lines) => http.Response.bytes(
      utf8.encode(lines.join('\n')),
      200,
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );

const _chatBody = {'model': 'test', 'messages': [], 'stream': false};
const _responsesBody = {
  'model': 'test',
  'instructions': 'x',
  'input': [],
  'stream': false,
};

AiService _serviceReturning(http.Response response) =>
    AiService(client: MockClient((_) async => response));

void main() {
  group('Chat 线路', () {
    test('非流式：DeepSeek 的 prompt_cache_hit_tokens', () async {
      final ai = _serviceReturning(
        _json(
          '{"choices":[{"message":{"content":"正文"}}],'
          '"usage":{"prompt_tokens":10000,"completion_tokens":500,'
          '"prompt_cache_hit_tokens":4940,"prompt_cache_miss_tokens":5060}}',
        ),
      );

      final result = await ai.chat(
        apiBaseUrl: 'https://example.com',
        apiKey: 'key',
        requestBody: _chatBody,
      );

      expect(result.promptTokens, 10000);
      expect(result.completionTokens, 500);
      expect(result.cachedTokensIn, 4940);
    });

    test('非流式：OpenAI 的 prompt_tokens_details.cached_tokens', () async {
      final ai = _serviceReturning(
        _json(
          '{"choices":[{"message":{"content":"正文"}}],'
          '"usage":{"prompt_tokens":800,"completion_tokens":20,'
          '"prompt_tokens_details":{"cached_tokens":640}}}',
        ),
      );

      final result = await ai.chat(
        apiBaseUrl: 'https://example.com',
        apiKey: 'key',
        requestBody: _chatBody,
      );

      expect(result.promptTokens, 800);
      expect(result.cachedTokensIn, 640);
    });

    test('非流式：服务商未返回缓存字段 → cachedTokensIn 为 null（非 0）', () async {
      final ai = _serviceReturning(
        _json(
          '{"choices":[{"message":{"content":"正文"}}],'
          '"usage":{"prompt_tokens":800,"completion_tokens":20}}',
        ),
      );

      final result = await ai.chat(
        apiBaseUrl: 'https://example.com',
        apiKey: 'key',
        requestBody: _chatBody,
      );

      expect(result.cachedTokensIn, isNull);
    });

    test('非流式：整个 usage 缺失 → 三桶全为 null，不回落 0', () async {
      final ai = _serviceReturning(
        _json('{"choices":[{"message":{"content":"正文"}}]}'),
      );

      final result = await ai.chat(
        apiBaseUrl: 'https://example.com',
        apiKey: 'key',
        requestBody: _chatBody,
      );

      expect(result.promptTokens, isNull);
      expect(result.completionTokens, isNull);
      expect(result.cachedTokensIn, isNull);
    });

    test('流式：末尾 chunk 的 usage 三桶一并解析', () async {
      final ai = _serviceReturning(
        _sse([
          'data: {"choices":[{"delta":{"content":"## 剧情演绎\\n正文"}}]}',
          'data: {"choices":[{"delta":{}}],'
              '"usage":{"prompt_tokens":1200,"completion_tokens":300,'
              '"prompt_cache_hit_tokens":900}}',
          'data: [DONE]',
          '',
        ]),
      );

      final result = await ai.chat(
        apiBaseUrl: 'https://example.com',
        apiKey: 'key',
        requestBody: const {'model': 'test', 'messages': [], 'stream': true},
        stream: true,
      );

      expect(result.promptTokens, 1200);
      expect(result.completionTokens, 300);
      expect(result.cachedTokensIn, 900);
      expect(result.content, contains('正文'));
    });

    test('流式：全程无 usage → 三桶全为 null', () async {
      final ai = _serviceReturning(
        _sse([
          'data: {"choices":[{"delta":{"content":"正文"}}]}',
          'data: [DONE]',
          '',
        ]),
      );

      final result = await ai.chat(
        apiBaseUrl: 'https://example.com',
        apiKey: 'key',
        requestBody: const {'model': 'test', 'messages': [], 'stream': true},
        stream: true,
      );

      expect(result.promptTokens, isNull);
      expect(result.completionTokens, isNull);
      expect(result.cachedTokensIn, isNull);
    });
  });

  group('Responses 线路', () {
    test('非流式：input_tokens_details.cached_tokens', () async {
      final ai = _serviceReturning(
        _json(
          '{"id":"resp_1","output":[{"type":"message","content":'
          '[{"type":"output_text","text":"正文"}]}],'
          '"usage":{"input_tokens":2000,"output_tokens":400,'
          '"input_tokens_details":{"cached_tokens":1536}}}',
        ),
      );

      final result = await ai.responses(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        requestBody: _responsesBody,
      );

      expect(result.promptTokens, 2000);
      expect(result.completionTokens, 400);
      expect(result.cachedTokensIn, 1536);
    });

    test('非流式：无 usage → 三桶全为 null', () async {
      final ai = _serviceReturning(
        _json('{"id":"resp_1","output":[]}'),
      );

      final result = await ai.responses(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        requestBody: _responsesBody,
      );

      expect(result.promptTokens, isNull);
      expect(result.completionTokens, isNull);
      expect(result.cachedTokensIn, isNull);
    });

    test('流式：response.completed 的 usage 携带缓存命中', () async {
      final ai = _serviceReturning(
        _sse([
          'data: {"type":"response.output_text.delta","delta":"正文"}',
          'data: {"type":"response.completed","response":{"id":"resp_1",'
              '"usage":{"input_tokens":1000,"output_tokens":120,'
              '"input_tokens_details":{"cached_tokens":768}}}}',
          '',
        ]),
      );

      final result = await ai.responses(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        requestBody: const {
          'model': 'test',
          'instructions': 'x',
          'input': [],
          'stream': true,
        },
        stream: true,
      );

      expect(result.promptTokens, 1000);
      expect(result.completionTokens, 120);
      expect(result.cachedTokensIn, 768);
    });

    test('流式：先到的中间事件用量不会被后续无用量事件清空', () async {
      final ai = _serviceReturning(
        _sse([
          'data: {"type":"response.created","response":{"id":"resp_1",'
              '"usage":{"input_tokens":1000,"output_tokens":0,'
              '"input_tokens_details":{"cached_tokens":512}}}}',
          'data: {"type":"response.output_text.delta","delta":"正文"}',
          'data: {"type":"response.completed","response":{"id":"resp_1"}}',
          '',
        ]),
      );

      final result = await ai.responses(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        requestBody: const {
          'model': 'test',
          'instructions': 'x',
          'input': [],
          'stream': true,
        },
        stream: true,
      );

      expect(result.promptTokens, 1000);
      expect(result.cachedTokensIn, 512);
    });
  });

  group('addTokenUsage', () {
    test('跳过 null 桶：全 null 保持 null，不变成 0', () {
      expect(addTokenUsage(null, null), isNull);
      expect(addTokenUsage(3, null), 3);
      expect(addTokenUsage(null, 3), 3);
      expect(addTokenUsage(3, 4), 7);
      expect(addTokenUsage(0, 0), 0, reason: '0 是真实数据，继续累加');
    });
  });
}
