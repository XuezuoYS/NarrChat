import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/models/api_type.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/widgets/settings_form_state.dart';

/// 记录 save 调用并返回可配置结果的 [AiSettingsProvider] 替身。
///
/// 覆写 `save` 以切断真实 LocalConfigService / flutter_secure_storage
/// 平台通道（与 fakes.dart 的约定一致：不触碰真实存储）。
class _FakeAiSettingsProvider extends AiSettingsProvider {
  _FakeAiSettingsProvider({this.saveResult = true});

  final bool saveResult;
  int saveCalls = 0;

  @override
  Future<bool> save({
    required List<AiPlatform> platforms,
    required String selectedPlatformId,
    required String selectedModelId,
    required Map<String, String> apiKeys,
  }) async {
    saveCalls++;
    return saveResult;
  }
}

/// 记录 save 调用并返回可配置结果的 [CloudSyncProvider] 替身。
class _FakeCloudSyncProvider extends CloudSyncProvider {
  _FakeCloudSyncProvider({this.saveResult = true});

  final bool saveResult;
  int saveCalls = 0;

  @override
  Future<bool> save({
    required String webdavUrl,
    required String webdavUsername,
    required String webdavPassword,
    required String folder,
    required SyncMode syncMode,
  }) async {
    saveCalls++;
    return saveResult;
  }
}

void main() {
  test('云同步未填写：保存其它设置成功，仅提示「云同步未填写」，不调用云同步落库', () async {
    // 云同步替身即使被调用会返回失败——用于证明保存时确实跳过了云同步落库。
    final ai = _FakeAiSettingsProvider();
    final sync = _FakeCloudSyncProvider(saveResult: false);
    final form = SettingsFormState(ai: ai, sync: sync);
    addTearDown(form.dispose);

    final result = await form.saveAll();

    expect(result.ok, isTrue);
    expect(result.errors, isEmpty);
    expect(result.notes, contains('云同步未填写'));
    expect(ai.saveCalls, 1);
    expect(sync.saveCalls, 0);
  });

  test('云同步仅填写地址：视为提示「云同步填写不完整」，不报保存失败', () async {
    final ai = _FakeAiSettingsProvider();
    final sync = _FakeCloudSyncProvider();
    final form = SettingsFormState(ai: ai, sync: sync);
    addTearDown(form.dispose);
    form.webdavUrl.text = 'https://dav.example.com/dav/';

    final result = await form.saveAll();

    expect(result.ok, isTrue);
    expect(result.notes, contains('云同步填写不完整，已跳过云同步保存'));
    expect(sync.saveCalls, 0);
  });

  test('云同步已完整填写且保存成功：无提示', () async {
    final ai = _FakeAiSettingsProvider();
    final sync = _FakeCloudSyncProvider();
    final form = SettingsFormState(ai: ai, sync: sync);
    addTearDown(form.dispose);
    form.webdavUrl.text = 'https://dav.example.com/dav/';
    form.webdavUsername.text = 'user';

    final result = await form.saveAll();

    expect(result.ok, isTrue);
    expect(result.errors, isEmpty);
    expect(result.notes, isEmpty);
    expect(ai.saveCalls, 1);
    expect(sync.saveCalls, 1);
  });

  test('云同步已完整填写但保存失败：仍报「云同步保存失败」', () async {
    final ai = _FakeAiSettingsProvider();
    final sync = _FakeCloudSyncProvider(saveResult: false);
    final form = SettingsFormState(ai: ai, sync: sync);
    addTearDown(form.dispose);
    form.webdavUrl.text = 'https://dav.example.com/dav/';
    form.webdavUsername.text = 'user';

    final result = await form.saveAll();

    expect(result.ok, isFalse);
    expect(result.errors, contains('云同步保存失败：未知错误'));
    expect(sync.saveCalls, 1);
  });

  test('AI 保存失败（云同步未填写）：整体判定失败并附带「云同步未填写」提示', () async {
    final ai = _FakeAiSettingsProvider(saveResult: false);
    final sync = _FakeCloudSyncProvider();
    final form = SettingsFormState(ai: ai, sync: sync);
    addTearDown(form.dispose);

    final result = await form.saveAll();

    expect(result.ok, isFalse);
    expect(result.errors, contains('API 设置保存失败：未知错误'));
    expect(result.notes, contains('云同步未填写'));
    expect(sync.saveCalls, 0);
  });

  group('SettingsFormState 平台/模型编辑', () {
    test('addPlatform：生成自定义平台，API 类型按传入协议（默认 Response 兼容）', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      final before = form.platforms.length;

      form.addPlatform(
        name: '我的网关',
        baseUrl: 'https://gw.example.com',
        apiTypeId: ApiType.openAiResponsesId,
      );

      expect(form.platforms.length, before + 1);
      final p = form.platforms.last;
      expect(p.displayName, '我的网关');
      expect(p.baseUrl, 'https://gw.example.com');
      expect(p.apiType.id, ApiType.openAiResponses.id);
      expect(p.models, isEmpty);
    });

    test('setPlatformApiType：切换默认平台接入协议（Response ↔ Chat）', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);

      expect(
        form.platforms.first.apiType.id,
        ApiType.openAiResponses.id,
      );
      form.setPlatformApiType(
        AiPlatforms.defaultPlatformId,
        ApiType.openAiCompatibleId,
      );
      expect(form.platforms.first.apiType.id, ApiType.openAiCompatible.id);
      form.setPlatformApiType(
        AiPlatforms.defaultPlatformId,
        ApiType.openAiResponsesId,
      );
      expect(form.platforms.first.apiType.id, ApiType.openAiResponses.id);
    });

    test('removePlatform：最后一个平台不可删，预置平台可删（可再恢复）', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      final defaultId = AiPlatforms.defaultPlatformId;

      // 仅预置平台（唯一）时删除应无效果（至少保留一个平台）。
      form.removePlatform(defaultId);
      expect(form.platforms.length, 1);

      // 添加自定义平台后，预置平台可删除（限制已放开，靠「恢复内置平台」找回）。
      form.addPlatform(
        name: 'p2',
        baseUrl: 'x',
        apiTypeId: ApiType.openAiCompatibleId,
      );
      form.removePlatform(defaultId);
      expect(form.platforms.length, 1);
      expect(form.platforms.any((p) => p.id == defaultId), isFalse);

      // 删除自定义平台可生效。
      form.removePlatform(form.platforms.last.id);
      expect(form.platforms.length, 1);
    });

    test('addModel / removeModel：维护至少一个模型（自定义平台）', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      form.addPlatform(
        name: 'gw',
        baseUrl: 'x',
        apiTypeId: ApiType.openAiCompatibleId,
      );
      final platformId = form.platforms.last.id;
      final before = form.platforms.last.models.length;

      form.addModel(platformId, id: 'gpt-4o-mini', shortLabel: 'GPT4O');
      expect(form.platforms.last.models.length, before + 1);
      expect(form.platforms.last.modelById('gpt-4o-mini')!.shortLabel, 'GPT4O');

      // 删到只剩一个模型后，再删最后一个应无效果（强制 ≥1）。
      for (final m in [...form.platforms.last.models]) {
        if (form.platforms.last.models.length > 1) {
          form.removeModel(platformId, m.id);
        }
      }
      expect(form.platforms.last.models.length, 1);
      form.removeModel(platformId, form.platforms.last.models.first.id);
      expect(form.platforms.last.models.length, 1);
    });

    test('内置预置平台：模型可增删（限制已放开），仍保证至少一个模型', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      final defaultId = AiPlatforms.defaultPlatformId;
      final before = form.platforms.first.models.length;

      // 预置平台可新增模型。
      form.addModel(defaultId, id: 'gpt-4o-mini', shortLabel: 'GPT4O');
      expect(form.platforms.first.models.length, before + 1);

      // 预置平台可删除预置模型。
      form.removeModel(defaultId, 'deepseek-v4-pro');
      expect(
        form.platforms.first.models.any((m) => m.id == 'deepseek-v4-pro'),
        isFalse,
      );

      // 删到只剩一个后不可再删。
      for (final m in [...form.platforms.first.models]) {
        if (form.platforms.first.models.length > 1) {
          form.removeModel(defaultId, m.id);
        }
      }
      expect(form.platforms.first.models.length, 1);
      form.removeModel(defaultId, form.platforms.first.models.first.id);
      expect(form.platforms.first.models.length, 1);
    });

    test('updateModel：按模型 id 写回参数（含默认平台模型）', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      final platformId = form.platforms.first.id;
      final model = form.platforms.first.models.first;

      form.updateModel(
        platformId,
        model.id,
        model.copyWith(temperature: 0.6, reasoningEffort: 'low', shortLabel: 'V4P'),
      );

      final updated = form.platforms.first.modelById(model.id)!;
      expect(updated.temperature, 0.6);
      expect(updated.reasoningEffort, 'low');
      expect(updated.shortLabel, 'V4P');
    });
  });

  group('SettingsFormState 预置平台重置与恢复', () {
    test('resetPlatform：只还原内置预置平台，自添加平台逐字段不受影响', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      final presetId = AiPlatforms.defaultPlatformId;
      final presetModels =
          AiPlatforms.defaultPlatform.models.map((m) => m.id).toList();

      // 改动内置预置平台：连接设置 + 模型参数 + 增删模型。
      form.setPlatformName(presetId, '我的 DeepSeek');
      form.setPlatformBaseUrl(presetId, 'https://my-proxy.example.com');
      form.setPlatformApiType(presetId, ApiType.openAiCompatibleId);
      final proModel = form.platforms.first.modelById('deepseek-v4-pro')!;
      form.updateModel(
        presetId,
        proModel.id,
        proModel.copyWith(temperature: 0.2, supportsSearch: false),
      );
      form.removeModel(presetId, 'deepseek-v4-flash');
      form.addModel(presetId, id: 'my-model', shortLabel: 'MY');

      // 自添加平台 aliyun：改名称 + 加模型。
      form.addPlatform(
        name: 'aliyun',
        baseUrl: 'https://gw.example.com/v1',
        apiTypeId: ApiType.openAiCompatibleId,
      );
      final customId = form.platforms.last.id;
      form.addModel(customId, id: 'qwen-max', shortLabel: 'QW');
      form.setPlatformName(customId, 'aliyun-2');

      expect(form.platformUnchanged(form.platforms.first), isFalse);
      expect(form.usesBuiltinPlatforms, isFalse);
      final revisionBefore = form.resetRevision;

      form.resetPlatform(presetId);

      // 内置平台完全回到预置（连接设置 + 模型列表 + 参数）。
      final restored = form.platforms.first;
      expect(AiPlatforms.isPresetUnchanged(restored), isTrue);
      expect(restored.displayName, AiPlatforms.defaultPlatform.displayName);
      expect(restored.baseUrl, AiPlatforms.defaultPlatform.baseUrl);
      expect(restored.apiType.id, ApiType.openAiResponses.id);
      expect(restored.models.map((m) => m.id), presetModels);
      expect(restored.modelById('deepseek-v4-pro')!.temperature, 1.0);
      expect(restored.modelById('deepseek-v4-pro')!.supportsSearch, isTrue);
      expect(form.platformUnchanged(restored), isTrue);

      // 平台级文本控制器同步（界面输入框不残留旧值）。
      expect(form.nameCtrlFor(presetId).text, AiPlatforms.defaultPlatform.displayName);
      expect(form.baseUrlCtrlFor(presetId).text, AiPlatforms.defaultPlatform.baseUrl);
      // 重置计数自增：UI 据此重建模型编辑器（丢弃旧文本控制器）。
      expect(form.resetRevision, revisionBefore + 1);

      // 自添加平台不受影响。
      final custom = form.platforms.last;
      expect(custom.id, customId);
      expect(custom.displayName, 'aliyun-2');
      expect(custom.baseUrl, 'https://gw.example.com/v1');
      expect(custom.models.single.id, 'qwen-max');
      expect(custom.models.single.shortLabel, 'QW');
      expect(form.platformUnchanged(custom), isFalse);
      // 仍有自定义平台 ⇒ 整体不视为"内置预置"。
      expect(form.usesBuiltinPlatforms, isFalse);
    });

    test('resetPlatform：无其它自定义时整体状态恢复"内置预置"', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      final presetId = AiPlatforms.defaultPlatformId;
      final model = form.platforms.first.models.first;

      form.updateModel(presetId, model.id, model.copyWith(maxTokens: 4096));
      expect(form.usesBuiltinPlatforms, isFalse);

      form.resetPlatform(presetId);
      expect(form.usesBuiltinPlatforms, isTrue);
    });

    test('resetPlatform：非预置平台 / 不存在的平台无操作', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      form.addPlatform(
        name: 'gw',
        baseUrl: 'x',
        apiTypeId: ApiType.openAiCompatibleId,
      );
      final customId = form.platforms.last.id;
      final before = [for (final p in form.platforms) jsonEncode(p.toJson())];

      form.resetPlatform(customId);
      form.resetPlatform('custom_不存在');

      expect(
        [for (final p in form.platforms) jsonEncode(p.toJson())],
        before,
      );
      expect(form.resetRevision, 0);
    });

    test('missingPresetPlatforms / restorePresetPlatform：删除后一键恢复', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      final presetId = AiPlatforms.defaultPlatformId;

      expect(form.missingPresetPlatforms, isEmpty);

      form.addPlatform(
        name: 'gw',
        baseUrl: 'x',
        apiTypeId: ApiType.openAiCompatibleId,
      );
      form.removePlatform(presetId);
      expect(form.missingPresetPlatforms.map((p) => p.id), [presetId]);

      form.restorePresetPlatform(presetId);
      expect(form.platforms.last.id, presetId);
      expect(AiPlatforms.isPresetUnchanged(form.platforms.last), isTrue);
      expect(form.missingPresetPlatforms, isEmpty);
      // 恢复后控制器就绪（可被界面直接使用）。
      expect(form.baseUrlCtrlFor(presetId).text, AiPlatforms.defaultPlatform.baseUrl);

      // 已存在时再恢复无效果；非预置 id 同样无效果。
      final length = form.platforms.length;
      form.restorePresetPlatform(presetId);
      form.restorePresetPlatform('custom_不存在');
      expect(form.platforms.length, length);
    });
  });
}
