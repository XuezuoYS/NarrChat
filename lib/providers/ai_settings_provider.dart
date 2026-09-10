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
///   内置默认平台复用旧键 `ai_api_key`，自定义平台用 `ai_api_key_<platformId>`；
/// - **其余设置**：写入本地明文 JSON `local_config/app_settings.json` 的
///   `ai` 命名空间（[aiNamespaceKey]），不进入云存储。
///
/// 分层语义（与 DeepSeek Harness 的「命名空间 → 用户层」一致）：
/// - `ai` 键缺失 / 为空 / 不可读（JSON 解析失败由 [LocalConfigService.read]
///   吞掉并返回空 Map）⇒ 平台与模型**全部遵循软件内置预置**
///   （[AiPlatforms.presetPlatforms]），UI 提示「当前为内置默认」；
/// - 用户在设置页修改并保存后，`ai.platforms` 写入**完整副本**（平台、模型、
///   参数齐全），可从文件手工编辑或转移到其它机器；
/// - 平台被重置为内置预置、且不再有自定义平台时，`platforms` 键整体消失，
///   回到"缺失即默认"的形态。
///
/// 配置结构（camelCase，均位于 `ai` 命名空间内）：
/// - `platforms`：平台数组，每个平台含 `id` / `displayName` / `apiTypeId` /
///   `baseUrl` / `supportsResponseChaining` / `models`（模型含 `id` /
///   `shortLabel` / `temperature` / `reasoningEffort` / `maxTokens` 与能力开关）；
/// - `selectedPlatformId` / `selectedModelId`：当前选中的平台与模型；
/// - `lastThinking` / `lastStreaming` / `lastSearch`：Chat 页每轮选项记忆；
/// - `maxImageSizeMB` / `convertJpgToJpeg`：图片设置。
class AiSettingsProvider extends ChangeNotifier {
  AiSettingsProvider() {
    // 未 load 也能用（测试直接构造）：内置预置平台就绪。
    _platforms = AiPlatforms.presetPlatforms;
    _selectedPlatformId = AiPlatforms.defaultPlatformId;
    _selectedModelId = AiPlatforms.defaultModelId;
  }

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  /// 内置默认平台的安全存储键（与旧版一致，老用户 Key 保留）。
  static const String _defaultKeyRef = 'ai_api_key';

  /// app_settings.json 中的 AI 设置命名空间键名。
  static const String aiNamespaceKey = 'ai';

  // ---- `ai` 命名空间内的配置键名（camelCase） ----
  static const String _keyPlatforms = 'platforms';
  static const String _keySelectedPlatformId = 'selectedPlatformId';
  static const String _keySelectedModelId = 'selectedModelId';
  static const String _keyLastThinking = 'lastThinking';
  static const String _keyLastStreaming = 'lastStreaming';
  static const String _keyLastSearch = 'lastSearch';
  static const String _keyMaxImageSizeMB = 'maxImageSizeMB';
  static const String _keyConvertJpgToJpeg = 'convertJpgToJpeg';

  /// 单张图片大小上限的默认值（MB）。
  static const int _defaultMaxImageSizeMB = 16;

  // ---- 状态 ----
  late List<AiPlatform> _platforms;
  String _selectedPlatformId = '';
  String _selectedModelId = '';
  final Map<String, String> _apiKeys = {};
  bool _lastThinking = true;
  bool _lastStreaming = true;
  bool _lastSearch = false;
  int _maxImageSizeMB = _defaultMaxImageSizeMB;
  bool _convertJpgToJpeg = false;

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

  /// 单张图片大小上限（MB，默认 16，可设置调整）。
  int get maxImageSizeMB => _maxImageSizeMB;

  /// 是否把导入的 `.jpg` 自动转换为 `.jpeg`（默认关闭）。
  bool get convertJpgToJpeg => _convertJpgToJpeg;

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

  /// 当前模型能力表（决定 Chat 页对话框内可用的模式）。
  bool get supportsStreaming => selectedModel.supportsStreaming;
  bool get supportsThinking => selectedModel.supportsThinking;
  bool get supportsSearch => selectedModel.supportsSearch;
  bool get supportsVision => selectedModel.supportsVision;

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
  // 加载
  // ---------------------------------------------------------------------------

  /// 从安全存储与本地 JSON 配置文件的 `ai` 命名空间加载设置。
  ///
  /// 命名空间缺失 / 为空 / 类型不符 / 不可读时一律回退软件内置预置（`platforms`
  /// 非数组、空数组、或逐项解析后无合法平台），**加载过程不写盘**：不迁移、
  /// 不物化、不清理历史键。
  Future<void> load() async {
    _isLoading = true;
    try {
      final section = _readAiSection(await LocalConfigService.read());
      _platforms = AiPlatforms.resolvePlatforms(section[_keyPlatforms]);
      _selectedPlatformId = _normalizePlatformId(
        section[_keySelectedPlatformId] as String?,
      );
      _selectedModelId = _normalizeModelId(
        _selectedPlatformId,
        section[_keySelectedModelId] as String?,
      );
      _lastThinking = section[_keyLastThinking] as bool? ?? true;
      _lastStreaming = section[_keyLastStreaming] as bool? ?? true;
      _lastSearch = section[_keyLastSearch] as bool? ?? false;
      _maxImageSizeMB =
          (section[_keyMaxImageSizeMB] as num?)?.toInt() ??
              _defaultMaxImageSizeMB;
      _convertJpgToJpeg = section[_keyConvertJpgToJpeg] as bool? ?? false;
      await _loadApiKeys();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 读取 `ai` 命名空间内容；不存在 / 非对象 ⇒ 空 Map（即全部遵循内置默认）。
  static Map<String, dynamic> _readAiSection(Map<String, dynamic> cfg) {
    final raw = cfg[aiNamespaceKey];
    if (raw is! Map) return const <String, dynamic>{};
    return raw.cast<String, dynamic>();
  }

  /// 选中平台归一化：未知 / 缺失 ⇒ 平台列表第一个。
  String _normalizePlatformId(String? raw) {
    if (raw != null && _platforms.any((p) => p.id == raw)) return raw;
    return _platforms.first.id;
  }

  /// 选中模型归一化：未知 / 缺失 ⇒ 该平台的第一个模型。
  String _normalizeModelId(String platformId, String? raw) {
    final platform = _platforms.firstWhere(
      (p) => p.id == platformId,
      orElse: () => _platforms.first,
    );
    if (raw != null && platform.modelById(raw) != null) return raw;
    return platform.defaultModel.id;
  }

  /// 为当前所有平台加载安全存储中的 API Key。
  Future<void> _loadApiKeys() async {
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
  // 保存
  // ---------------------------------------------------------------------------

  /// 组装 `ai` 命名空间的完整用户层内容。
  ///
  /// 与内置预置完全一致时**不写** `platforms`（等价于"未自定义平台"），
  /// 使重置回预置后文件自动回到"缺失即默认"的形态；其余键始终写全量，
  /// 便于用户查看、手工修改与转移。
  Map<String, dynamic> _buildAiSection({
    List<AiPlatform>? platforms,
    String? selectedPlatformId,
    String? selectedModelId,
  }) {
    final list = platforms ?? _platforms;
    return {
      if (!AiPlatforms.matchesPresets(list))
        _keyPlatforms: [for (final p in list) p.toJson()],
      _keySelectedPlatformId: selectedPlatformId ?? _selectedPlatformId,
      _keySelectedModelId: selectedModelId ?? _selectedModelId,
      _keyLastThinking: _lastThinking,
      _keyLastStreaming: _lastStreaming,
      _keyLastSearch: _lastSearch,
      _keyMaxImageSizeMB: _maxImageSizeMB,
      _keyConvertJpgToJpeg: _convertJpgToJpeg,
    };
  }

  /// 写入 `ai` 命名空间（整体替换，命名空间内不会丢键；其它顶层键不受影响）。
  Future<void> _persistAiSection() =>
      LocalConfigService.update({aiNamespaceKey: _buildAiSection()});

  /// 保存设置页（AI 模块）的全量平台结构。
  ///
  /// [platforms] 为编辑后的平台列表；[apiKeys] 为平台 id → API Key（空串表示无）。
  /// 校验平台与模型非空后落库（密钥写安全存储、配置写 `ai` 命名空间内）。
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

      // 先落盘再更新内存态：写盘失败时保持原状态。
      await LocalConfigService.update({
        aiNamespaceKey: _buildAiSection(
          platforms: normalizedPlatforms,
          selectedPlatformId: normPlatformId,
          selectedModelId: normModelId,
        ),
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
      await _persistAiSection();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 设置单张图片大小上限（MB，用于导入校验），并持久化。
  Future<bool> setMaxImageSizeMB(int mb) async {
    final value = mb < 1 ? 1 : mb;
    _maxImageSizeMB = value;
    notifyListeners();
    try {
      await _persistAiSection();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 设置「导入时自动将 .jpg 转换为 .jpeg」开关，并持久化。
  ///
  /// 先乐观更新 UI 再异步持久化：即便磁盘写入慢或失败，界面也会立即反馈。
  Future<bool> setConvertJpgToJpeg(bool value) async {
    _convertJpgToJpeg = value;
    notifyListeners();
    try {
      await _persistAiSection();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 切换当前对话所用模型（跨平台），并持久化选中项。
  ///
  /// 由 Chat 页右下角模型选择器调用；模型/平台需已存在，否则返回 false 不变更。
  Future<bool> setSelectedModel(String platformId, String modelId) async {
    if (!_platforms.any((p) => p.id == platformId)) return false;
    final platform = _platforms.firstWhere((p) => p.id == platformId);
    if (platform.modelById(modelId) == null) return false;
    _selectedPlatformId = platformId;
    _selectedModelId = modelId;
    notifyListeners();
    try {
      await _persistAiSection();
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

  /// 按当前模型构建请求体（由所属平台接入协议规则组合）。
  Map<String, dynamic> buildRequestBody(AiRequestValues values) {
    return AiRequestBodyBuilder.buildPresetBody(
      rules: selectedPlatform.apiType.requestRules,
      values: values,
    );
  }
}
