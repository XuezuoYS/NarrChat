import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/models/api_type.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
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
    required int keepVersions,
    required bool autoUpload,
    required String userName,
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
    test('addPlatform：生成自定义平台，API 类型固定为 OpenAI 兼容', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      final before = form.platforms.length;

      form.addPlatform(name: '我的网关', baseUrl: 'https://gw.example.com');

      expect(form.platforms.length, before + 1);
      final p = form.platforms.last;
      expect(p.displayName, '我的网关');
      expect(p.baseUrl, 'https://gw.example.com');
      expect(p.apiType.id, ApiType.openAiCompatible.id);
      expect(p.models, isEmpty);
    });

    test('removePlatform：内置默认平台与最后一个平台不可删', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      final defaultId = AiPlatforms.defaultPlatformId;

      // 仅默认平台（唯一）时删除应无效果。
      form.removePlatform(defaultId);
      expect(form.platforms.length, 1);

      // 再添加自定义平台；删除内置默认平台仍应无效果（isBuiltin + id 双保险）。
      form.addPlatform(name: 'p2', baseUrl: 'x');
      form.removePlatform(defaultId);
      expect(form.platforms.length, 2);
      expect(form.platforms.any((p) => p.id == defaultId), isTrue);

      // 删除自定义平台可生效。
      form.removePlatform(form.platforms.last.id);
      expect(form.platforms.length, 1);
    });

    test('addModel / removeModel：维护至少一个模型（自定义平台）', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      form.addPlatform(name: 'gw', baseUrl: 'x');
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

    test('内置默认平台：模型不可增删', () {
      final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
      addTearDown(form.dispose);
      final defaultId = AiPlatforms.defaultPlatformId;
      final before = form.platforms.first.models.length;

      // 默认平台不可新增模型。
      form.addModel(defaultId, id: 'gpt-4o-mini');
      expect(form.platforms.first.models.length, before);

      // 默认平台不可删除模型（V4 Pro 仍然存在）。
      form.removeModel(defaultId, 'deepseek-v4-pro');
      expect(
        form.platforms.first.models.any((m) => m.id == 'deepseek-v4-pro'),
        isTrue,
      );
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
}
