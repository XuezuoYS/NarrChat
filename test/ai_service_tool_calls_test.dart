import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/services/ai_service.dart';

http.Response _jsonResponse(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('AiService 非流式 tool_calls', () {
    test('解析 message.tool_calls 与参数 JSON', () async {
      final ai = AiService(
        client: MockClient((request) async {
          return _jsonResponse('''
{
  "choices": [
    {
      "message": {
        "content": null,
        "tool_calls": [
          {
            "id": "call_1",
            "type": "function",
            "function": {
              "name": "web_search",
              "arguments": "{\\"query\\": \\"青云宗\\"}"
            }
          }
        ]
      }
    }
  ],
  "usage": {"prompt_tokens": 5, "completion_tokens": 2}
}
''');
        }),
      );

      final result = await ai.chat(
        apiBaseUrl: 'https://example.com',
        apiKey: 'key',
        requestBody: const {'model': 'test', 'messages': [], 'stream': false},
      );

      expect(result.toolCalls, hasLength(1));
      expect(result.toolCalls.first.id, 'call_1');
      expect(result.toolCalls.first.name, 'web_search');
      expect(result.toolCalls.first.arguments['query'], '青云宗');
      expect(result.promptTokens, 5);
      expect(result.completionTokens, 2);
    });

    test('无 tool_calls 时返回空列表', () async {
      final ai = AiService(
        client: MockClient((request) async {
          return _jsonResponse(
            '{"choices":[{"message":{"content":"正文"}}],"usage":{}}',
          );
        }),
      );

      final result = await ai.chat(
        apiBaseUrl: 'https://example.com',
        apiKey: 'key',
        requestBody: const {'model': 'test', 'messages': [], 'stream': false},
      );

      expect(result.content, '正文');
      expect(result.toolCalls, isEmpty);
    });
  });

  group('AiService 流式 tool_calls', () {
    test('累积分块 tool_calls delta', () async {
      final ai = AiService(
        client: MockClient((request) async {
          final lines = [
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":""}}]}}]}',
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"query\\":"}}]}}]}',
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"青云宗\\"}"}}]}}]}',
            'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
            'data: {"usage":{"prompt_tokens":3,"completion_tokens":1}}',
            'data: [DONE]',
            '',
          ];
          return http.Response.bytes(
            utf8.encode(lines.join('\n')),
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }),
      );

      final result = await ai.chat(
        apiBaseUrl: 'https://example.com',
        apiKey: 'key',
        requestBody: const {'model': 'test', 'messages': [], 'stream': true},
        stream: true,
      );

      expect(result.toolCalls, hasLength(1));
      expect(result.toolCalls.first.id, 'call_1');
      expect(result.toolCalls.first.name, 'web_search');
      expect(result.toolCalls.first.arguments['query'], '青云宗');
      expect(result.promptTokens, 3);
      expect(result.completionTokens, 1);
    });

    test('流式无工具调用时 toolCalls 为空', () async {
      final ai = AiService(
        client: MockClient((request) async {
          final lines = [
            'data: {"choices":[{"delta":{"content":"## 剧情演绎\\n正文"}}]}',
            'data: {"choices":[{"delta":{},"usage":{"prompt_tokens":1,"completion_tokens":1}}]}',
            'data: [DONE]',
            '',
          ];
          return http.Response.bytes(
            utf8.encode(lines.join('\n')),
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }),
      );

      final result = await ai.chat(
        apiBaseUrl: 'https://example.com',
        apiKey: 'key',
        requestBody: const {'model': 'test', 'messages': [], 'stream': true},
        stream: true,
      );

      expect(result.content, contains('剧情演绎'));
      expect(result.toolCalls, isEmpty);
    });
  });
}
