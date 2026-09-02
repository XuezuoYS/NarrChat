import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/services/ai_service.dart';

/// `AiService.responses`（Responses API 适配器）单元测试。
///
/// 覆盖：请求路径 `/responses`、非流式 output 数组解析（reasoning /
/// message / function_call / usage）、流式事件映射（正文 / 思考 / 
/// 工具参数分块 / completed usage）、事件与字段容错。
void main() {
  http.Response jsonResponse(String body) => http.Response.bytes(
        utf8.encode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  http.Response sseResponse(List<String> lines) => http.Response.bytes(
        utf8.encode(lines.join('\n')),
        200,
        headers: {'content-type': 'text/event-stream; charset=utf-8'},
      );

  group('responses 非流式', () {
    test('输出数组：reasoning / message / function_call / usage 映射', () async {
      late Uri requestedUri;
      final ai = AiService(
        client: MockClient((request) async {
          requestedUri = request.url;
          return jsonResponse('''
{
  "id": "resp_1",
  "output": [
    {
      "type": "reasoning",
      "id": "rs_1",
      "summary": [{"type": "output_text", "text": "先分析状态"}]
    },
    {
      "type": "message",
      "id": "msg_1",
      "role": "assistant",
      "content": [{"type": "output_text", "text": "## 剧情演绎\\n主角踏入主殿。\\n\\n## 推荐行动\\n行礼"}]
    },
    {
      "type": "function_call",
      "id": "fc_1",
      "call_id": "fc_1",
      "name": "narrchat_setLine",
      "arguments": "{\\"section\\": \\"worldState\\", \\"anchor\\": \\"a\\", \\"newLine\\": \\"b\\"}"
    }
  ],
  "usage": {"input_tokens": 100, "output_tokens": 42, "output_tokens_details": {"reasoning_tokens": 7}}
}
''');
        }),
      );

      final result = await ai.responses(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        requestBody: const {
          'model': 'deepseek-v4-pro',
          'instructions': 'x',
          'input': [],
          'stream': false,
        },
      );

      expect(requestedUri.path, '/responses');
      expect(result.reasoningContent, '先分析状态');
      expect(result.content, contains('主角踏入主殿'));
      expect(result.toolCalls, hasLength(1));
      final tc = result.toolCalls.first;
      expect(tc.name, 'narrchat_setLine');
      expect(tc.arguments['newLine'], 'b');
      expect(result.promptTokens, 100);
      expect(result.completionTokens, 42);
    });

    test('arguments 为对象形态同样解析；错误对象转 AiException', () async {
      var first = true;
      final ai = AiService(
        client: MockClient((request) async {
          if (first) {
            first = false;
            return jsonResponse(
              '{"output":[{"type":"function_call","id":"f1","name":"x",'
              '"arguments":{"query":"q"}}],"usage":{}}',
            );
          }
          return jsonResponse('{"error": {"message": "boom"}}');
        }),
      );

      final ok = await ai.responses(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'k',
        requestBody: const {'model': 'm', 'input': []},
      );
      expect(ok.toolCalls.single.arguments['query'], 'q');

      await expectLater(
        ai.responses(
          apiBaseUrl: 'https://api.deepseek.com',
          apiKey: 'k',
          requestBody: const {'model': 'm', 'input': []},
        ),
        throwsA(isA<AiException>()),
      );
    });
  });

  group('responses 流式', () {
    test('正文/思考增量、工具参数分块、completed usage', () async {
      final ai = AiService(
        client: MockClient((request) async {
          final lines = [
            'data: {"type":"response.created"}',
            'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","name":"narrchat_setLine"}}',
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"sec"}',
            'data: {"type":"response.reasoning_summary_text.delta","delta":"先看状态"}',
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"tion\\":\\"worldState\\"}"}',
            'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n正"}',
            'data: {"type":"response.output_text.delta","delta":"文"}',
            'data: {"type":"response.completed","response":{"usage":{"input_tokens":7,"output_tokens":3}}}',
            '',
          ];
          return sseResponse(lines);
        }),
      );

      final chunks = <String>[];
      final result = await ai.responses(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        requestBody: const {'model': 'm', 'input': [], 'stream': true},
        stream: true,
        onChunk: (c) {
          if (c.contentDelta.isNotEmpty) chunks.add(c.contentDelta);
        },
      );

      expect(chunks.join(), '## 剧情演绎\n正' '文');
      expect(result.content, '## 剧情演绎\n正' '文');
      expect(result.reasoningContent, '先看状态');
      expect(result.toolCalls.single.name, 'narrchat_setLine');
      expect(
        result.toolCalls.single.arguments,
        {'section': 'worldState'},
      );
      expect(result.promptTokens, 7);
      expect(result.completionTokens, 3);
    });

    test('未知事件与非法行忽略；response.failed 转 AiException', () async {
      final ai = AiService(
        client: MockClient((request) async {
          final lines = [
            'data: {"type":"response.created"}',
            'data: {"type": 非法, "x":1}',
            'not a data line',
            'data: {"type":"response.failed","response":{"error":{"message":"boom"}}}',
            '',
          ];
          return sseResponse(lines);
        }),
      );

      await expectLater(
        ai.responses(
          apiBaseUrl: 'https://api.deepseek.com',
          apiKey: 'key',
          requestBody: const {'model': 'm', 'input': []},
          stream: true,
        ),
        throwsA(isA<AiException>()),
      );
    });

    test('多工具交错增量：三个 function_call 各自累积参数（回归）', () async {
      final ai = AiService(
        client: MockClient((request) async {
          final lines = [
            'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n正文"}',
            'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_2","name":"narrchat_setWorldState"}}',
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_2","delta":"{\\"content\\":\\"- 地点：主峰\\n- 天气：晴\\"}"}',
            'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_3","name":"narrchat_advanceTime"}}',
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_3","delta":"{\\"time\\":\\"第一天 申时\\"}"}',
            'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_4","name":"narrchat_setMemorySummary"}}',
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_4","delta":"{\\"content\\":\\"- 第2轮｜日期：第一天 申时｜前往主峰\\"}"}',
            'data: {"type":"response.completed","response":{"id":"r2","usage":{"input_tokens":1,"output_tokens":1}}}',
            '',
          ];
          return sseResponse(lines);
        }),
      );

      final result = await ai.responses(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        requestBody: const {'model': 'm', 'input': []},
        stream: true,
      );

      expect(result.content, contains('正文'));
      expect(result.toolCalls, hasLength(3));
      expect(result.toolCalls[0].name, 'narrchat_setWorldState');
      expect(result.toolCalls[0].arguments['content'], contains('主峰'));
      expect(result.toolCalls[1].arguments['time'], '第一天 申时');
      expect(result.toolCalls[2].arguments['content'], contains('第2轮'));
    });
  });

  group('responses 截断（incomplete）与失败（failed）', () {
    test('流式触顶：保留截断前的正文与工具参数并标记 incomplete', () async {
      final ai = AiService(
        client: MockClient((request) async => sseResponse([
          'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n写到一半"}',
          'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","name":"narrchat_editSection"}}',
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"section\\":\\"worldState\\""}',
          'data: {"type":"response.incomplete","response":{"id":"r9","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":5,"output_tokens":4096}}}',
          '',
        ])),
      );

      final result = await ai.responses(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        requestBody: const {'model': 'm', 'input': []},
        stream: true,
      );

      // 关键：不抛异常——上层按语义补救（旧行为 = 整轮失败）。
      expect(result.incomplete, isTrue);
      expect(result.incompleteReason, 'max_output_tokens');
      expect(result.content, contains('写到一半'));
      expect(result.toolCalls, hasLength(1));
      // 参数 JSON 未闭合 → 标记为无法解析（不得当成合法空参数调用）。
      expect(result.toolCalls.single.argumentsUnparsable, isTrue);
      expect(result.completionTokens, 4096);
      expect(result.responseId, 'r9');
    });

    test('非流式 status=incomplete → 同样标记并保留部分结果', () async {
      final ai = AiService(
        client: MockClient((request) async => jsonResponse('''
{
  "id": "resp_9",
  "status": "incomplete",
  "incomplete_details": {"reason": "max_output_tokens"},
  "output": [{"type": "message", "content": [{"type": "output_text", "text": "半截正文"}]}],
  "usage": {"input_tokens": 3, "output_tokens": 8}
}
''')),
      );

      final result = await ai.responses(
        apiBaseUrl: 'https://api.deepseek.com',
        apiKey: 'key',
        requestBody: const {'model': 'm', 'input': []},
      );

      expect(result.incomplete, isTrue);
      expect(result.incompleteReason, 'max_output_tokens');
      expect(result.content, '半截正文');
    });

    test('failed 事件缺 error 字段：文案仍可读，绝不出现 "null"', () async {
      final ai = AiService(
        client: MockClient((request) async => sseResponse([
          'data: {"type":"response.failed","response":{"id":"r1"}}',
          '',
        ])),
      );

      await expectLater(
        ai.responses(
          apiBaseUrl: 'https://api.deepseek.com',
          apiKey: 'key',
          requestBody: const {'model': 'm', 'input': []},
          stream: true,
        ),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('服务端未给出原因'),
          ),
        ),
      );
    });
  });
}
