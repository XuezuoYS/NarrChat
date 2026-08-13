import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:narrchat/services/ai_service.dart';

/// 可控 http 客户端：send 立即返回 200 + 挂起的响应体，模拟
/// 「服务器已回响应头、正文仍在生成中」的非流式请求。
class _PendingBodyClient extends http.BaseClient {
  final StreamController<List<int>> body = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(body.stream, 200);
  }
}

/// 立即返回完整 JSON 正文的客户端，用于验证正常路径不受影响。
class _ImmediateClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonEncode({
      'choices': [
        {
          'message': {
            'content': '## 剧情演绎\n非流式正常正文\n'
                '## 推荐行动\n\n'
                '## 当前时间\n第一天 午时\n'
                '## 世界状态\n\n'
                '## 角色状态\n\n'
                '## 记忆总结\n',
          }
        }
      ],
      'usage': {'prompt_tokens': 3, 'completion_tokens': 5},
    });
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

/// 可控 SSE 流客户端：测试可随时向响应体追加数据行，模拟「停止后仍到达残留数据」。
class _SseControllerClient extends http.BaseClient {
  final StreamController<List<int>> body = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(body.stream, 200);
  }
}

/// 模拟 SSE 流式响应：依次返回 content / usage / [DONE] 数据行。
class _SseClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final lines = [
      'data: {"choices":[{"delta":{"content":"## 剧情演绎\\n"}}]}',
      'data: {"choices":[{"delta":{"content":"剧情正文"}}]}',
      'data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":3,"completion_tokens":5}}',
      'data: [DONE]',
      '',
    ];
    return http.StreamedResponse(
      Stream.value(utf8.encode(lines.join('\n'))),
      200,
    );
  }
}

void main() {
  Map<String, dynamic> body({bool stream = false}) => {
    'model': 'test',
    'messages': [
      {'role': 'system', 'content': '系统提示'},
      {'role': 'user', 'content': '用户输入'},
    ],
    'stream': stream,
  };

  test('非流式：生成中停止会及时中止（无需等服务器返回正文）', () async {
    final client = _PendingBodyClient();
    final ai = AiService(client: client);

    var cancelled = false;
    final chatFuture = ai.chat(
      apiBaseUrl: 'https://example.com',
      apiKey: 'test-key',
      requestBody: body(stream: false),
      stream: false,
      isCancelled: () => cancelled,
    );

    // 等待请求发出（响应头已就绪、正文挂起），随后用户点击停止。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    cancelled = true;

    // 取消应在 100ms 轮询周期内生效（而非等响应体完成）。
    await expectLater(
      chatFuture,
      throwsA(isA<AiCancelledException>()),
    );

    await client.body.close();
  });

  test('非流式：未取消时正常返回解析结果', () async {
    final ai = AiService(client: _ImmediateClient());

    final result = await ai.chat(
      apiBaseUrl: 'https://example.com',
      apiKey: 'test-key',
      requestBody: body(stream: false),
      stream: false,
      isCancelled: () => false,
    );

    expect(result.content, contains('非流式正常正文'));
    expect(result.promptTokens, 3);
    expect(result.completionTokens, 5);
  });

  test('流式：响应体挂起时停止生成及时生效（不会永久卡住）', () async {
    final client = _PendingBodyClient();
    final ai = AiService(client: client);

    var cancelled = false;
    final chatFuture = ai.chat(
      apiBaseUrl: 'https://example.com',
      apiKey: 'test-key',
      requestBody: body(stream: true),
      stream: true,
      isCancelled: () => cancelled,
    );

    // 服务器已回响应头、正文挂起；用户点击停止生成。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    cancelled = true;

    // 100ms 轮询周期内即中止，无需等服务器返回 / 超时。
    await expectLater(
      chatFuture,
      throwsA(isA<AiCancelledException>()),
    );

    await client.body.close();
  });

  test('流式：服务器挂起无数据时按请求超时兜底（不会永久卡住）', () async {
    final client = _PendingBodyClient();
    final ai = AiService(
      client: client,
      requestTimeout: const Duration(milliseconds: 200),
    );

    final chatFuture = ai.chat(
      apiBaseUrl: 'https://example.com',
      apiKey: 'test-key',
      requestBody: body(stream: true),
      stream: true,
      isCancelled: () => false,
    );

    await expectLater(
      chatFuture,
      throwsA(isA<AiException>()),
    );

    await client.body.close();
  });

  test('流式：正常路径逐块回调并返回聚合内容与 usage', () async {
    final ai = AiService(client: _SseClient());
    final deltas = <String>[];

    final result = await ai.chat(
      apiBaseUrl: 'https://example.com',
      apiKey: 'test-key',
      requestBody: body(stream: true),
      stream: true,
      onChunk: (c) {
        if (!c.done && c.contentDelta.isNotEmpty) deltas.add(c.contentDelta);
      },
      isCancelled: () => false,
    );

    expect(result.content, contains('剧情正文'));
    expect(result.promptTokens, 3);
    expect(result.completionTokens, 5);
    expect(deltas.join(), contains('剧情正文'));
  });

  test('流式：停止后残留数据行不再触发 onChunk（僵尸流已中止）', () async {
    final client = _SseControllerClient();
    final ai = AiService(client: client);
    var cancelled = false;
    final deltas = <String>[];
    final chatFuture = ai.chat(
      apiBaseUrl: 'https://example.com',
      apiKey: 'test-key',
      requestBody: body(stream: true),
      stream: true,
      onChunk: (c) {
        if (c.contentDelta.isNotEmpty) deltas.add(c.contentDelta);
      },
      isCancelled: () => cancelled,
    );

    // 正常流式阶段：推送一块内容。
    client.body.add(
      utf8.encode('data: {"choices":[{"delta":{"content":"AB"}}]}\n'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(deltas, ['AB']);

    // 用户停止后，服务器仍推来残留数据行——不得再触发 onChunk（注入下一轮）。
    cancelled = true;
    // 预注册结果期望（错误可能在 50ms 等待期内已触发，须在触发前挂上监听）。
    final expectation = expectLater(
      chatFuture,
      throwsA(isA<AiCancelledException>()),
    );
    client.body.add(
      utf8.encode('data: {"choices":[{"delta":{"content":"ZOMBIE"}}]}\n'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 取消在轮询周期内生效（抛 AiCancelledException）。
    await expectation;
    expect(deltas, ['AB'], reason: '停止后残留数据不得再触发 onChunk');

    await client.body.close();
  });
}
