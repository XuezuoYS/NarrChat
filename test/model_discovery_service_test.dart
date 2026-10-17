import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narrchat/models/api_type.dart';
import 'package:narrchat/services/model_discovery_service.dart';

/// 构造 JSON 响应（按 UTF-8 编码，模拟真实网关返回中文模型名）。
http.Response _jsonResponse(Object body, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// 构造原始文本响应（用于非 JSON / 错误体场景）。
http.Response _textResponse(String body, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(body),
      status,
      headers: {'content-type': 'text/plain; charset=utf-8'},
    );

void main() {
  const baseUrl = 'https://gw.example.com';

  /// 捕获一次失败的 [ModelDiscoveryException]（成功时直接判失败）。
  Future<ModelDiscoveryException> captureFailure(
    Future<Object?> Function() run,
  ) async {
    try {
      await run();
    } on ModelDiscoveryException catch (e) {
      return e;
    }
    fail('应抛出 ModelDiscoveryException');
  }

  group('ModelDiscoveryService 请求', () {
    test('GET {baseUrl}/models：去掉尾部斜杠、携带 Bearer Key', () async {
      late http.Request captured;
      final service = ModelDiscoveryService(
        client: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'data': [
              {'id': 'gpt-4o'},
            ],
          });
        }),
      );

      final models = await service.fetchModels(
        baseUrl: '$baseUrl/v1/',
        apiType: ApiType.openAiCompatible,
        apiKey: 'sk-test',
      );

      expect(captured.method, 'GET');
      expect(captured.url.toString(), 'https://gw.example.com/v1/models');
      expect(captured.headers['authorization'], 'Bearer sk-test');
      expect(captured.headers['accept'], 'application/json');
      expect(models.single.id, 'gpt-4o');
    });

    test('无 API Key 时不带鉴权头', () async {
      late http.Request captured;
      final service = ModelDiscoveryService(
        client: MockClient((request) async {
          captured = request;
          return _jsonResponse({
            'data': [
              {'id': 'm'},
            ],
          });
        }),
      );
      await service.fetchModels(
        baseUrl: baseUrl,
        apiType: ApiType.openAiCompatible,
      );
      expect(captured.headers.containsKey('authorization'), isFalse);
    });

    test('协议不支持查询模型列表：直接拒绝且不发请求', () async {
      var called = false;
      final service = ModelDiscoveryService(
        client: MockClient((_) async {
          called = true;
          return _jsonResponse({'data': []});
        }),
      );
      const legacy = ApiType(
        id: 'legacy',
        displayName: '旧协议',
        supportsStreaming: true,
        supportsThinking: true,
        supportsSearch: true,
        requestRules: RequestParamRules([]),
      );
      final failure = await captureFailure(
        () => service.fetchModels(baseUrl: baseUrl, apiType: legacy),
      );
      expect(failure.kind, ModelDiscoveryErrorKind.unsupported);
      expect(called, isFalse);
    });

    test('请求超时：按网络错误上报', () async {
      final service = ModelDiscoveryService(
        timeout: const Duration(milliseconds: 10),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return _jsonResponse({'data': []});
        }),
      );
      final failure = await captureFailure(
        () => service.fetchModels(
          baseUrl: baseUrl,
          apiType: ApiType.openAiCompatible,
        ),
      );
      expect(failure.kind, ModelDiscoveryErrorKind.network);
      expect(failure.describe(), contains('超时'));
    });

    test('空 Base URL 属于调用错误（UI 已前置提示）', () async {
      final service = ModelDiscoveryService(
        client: MockClient((_) async => _jsonResponse({'data': []})),
      );
      await expectLater(
        service.fetchModels(
          baseUrl: '   ',
          apiType: ApiType.openAiCompatible,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('ModelDiscoveryService 响应解析', () {
    test('data 数组：名称 / 最大输出 / 能力字段按接口读取', () async {
      final service = ModelDiscoveryService(
        client: MockClient(
          (_) async => _jsonResponse({
            'data': [
              {
                'id': 'a-model',
                'name': 'A Model',
                'max_output_tokens': 8192,
                'architecture': {
                  'input_modalities': ['text', 'image'],
                },
                'supported_parameters': [
                  'temperature',
                  'reasoning',
                  'reasoning_effort',
                ],
                'reasoning_effort_options': ['low', 'high'],
              },
              {'id': 'b-model', 'max_tokens': 2048},
            ],
          }),
        ),
      );
      final models = await service.fetchModels(
        baseUrl: baseUrl,
        apiType: ApiType.openAiCompatible,
      );

      expect(models, hasLength(2));
      final a = models.first;
      expect(a.id, 'a-model');
      expect(a.name, 'A Model');
      expect(a.maxTokens, 8192);
      expect(a.supportsThinking, isTrue);
      expect(a.supportsVision, isTrue);
      expect(a.reasoningEffortOptions, ['low', 'high']);

      final b = models.last;
      expect(b.name, 'b-model'); // 缺展示名回退模型名
      expect(b.maxTokens, 2048);
      expect(b.supportsThinking, isNull); // 接口没说 ⇒ 留空
      expect(b.supportsVision, isNull);
      expect(b.reasoningEffortOptions, isNull);
    });

    test('能力字段缺省：导入时回落默认值（思考开 / 识图关 / 内置档位）', () async {
      final service = ModelDiscoveryService(
        client: MockClient(
          (_) async => _jsonResponse({
            'data': [
              {'id': 'plain'},
            ],
          }),
        ),
      );
      final model = (await service.fetchModels(
        baseUrl: baseUrl,
        apiType: ApiType.openAiCompatible,
      )).single.toAiModel();

      expect(model.id, 'plain');
      expect(model.supportsThinking, isTrue);
      expect(model.supportsVision, isFalse);
      expect(model.reasoningEffortOptions, isEmpty); // 空列表 ⇒ 内置默认档位
      expect(model.reasoningEffort, 'high');
      expect(model.temperature, 1.0);
      expect(model.maxTokens, isNull);
    });

    test('models 映射形态：对象键即模型名，非对象条目忽略', () async {
      final service = ModelDiscoveryService(
        client: MockClient(
          (_) async => _jsonResponse({
            'models': {
              'deepseek-chat': {
                'id': 'canonical',
                'display_name': 'DeepSeek Chat',
              },
              'meta': 'not-a-model',
            },
          }),
        ),
      );
      final models = await service.fetchModels(
        baseUrl: baseUrl,
        apiType: ApiType.openAiCompatible,
      );
      expect(models, hasLength(1));
      expect(models.single.id, 'deepseek-chat');
      expect(models.single.name, 'DeepSeek Chat');
    });

    test('缺模型名的条目跳过，不丢整份列表', () async {
      final service = ModelDiscoveryService(
        client: MockClient(
          (_) async => _jsonResponse({
            'data': [
              <String, dynamic>{},
              {'id': '   '},
              {'id': 'ok', 'name': 'OK'},
            ],
          }),
        ),
      );
      final models = await service.fetchModels(
        baseUrl: baseUrl,
        apiType: ApiType.openAiCompatible,
      );
      expect(models.map((m) => m.id), ['ok']);
    });

    test('识图与思考的多种写法都能识别', () async {
      final service = ModelDiscoveryService(
        client: MockClient(
          (_) async => _jsonResponse({
            'data': [
              {
                'id': 'vision-1',
                'modalities': {
                  'input': ['text', 'IMAGE'],
                },
              },
              {
                'id': 'vision-2',
                'input_modalities': ['text'],
              },
              {
                'id': 'thinking-1',
                'supported_parameters': ['temperature'],
              },
              {
                'id': 'thinking-2',
                'reasoning': {'supported': true},
              },
              {
                'id': 'thinking-3',
                'reasoning': {
                  'efforts': [
                    {'id': 'low'},
                    {'id': 'high'},
                  ],
                },
              },
            ],
          }),
        ),
      );
      final models = await service.fetchModels(
        baseUrl: baseUrl,
        apiType: ApiType.openAiCompatible,
      );
      final byId = {for (final model in models) model.id: model};
      expect(byId['vision-1']!.supportsVision, isTrue);
      expect(byId['vision-2']!.supportsVision, isFalse);
      expect(byId['thinking-1']!.supportsThinking, isFalse);
      expect(byId['thinking-2']!.supportsThinking, isTrue);
      expect(byId['thinking-3']!.supportsThinking, isTrue);
      expect(byId['thinking-3']!.reasoningEffortOptions, ['low', 'high']);
    });
  });

  group('ModelDiscoveryService 失败信息', () {
    test('HTTP 401：带状态码与响应体，通知文案包含两者', () async {
      final service = ModelDiscoveryService(
        client: MockClient(
          (_) async => _textResponse(
            '{"error":{"message":"invalid key"}}',
            status: 401,
          ),
        ),
      );
      final failure = await captureFailure(
        () => service.fetchModels(
          baseUrl: baseUrl,
          apiType: ApiType.openAiCompatible,
          apiKey: 'bad',
        ),
      );

      expect(failure.kind, ModelDiscoveryErrorKind.httpStatus);
      expect(failure.statusCode, 401);
      final text = failure.describe();
      expect(text, contains('HTTP 401'));
      expect(text, contains('请检查 API Key'));
      expect(text, contains('invalid key'));
    });

    test('非 JSON：上报「响应不是 JSON」并附带响应体', () async {
      final service = ModelDiscoveryService(
        client: MockClient(
          (_) async => _textResponse('<html>bad gateway</html>'),
        ),
      );
      final failure = await captureFailure(
        () => service.fetchModels(
          baseUrl: baseUrl,
          apiType: ApiType.openAiCompatible,
        ),
      );
      expect(failure.kind, ModelDiscoveryErrorKind.notJson);
      expect(failure.describe(), contains('bad gateway'));
    });

    test('空列表视为失败（不弹空对话框）', () async {
      final service = ModelDiscoveryService(
        client: MockClient((_) async => _jsonResponse({'data': []})),
      );
      final failure = await captureFailure(
        () => service.fetchModels(
          baseUrl: baseUrl,
          apiType: ApiType.openAiCompatible,
        ),
      );
      expect(failure.kind, ModelDiscoveryErrorKind.empty);
    });

    test('未知形态（既无 data 数组也无 models 对象）', () async {
      final service = ModelDiscoveryService(
        client: MockClient((_) async => _jsonResponse({'foo': 1})),
      );
      final failure = await captureFailure(
        () => service.fetchModels(
          baseUrl: baseUrl,
          apiType: ApiType.openAiCompatible,
        ),
      );
      expect(failure.kind, ModelDiscoveryErrorKind.unexpectedShape);
    });

    test('响应体超过上限：tooLarge', () async {
      final big = 'x' * (ModelDiscoveryService.maxResponseBytes + 1);
      final service = ModelDiscoveryService(
        client: MockClient((_) async => _textResponse(big)),
      );
      final failure = await captureFailure(
        () => service.fetchModels(
          baseUrl: baseUrl,
          apiType: ApiType.openAiCompatible,
        ),
      );
      expect(failure.kind, ModelDiscoveryErrorKind.tooLarge);
    });

    test('超长响应体在通知里截断并标注', () async {
      final body = 'e' * (ModelDiscoveryService.noticeBodyLimit + 50);
      final service = ModelDiscoveryService(
        client: MockClient((_) async => _textResponse(body, status: 500)),
      );
      final failure = await captureFailure(
        () => service.fetchModels(
          baseUrl: baseUrl,
          apiType: ApiType.openAiCompatible,
        ),
      );
      expect(failure.describe(), contains('已截断'));
      expect(
        failure.body!.length,
        lessThanOrEqualTo(ModelDiscoveryService.noticeBodyLimit + 8),
      );
    });
  });
}
