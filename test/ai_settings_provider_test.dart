import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/models/api_type.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/services/local_config_service.dart';

/// [AiSettingsProvider] 的加载 / 保存与预置分层语义测试。
///
/// - 本地配置走 [LocalConfigService.testRootOverride] 临时目录（真实文件 I/O，
///   非 FakeAsync 的普通 `test()` 中可正常完成）；
/// - 系统密钥库用 `FlutterSecureStorage.setMockInitialValues` 换成内存替身，
///   禁止触碰真实系统密钥库；
/// - 覆盖：`ai` 命名空间缺失/为空/不可读 ⇒ 遵循内置预置；用户修改保存后写入
///   完整副本；与预置等价时 `platforms` 键消失；加载不写盘；API Key 不受影响。
void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('narrchat_ai_settings_');
    LocalConfigService.testRootOverride = tempRoot.path;
    LocalConfigService.resetForTest();
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    LocalConfigService.testRootOverride = null;
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  /// 当前配置文件内容（JSON）。
  Future<Map<String, dynamic>> readConfig() => LocalConfigService.read();

  /// 当前配置文件里的 `ai` 命名空间。
  Future<Map<String, dynamic>> readAiSection() async {
    final cfg = await readConfig();
    return (cfg[AiSettingsProvider.aiNamespaceKey] as Map?)?.cast<String, dynamic>() ??
        const {};
  }

  /// 写一份原始配置文件（模拟用户手工编辑 / 旧版本遗留）。
  Future<void> writeRawConfig(Map<String, dynamic> data) =>
      LocalConfigService.write(data);

  /// 构造一份"用户已自定义"的平台副本：预置平台改参数 + 追加自定义平台。
  List<AiPlatform> customizedPlatforms() {
    final preset = AiPlatforms.defaultPlatform;
    return [
      preset.copyWith(
        models: [
          preset.models.first.copyWith(temperature: 0.7, shortLabel: 'V4P'),
          ...preset.models.skip(1),
        ],
      ),
      const AiPlatform(
        id: 'custom_1',
        displayName: 'aliyun',
        apiType: ApiType.openAiCompatible,
        baseUrl: 'https://gw.example.com/v1',
        models: [AiModel(id: 'qwen-max', temperature: 0.5, maxTokens: 2048)],
      ),
    ];
  }

  group('图片设置（沿用即时持久化）', () {
    test('convertJpgToJpeg 默认关闭，读取缺失的 ai 命名空间不报错', () async {
      final provider = AiSettingsProvider();
      await provider.load();
      expect(provider.convertJpgToJpeg, isFalse);
      expect(provider.maxImageSizeMB, 16);
      expect(provider.error, isNull);
    });

    test('setConvertJpgToJpeg：更新状态并持久化到 ai 命名空间', () async {
      final provider = AiSettingsProvider();
      expect(provider.convertJpgToJpeg, isFalse);

      final ok = await provider.setConvertJpgToJpeg(true);
      expect(ok, isTrue);
      expect(provider.convertJpgToJpeg, isTrue);

      // 写入 `ai` 命名空间内，顶层不再出现该键。
      final cfg = await readConfig();
      expect(cfg.containsKey('convertJpgToJpeg'), isFalse);
      expect((cfg['ai'] as Map)['convertJpgToJpeg'], isTrue);

      // 再次关闭：状态与持久化均更新。
      final ok2 = await provider.setConvertJpgToJpeg(false);
      expect(ok2, isTrue);
      expect(provider.convertJpgToJpeg, isFalse);
      expect((await readAiSection())['convertJpgToJpeg'], isFalse);
    });

    test('setMaxImageSizeMB / setPerRoundOptions / setSelectedModel 均写入 ai 命名空间',
        () async {
      final provider = AiSettingsProvider();
      await provider.load();

      await provider.setMaxImageSizeMB(8);
      await provider.setPerRoundOptions(
        thinking: false,
        streaming: true,
        search: true,
      );
      final switched = await provider.setSelectedModel(
        AiPlatforms.defaultPlatformId,
        'deepseek-v4-flash',
      );
      expect(switched, isTrue);

      final cfg = await readConfig();
      for (final key in const [
        'maxImageSizeMB',
        'lastThinking',
        'lastStreaming',
        'lastSearch',
        'selectedPlatformId',
        'selectedModelId',
      ]) {
        expect(cfg.containsKey(key), isFalse, reason: '顶层不应出现 $key');
      }
      final ai = (cfg['ai'] as Map).cast<String, dynamic>();
      expect(ai['maxImageSizeMB'], 8);
      expect(ai['lastThinking'], isFalse);
      expect(ai['lastStreaming'], isTrue);
      expect(ai['lastSearch'], isTrue);
      expect(ai['selectedModelId'], 'deepseek-v4-flash');
    });

    test('写 ai 命名空间不破坏其它命名空间与顶层设置键', () async {
      await writeRawConfig({'themeMode': 'dark'});
      final provider = AiSettingsProvider();
      await provider.load();

      await provider.setConvertJpgToJpeg(true);

      final cfg = await readConfig();
      expect(cfg['themeMode'], 'dark');
      expect((cfg['ai'] as Map)['convertJpgToJpeg'], isTrue);
    });
  });

  group('load：命名空间缺失 / 为空 / 不可读 ⇒ 遵循内置预置', () {
    test('无配置文件：预置平台 + 默认选中项 + 默认开关', () async {
      final provider = AiSettingsProvider();
      await provider.load();

      expect(AiPlatforms.matchesPresets(provider.platforms), isTrue);
      expect(provider.platforms.length, 1);
      expect(provider.selectedPlatformId, AiPlatforms.defaultPlatformId);
      expect(provider.selectedModelId, AiPlatforms.defaultModelId);
      expect(provider.model, 'deepseek-v4-pro');
      expect(provider.thinking, isTrue);
      expect(provider.streaming, isTrue);
      expect(provider.lastSearch, isFalse);
      expect(provider.error, isNull);
    });

    test('ai 键为空对象 / 非对象 / platforms 为空数组或非法类型 ⇒ 预置', () async {
      for (final raw in <Object?>[
        <String, dynamic>{},
        'not-a-map',
        42,
        <String, dynamic>{'platforms': <Object?>[]},
        <String, dynamic>{'platforms': 'oops'},
        <String, dynamic>{'platforms': <Object?>[42, 'x']},
      ]) {
        await writeRawConfig({'ai': raw});
        final provider = AiSettingsProvider();
        await provider.load();
        expect(
          AiPlatforms.matchesPresets(provider.platforms),
          isTrue,
          reason: 'ai=$raw 应回退内置预置',
        );
        expect(provider.selectedModelId, AiPlatforms.defaultModelId);
      }
    });

    test('ai 命名空间存在且平台层与预置一致（旧版本物化副本）⇒ 仍视为预置', () async {
      await writeRawConfig({
        'ai': {
          'platforms': [AiPlatforms.defaultPlatform.toJson()],
          'selectedPlatformId': AiPlatforms.defaultPlatformId,
          'selectedModelId': AiPlatforms.defaultModelId,
        },
      });
      final provider = AiSettingsProvider();
      await provider.load();
      expect(AiPlatforms.matchesPresets(provider.platforms), isTrue);
    });

    test('用户副本：平台与模型参数逐项生效，选中项保留', () async {
      final platforms = customizedPlatforms();
      await writeRawConfig({
        'ai': {
          'platforms': [for (final p in platforms) p.toJson()],
          'selectedPlatformId': 'custom_1',
          'selectedModelId': 'qwen-max',
          'lastSearch': true,
          'maxImageSizeMB': 4,
          'convertJpgToJpeg': true,
        },
      });

      final provider = AiSettingsProvider();
      await provider.load();

      expect(provider.platforms.length, 2);
      expect(provider.platforms.first.models.first.temperature, 0.7);
      expect(provider.platforms.first.models.first.shortLabel, 'V4P');
      expect(provider.platforms.last.displayName, 'aliyun');
      expect(provider.platforms.last.models.single.maxTokens, 2048);
      expect(provider.selectedPlatformId, 'custom_1');
      expect(provider.selectedModelId, 'qwen-max');
      expect(provider.model, 'qwen-max');
      expect(provider.baseUrl, 'https://gw.example.com/v1');
      expect(provider.lastSearch, isTrue);
      expect(provider.maxImageSizeMB, 4);
      expect(provider.convertJpgToJpeg, isTrue);
    });

    test('选中项失效（指向已删除平台 / 模型）⇒ 归一化到预置默认', () async {
      await writeRawConfig({
        'ai': {
          'selectedPlatformId': 'custom_gone',
          'selectedModelId': 'gone-model',
        },
      });
      final provider = AiSettingsProvider();
      await provider.load();
      expect(provider.selectedPlatformId, AiPlatforms.defaultPlatformId);
      expect(provider.selectedModelId, AiPlatforms.defaultModelId);
    });

    test('配置文件不可读（JSON 写坏）⇒ 遵循内置预置，且不覆盖坏文件', () async {
      final dir = Directory(
        '${tempRoot.path}${Platform.pathSeparator}local_config',
      );
      await dir.create(recursive: true);
      final file = File(
        '${dir.path}${Platform.pathSeparator}${LocalConfigService.fileName}',
      );
      await file.writeAsString('{ 这不是合法 JSON');

      final provider = AiSettingsProvider();
      await provider.load();

      expect(AiPlatforms.matchesPresets(provider.platforms), isTrue);
      expect(provider.selectedModelId, AiPlatforms.defaultModelId);
      expect(provider.error, isNull);
      // 不静默忽略 / 不静默覆盖用户的手工编辑：坏文件原样保留（直到用户显式保存）。
      expect(await file.readAsString(), '{ 这不是合法 JSON');
    });

    test('加载不写盘：不迁移、不物化、不清理', () async {
      await writeRawConfig({
        // 旧扁平键（历史版本遗留）：不再读取，也不在加载时清理。
        'platforms': [AiPlatforms.defaultPlatform.toJson()],
        'selectedModelId': 'deepseek-v4-flash',
        'themeMode': 'dark',
      });

      final provider = AiSettingsProvider();
      await provider.load();

      // 全部回退内置预置（旧键不再被识别）。
      expect(AiPlatforms.matchesPresets(provider.platforms), isTrue);
      expect(provider.selectedModelId, AiPlatforms.defaultModelId);
      // 文件内容保持原样。
      final raw = await File(
        '${tempRoot.path}${Platform.pathSeparator}local_config'
        '${Platform.pathSeparator}${LocalConfigService.fileName}',
      ).readAsString();
      final cfg = jsonDecode(raw) as Map<String, dynamic>;
      expect(cfg.containsKey('ai'), isFalse);
      expect(cfg['themeMode'], 'dark');
      expect(cfg['selectedModelId'], 'deepseek-v4-flash');
    });
  });

  group('save：修改即物化完整副本，与预置等价则省略 platforms', () {
    test('保存自定义平台副本：写出完整副本（平台 / 模型 / 参数齐全）', () async {
      final platforms = customizedPlatforms();
      final provider = AiSettingsProvider();
      await provider.load();

      final ok = await provider.save(
        platforms: platforms,
        selectedPlatformId: 'custom_1',
        selectedModelId: 'qwen-max',
        apiKeys: const {},
      );
      expect(ok, isTrue);

      final ai = await readAiSection();
      final stored = (ai['platforms'] as List).cast<Map<String, dynamic>>();
      expect(stored.length, 2);
      expect(stored.first['id'], AiPlatforms.defaultPlatformId);
      expect(stored.last['id'], 'custom_1');
      expect(stored.last['displayName'], 'aliyun');
      expect(stored.last['baseUrl'], 'https://gw.example.com/v1');
      expect(ai['selectedPlatformId'], 'custom_1');
      expect(ai['selectedModelId'], 'qwen-max');

      // 往返一致：再读回来与保存前逐字段等价。
      final reloaded = AiSettingsProvider();
      await reloaded.load();
      expect(
        [for (final p in reloaded.platforms) jsonEncode(p.toJson())],
        [for (final p in platforms) jsonEncode(p.toJson())],
      );
    });

    test('保存与预置一致的副本 ⇒ 不写 platforms 键（回到"缺失即默认"）', () async {
      // 先制造自定义副本，再"重置"为预置后保存。
      await writeRawConfig({
        'ai': {
          'platforms': [for (final p in customizedPlatforms()) p.toJson()],
        },
        'themeMode': 'dark',
      });
      final provider = AiSettingsProvider();
      await provider.load();
      expect(AiPlatforms.matchesPresets(provider.platforms), isFalse);

      final ok = await provider.save(
        platforms: AiPlatforms.presetPlatforms,
        selectedPlatformId: provider.selectedPlatformId,
        selectedModelId: provider.selectedModelId,
        apiKeys: const {},
      );
      expect(ok, isTrue);

      final cfg = await readConfig();
      final ai = (cfg['ai'] as Map).cast<String, dynamic>();
      expect(ai.containsKey('platforms'), isFalse);
      // 其余键照常写全，顶层其它命名空间不受影响。
      expect(ai['selectedModelId'], AiPlatforms.defaultModelId);
      expect(cfg['themeMode'], 'dark');
    });

    test('选中项失效时归一化后落盘', () async {
      final provider = AiSettingsProvider();
      await provider.load();

      final ok = await provider.save(
        platforms: AiPlatforms.presetPlatforms,
        selectedPlatformId: 'custom_gone',
        selectedModelId: 'gone-model',
        apiKeys: const {},
      );
      expect(ok, isTrue);
      expect(provider.selectedPlatformId, AiPlatforms.defaultPlatformId);
      expect(provider.selectedModelId, AiPlatforms.defaultModelId);
      final ai = await readAiSection();
      expect(ai['selectedPlatformId'], AiPlatforms.defaultPlatformId);
      expect(ai['selectedModelId'], AiPlatforms.defaultModelId);
    });

    test('API Key 与重置/保存正交：重置为预置不删除密钥', () async {
      FlutterSecureStorage.setMockInitialValues({
        'ai_api_key': 'sk-default',
        'ai_api_key_custom_1': 'sk-custom',
      });
      final provider = AiSettingsProvider();
      await provider.load();
      expect(provider.apiKey, 'sk-default');

      // 保存"重置为内置预置"后的平台列表（自定义平台已被移除）。
      final ok = await provider.save(
        platforms: AiPlatforms.presetPlatforms,
        selectedPlatformId: AiPlatforms.defaultPlatformId,
        selectedModelId: AiPlatforms.defaultModelId,
        apiKeys: const {AiPlatforms.defaultPlatformId: 'sk-default'},
      );
      expect(ok, isTrue);
      expect(provider.apiKey, 'sk-default');
      expect((await readAiSection()).containsKey('platforms'), isFalse);

      // 已移除平台在系统密钥库中的条目维持现状（不清理、不迁移）。
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'ai_api_key_custom_1'), 'sk-custom');
    });

    test('保存失败（平台无模型）不落盘', () async {
      final provider = AiSettingsProvider();
      final bad = AiPlatforms.defaultPlatform.copyWith(models: const []);
      final ok = await provider.save(
        platforms: [bad],
        selectedPlatformId: AiPlatforms.defaultPlatformId,
        selectedModelId: AiPlatforms.defaultModelId,
        apiKeys: const {},
      );
      expect(ok, isFalse);
      expect(provider.error, contains('至少需要一个模型'));
      expect((await readConfig()).containsKey('ai'), isFalse);
    });
  });
}
