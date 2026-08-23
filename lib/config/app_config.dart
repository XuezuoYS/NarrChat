import 'ai_platforms.dart';

/// 应用全局配置。
///
/// API Key 与 Base URL 的默认值写在此处；运行时实际值由
/// [AiSettingsProvider] 从安全存储（flutter_secure_storage）与本地 JSON 配置文件
/// （local_config/app_settings.json）中读取，并可在「AI 选择」设置页中修改。
/// 也支持通过 `--dart-define` 覆盖默认值，例如：
/// ```bash
/// flutter run --dart-define=NARRCHAT_API_KEY=sk-xxx \
///             --dart-define=NARRCHAT_API_BASE_URL=https://api.deepseek.com \
///             --dart-define=NARRCHAT_MODEL=deepseek-v4-flash
/// ```
///
/// 参数与模型名以官方文档为准：
/// https://api-docs.deepseek.com/zh-cn/api/create-chat-completion
class AppConfig {
  AppConfig._();

  /// 默认 API Base URL（OpenAI 兼容格式，DeepSeek 官方地址）。
  static const String defaultApiBaseUrl = 'https://api.deepseek.com';

  /// 默认 API Key（请通过「AI 选择」设置页或安全存储配置）。
  static const String defaultApiKey = '';

  /// 默认模型名称（DeepSeek 官方模型 ID）。
  static const String defaultModelName = 'deepseek-v4-flash';

  /// 内置支持的模型列表（来自默认平台，可在设置中选择，也支持自定义输入）。
  static List<String> get supportedModels => [
    for (final m in AiPlatforms.defaultPlatform.models) m.id,
  ];

  /// 思考强度档位（`reasoning_effort`，官方取值）。
  static const List<String> reasoningEffortOptions = ['low', 'high', 'max'];

  /// 默认思考强度。
  static const String defaultReasoningEffort = 'high';

  /// 默认最大输出 Tokens（null 表示不限制，由服务端决定）。
  static const int? defaultMaxTokens = null;

  /// 温度可调范围（官方：0 ~ 2，默认 1）。
  static const double minTemperature = 0.0;
  static const double maxTemperature = 2.0;

  // 通过 --dart-define 注入的环境变量覆盖（仅覆盖默认值）。
  static const String _envApiBaseUrl = String.fromEnvironment('NARRCHAT_API_BASE_URL');
  static const String _envApiKey = String.fromEnvironment('NARRCHAT_API_KEY');
  static const String _envModelName = String.fromEnvironment('NARRCHAT_MODEL');

  static String get defaultApiBaseUrlEffective =>
      _envApiBaseUrl.isNotEmpty ? _envApiBaseUrl : defaultApiBaseUrl;

  static String get defaultApiKeyEffective =>
      _envApiKey.isNotEmpty ? _envApiKey : defaultApiKey;

  static String get defaultModelNameEffective =>
      _envModelName.isNotEmpty ? _envModelName : defaultModelName;

  /// 请求大模型 API 的超时时间。
  static const Duration requestTimeout = Duration(seconds: 180);
}

