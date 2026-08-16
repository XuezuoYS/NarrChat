import 'package:flutter_test/flutter_test.dart';
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
    required String apiKey,
    required String baseUrl,
    required String selectedPresetId,
    required double temperature,
    required String reasoningEffort,
    required int? maxTokens,
    required String customModelName,
    required String customRequestBody,
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
    expect(result.errors, contains('AI 设置保存失败：未知错误'));
    expect(result.notes, contains('云同步未填写'));
    expect(sync.saveCalls, 0);
  });
}
