/// 请求体参数注入条件的枚举。
///
/// 每个 [ParamRule] 声明「当某个模式条件满足时」注入哪些请求参数，
/// 由构建器按当前模式组合（思考 / 联网搜索 / 流式）合并命中规则。
enum ParamCondition {
  /// 任何模式下都注入。
  always,

  /// 思考模式开启时注入。
  thinking,

  /// 思考模式关闭时注入。
  notThinking,

  /// 联网搜索开启时注入（[AiRequestValues.tools] 非空）。
  search,

  /// 联网搜索关闭时注入（[AiRequestValues.tools] 为空）。
  notSearch,

  /// 流式输出开启时注入。
  stream,

  /// 流式输出关闭时注入。
  notStream,
}

/// 一条参数注入规则：当 [condition] 满足时，把 [params] 合并进请求体。
///
/// [params] 的值支持占位符（如 `{{temperature}}`、`{{max_tokens}}`），
/// 由 `AiRequestBodyBuilder` 在合并时替换为实际值；值为 `null` 的
/// 占位符（如未设置最大 Tokens）会**移除**该顶层键。
class ParamRule {
  final ParamCondition condition;

  /// 要注入的参数字段（键值对），值可含占位符。
  final Map<String, dynamic> params;

  const ParamRule(this.condition, this.params);
}

/// 预设的请求体动态组合规则集合（声明式、纯数据）。
///
/// 各规则按 [rules] 中的顺序合并，后出现的同名字段覆盖先出现的。
/// 不同模型可通过不同规则组合定义各自的请求体结构，无需改动构建器。
class RequestParamRules {
  final List<ParamRule> rules;

  const RequestParamRules(this.rules);
}

/// 某预设下用户调整过的参数（每个预设独立记忆，切换预设互不影响）。
class PresetParamMemory {
  final double temperature;
  final String reasoningEffort;
  final int? maxTokens;

  const PresetParamMemory({
    required this.temperature,
    required this.reasoningEffort,
    this.maxTokens,
  });

  Map<String, dynamic> toJson() {
    final max = maxTokens;
    return {
      'temperature': temperature,
      'reasoningEffort': reasoningEffort,
      if (max != null && max > 0) 'maxTokens': max,
    };
  }

  factory PresetParamMemory.fromJson(Map<String, dynamic> json) {
    return PresetParamMemory(
      temperature: (json['temperature'] as num?)?.toDouble() ?? 1.0,
      reasoningEffort:
          (json['reasoningEffort'] as String?) ?? 'high',
      maxTokens: (json['maxTokens'] as num?)?.toInt(),
    );
  }
}

/// 模型预设：模型 + 能力表 + 默认参数 + 请求体组合规则 + 参数说明。
///
/// 预设决定了：
/// - 能力表（[supportsStreaming] / [supportsThinking] / [supportsSearch]）：
///   Chat 页每轮选项下拉中可用的选项；
/// - 默认参数（[defaultTemperature] 等）：用户未调整时的取值；
/// - 请求体动态组合规则（[requestRules]）：不同模式下发送的请求参数结构；
/// - 参数次级说明（[temperatureNote] 等）：设置页「参数始终启用」下的特殊情况提示。
class ModelPreset {
  /// 预设唯一标识（与 [modelId] 一致，内置预设为官方模型 ID）。
  final String id;

  /// 展示名称。
  final String displayName;

  /// 实际发送给 API 的模型名。
  final String modelId;

  // ---- 能力表 ----
  final bool supportsStreaming;
  final bool supportsThinking;
  final bool supportsSearch;

  // ---- 默认参数 ----
  final double defaultTemperature;
  final bool defaultThinking;
  final String defaultReasoningEffort;
  final int? defaultMaxTokens;
  final bool defaultStreaming;

  // ---- 请求体动态组合规则 ----
  final RequestParamRules requestRules;

  // ---- 参数次级说明 ----
  final String? temperatureNote;
  final String? reasoningEffortNote;
  final String? maxTokensNote;

  const ModelPreset({
    required this.id,
    required this.displayName,
    required this.modelId,
    required this.supportsStreaming,
    required this.supportsThinking,
    required this.supportsSearch,
    required this.defaultTemperature,
    required this.defaultThinking,
    required this.defaultReasoningEffort,
    required this.defaultMaxTokens,
    required this.defaultStreaming,
    required this.requestRules,
    this.temperatureNote,
    this.reasoningEffortNote,
    this.maxTokensNote,
  });
}
