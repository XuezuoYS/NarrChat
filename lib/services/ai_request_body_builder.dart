import '../models/api_type.dart';

/// 请求体构建所需的动态值（由调用方按当前设置与每轮选项组装）。
class AiRequestValues {
  /// 实际发送的模型名。
  final String model;

  /// messages 数组（system → 历史 user/assistant → 当前 user）。
  final List<Map<String, dynamic>> messages;

  /// 采样温度。
  final double temperature;

  /// 是否思考模式。
  final bool thinking;

  /// 推理强度（思考模式下生效）。
  final String reasoningEffort;

  /// 最大输出 Tokens（null 表示不限制）。
  final int? maxTokens;

  /// 是否流式输出。
  final bool stream;

  /// 工具列表（联网搜索等）；null 表示本轮不注入工具。
  final List<Map<String, dynamic>>? tools;

  /// 系统指令（Response API 协议的 `instructions` 字段；null 表示移除该键）。
  final String? instructions;

  /// 工具选择策略（`tool_choice`：`auto` / `required` / `none`；null = 不发送）。
  ///
  /// 仅 AGENT 模式使用：正文轮 `auto`，状态轮 `required`（强制调用工具，
  /// 杜绝「只写正文不改状态」）。两阶段的 `instructions` / `tools` 必须
  /// **完全一致**（工具取超集），否则请求前缀变化会让服务商的上下文缓存失效。
  final String? toolChoice;

  const AiRequestValues({
    required this.model,
    required this.messages,
    required this.temperature,
    required this.thinking,
    required this.reasoningEffort,
    required this.maxTokens,
    required this.stream,
    this.tools,
    this.instructions,
    this.toolChoice,
  });
}

/// OpenAI 兼容请求体构建器。
///
/// 两种构建路径：
/// - [buildPresetBody]：按模型预设的 [RequestParamRules] 动态组合（模块化、可扩展）；
/// - 预设规则不满足的高阶定制需求由各协议专有构建器负责（如 Response API 的
///   AGENT 请求体），不再提供「自定义 JSON 模板」直发路径。
class AiRequestBodyBuilder {
  AiRequestBodyBuilder._();

  // ---------------------------------------------------------------------------
  // 占位符（可在预设规则中使用）
  // ---------------------------------------------------------------------------
  static const String placeholderModel = '{{model}}';
  static const String placeholderMessages = '{{messages}}';
  static const String placeholderStream = '{{stream}}';
  static const String placeholderTemperature = '{{temperature}}';
  static const String placeholderThinkingType = '{{thinking_type}}';
  static const String placeholderReasoningEffort = '{{reasoning_effort}}';
  static const String placeholderMaxTokens = '{{max_tokens}}';
  static const String placeholderTools = '{{tools}}';
  static const String placeholderInstructions = '{{instructions}}';
  static const String placeholderToolChoice = '{{tool_choice}}';

  /// 值为 null 时移除顶层键的哨兵（如未设置最大 Tokens / 本轮无工具）。
  static const Object _omit = Object();

  // ---------------------------------------------------------------------------
  // 预设规则路径
  // ---------------------------------------------------------------------------

  /// 按预设规则合并生成请求体（不含占位符，可直接 jsonEncode 发送）。
  static Map<String, dynamic> buildPresetBody({
    required RequestParamRules rules,
    required AiRequestValues values,
  }) {
    final body = <String, dynamic>{};
    for (final rule in rules.rules) {
      if (!_matches(rule.condition, values)) continue;
      for (final entry in rule.params.entries) {
        final resolved = _resolveValue(entry.value, values);
        if (identical(resolved, _omit)) continue;
        body[entry.key] = resolved;
      }
    }
    return body;
  }

  static bool _matches(ParamCondition condition, AiRequestValues values) {
    switch (condition) {
      case ParamCondition.always:
        return true;
      case ParamCondition.thinking:
        return values.thinking;
      case ParamCondition.notThinking:
        return !values.thinking;
      case ParamCondition.search:
        return values.tools != null;
      case ParamCondition.notSearch:
        return values.tools == null;
      case ParamCondition.stream:
        return values.stream;
      case ParamCondition.notStream:
        return !values.stream;
    }
  }

  /// 递归解析值中的占位符；可省略的占位符（max_tokens / tools）为 null 时返回 [_omit]。
  static Object? _resolveValue(Object? value, AiRequestValues v) {
    if (value is String) {
      switch (value) {
        case placeholderModel:
          return v.model;
        case placeholderMessages:
          return v.messages;
        case placeholderStream:
          return v.stream;
        case placeholderTemperature:
          return v.temperature;
        case placeholderThinkingType:
          return v.thinking ? 'enabled' : 'disabled';
        case placeholderReasoningEffort:
          return v.reasoningEffort;
        case placeholderMaxTokens:
          return v.maxTokens ?? _omit;
        case placeholderTools:
          return v.tools ?? _omit;
        case placeholderInstructions:
          return v.instructions ?? _omit;
        case placeholderToolChoice:
          return v.toolChoice ?? _omit;
        default:
          return value;
      }
    }
    if (value is Map) {
      return value.map((k, val) => MapEntry(k, _resolveValue(val, v)));
    }
    if (value is List) {
      return value.map((e) => _resolveValue(e, v)).toList();
    }
    return value;
  }
}
