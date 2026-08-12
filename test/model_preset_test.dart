import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/config/model_presets.dart';
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
  group('ModelPresets', () {
    test('内置预设包含 Pro / Flash', () {
      expect(
        ModelPresets.builtins.map((p) => p.id),
        containsAll(['deepseek-v4-pro', 'deepseek-v4-flash']),
      );
      for (final p in ModelPresets.builtins) {
        expect(p.id, p.modelId);
        expect(p.supportsStreaming, isTrue);
        expect(p.supportsThinking, isTrue);
        expect(p.supportsSearch, isTrue);
        expect(p.defaultThinking, isTrue);
        expect(p.defaultStreaming, isTrue);
        expect(p.defaultReasoningEffort, 'high');
        expect(p.temperatureNote, isNotEmpty);
        expect(p.reasoningEffortNote, isNotEmpty);
      }
    });

    test('byId：内置 / 自定义 / 未知回退', () {
      expect(ModelPresets.byId('deepseek-v4-pro').id, 'deepseek-v4-pro');
      expect(ModelPresets.byId(ModelPresets.customId).id, ModelPresets.customId);
      expect(ModelPresets.byId('不存在').id, ModelPresets.defaultPreset.id);
    });

    test('byModelId：命中内置 / 未命中返回 null', () {
      expect(ModelPresets.byModelId('deepseek-v4-flash')?.id, 'deepseek-v4-flash');
      expect(ModelPresets.byModelId('my-model'), isNull);
    });

    test('自定义预设能力默认全开', () {
      final custom = ModelPresets.customPreset;
      expect(custom.supportsStreaming, isTrue);
      expect(custom.supportsThinking, isTrue);
      expect(custom.supportsSearch, isTrue);
    });
  });

  group('AiRequestBodyBuilder.buildPresetBody', () {
    test('思考模式：注入 reasoning_effort，不注入 temperature', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ModelPresets.deepseekV4Pro.requestRules,
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
        rules: ModelPresets.deepseekV4Pro.requestRules,
        values: _values(thinking: false, temperature: 0.7),
      );
      expect((body['thinking'] as Map)['type'], 'disabled');
      expect(body['temperature'], 0.7);
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('max_tokens 为空时移除该键', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ModelPresets.deepseekV4Pro.requestRules,
        values: _values(maxTokens: null),
      );
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('tools 非空时注入 tools', () {
      const tools = [
        {'type': 'function', 'function': {'name': 'web_search'}},
      ];
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ModelPresets.deepseekV4Pro.requestRules,
        values: _values(tools: tools),
      );
      expect(body['tools'], tools);
    });

    test('非流式：不注入 stream_options', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ModelPresets.deepseekV4Pro.requestRules,
        values: _values(stream: false),
      );
      expect(body['stream'], isFalse);
      expect(body.containsKey('stream_options'), isFalse);
    });

    test('嵌套占位符（thinking.type）被递归解析', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ModelPresets.deepseekV4Pro.requestRules,
        values: _values(thinking: false),
      );
      expect((body['thinking'] as Map)['type'], 'disabled');
    });
  });

  group('AiRequestBodyBuilder.buildCustomBody', () {
    test('默认模板替换后为合法请求体', () {
      final body = AiRequestBodyBuilder.buildCustomBody(
        template: ModelPresets.defaultCustomRequestBody,
        values: _values(temperature: 0.7, maxTokens: 2048),
      );
      expect(body['model'], 'deepseek-v4-pro');
      expect((body['messages'] as List).length, 2);
      expect(body['stream'], isTrue);
      expect(body['temperature'], 0.7);
      expect(body['max_tokens'], 2048);
    });

    test('thinking_type / tools 占位符替换', () {
      const template = '''
{
  "model": {{model}},
  "messages": {{messages}},
  "thinking": {"type": {{thinking_type}}},
  "tools": {{tools}}
}
''';
      final body = AiRequestBodyBuilder.buildCustomBody(
        template: template,
        values: _values(thinking: true),
      );
      expect((body['thinking'] as Map)['type'], 'enabled');
      expect(body['tools'], isEmpty);
    });

    test('max_tokens 为空替换为 null', () {
      final body = AiRequestBodyBuilder.buildCustomBody(
        template: ModelPresets.defaultCustomRequestBody,
        values: _values(maxTokens: null),
      );
      expect(body['max_tokens'], isNull);
    });

    test('非法模板抛 FormatException（含占位符合法性校验）', () {
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
          ModelPresets.defaultCustomRequestBody,
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
