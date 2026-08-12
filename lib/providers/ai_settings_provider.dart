import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/app_config.dart';
import '../config/model_presets.dart';
import '../models/model_preset.dart';
import '../services/ai_request_body_builder.dart';
import '../services/local_config_service.dart';

/// 旧配置迁移结果（纯数据，便于单测）。
class MigratedConfig {
  final String selectedPresetId;
  final Map<String, PresetParamMemory> presetParams;
  final String customModelName;
  final bool lastThinking;
  final bool lastStreaming;
  final bool lastSearch;

  const MigratedConfig({
    required this.selectedPresetId,
    required this.presetParams,
    required this.customModelName,
    required this.lastThinking,
    required this.lastStreaming,
    required this.lastSearch,
  });
}

/// AI 接口设置状态管理。
///
/// 本地存储策略（符合 AGENTS.md 数据结构规范）：
/// - **API Key**：写入 `flutter_secure_storage`
///   （Android 使用 Keystore/加密存储，Windows 使用 DPAPI/凭据管理器），禁止明文落盘；
/// - **其余设置**：写入本地明文 JSON 配置文件
///   `local_config/app_settings.json`（[LocalConfigService]），不进入云存储。
///
/// 配置结构（camelCase）：
/// - `baseUrl`：接口地址（全局）；
/// - `selectedPreset`：当前选中的预设 id（内置官方模型 id 或 `__custom__`）；
/// - `presetParams`：每个预设独立记忆的参数（`{预设id: {temperature,
///   reasoningEffort, maxTokens}}`）；
/// - `customModelName` / `customRequestBody`：自定义模型名称与请求体 JSON 模板；
/// - `lastThinking` / `lastStreaming` / `lastSearch`：Chat 页每轮选项记忆。
class AiSettingsProvider extends ChangeNotifier {
  AiSettingsProvider();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static const String _keyApiKey = 'ai_api_key';

  /// 本地 JSON 配置文件中的键名（camelCase）。
  static const String _keyBaseUrl = 'baseUrl';
  static const String _keySelectedPreset = 'selectedPreset';
  static const String _keyPresetParams = 'presetParams';
  static const String _keyCustomModelName = 'customModelName';
  static const String _keyCustomRequestBody = 'customRequestBody';
  static const String _keyLastThinking = 'lastThinking';
  static const String _keyLastStreaming = 'lastStreaming';
  static const String _keyLastSearch = 'lastSearch';

  /// 旧版（v1.2.x 及更早）配置键，用于迁移。
  static const String _oldKeyModel = 'model';
  static const String _oldKeyTemperature = 'temperature';
  static const String _oldKeyThinking = 'thinking';
  static const String _oldKeyReasoningEffort = 'reasoningEffort';
  static const String _oldKeyMaxTokens = 'maxTokens';
  static const String _oldKeyStreaming = 'streaming';

  String _apiKey = AppConfig.defaultApiKeyEffective;
  String _baseUrl = AppConfig.defaultApiBaseUrlEffective;
  String _selectedPresetId = ModelPresets.defaultPreset.id;
  final Map<String, PresetParamMemory> _presetParams = {};
  String _customModelName = '';
  String _customRequestBody = ModelPresets.defaultCustomRequestBody;
  bool _lastThinking = ModelPresets.defaultPreset.defaultThinking;
  bool _lastStreaming = ModelPresets.defaultPreset.defaultStreaming;
  // 搜索能力默认开启（预设支持搜索时开箱即用，用户可手动关闭）。
  bool _lastSearch = true;

  bool _isLoading = false;
  String? _error;

  // ---------------------------------------------------------------------------
  // 派生状态
  // ---------------------------------------------------------------------------
  String get apiKey => _apiKey;
  String get baseUrl => _baseUrl;
  String get selectedPresetId => _selectedPresetId;
  Map<String, PresetParamMemory> get presetParams =>
      Map.unmodifiable(_presetParams);
  String get customModelName => _customModelName;
  String get customRequestBody => _customRequestBody;
  bool get lastSearch => _lastSearch;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 当前选中的预设（自定义模型返回 [ModelPresets.customPreset]）。
  ModelPreset get selectedPreset => ModelPresets.byId(_selectedPresetId);

  /// 是否自定义模型。
  bool get isCustom => _selectedPresetId == ModelPresets.customId;

  /// 实际发送给 API 的模型名（内置预设用 modelId，自定义用用户填的名称）。
  String get model => isCustom ? _customModelName : selectedPreset.modelId;

  /// 当前预设的有效温度（优先用户记忆，回退预设默认）。
  double get temperature =>
      _presetParams[_selectedPresetId]?.temperature ??
      selectedPreset.defaultTemperature;

  /// 当前预设的有效推理强度。
  String get reasoningEffort =>
      _presetParams[_selectedPresetId]?.reasoningEffort ??
      selectedPreset.defaultReasoningEffort;

  /// 当前预设的有效最大输出 Tokens。
  int? get maxTokens =>
      _presetParams[_selectedPresetId]?.maxTokens ??
      selectedPreset.defaultMaxTokens;

  /// 每轮思考选项（记忆值，并按预设能力收敛）。
  bool get thinking => _lastThinking && selectedPreset.supportsThinking;

  /// 每轮流式选项（记忆值，并按预设能力收敛）。
  bool get streaming => _lastStreaming && selectedPreset.supportsStreaming;

  /// 是否已配置有效的 API Key。
  bool get hasApiKey => _apiKey.trim().isNotEmpty;

  // ---------------------------------------------------------------------------
  // 加载与迁移
  // ---------------------------------------------------------------------------

  /// 从安全存储与本地 JSON 配置文件中加载设置（旧版配置自动迁移）。
  Future<void> load() async {
    _isLoading = true;
    try {
      final storedKey = await _secureStorage.read(key: _keyApiKey);
      _apiKey = (storedKey ?? '').isNotEmpty
          ? storedKey!
          : AppConfig.defaultApiKeyEffective;
      final cfg = await LocalConfigService.read();
      _baseUrl =
          (cfg[_keyBaseUrl] as String?) ?? AppConfig.defaultApiBaseUrlEffective;

      if (cfg.containsKey(_keySelectedPreset)) {
        _readNewConfig(cfg);
      } else {
        await _migrateOldConfig(cfg);
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _readNewConfig(Map<String, dynamic> cfg) {
    _selectedPresetId =
        (cfg[_keySelectedPreset] as String?) ?? ModelPresets.defaultPreset.id;
    final presetMap =
        (cfg[_keyPresetParams] as Map<String, dynamic>?) ?? const {};
    _presetParams
      ..clear()
      ..addAll({
        for (final e in presetMap.entries)
          e.key: PresetParamMemory.fromJson(
            (e.value as Map).cast<String, dynamic>(),
          ),
      });
    _customModelName = (cfg[_keyCustomModelName] as String?) ?? '';
    _customRequestBody =
        (cfg[_keyCustomRequestBody] as String?) ??
        ModelPresets.defaultCustomRequestBody;
    final preset = selectedPreset;
    _lastThinking = (cfg[_keyLastThinking] as bool?) ?? preset.defaultThinking;
    _lastStreaming =
        (cfg[_keyLastStreaming] as bool?) ?? preset.defaultStreaming;
    _lastSearch = (cfg[_keyLastSearch] as bool?) ?? true;
  }

  /// 旧版配置（v1.2.x 及更早）迁移：
  /// - `model` 命中内置预设 → 选中该预设；否则 → 自定义模型（名称取旧 model）；
  /// - 旧参数（temperature/reasoningEffort/maxTokens）写入该预设的参数记忆；
  /// - 旧 thinking/streaming 写入每轮选项记忆；
  /// - 迁移后写回新结构，旧键保留（无害）。
  Future<void> _migrateOldConfig(Map<String, dynamic> cfg) async {
    final migrated = migrateFromOldConfig(cfg);
    _selectedPresetId = migrated.selectedPresetId;
    _presetParams
      ..clear()
      ..addAll(migrated.presetParams);
    _customModelName = migrated.customModelName;
    _lastThinking = migrated.lastThinking;
    _lastStreaming = migrated.lastStreaming;
    _lastSearch = migrated.lastSearch;

    await LocalConfigService.update({
      _keySelectedPreset: _selectedPresetId,
      _keyPresetParams: {
        for (final e in _presetParams.entries) e.key: e.value.toJson(),
      },
      _keyCustomModelName: _customModelName,
      _keyLastThinking: _lastThinking,
      _keyLastStreaming: _lastStreaming,
      _keyLastSearch: _lastSearch,
    });
  }

  /// 旧配置 → 新结构的纯函数（可单测）。
  @visibleForTesting
  static MigratedConfig migrateFromOldConfig(Map<String, dynamic> cfg) {
    final oldModel = (cfg[_oldKeyModel] as String?)?.trim() ?? '';
    final oldTemp = (cfg[_oldKeyTemperature] as num?)?.toDouble() ?? 1.0;
    final oldThinking = (cfg[_oldKeyThinking] as bool?) ?? true;
    final oldReasoning =
        (cfg[_oldKeyReasoningEffort] as String?) ??
        AppConfig.defaultReasoningEffort;
    final oldMaxTokens = (cfg[_oldKeyMaxTokens] as num?)?.toInt();
    final oldStreaming = (cfg[_oldKeyStreaming] as bool?) ?? true;

    final preset = ModelPresets.byModelId(oldModel);
    if (preset != null) {
      return MigratedConfig(
        selectedPresetId: preset.id,
        presetParams: {
          preset.id: PresetParamMemory(
            temperature: oldTemp,
            reasoningEffort: oldReasoning,
            maxTokens: oldMaxTokens,
          ),
        },
        customModelName: '',
        lastThinking: oldThinking,
        lastStreaming: oldStreaming,
        lastSearch: true,
      );
    }
    // 未命中内置预设（含空值 / 自定义模型名）→ 自定义模型。
    return MigratedConfig(
      selectedPresetId: ModelPresets.customId,
      presetParams: const {},
      customModelName: oldModel,
      lastThinking: oldThinking,
      lastStreaming: oldStreaming,
      lastSearch: true,
    );
  }

  // ---------------------------------------------------------------------------
  // 保存
  // ---------------------------------------------------------------------------

  /// 保存设置页表单（API 连接 + 预设选择 + 当前预设参数 + 自定义模型）。
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
    try {
      final trimmedKey = apiKey.trim();
      final trimmedBaseUrl = baseUrl.trim();
      final trimmedCustomName = customModelName.trim();

      if (trimmedKey.isNotEmpty) {
        await _secureStorage.write(key: _keyApiKey, value: trimmedKey);
      } else {
        await _secureStorage.delete(key: _keyApiKey);
      }

      // 当前预设的参数记忆（仅内置预设可调参数；自定义记录模板即可）。
      final params = Map<String, PresetParamMemory>.from(_presetParams);
      if (selectedPresetId != ModelPresets.customId) {
        params[selectedPresetId] = PresetParamMemory(
          temperature: temperature,
          reasoningEffort: reasoningEffort,
          maxTokens: maxTokens,
        );
      }

      await LocalConfigService.update({
        _keyBaseUrl: trimmedBaseUrl,
        _keySelectedPreset: selectedPresetId,
        _keyPresetParams: {
          for (final e in params.entries) e.key: e.value.toJson(),
        },
        _keyCustomModelName: trimmedCustomName,
        _keyCustomRequestBody: customRequestBody,
      });

      _apiKey = trimmedKey;
      _baseUrl = trimmedBaseUrl;
      _selectedPresetId = selectedPresetId;
      _presetParams
        ..clear()
        ..addAll(params);
      _customModelName = trimmedCustomName;
      _customRequestBody = customRequestBody;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 保存 Chat 页每轮选项（思考 / 流式 / 联网搜索）的记忆值。
  Future<bool> setPerRoundOptions({
    required bool thinking,
    required bool streaming,
    bool? search,
  }) async {
    try {
      _lastThinking = thinking;
      _lastStreaming = streaming;
      if (search != null) _lastSearch = search;
      await LocalConfigService.update({
        _keyLastThinking: _lastThinking,
        _keyLastStreaming: _lastStreaming,
        _keyLastSearch: _lastSearch,
      });
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 清除已保存的 API Key（安全存储）。
  Future<void> clearApiKey() async {
    try {
      await _secureStorage.delete(key: _keyApiKey);
      _apiKey = '';
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // 请求体构建
  // ---------------------------------------------------------------------------

  /// 按当前预设（规则）或自定义模板构建请求体。
  Map<String, dynamic> buildRequestBody(AiRequestValues values) {
    if (isCustom) {
      return AiRequestBodyBuilder.buildCustomBody(
        template: _customRequestBody,
        values: values,
      );
    }
    return AiRequestBodyBuilder.buildPresetBody(
      rules: selectedPreset.requestRules,
      values: values,
    );
  }
}
