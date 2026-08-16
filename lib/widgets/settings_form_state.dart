import 'package:flutter/widgets.dart';

import '../config/model_presets.dart';
import '../providers/ai_settings_provider.dart';
import '../providers/cloud_sync_provider.dart';
import '../services/ai_request_body_builder.dart';

/// 设置页全量表单状态（AI 选择 + 云同步）。
///
/// 由 [SettingsScreen] 持有并注入各面板：面板切换时表单状态不丢失，
/// 右上角「保存」按钮可任意时机统一校验并落库（类似书籍设置的机制）；
/// 保存成功后不退出设置页，仅弹出成功/失败提示。
///
/// 即时设置（如主题/字体）不在此列，保持即时生效。
class SettingsFormState extends ChangeNotifier {
  SettingsFormState({
    required AiSettingsProvider ai,
    required CloudSyncProvider sync,
  }) : _ai = ai,
       _sync = sync,
       apiKey = TextEditingController(text: ai.apiKey),
       baseUrl = TextEditingController(text: ai.baseUrl),
       customModelName = TextEditingController(text: ai.customModelName),
       customRequestBody = TextEditingController(text: ai.customRequestBody),
       maxTokens = TextEditingController(text: ai.maxTokens?.toString() ?? ''),
       selectedPresetId = ai.selectedPresetId,
       temperature = ai.temperature,
       reasoningEffort = ai.reasoningEffort,
       webdavUrl = TextEditingController(text: sync.webdavUrl),
       webdavUsername = TextEditingController(text: sync.webdavUsername),
       webdavPassword = TextEditingController(text: sync.webdavPassword),
       webdavFolder = TextEditingController(text: sync.folder),
       webdavUserName = TextEditingController(text: sync.userName),
       webdavKeepVersions = TextEditingController(text: '${sync.keepVersions}'),
       autoUpload = sync.autoUpload;

  final AiSettingsProvider _ai;
  final CloudSyncProvider _sync;

  // ---------------------------------------------------------------------------
  // AI 选择
  // ---------------------------------------------------------------------------
  final TextEditingController apiKey;
  final TextEditingController baseUrl;
  final TextEditingController customModelName;
  final TextEditingController customRequestBody;
  final TextEditingController maxTokens;
  String selectedPresetId;
  double temperature;
  String reasoningEffort;
  bool obscureKey = true;

  // ---------------------------------------------------------------------------
  // 云同步
  // ---------------------------------------------------------------------------
  final TextEditingController webdavUrl;
  final TextEditingController webdavUsername;
  final TextEditingController webdavPassword;
  final TextEditingController webdavFolder;
  final TextEditingController webdavUserName;
  final TextEditingController webdavKeepVersions;
  bool autoUpload;
  bool obscurePassword = true;

  bool get isCustom => selectedPresetId == ModelPresets.customId;

  int? get effectiveMaxTokens {
    final text = maxTokens.text.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  /// 切换模型预设：载入该预设记忆的参数（无记忆则用预设默认值）。
  void selectPreset(String id) {
    selectedPresetId = id;
    final preset = ModelPresets.byId(id);
    final memory = _ai.presetParams[id];
    temperature = memory?.temperature ?? preset.defaultTemperature;
    reasoningEffort = memory?.reasoningEffort ?? preset.defaultReasoningEffort;
    final max = memory?.maxTokens ?? preset.defaultMaxTokens;
    maxTokens.text = max?.toString() ?? '';
  }

  /// 统一保存全部设置（校验通过后 AI 与云同步并行落库）。
  ///
  /// 返回失败原因列表与提示列表；[SettingsSaveResult.errors] 为空表示全部保存成功。
  /// 校验失败时不执行任何写入。
  ///
  /// 云同步未填写（服务器地址或登录用户名为空）时不视为保存失败：
  /// 跳过云同步落库并仅加入提示（如「云同步未填写」），避免保存其它设置被误报失败。
  Future<SettingsSaveResult> saveAll() async {
    final errors = <String>[];
    final notes = <String>[];

    // —— 校验（不落库）——
    final maxTokensValue = effectiveMaxTokens;
    if (maxTokensValue != null && maxTokensValue <= 0) {
      errors.add('AI 设置：最大输出 Tokens 需为正整数或留空');
    }
    if (isCustom) {
      final name = customModelName.text.trim();
      if (name.isEmpty) {
        errors.add('AI 设置：自定义模型名称不能为空');
      } else {
        try {
          AiRequestBodyBuilder.validateCustomTemplate(customRequestBody.text);
        } on FormatException catch (e) {
          errors.add('AI 设置：${e.message}');
        }
      }
    }
    final keep = int.tryParse(webdavKeepVersions.text.trim());
    if (keep == null || keep < 1 || keep > 99) {
      errors.add('云同步：保留历史版本需为 1 ~ 99 的整数');
    }
    if (errors.isNotEmpty) return SettingsSaveResult(errors: errors);

    // 云同步是否已完整填写（与 CloudSyncProvider.isConfigured 口径一致）。
    final syncUrl = webdavUrl.text.trim();
    final syncUsername = webdavUsername.text.trim();
    final syncConfigured = syncUrl.isNotEmpty && syncUsername.isNotEmpty;

    // 并行落库。keep 已由上方校验保证非空（不满足则已提前返回）。
    // 云同步未填写时不调用 _sync.save（避免留下误报错误态），仅提示。
    final results = await Future.wait([
      _ai.save(
        apiKey: apiKey.text,
        baseUrl: baseUrl.text,
        selectedPresetId: selectedPresetId,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
        maxTokens: maxTokensValue,
        customModelName: customModelName.text,
        customRequestBody: customRequestBody.text,
      ),
      if (syncConfigured)
        _sync.save(
          webdavUrl: webdavUrl.text,
          webdavUsername: webdavUsername.text,
          webdavPassword: webdavPassword.text,
          folder: webdavFolder.text,
          keepVersions: keep!,
          autoUpload: autoUpload,
          userName: webdavUserName.text,
        ),
    ]);
    if (!results[0]) {
      errors.add('AI 设置保存失败：${_ai.error ?? '未知错误'}');
    }
    if (syncConfigured) {
      if (!results[1]) {
        errors.add('云同步保存失败：${_sync.error ?? '未知错误'}');
      }
    } else {
      notes.add(
        syncUrl.isEmpty && syncUsername.isEmpty
            ? '云同步未填写'
            : '云同步填写不完整，已跳过云同步保存',
      );
    }
    return SettingsSaveResult(errors: errors, notes: notes);
  }

  @override
  void dispose() {
    apiKey.dispose();
    baseUrl.dispose();
    customModelName.dispose();
    customRequestBody.dispose();
    maxTokens.dispose();
    webdavUrl.dispose();
    webdavUsername.dispose();
    webdavPassword.dispose();
    webdavFolder.dispose();
    webdavUserName.dispose();
    webdavKeepVersions.dispose();
    super.dispose();
  }
}

/// 设置页统一保存结果。
///
/// - [errors]：真正的保存失败原因（如 AI / 云同步落库失败），非空即整体失败；
/// - [notes]：非致命提示（如「云同步未填写」），不影响 [ok] 判定。
class SettingsSaveResult {
  final List<String> errors;
  final List<String> notes;

  const SettingsSaveResult({this.errors = const [], this.notes = const []});

  bool get ok => errors.isEmpty;
}
