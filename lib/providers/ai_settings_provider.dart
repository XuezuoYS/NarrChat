import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/app_config.dart';
import '../models/ai_settings.dart';
import '../services/local_config_service.dart';

/// AI 接口设置状态管理。
///
/// 本地存储策略（符合 AGENTS.md 数据结构规范）：
/// - **API Key**：写入 `flutter_secure_storage`
///   （Android 使用 Keystore/加密存储，Windows 使用 DPAPI/凭据管理器），禁止明文落盘；
/// - 其余设置（Base URL、模型、温度、思考、流式）：写入本地明文 JSON 配置文件
///   `local_config/app_settings.json`（[LocalConfigService]），不进入云存储。
class AiSettingsProvider extends ChangeNotifier {
  AiSettingsProvider();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static const String _keyApiKey = 'ai_api_key';

  /// 本地 JSON 配置文件中的键名（camelCase）。
  static const String _keyBaseUrl = 'baseUrl';
  static const String _keyModel = 'model';
  static const String _keyTemperature = 'temperature';
  static const String _keyThinking = 'thinking';
  static const String _keyReasoningEffort = 'reasoningEffort';
  static const String _keyMaxTokens = 'maxTokens';
  static const String _keyStreaming = 'streaming';

  String _apiKey = AppConfig.defaultApiKeyEffective;
  String _baseUrl = AppConfig.defaultApiBaseUrlEffective;
  String _model = AppConfig.defaultModelNameEffective;
  double _temperature = 1.0;
  bool _thinking = false;
  String _reasoningEffort = AppConfig.defaultReasoningEffort;
  int? _maxTokens = AppConfig.defaultMaxTokens;
  bool _streaming = true;

  bool _isLoading = false;
  String? _error;

  String get apiKey => _apiKey;
  String get baseUrl => _baseUrl;
  String get model => _model;
  double get temperature => _temperature;
  bool get thinking => _thinking;
  String get reasoningEffort => _reasoningEffort;
  int? get maxTokens => _maxTokens;
  bool get streaming => _streaming;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 是否已配置有效的 API Key。
  bool get hasApiKey => _apiKey.trim().isNotEmpty;

  AiSettings get settings => AiSettings(
    apiBaseUrl: _baseUrl,
    apiKey: _apiKey,
    model: _model,
    temperature: _temperature,
    thinking: _thinking,
    reasoningEffort: _reasoningEffort,
    maxTokens: _maxTokens,
    streaming: _streaming,
  );

  /// 从安全存储与本地 JSON 配置文件中加载设置。
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
      _model =
          (cfg[_keyModel] as String?) ?? AppConfig.defaultModelNameEffective;
      _temperature = (cfg[_keyTemperature] as num?)?.toDouble() ?? 1.0;
      _thinking = (cfg[_keyThinking] as bool?) ?? false;
      _reasoningEffort =
          (cfg[_keyReasoningEffort] as String?) ??
          AppConfig.defaultReasoningEffort;
      _maxTokens = (cfg[_keyMaxTokens] as num?)?.toInt();
      _streaming = (cfg[_keyStreaming] as bool?) ?? true;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 保存设置。API Key 写入安全存储，其余写入本地 JSON 配置文件。
  Future<bool> save({
    required String apiKey,
    required String baseUrl,
    required String model,
    required double temperature,
    required bool thinking,
    required String reasoningEffort,
    required int? maxTokens,
    required bool streaming,
  }) async {
    try {
      final trimmedKey = apiKey.trim();
      final trimmedBaseUrl = baseUrl.trim();
      final trimmedModel = model.trim();
      if (trimmedKey.isNotEmpty) {
        await _secureStorage.write(key: _keyApiKey, value: trimmedKey);
      } else {
        await _secureStorage.delete(key: _keyApiKey);
      }
      // 局部合并写入，避免覆盖文件中未来的其他本地配置（如 UI 设置）。
      await LocalConfigService.update({
        _keyBaseUrl: trimmedBaseUrl,
        _keyModel: trimmedModel,
        _keyTemperature: temperature,
        _keyThinking: thinking,
        _keyReasoningEffort: reasoningEffort,
        if (maxTokens != null && maxTokens > 0) _keyMaxTokens: maxTokens,
        _keyStreaming: streaming,
      });

      _apiKey = trimmedKey;
      _baseUrl = trimmedBaseUrl;
      _model = trimmedModel;
      _temperature = temperature;
      _thinking = thinking;
      _reasoningEffort = reasoningEffort;
      _maxTokens = (maxTokens != null && maxTokens > 0) ? maxTokens : null;
      _streaming = streaming;
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
}
