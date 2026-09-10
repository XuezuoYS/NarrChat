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
  String? instructions,
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
    instructions: instructions,
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
    });

    test('openAiResponses：AGENT 协议注册、byId 命中、all 两项', () {
      final apiType = ApiType.openAiResponses;
      expect(apiType.id, 'openai-responses');
      expect(apiType.isResponses, isTrue);
      expect(ApiType.openAiCompatible.isResponses, isFalse);
      expect(apiType.supportsStreaming, isTrue);
      expect(apiType.supportsThinking, isTrue);
      expect(apiType.supportsSearch, isTrue);
      expect(ApiType.byId('openai-responses').id, 'openai-responses');
      expect(ApiType.all.map((t) => t.id), ['openai-responses', 'openai-compatible']);
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
    test('默认平台：预置 Flash（识图，默认选中）与 v4 Pro，协议为 Response API 兼容', () {
      final platform = AiPlatforms.defaultPlatform;
      expect(platform.id, AiPlatforms.defaultPlatformId);
      expect(platform.apiType.id, ApiType.openAiResponses.id);
      expect(platform.supportsResponseChaining, isFalse);
      expect(
        platform.models.map((m) => m.id),
        ['deepseek-flash', 'deepseek-v4-pro'],
      );
      expect(platform.defaultModel.id, 'deepseek-flash');
      expect(platform.modelOrFirst('不存在').id, 'deepseek-flash');
      expect(AiPlatforms.defaultModelId, 'deepseek-flash');
      expect(AiPlatforms.defaultSupportsSearch, isTrue);

      // v4 Pro：能力默认（流式 / 思考 / 搜索开、识图关）。
      final pro = platform.modelById('deepseek-v4-pro')!;
      expect(pro.supportsStreaming, isTrue);
      expect(pro.supportsThinking, isTrue);
      expect(pro.supportsSearch, isTrue);
      expect(pro.supportsVision, isFalse);

      // Flash：简写名称 DeepSeek V4.1 Flash，能力全开（含识图）。
      final flash = platform.modelById('deepseek-flash')!;
      expect(flash.shortLabel, 'DeepSeek V4.1 Flash');
      expect(flash.displayLabel, 'DeepSeek V4.1 Flash');
      expect(flash.supportsStreaming, isTrue);
      expect(flash.supportsThinking, isTrue);
      expect(flash.supportsSearch, isTrue);
      expect(flash.supportsVision, isTrue);

      // 已下线的旧预置模型不再存在。
      expect(platform.modelById('deepseek-v4-flash'), isNull);
      expect(platform.modelById('deepseek-v4-flash-vision-exp'), isNull);
    });

    test('supportsResponseChaining：toJson/fromJson 往返，旧配置缺失默认 false', () {
      final platform = AiPlatforms.defaultPlatform.copyWith(
        supportsResponseChaining: true,
      );
      final parsed = AiPlatform.fromJson(platform.toJson());
      expect(parsed.supportsResponseChaining, isTrue);
      final legacy = AiPlatform.fromJson(
        AiPlatforms.defaultPlatform.toJson()..remove('supportsResponseChaining'),
      );
      expect(legacy.supportsResponseChaining, isFalse);
    });

    test('平台配置不落盘"内置"标记（由预置注册表派生）', () {
      expect(AiPlatforms.defaultPlatform.toJson().containsKey('isBuiltin'), isFalse);
    });
  });

  group('AiPlatforms 内置预置注册表', () {
    test('预置列表与按 id 查找', () {
      final presets = AiPlatforms.presetPlatforms;
      expect(presets.length, 1);
      expect(presets.single.id, AiPlatforms.deepseekPlatformId);
      expect(AiPlatforms.presetFor(AiPlatforms.defaultPlatformId), isNotNull);
      expect(AiPlatforms.isPresetId(AiPlatforms.defaultPlatformId), isTrue);
      // 自定义平台 id 不是预置。
      expect(AiPlatforms.presetFor('custom_1'), isNull);
      expect(AiPlatforms.isPresetId('custom_1'), isFalse);
      // 每次返回全新实例，避免共享可变引用。
      expect(
        identical(AiPlatforms.presetPlatforms.single, AiPlatforms.presetPlatforms.single),
        isFalse,
      );
    });

    test('isPresetUnchanged：未改动为 true，任一字段改动为 false', () {
      expect(AiPlatforms.isPresetUnchanged(AiPlatforms.defaultPlatform), isTrue);
      // 非预置 id 一律 false。
      expect(
        AiPlatforms.isPresetUnchanged(
          AiPlatforms.defaultPlatform.copyWith(id: 'custom_1'),
        ),
        isFalse,
      );

      final preset = AiPlatforms.defaultPlatform;
      final changed = <AiPlatform>[
        preset.copyWith(displayName: '我的 DeepSeek'),
        preset.copyWith(baseUrl: 'https://gw.example.com'),
        preset.copyWith(apiType: ApiType.openAiCompatible),
        preset.copyWith(supportsResponseChaining: true),
        // 模型参数 / 能力 / 增删模型。
        preset.copyWith(
          models: [
            preset.models.first.copyWith(temperature: 0.7),
            ...preset.models.skip(1),
          ],
        ),
        preset.copyWith(
          models: [
            preset.models.first.copyWith(shortLabel: 'V4P'),
            ...preset.models.skip(1),
          ],
        ),
        preset.copyWith(
          models: [
            preset.models.first.copyWith(supportsSearch: false),
            ...preset.models.skip(1),
          ],
        ),
        preset.copyWith(models: [preset.models.first]),
        preset.copyWith(
          models: [...preset.models, const AiModel(id: 'extra-model')],
        ),
      ];
      for (final platform in changed) {
        expect(
          AiPlatforms.isPresetUnchanged(platform),
          isFalse,
          reason: '改动后应判定为已自定义：${platform.toJson()}',
        );
      }
    });

    test('matchesPresets：数量 / 顺序 / 内容任一不同即 false', () {
      final presets = AiPlatforms.presetPlatforms;
      expect(AiPlatforms.matchesPresets(presets), isTrue);
      // 与 toJson 往返后的副本等价（配置读取路径）。
      expect(
        AiPlatforms.matchesPresets(
          [for (final p in presets) AiPlatform.fromJson(p.toJson())],
        ),
        isTrue,
      );
      expect(AiPlatforms.matchesPresets([]), isFalse);
      expect(
        AiPlatforms.matchesPresets([
          ...presets,
          const AiPlatform(
            id: 'custom_1',
            displayName: '网关',
            apiType: ApiType.openAiCompatible,
            baseUrl: 'https://gw.example.com',
            models: [AiModel(id: 'gpt-4o-mini')],
          ),
        ]),
        isFalse,
      );
      expect(
        AiPlatforms.matchesPresets([presets.single.copyWith(baseUrl: 'x')]),
        isFalse,
      );
    });
  });

  group('AiPlatforms.resolvePlatforms（用户层 `ai.platforms` 解析）', () {
    test('缺失 / 非数组 / 空数组 ⇒ 内置预置', () {
      for (final raw in <Object?>[null, 'ai', 42, const <Object?>[], const {}]) {
        final resolved = AiPlatforms.resolvePlatforms(raw);
        expect(AiPlatforms.matchesPresets(resolved), isTrue, reason: '$raw');
        expect(resolved.single.id, AiPlatforms.defaultPlatformId);
      }
    });

    test('合法用户副本（含自定义平台）原样保留', () {
      final custom = AiPlatform(
        id: 'custom_1',
        displayName: 'aliyun',
        apiType: ApiType.openAiCompatible,
        baseUrl: 'https://gw.example.com/v1',
        models: const [
          AiModel(id: 'qwen-max', shortLabel: 'QW', temperature: 0.5, maxTokens: 2048),
        ],
      );
      final edited = AiPlatforms.defaultPlatform.copyWith(
        models: [
          AiPlatforms.defaultPlatform.models.first.copyWith(temperature: 0.7),
          ...AiPlatforms.defaultPlatform.models.skip(1),
        ],
      );
      final resolved = AiPlatforms.resolvePlatforms([
        edited.toJson(),
        custom.toJson(),
      ]);
      expect(resolved.length, 2);
      expect(resolved.first.models.first.temperature, 0.7);
      expect(resolved.last.id, 'custom_1');
      expect(resolved.last.displayName, 'aliyun');
      expect(resolved.last.models.single.shortLabel, 'QW');
      expect(resolved.last.models.single.maxTokens, 2048);
    });

    test('非法项被丢弃；全非法 ⇒ 内置预置', () {
      final resolved = AiPlatforms.resolvePlatforms([
        // 非法：id 为空
        {'id': '', 'models': [const AiModel(id: 'm').toJson()]},
        // 非法：无模型（手改配置常见错误）
        {'id': 'half', 'displayName': '半成品'},
        42,
        // 合法
        {
          'id': 'custom_2',
          'displayName': '网关',
          'baseUrl': 'https://gw.example.com',
          'models': [const AiModel(id: 'gpt-4o-mini').toJson()],
        },
      ]);
      expect(resolved.length, 1);
      expect(resolved.single.id, 'custom_2');

      expect(
        AiPlatforms.matchesPresets(
          AiPlatforms.resolvePlatforms([
            {'id': 'half', 'displayName': '半成品'},
          ]),
        ),
        isTrue,
      );
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
        {'type': 'function', 'function': {'name': 'narrchat_webSearch'}},
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

  group('AiRequestBodyBuilder.openAiResponses 规则', () {
    test('思考模式：instructions/input/reasoning.effort，无 temperature', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ApiType.openAiResponses.requestRules,
        values: _values(
          thinking: true,
          reasoningEffort: 'high',
          maxTokens: 4096,
          instructions: 'AGENT 指令',
        ),
      );
      expect(body['model'], 'deepseek-v4-pro');
      expect(body['instructions'], 'AGENT 指令');
      expect(body['input'], _values().messages);
      expect(body['stream'], isTrue);
      expect((body['reasoning'] as Map)['effort'], 'high');
      expect(body['temperature'], isNull);
      expect(body['max_output_tokens'], 4096);
      expect(body.containsKey('tools'), isFalse);
    });

    test('非思考模式：注入 temperature + reasoning.effort=none（显式关闭思考）', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ApiType.openAiResponses.requestRules,
        values: _values(thinking: false, temperature: 0.7),
      );
      expect(body['temperature'], 0.7);
      // DeepSeek 思考模式默认开启：省略 reasoning 等于思考开启，
      // 必须显式 effort=none 才能关闭。
      expect((body['reasoning'] as Map)['effort'], 'none');
    });

    test('instructions 为空时移除该键；max_output_tokens 为空时移除', () {
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ApiType.openAiResponses.requestRules,
        values: _values(maxTokens: null),
      );
      expect(body.containsKey('instructions'), isFalse);
      expect(body.containsKey('max_output_tokens'), isFalse);
    });

    test('tools 非空时注入 tools', () {
      const tools = [
        {'type': 'function', 'function': {'name': 'narrchat_setLine'}},
      ];
      final body = AiRequestBodyBuilder.buildPresetBody(
        rules: ApiType.openAiResponses.requestRules,
        values: _values(tools: tools),
      );
      expect(body['tools'], tools);
    });
  });
}
