import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';

void main() {
  group('AiSettingsProvider.migrateFromV2（旧 selectedPreset 结构迁移）', () {
    test('旧预设命中内置 → 默认平台该模型，并入参数记忆与 Base URL', () {
      final config = AiSettingsProvider.migrateFromV2({
        'baseUrl': 'https://my.deepseek.com',
        'selectedPreset': 'deepseek-v4-pro',
        'presetParams': {
          'deepseek-v4-pro': {
            'temperature': 0.7,
            'reasoningEffort': 'low',
            'maxTokens': 2048,
          },
        },
      });

      final platform = config.platforms.single;
      expect(platform.id, AiPlatforms.defaultPlatformId);
      expect(platform.isBuiltin, isTrue);
      expect(platform.baseUrl, 'https://my.deepseek.com');
      expect(config.selectedPlatformId, AiPlatforms.defaultPlatformId);
      expect(config.selectedModelId, 'deepseek-v4-pro');
      final pro = platform.modelById('deepseek-v4-pro')!;
      expect(pro.temperature, 0.7);
      expect(pro.reasoningEffort, 'low');
      expect(pro.maxTokens, 2048);
    });

    test('旧自定义模型 → 默认平台追加模型，requestTemplate 取旧模板', () {
      final config = AiSettingsProvider.migrateFromV2({
        'baseUrl': 'https://api.deepseek.com',
        'selectedPreset': '__custom__',
        'customModelName': 'my-model',
        'customRequestBody': '{"model": {{model}}}',
      });

      final platform = config.platforms.single;
      expect(config.selectedModelId, 'my-model');
      final model = platform.modelById('my-model')!;
      expect(model.requestTemplate, '{"model": {{model}}}');
      expect(platform.models.length, 3); // pro + flash + my-model
    });

    test('无自定义时选中回退到默认平台模型', () {
      final config = AiSettingsProvider.migrateFromV2({
        'baseUrl': 'https://api.deepseek.com',
        'selectedPreset': 'deepseek-v4-flash',
      });
      expect(config.selectedModelId, 'deepseek-v4-flash');
    });
  });

  group('AiSettingsProvider.migrateFromV1（旧扁平结构迁移）', () {
    test('model 命中内置 → 默认平台该模型并并入旧参数', () {
      final config = AiSettingsProvider.migrateFromV1({
        'model': 'deepseek-v4-pro',
        'temperature': 0.7,
        'reasoningEffort': 'low',
        'maxTokens': 2048,
      });

      final platform = config.platforms.single;
      expect(config.selectedModelId, 'deepseek-v4-pro');
      final pro = platform.modelById('deepseek-v4-pro')!;
      expect(pro.temperature, 0.7);
      expect(pro.reasoningEffort, 'low');
      expect(pro.maxTokens, 2048);
      expect(platform.modelById('deepseek-v4-flash')!.temperature, 1.0);
    });

    test('model 未命中内置 → 默认平台追加自定义模型', () {
      final config = AiSettingsProvider.migrateFromV1({
        'model': 'my-custom-model',
        'temperature': 1.2,
      });

      final platform = config.platforms.single;
      expect(config.selectedModelId, 'my-custom-model');
      final model = platform.modelById('my-custom-model')!;
      expect(model.temperature, 1.2);
      expect(model.requestTemplate, isNull);
    });

    test('model 为空 → 回退默认平台默认模型', () {
      final config = AiSettingsProvider.migrateFromV1({'model': ''});
      expect(config.selectedModelId, AiPlatforms.defaultModelId);
      expect(config.platforms.single.models.length, 2);
    });
  });
}
