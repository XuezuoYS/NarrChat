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

void main() {
  test('非流式：生成中停止会及时中止（无需等服务器返回正文）', () async {
    final client = _PendingBodyClient();
    final ai = AiService(client: client);

    var cancelled = false;
    final chatFuture = ai.chat(
      apiBaseUrl: 'https://example.com',
      apiKey: 'test-key',
      systemPrompt: '系统提示',
      userPrompt: '用户输入',
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
      systemPrompt: '系统提示',
      userPrompt: '用户输入',
      stream: false,
      isCancelled: () => false,
    );

    expect(result.content, contains('非流式正常正文'));
    expect(result.promptTokens, 3);
    expect(result.completionTokens, 5);
  });
}
