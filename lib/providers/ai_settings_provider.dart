import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/ai_platforms.dart';
import '../config/app_config.dart';
import '../models/ai_platform.dart';
import '../services/ai_request_body_builder.dart';
import '../services/local_config_service.dart';

/// AI 接口设置状态管理（平台 + 模型两级结构，参考 DeepSeek Harness 的
/// `providers[].models[]` 组织方式）。
///
/// 本地存储策略（符合 AGENTS.md 数据结构规范）：
/// - **API Key**：按平台写入 `flutter_secure_storage`，禁止明文落盘。
///   内置默认平台复用旧键 `ai_api_key`（老用户无感迁移），自定义平台用
///   `ai_api_key_<platformId>`；
/// - **其余设置**：写入本地明文 JSON `local_config/app_settings.json`
///   （[LocalConfigService]），不进入云存储。
///
/// 配置结构（camelCase）：
/// - `platforms`：平台数组，每个平台含 `id` / `displayName` / `apiTypeId` /
///   `baseUrl` / `isBuiltin` / `models`（模型含 `id` / `shortLabel` /
///   `temperature` / `reasoningEffort` / `maxTokens` / `requestTemplate`）；
/// - `selectedPlatformId` / `selectedModelId`：当前选中的平台与模型；
/// - `lastThinking` / `lastStreaming` / `lastSearch`：Chat 页每轮选项记忆。
class AiSettingsProvider extends ChangeNotifier {
  AiSettingsProvider() {
    // 未 load 也能用（测试直接构造）：内置默认平台就绪。
    _platforms = [AiPlatforms.defaultPlatform];
    _selectedPlatformId = AiPlatforms.defaultPlatformId;
    _selectedModelId = AiPlatforms.defaultModelId;
  }

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  /// 内置默认平台的安全存储键（与旧版一致，老用户 Key 保留）。
  static const String _defaultKeyRef = 'ai_api_key';

  // ---- 本地 JSON 配置文件键名（camelCase） ----
  static const String _keyPlatforms = 'platforms';
  static const String _keySelectedPlatformId = 'selectedPlatformId';
  static const String _keySelectedModelId = 'selectedModelId';
  static const String _keyLastThinking = 'lastThinking';
  static const String _keyLastStreaming = 'lastStreaming';
  static const String _keyLastSearch = 'lastSearch';

  // ---- 旧版（v2：selectedPreset 结构）配置键，用于迁移 ----
  static const String _keyBaseUrl = 'baseUrl';
  static const String _keySelectedPreset = 'selectedPreset';
  static const String _keyPresetParams = 'presetParams';
  static const String _keyCustomModelName = 'customModelName';
  static const String _keyCustomRequestBody = 'customRequestBody';

  // ---- 旧版（v1.2.x 及更早）配置键，用于迁移 ----
  static const String _oldKeyModel = 'model';
  static const String _oldKeyTemperature = 'temperature';
  static const String _oldKeyThinking = 'thinking';
  static const String _oldKeyReasoningEffort = 'reasoningEffort';
  static const String _oldKeyMaxTokens = 'maxTokens';
  static const String _oldKeyStreaming = 'streaming';

  // ---- 状态 ----
  late List<AiPlatform> _platforms;
  String _selectedPlatformId = '';
  String _selectedModelId = '';
  final Map<String, String> _apiKeys = {};
  bool _lastThinking = true;
  bool _lastStreaming = true;
  bool _lastSearch = false;

  bool _isLoading = false;
  String? _error;

  // ---------------------------------------------------------------------------
  // 派生状态
  // ---------------------------------------------------------------------------
  List<AiPlatform> get platforms => List.unmodifiable(_platforms);
  String get selectedPlatformId => _selectedPlatformId;
  String get selectedModelId => _selectedModelId;
  bool get lastSearch => _lastSearch;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 当前选中的平台（未知回退平台列表第一个）。
  AiPlatform get selectedPlatform {
    for (final p in _platforms) {
      if (p.id == _selectedPlatformId) return p;
    }
    return _platforms.first;
  }

  /// 当前选中的模型（未命中回退该平台默认模型）。
  AiModel get selectedModel => selectedPlatform.modelOrFirst(_selectedModelId);

  /// 实际发送给 API 的模型名。
  String get model => selectedModel.id;

  /// 当前平台接口地址（空则回退默认）。
  String get baseUrl => selectedPlatform.baseUrl.isEmpty
      ? AppConfig.defaultApiBaseUrlEffective
      : selectedPlatform.baseUrl;

  /// 当前平台接入协议 id。
  String get apiTypeId => selectedPlatform.apiTypeId;

  /// 当前平台能力表（来自接入协议）。
  bool get supportsStreaming => selectedPlatform.apiType.supportsStreaming;
  bool get supportsThinking => selectedPlatform.apiType.supportsThinking;
  bool get supportsSearch => selectedPlatform.apiType.supportsSearch;

  /// 当前模型有效温度。
  double get temperature => selectedModel.temperature;

  /// 当前模型有效推理强度。
  String get reasoningEffort => selectedModel.reasoningEffort;

  /// 当前模型有效最大输出 Tokens。
  int? get maxTokens => selectedModel.maxTokens;

  /// 当前平台 API Key（默认平台空时回退默认值）。
  String get apiKey {
    final key = _apiKeys[selectedPlatform.id];
    if (key != null && key.isNotEmpty) return key;
    if (selectedPlatform.id == AiPlatforms.defaultPlatformId) {
      return AppConfig.defaultApiKeyEffective;
    }
    return '';
  }

  /// 是否已配置有效的 API Key。
  bool get hasApiKey => apiKey.trim().isNotEmpty;

  /// 每轮思考选项（记忆值，并按平台能力收敛）。
  bool get thinking => _lastThinking && supportsThinking;

  /// 每轮流式选项（记忆值，并按平台能力收敛）。
  bool get streaming => _lastStreaming && supportsStreaming;

  /// 指定平台的 API Key（供设置编辑器读取）。
  String apiKeyFor(String platformId) => _apiKeys[platformId] ?? '';

  // ---------------------------------------------------------------------------
  // 加载与迁移
  // ---------------------------------------------------------------------------

  /// 从安全存储与本地 JSON 配置文件中加载设置（旧版配置自动迁移）。
  Future<void> load() async {
    _isLoading = true;
    try {
      final cfg = await LocalConfigService.read();
      if (cfg.containsKey(_keyPlatforms)) {
        _readPlatforms(cfg);
        _lastThinking = (cfg[_keyLastThinking] as bool?) ?? true;
        _lastStreaming = (cfg[_keyLastStreaming] as bool?) ?? true;
        _lastSearch = (cfg[_keyLastSearch] as bool?) ?? false;
      } else if (cfg.containsKey(_keySelectedPreset)) {
        final migrated = migrateFromV2(cfg);
        _applyPlatformsConfig(migrated);
        _lastThinking = (cfg[_keyLastThinking] as bool?) ?? true;
        _lastStreaming = (cfg[_keyLastStreaming] as bool?) ?? true;
        _lastSearch = (cfg[_keyLastSearch] as bool?) ?? false;
        await _persistPlatformsConfig(migrated);
      } else {
        final migrated = migrateFromV1(cfg);
        _applyPlatformsConfig(migrated);
        _lastThinking = (cfg[_oldKeyThinking] as bool?) ?? true;
        _lastStreaming = (cfg[_oldKeyStreaming] as bool?) ?? true;
        _lastSearch = false;
        await _persistPlatformsConfig(migrated);
      }
      await _loadApiKeys(cfg);
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _readPlatforms(Map<String, dynamic> cfg) {
    final raw = (cfg[_keyPlatforms] as List<dynamic>?) ?? const [];
    final parsed = <AiPlatform>[
      for (final e in raw)
        AiPlatform.fromJson((e as Map).cast<String, dynamic>()),
    ];
    _platforms = parsed.isEmpty ? [AiPlatforms.defaultPlatform] : parsed;
    _selectedPlatformId =
        (cfg[_keySelectedPlatformId] as String?) ?? _platforms.first.id;
    if (!_platforms.any((p) => p.id == _selectedPlatformId)) {
      _selectedPlatformId = _platforms.first.id;
    }
    final platform = _platforms.firstWhere(
      (p) => p.id == _selectedPlatformId,
      orElse: () => _platforms.first,
    );
    _selectedModelId = (cfg[_keySelectedModelId] as String?) ?? '';
    if (platform.modelById(_selectedModelId) == null) {
      _selectedModelId = platform.models.isNotEmpty
          ? platform.models.first.id
          : '';
    }
  }

  void _applyPlatformsConfig(AiPlatformsConfig config) {
    _platforms = List.of(config.platforms);
    _selectedPlatformId = config.selectedPlatformId;
    _selectedModelId = config.selectedModelId;
  }

  Future<void> _persistPlatformsConfig(AiPlatformsConfig config) async {
    await LocalConfigService.update(config.toJson());
  }

  /// 为当前所有平台加载安全存储中的 API Key。
  Future<void> _loadApiKeys(Map<String, dynamic> cfg) async {
    _apiKeys.clear();
    for (final platform in _platforms) {
      final stored = await _secureStorage.read(key: _keyRefFor(platform.id));
      if (stored != null && stored.isNotEmpty) {
        _apiKeys[platform.id] = stored;
      }
    }
  }

  /// 指定平台的安全存储键名。
  static String _keyRefFor(String platformId) {
    return platformId == AiPlatforms.defaultPlatformId
        ? _defaultKeyRef
        : 'ai_api_key_$platformId';
  }

  // ---------------------------------------------------------------------------
  // 旧版迁移（纯函数，可单测）
  // ---------------------------------------------------------------------------

  /// v1.2.x 旧结构（`model` / `temperature` / `thinking` /
  /// `reasoningEffort` / `maxTokens` / `streaming`）→ 平台结构。
  ///
  /// - `model` 命中内置模型 → 默认平台该模型（并入旧参数）；
  /// - 否则 → 默认平台追加一个自定义模型（名称取旧 model，无参时回退默认模型）。
  @visibleForTesting
  static AiPlatformsConfig migrateFromV1(Map<String, dynamic> cfg) {
    final oldModel = (cfg[_oldKeyModel] as String?)?.trim() ?? '';
    final oldTemp = (cfg[_oldKeyTemperature] as num?)?.toDouble() ?? 1.0;
    final oldReasoning =
        (cfg[_oldKeyReasoningEffort] as String?) ??
        AppConfig.defaultReasoningEffort;
    final oldMaxTokens = (cfg[_oldKeyMaxTokens] as num?)?.toInt();

    final base = AiPlatforms.defaultPlatform;
    final known = base.modelById(oldModel);
    var models = <AiModel>[];
    String selectedModelId;
    if (known != null) {
      models = [
        for (final m in base.models)
          m.id == known.id
              ? m.copyWith(
                  temperature: oldTemp,
                  reasoningEffort: oldReasoning,
                  maxTokens: oldMaxTokens,
                )
              : m,
      ];
      selectedModelId = known.id;
    } else {
      final custom = oldModel.isEmpty
          ? null
          : AiModel(
              id: oldModel,
              temperature: oldTemp,
              reasoningEffort: oldReasoning,
              maxTokens: oldMaxTokens,
            );
      models = [...base.models, ?custom];
      selectedModelId = custom?.id ?? base.defaultModel.id;
    }
    return AiPlatformsConfig(
      platforms: [base.copyWith(models: models)],
      selectedPlatformId: base.id,
      selectedModelId: selectedModelId,
    );
  }

  /// v2 结构（`selectedPreset` / `presetParams` / `customModelName` /
  /// `customRequestBody` + `baseUrl`）→ 平台结构。
  ///
  /// - `baseUrl` → 默认平台接口地址；
  /// - `presetParams`（按预设 id 记忆）应用到默认平台的同名模型；
  /// - 旧自定义模型（`customModelName` + `customRequestBody`）→ 默认平台追加一个
  ///   模型，`requestTemplate` 取旧模板（等于默认模板时可留空）。
  @visibleForTesting
  static AiPlatformsConfig migrateFromV2(Map<String, dynamic> cfg) {
    final presetId = (cfg[_keySelectedPreset] as String?) ?? '';
    final baseUrl =
        (cfg[_keyBaseUrl] as String?) ?? AppConfig.defaultApiBaseUrlEffective;
    final presetParams =
        (cfg[_keyPresetParams] as Map<String, dynamic>?) ?? const {};
    final customName = (cfg[_keyCustomModelName] as String?)?.trim() ?? '';
    final customBody = (cfg[_keyCustomRequestBody] as String?) ?? '';
    final isCustom = presetId == '__custom__';

    final base = AiPlatforms.defaultPlatform.copyWith(baseUrl: baseUrl);
    final models = <AiModel>[
      for (final m in base.models)
        _applyPresetMemory(m, presetParams[m.id]),
    ];

    String selectedModelId;
    if (isCustom && customName.isNotEmpty) {
      models.add(
        AiModel(
          id: customName,
          temperature: 1.0,
          reasoningEffort: AppConfig.defaultReasoningEffort,
          requestTemplate: customBody.trim().isEmpty ? null : customBody,
        ),
      );
      selectedModelId = customName;
    } else {
      selectedModelId = models.any((m) => m.id == presetId)
          ? presetId
          : models.first.id;
    }

    return AiPlatformsConfig(
      platforms: [base.copyWith(models: models)],
      selectedPlatformId: base.id,
      selectedModelId: selectedModelId,
    );
  }

  /// 把旧「预设参数记忆」应用到同名模型；无记忆则保持模型默认。
  static AiModel _applyPresetMemory(AiModel model, Object? rawMemory) {
    if (rawMemory is! Map) return model;
    final map = rawMemory.cast<String, dynamic>();
    return model.copyWith(
      temperature: (map['temperature'] as num?)?.toDouble() ?? model.temperature,
      reasoningEffort: map['reasoningEffort'] as String? ?? model.reasoningEffort,
      maxTokens: (map['maxTokens'] as num?)?.toInt() ?? model.maxTokens,
    );
  }

  // ---------------------------------------------------------------------------
  // 保存
  // ---------------------------------------------------------------------------

  /// 保存设置页（AI 模块）的全量平台结构。
  ///
  /// [platforms] 为编辑后的平台列表；[apiKeys] 为平台 id → API Key（空串表示无）。
  /// 校验平台与模型非空后落库（密钥写安全存储、配置写 LocalConfig）。
  Future<bool> save({
    required List<AiPlatform> platforms,
    required String selectedPlatformId,
    required String selectedModelId,
    required Map<String, String> apiKeys,
  }) async {
    try {
      if (platforms.isEmpty) {
        _error = '至少需要保留一个平台';
        notifyListeners();
        return false;
      }
      for (final p in platforms) {
        if (p.models.isEmpty) {
          _error = '平台「${p.displayName}」至少需要一个模型';
          notifyListeners();
          return false;
        }
      }

      // 归一化选中项：平台与模型必须存在于列表中，否则回退到平台默认。
      final normalizedPlatforms = List<AiPlatform>.from(platforms);
      final normPlatformId = normalizedPlatforms.any(
        (p) => p.id == selectedPlatformId,
      )
          ? selectedPlatformId
          : normalizedPlatforms.first.id;
      final normPlatform = normalizedPlatforms.firstWhere(
        (p) => p.id == normPlatformId,
      );
      final normModelId = normPlatform.models.any(
        (m) => m.id == selectedModelId,
      )
          ? selectedModelId
          : normPlatform.defaultModel.id;

      // 写各平台 API Key（空则清除，回退默认）。
      for (final p in normalizedPlatforms) {
        final key = (apiKeys[p.id] ?? '').trim();
        final ref = _keyRefFor(p.id);
        if (key.isNotEmpty) {
          await _secureStorage.write(key: ref, value: key);
        } else {
          await _secureStorage.delete(key: ref);
        }
      }

      await LocalConfigService.update({
        _keyPlatforms: [for (final p in normalizedPlatforms) p.toJson()],
        _keySelectedPlatformId: normPlatformId,
        _keySelectedModelId: normModelId,
      });

      _platforms = normalizedPlatforms;
      _selectedPlatformId = normPlatformId;
      _selectedModelId = normModelId;
      _apiKeys
        ..clear()
        ..addAll({
          for (final p in normalizedPlatforms)
            p.id: (apiKeys[p.id] ?? '').trim(),
        });
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 保存 Chat 页每轮选项（思考 / 流式 / 联网搜索）的记忆值。
  ///
  /// 先乐观更新 UI 再异步持久化：即便磁盘写入慢或失败，界面也会立即反馈。
  Future<bool> setPerRoundOptions({
    required bool thinking,
    required bool streaming,
    bool? search,
  }) async {
    _lastThinking = thinking;
    _lastStreaming = streaming;
    if (search != null) _lastSearch = search;
    notifyListeners();
    try {
      await LocalConfigService.update({
        _keyLastThinking: _lastThinking,
        _keyLastStreaming: _lastStreaming,
        _keyLastSearch: _lastSearch,
      });
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 清除已保存的当前平台 API Key（安全存储）。
  Future<void> clearApiKey() async {
    try {
      final ref = _keyRefFor(selectedPlatform.id);
      await _secureStorage.delete(key: ref);
      _apiKeys.remove(selectedPlatform.id);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // 请求体构建
  // ---------------------------------------------------------------------------

  /// 按当前模型构建请求体：模型带自定义模板则走模板直发，否则按平台接入协议规则。
  Map<String, dynamic> buildRequestBody(AiRequestValues values) {
    final model = selectedModel;
    final template = model.requestTemplate;
    if (template != null && template.trim().isNotEmpty) {
      return AiRequestBodyBuilder.buildCustomBody(
        template: template,
        values: values,
      );
    }
    return AiRequestBodyBuilder.buildPresetBody(
      rules: selectedPlatform.apiType.requestRules,
      values: values,
    );
  }
}
