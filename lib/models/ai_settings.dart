/// AI 接口设置（模型、温度、思考、推理强度、流式等）。
class AiSettings {
  final String apiBaseUrl;
  final String apiKey;
  final String model;

  /// 采样温度（0 ~ 2）。注意：思考模式下官方不支持 temperature，不会生效。
  final double temperature;

  /// 是否启用思考模式（`thinking.type = enabled/disabled`）。
  final bool thinking;

  /// 思考强度（`reasoning_effort`：low / high / max，官方默认 high）。
  final String reasoningEffort;

  /// 最大输出 Tokens（null 表示不限制，由服务端决定）。
  final int? maxTokens;

  /// 是否启用流式输出（SSE）。
  final bool streaming;

  const AiSettings({
    required this.apiBaseUrl,
    required this.apiKey,
    required this.model,
    required this.temperature,
    required this.thinking,
    required this.reasoningEffort,
    required this.maxTokens,
    required this.streaming,
  });

  AiSettings copyWith({
    String? apiBaseUrl,
    String? apiKey,
    String? model,
    double? temperature,
    bool? thinking,
    String? reasoningEffort,
    int? maxTokens,
    bool? streaming,
  }) {
    return AiSettings(
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
      thinking: thinking ?? this.thinking,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      maxTokens: maxTokens ?? this.maxTokens,
      streaming: streaming ?? this.streaming,
    );
  }
}
