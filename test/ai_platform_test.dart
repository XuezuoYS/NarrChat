import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/models/api_type.dart';
import 'package:narrchat/services/ai_request_body_builder.dart';

AiRequestValues _values({
  double temperature = 1.0,
  bool thinking = true,
  String reasoningEffort = 'high',
  int? maxTokens = 4096,
  bool stream = true,
  List<Map<String, dynamic>>? tools,
}) {
  return AiRequestValues(
    model: 'deepseek-v4-pro',
    messages: const [
      {'role': 'system', 'content': '系统'},
      {'role': 'user', 'content': '用户'},
    ],
    temperature: temperature,
    thinking: thinking,
    reasoningEffort: reasoningEffort,
    maxTokens: maxTokens,
    stream: stream,
    tools: tools,
  );
}

void main() {
  group('ApiType', () {
    test('openAiCompatible：能力表与说明齐全，byId 未知回退', () {
      final apiType = ApiType.openAiCompatible;
      expect(apiType.id, 'openai-compatible');
      expect(apiType.supportsStreaming, isTrue);
      expect(apiType.supportsThinking, isTrue);
      expect(apiType.supportsSearch, isTrue);
      expect(apiType.temperatureNote, isNotEmpty);
      expect(apiType.reasoningEffortNote, isNotEmpty);
      expect(ApiType.byId('不存在').id, ApiType.openAiCompatible.id);
      expect(ApiType.all, hasLength(1));
    });
  });

  group('AiModel', () {
    test('displayLabel：简写标识非空用简写，否则回退模型名', () {
      const labeled = AiModel(id: 'm1', shortLabel: 'V4F', temperature: 1.0);
      const plain = AiModel(id: 'm2', temperature: 1.0);
      expect(labeled.displayLabel, 'V4F');
      expect(plain.displayLabel, 'm2');
    });

    test('toJson/fromJson 往返（maxTokens 为空不落盘，能力表一致）', () {
      final model = AiModel(
        id: 'm1',
        shortLabel: 'V4F',
        temperature: 0.7,
        reasoningEffort: 'low',
        maxTokens: 2048,
        requestTemplate: '{"model": {{model}}}',
        supportsStreaming: false,
        supportsThinking: true,
        supportsSearch: false,
        supportsVision: true,
      );
      final parsed = AiModel.fromJson(model.toJson());
      expect(parsed.id, 'm1');
      expect(parsed.shortLabel, 'V4F');
      expect(parsed.temperature, 0.7);
      expect(parsed.reasoningEffort, 'low');
      expect(parsed.maxTokens, 2048);
      expect(parsed.requestTemplate, '{"model": {{model}}}');
      expect(parsed.supportsStreaming, isFalse);
      expect(parsed.supportsThinking, isTrue);
      expect(parsed.supportsSearch, isFalse);
      expect(parsed.supportsVision, isTrue);

      final noMax = AiModel(id: 'm2', temperature: 1.0);
      expect(noMax.toJson().containsKey('maxTokens'), isFalse);
      expect(AiModel.fromJson(noMax.toJson()).maxTokens, isNull);
    });

    test('能力表默认：流式/思考/搜索开、识图关；copyWith 可改', () {
      const model = AiModel(id: 'm1');
      expect(model.supportsStreaming, isTrue);
      expect(model.supportsThinking, isTrue);
      expect(model.supportsSearch, isTrue);
      expect(model.supportsVision, isFalse);

      final changed = model.copyWith(
        supportsStreaming: false,
        supportsSearch: false,
        supportsVision: true,
      );
      expect(changed.supportsStreaming, isFalse);
      expect(changed.supportsThinking, isTrue);
      expect(changed.supportsSearch, isFalse);
      expect(changed.supportsVision, isTrue);
    });
  });

  group('AiPlatform', () {
    test('默认平台：预置 Pro / Flash / Vision Exp，默认模型能力全开', () {
      final platform = AiPlatforms.defaultPlatform;
      expect(platform.isBuiltin, isTrue);
      expect(platform.apiType.id, ApiType.openAiCompatible.id);
      expect(
        platform.models.map((m) => m.id),
        ['deepseek-v4-pro', 'deepseek-v4-flash', 'deepseek-v4-flash-vision-exp'],
      );
      expect(platform.defaultModel.id, 'deepseek-v4-pro');
      expect(platform.modelOrFirst('不存在').id, 'deepseek-v4-pro');
      expect(AiPlatforms.defaultModelId, 'deepseek-v4-pro');
      expect(AiPlatforms.defaultSupportsSearch, isTrue);
      // 识图能力：Vision Exp 模型开启，Pro / Flash 关闭。
      expect(platform.modelById('deepseek-v4-flash-vision-exp')!.supportsVision, isTrue);
      expect(platform.modelById('deepseek-v4-pro')!.supportsVision, isFalse);
      expect(platform.modelById('deepseek-v4-flash')!.supportsVision, isFalse);
    });
  });

  group('AiRequestBodyBuilder.buildPresetBody', () {
    test('思考模式：注入 reasoning_effort，不注入 temperature', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ApiType.openAiCompatible.requestRules,
        values: _values(thinking: true, reasoningEffort: 'high', maxTokens: 4096),
      );
      expect(body['model'], 'deepseek-v4-pro');
      expect(body['stream'], isTrue);
      expect((body['thinking'] as Map)['type'], 'enabled');
      expect(body['reasoning_effort'], 'high');
      expect(body['temperature'], isNull);
      expect(body['max_tokens'], 4096);
      expect(body['stream_options'], {'include_usage': true});
      expect(body.containsKey('tools'), isFalse);
    });

    test('非思考模式：注入 temperature，不注入 reasoning_effort', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ApiType.openAiCompatible.requestRules,
        values: _values(thinking: false, temperature: 0.7),
      );
      expect((body['thinking'] as Map)['type'], 'disabled');
      expect(body['temperature'], 0.7);
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('max_tokens 为空时移除该键', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ApiType.openAiCompatible.requestRules,
        values: _values(maxTokens: null),
      );
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('tools 非空时注入 tools', () {
      const tools = [
        {'type': 'function', 'function': {'name': 'web_search'}},
      ];
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ApiType.openAiCompatible.requestRules,
        values: _values(tools: tools),
      );
      expect(body['tools'], tools);
    });

    test('非流式：不注入 stream_options', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ApiType.openAiCompatible.requestRules,
        values: _values(stream: false),
      );
      expect(body['stream'], isFalse);
      expect(body.containsKey('stream_options'), isFalse);
    });
  });

  group('AiRequestBodyBuilder.buildCustomBody', () {
    test('默认模板替换后为合法请求体', () {
      final body = AiRequestBodyBuilder.buildCustomBody(
        template: AiRequestBodyBuilder.defaultCustomRequestBody,
        values: _values(temperature: 0.7, maxTokens: 2048),
      );
      expect(body['model'], 'deepseek-v4-pro');
      expect((body['messages'] as List).length, 2);
      expect(body['stream'], isTrue);
      expect(body['temperature'], 0.7);
      expect(body['max_tokens'], 2048);
    });

    test('max_tokens 为空替换为 null', () {
      final body = AiRequestBodyBuilder.buildCustomBody(
        template: AiRequestBodyBuilder.defaultCustomRequestBody,
        values: _values(maxTokens: null),
      );
      expect(body['max_tokens'], isNull);
    });

    test('非法模板抛 FormatException', () {
      expect(
        () => AiRequestBodyBuilder.buildCustomBody(
          template: '{ 非法',
          values: _values(),
        ),
        throwsFormatException,
      );
    });
  });

  group('AiRequestBodyBuilder.validateCustomTemplate', () {
    test('合法模板通过', () {
      expect(
        () => AiRequestBodyBuilder.validateCustomTemplate(
          AiRequestBodyBuilder.defaultCustomRequestBody,
        ),
        returnsNormally,
      );
    });

    test('非法模板抛 FormatException', () {
      expect(
        () => AiRequestBodyBuilder.validateCustomTemplate('{"model": '),
        throwsFormatException,
      );
    });
  });
}
