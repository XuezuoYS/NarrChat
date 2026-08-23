import 'dart:convert';

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

  const AiRequestValues({
    required this.model,
    required this.messages,
    required this.temperature,
    required this.thinking,
    required this.reasoningEffort,
    required this.maxTokens,
    required this.stream,
    this.tools,
  });
}

/// OpenAI 兼容请求体构建器。
///
/// 两种构建路径：
/// - [buildPresetBody]：按模型预设的 [RequestParamRules] 动态组合（模块化、可扩展）；
/// - [buildCustomBody]：按用户自定义 JSON 模板替换占位符后直发（自定义模型）。
class AiRequestBodyBuilder {
  AiRequestBodyBuilder._();

  // ---------------------------------------------------------------------------
  // 占位符（可在预设规则与自定义模板中使用）
  // ---------------------------------------------------------------------------
  static const String placeholderModel = '{{model}}';
  static const String placeholderMessages = '{{messages}}';
  static const String placeholderStream = '{{stream}}';
  static const String placeholderTemperature = '{{temperature}}';
  static const String placeholderThinkingType = '{{thinking_type}}';
  static const String placeholderReasoningEffort = '{{reasoning_effort}}';
  static const String placeholderMaxTokens = '{{max_tokens}}';
  static const String placeholderTools = '{{tools}}';

  static const List<String> allPlaceholders = [
    placeholderModel,
    placeholderMessages,
    placeholderStream,
    placeholderTemperature,
    placeholderThinkingType,
    placeholderReasoningEffort,
    placeholderMaxTokens,
    placeholderTools,
  ];

  /// 默认自定义请求体模板（OpenAI 兼容格式）。
  ///
  /// 占位符代表 JSON 编码后的值（无需额外引号）：
  /// `{{model}}` / `{{messages}}` / `{{stream}}` / `{{temperature}}` /
  /// `{{thinking_type}}` / `{{reasoning_effort}}` / `{{max_tokens}}` / `{{tools}}`。
  static const String defaultCustomRequestBody = '''
{
  "model": {{model}},
  "messages": {{messages}},
  "stream": {{stream}},
  "temperature": {{temperature}},
  "max_tokens": {{max_tokens}}
}
''';

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

  // ---------------------------------------------------------------------------
  // 自定义模板路径
  // ---------------------------------------------------------------------------

  /// 替换自定义请求体 JSON 模板中的占位符并解析为请求体 Map。
  ///
  /// - 模板必须是合法 JSON（占位符替换后校验）；
  /// - `{{max_tokens}}` 未设置时替换为 `null`（多数 OpenAI 兼容服务端忽略 null）；
  /// - `{{tools}}` 未开启时替换为 `[]`。
  ///
  /// 抛出 [FormatException]（消息为中文友好提示）当模板非法。
  static Map<String, dynamic> buildCustomBody({
    required String template,
    required AiRequestValues values,
  }) {
    final replaced = _substitute(template, values);
    try {
      final decoded = jsonDecode(replaced);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('自定义请求体顶层必须是 JSON 对象');
      }
      return decoded;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('自定义请求体不是合法 JSON，请检查语法与占位符');
    }
  }

  /// 校验自定义请求体模板（用合法 JSON 占位值替换后解析），非法时抛 [FormatException]。
  static void validateCustomTemplate(String template) {
    final sanity = template
        .replaceAll(placeholderModel, '"m"')
        .replaceAll(placeholderMessages, '[]')
        .replaceAll(placeholderStream, 'false')
        .replaceAll(placeholderTemperature, '0')
        .replaceAll(placeholderThinkingType, '"enabled"')
        .replaceAll(placeholderReasoningEffort, '"high"')
        .replaceAll(placeholderMaxTokens, '0')
        .replaceAll(placeholderTools, '[]');
    try {
      jsonDecode(sanity);
    } on FormatException {
      throw const FormatException('自定义请求体不是合法 JSON，请检查语法与占位符');
    }
  }

  static String _substitute(String template, AiRequestValues values) {
    String json(Object? v) => jsonEncode(v);
    return template
        .replaceAll(placeholderModel, json(values.model))
        .replaceAll(placeholderMessages, json(values.messages))
        .replaceAll(placeholderStream, values.stream ? 'true' : 'false')
        .replaceAll(placeholderTemperature, json(values.temperature))
        .replaceAll(
          placeholderThinkingType,
          json(values.thinking ? 'enabled' : 'disabled'),
        )
        .replaceAll(placeholderReasoningEffort, json(values.reasoningEffort))
        .replaceAll(placeholderMaxTokens, values.maxTokens?.toString() ?? 'null')
        .replaceAll(placeholderTools, json(values.tools ?? const []));
  }
}
