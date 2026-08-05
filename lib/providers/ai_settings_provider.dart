import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/ai_settings.dart';

/// AI 接口设置状态管理。
///
/// 安全存储策略（符合业界本地安全存储标准）：
/// - **API Key**：写入 `flutter_secure_storage`
///   （Android 使用 Keystore/加密存储，Windows 使用 DPAPI/凭据管理器）；
/// - 其余设置（Base URL、模型、温度、思考、流式）：写入 `shared_preferences`。
class AiSettingsProvider extends ChangeNotifier {
  AiSettingsProvider(this._prefs);

  final SharedPreferences _prefs;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static const String _keyApiKey = 'ai_api_key';
  static const String _keyBaseUrl = 'ai_base_url';
  static const String _keyModel = 'ai_model';
  static const String _keyTemperature = 'ai_temperature';
  static const String _keyThinking = 'ai_thinking';
  static const String _keyReasoningEffort = 'ai_reasoning_effort';
  static const String _keyMaxTokens = 'ai_max_tokens';
  static const String _keyStreaming = 'ai_streaming';

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

  /// 从安全存储与偏好设置中加载设置。
  Future<void> load() async {
    _isLoading = true;
    try {
      final storedKey = await _secureStorage.read(key: _keyApiKey);
      _apiKey = (storedKey ?? '').isNotEmpty ? storedKey! : AppConfig.defaultApiKeyEffective;
      _baseUrl = _prefs.getString(_keyBaseUrl) ?? AppConfig.defaultApiBaseUrlEffective;
      _model = _prefs.getString(_keyModel) ?? AppConfig.defaultModelNameEffective;
      _temperature = _prefs.getDouble(_keyTemperature) ?? 1.0;
      _thinking = _prefs.getBool(_keyThinking) ?? false;
      _reasoningEffort =
          _prefs.getString(_keyReasoningEffort) ?? AppConfig.defaultReasoningEffort;
      _maxTokens = _prefs.getInt(_keyMaxTokens);
      _streaming = _prefs.getBool(_keyStreaming) ?? true;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 保存设置。API Key 写入安全存储，其余写入偏好设置。
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
      await _prefs.setString(_keyBaseUrl, trimmedBaseUrl);
      await _prefs.setString(_keyModel, trimmedModel);
      await _prefs.setDouble(_keyTemperature, temperature);
      await _prefs.setBool(_keyThinking, thinking);
      await _prefs.setString(_keyReasoningEffort, reasoningEffort);
      if (maxTokens != null && maxTokens > 0) {
        await _prefs.setInt(_keyMaxTokens, maxTokens);
      } else {
        await _prefs.remove(_keyMaxTokens);
      }
      await _prefs.setBool(_keyStreaming, streaming);

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
