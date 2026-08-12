import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/config/model_presets.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';

void main() {
  group('AiSettingsProvider.migrateFromOldConfig（v1.2.x 旧结构迁移）', () {
    test('旧 model 命中内置预设 → 选中该预设并迁移参数与选项', () {
      final migrated = AiSettingsProvider.migrateFromOldConfig({
        'model': 'deepseek-v4-pro',
        'temperature': 0.7,
        'thinking': false,
        'reasoningEffort': 'low',
        'maxTokens': 2048,
        'streaming': true,
      });

      expect(migrated.selectedPresetId, 'deepseek-v4-pro');
      final memory = migrated.presetParams['deepseek-v4-pro'];
      expect(memory, isNotNull);
      expect(memory!.temperature, 0.7);
      expect(memory.reasoningEffort, 'low');
      expect(memory.maxTokens, 2048);
      expect(migrated.customModelName, '');
      expect(migrated.lastThinking, isFalse);
      expect(migrated.lastStreaming, isTrue);
      expect(migrated.lastSearch, isFalse);
    });

    test('旧 model 未命中内置 → 迁移为自定义模型（名称保留）', () {
      final migrated = AiSettingsProvider.migrateFromOldConfig({
        'model': 'my-custom-model',
        'temperature': 1.2,
        'thinking': true,
        'streaming': false,
      });

      expect(migrated.selectedPresetId, ModelPresets.customId);
      expect(migrated.customModelName, 'my-custom-model');
      expect(migrated.presetParams, isEmpty);
      expect(migrated.lastThinking, isTrue);
      expect(migrated.lastStreaming, isFalse);
    });

    test('旧 model 为空 → 自定义模型（空名称）', () {
      final migrated = AiSettingsProvider.migrateFromOldConfig({
        'model': '',
        'streaming': true,
      });

      expect(migrated.selectedPresetId, ModelPresets.customId);
      expect(migrated.customModelName, '');
    });

    test('缺少旧键时使用合理默认值', () {
      final migrated = AiSettingsProvider.migrateFromOldConfig({
        'model': 'deepseek-v4-flash',
      });

      expect(migrated.selectedPresetId, 'deepseek-v4-flash');
      final memory = migrated.presetParams['deepseek-v4-flash']!;
      expect(memory.temperature, 1.0);
      expect(memory.reasoningEffort, 'high');
      expect(memory.maxTokens, isNull);
      expect(migrated.lastThinking, isTrue);
      expect(migrated.lastStreaming, isTrue);
    });
  });
}
