import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/models/api_type.dart';
import 'package:narrchat/services/agent/agent_sub_model.dart';

/// 子模型解析：配置 → 平台 + 模型；生成侧折叠「与主模型相同」，设置侧保留原始选择。
void main() {
  final platforms = AiPlatforms.presetPlatforms;

  const otherPlatform = AiPlatform(
    id: 'custom-p1',
    displayName: '自建平台',
    apiType: ApiType.openAiCompatible,
    baseUrl: 'https://example.com/v1',
    models: [
      AiModel(id: 'cheap-model', shortLabel: '便宜模型'),
      AiModel(id: 'deepseek-flash'),
    ],
  );

  List<AiPlatform> withOther() => [...platforms, otherPlatform];

  group('findAgentSubModel', () {
    test('空 id / 平台不存在 / 模型不存在 → null', () {
      expect(
        findAgentSubModel(
          platforms: platforms,
          platformId: '',
          modelId: 'deepseek-v4-pro',
        ),
        isNull,
      );
      expect(
        findAgentSubModel(
          platforms: platforms,
          platformId: AiPlatforms.deepseekPlatformId,
          modelId: '',
        ),
        isNull,
      );
      expect(
        findAgentSubModel(
          platforms: platforms,
          platformId: 'missing',
          modelId: 'deepseek-v4-pro',
        ),
        isNull,
      );
      expect(
        findAgentSubModel(
          platforms: platforms,
          platformId: AiPlatforms.deepseekPlatformId,
          modelId: 'missing-model',
        ),
        isNull,
      );
    });

    test('空白配置归一后仍能解析', () {
      final target = findAgentSubModel(
        platforms: platforms,
        platformId: '  ${AiPlatforms.deepseekPlatformId}  ',
        modelId: ' deepseek-v4-pro ',
      );
      expect(target, isNotNull);
      expect(target!.model.id, 'deepseek-v4-pro');
    });

    test('同平台不同模型 / 跨平台模型都能解析；不折叠主模型', () {
      final samePlatform = findAgentSubModel(
        platforms: platforms,
        platformId: AiPlatforms.deepseekPlatformId,
        modelId: 'deepseek-v4-pro',
      );
      expect(samePlatform!.platform.id, AiPlatforms.deepseekPlatformId);
      expect(samePlatform.model.id, 'deepseek-v4-pro');

      final other = findAgentSubModel(
        platforms: withOther(),
        platformId: otherPlatform.id,
        modelId: 'cheap-model',
      );
      expect(other!.platform.id, otherPlatform.id);
      expect(other.model.id, 'cheap-model');

      // 设置页要能显示「用户原始选的就是主模型」，因此 find 不折叠。
      final sameAsMain = findAgentSubModel(
        platforms: platforms,
        platformId: AiPlatforms.deepseekPlatformId,
        modelId: 'deepseek-flash',
      );
      expect(sameAsMain, isNotNull);
      expect(sameAsMain!.model.id, 'deepseek-flash');
    });
  });

  group('resolveAgentSubModel', () {
    test('同平台同模型 → null（按未启用子模型处理）', () {
      expect(
        resolveAgentSubModel(
          platforms: platforms,
          configuredPlatformId: AiPlatforms.deepseekPlatformId,
          configuredModelId: 'deepseek-flash',
          mainPlatformId: AiPlatforms.deepseekPlatformId,
          mainModelId: 'deepseek-flash',
        ),
        isNull,
      );
    });

    test('同平台不同模型 → 目标', () {
      final target = resolveAgentSubModel(
        platforms: platforms,
        configuredPlatformId: AiPlatforms.deepseekPlatformId,
        configuredModelId: 'deepseek-v4-pro',
        mainPlatformId: AiPlatforms.deepseekPlatformId,
        mainModelId: 'deepseek-flash',
      );
      expect(target, isNotNull);
      expect(target!.model.id, 'deepseek-v4-pro');
    });

    test('跨平台同名模型 → 仍保留为目标（平台不同，不共享缓存）', () {
      final target = resolveAgentSubModel(
        platforms: withOther(),
        configuredPlatformId: otherPlatform.id,
        configuredModelId: 'deepseek-flash',
        mainPlatformId: AiPlatforms.deepseekPlatformId,
        mainModelId: 'deepseek-flash',
      );
      expect(target, isNotNull);
      expect(target!.platform.id, otherPlatform.id);
      expect(target.model.id, 'deepseek-flash');
    });

    test('未配置 / 半套 / 失效 → null', () {
      for (final pair in const [
        ('', ''),
        (AiPlatforms.deepseekPlatformId, ''),
        ('', 'deepseek-v4-pro'),
        ('missing', 'deepseek-v4-pro'),
        (AiPlatforms.deepseekPlatformId, 'missing-model'),
      ]) {
        expect(
          resolveAgentSubModel(
            platforms: platforms,
            configuredPlatformId: pair.$1,
            configuredModelId: pair.$2,
            mainPlatformId: AiPlatforms.deepseekPlatformId,
            mainModelId: 'deepseek-flash',
          ),
          isNull,
          reason: '${pair.$1} / ${pair.$2}',
        );
      }
    });
  });
}
