import '../models/model_preset.dart';

/// 内置模型预设与自定义模型模板。
///
/// - 内置预设为只读数据：定义模型能力、默认参数与请求体动态组合规则；
/// - 未来新增模型只需在此追加一个 [ModelPreset]，无需改动构建器或 UI。
class ModelPresets {
  ModelPresets._();

  /// 自定义模型预设 id（无能力表，请求体由用户自定义）。
  static const String customId = '__custom__';

  // ---------------------------------------------------------------------------
  // DeepSeek 官方请求体动态组合规则（OpenAI 兼容）。
  //
  // - 始终注入：model / messages / stream / thinking（官方默认开启，必须显式声明）
  //   与 max_tokens（留空时移除该键）；
  // - 思考模式：追加 reasoning_effort，不发送 temperature；
  // - 非思考模式：追加 temperature，不发送 reasoning_effort；
  // - 流式：追加 stream_options.include_usage 以统计 Token；
  // - 联网搜索：追加 tools。
  // ---------------------------------------------------------------------------
  static const RequestParamRules _deepseekRules = RequestParamRules([
    ParamRule(ParamCondition.always, {
      'model': '{{model}}',
      'messages': '{{messages}}',
      'stream': '{{stream}}',
      'thinking': {'type': '{{thinking_type}}'},
      'max_tokens': '{{max_tokens}}',
    }),
    ParamRule(ParamCondition.thinking, {
      'reasoning_effort': '{{reasoning_effort}}',
    }),
    ParamRule(ParamCondition.notThinking, {
      'temperature': '{{temperature}}',
    }),
    ParamRule(ParamCondition.stream, {
      'stream_options': {'include_usage': true},
    }),
    ParamRule(ParamCondition.search, {
      'tools': '{{tools}}',
    }),
  ]);

  /// DeepSeek V4 Pro：旗舰模型。
  static const ModelPreset deepseekV4Pro = ModelPreset(
    id: 'deepseek-v4-pro',
    displayName: 'DeepSeek V4 Pro',
    modelId: 'deepseek-v4-pro',
    supportsStreaming: true,
    supportsThinking: true,
    supportsSearch: true,
    defaultTemperature: 1.0,
    defaultThinking: true,
    defaultReasoningEffort: 'high',
    defaultMaxTokens: null,
    defaultStreaming: true,
    temperatureNote: '思考模式下不发送该参数',
    reasoningEffortNote: '非思考模式下无效',
    maxTokensNote: '留空由服务端自动决定',
    requestRules: _deepseekRules,
  );

  /// DeepSeek V4 Flash：轻量快速。
  static const ModelPreset deepseekV4Flash = ModelPreset(
    id: 'deepseek-v4-flash',
    displayName: 'DeepSeek V4 Flash',
    modelId: 'deepseek-v4-flash',
    supportsStreaming: true,
    supportsThinking: true,
    supportsSearch: true,
    defaultTemperature: 1.0,
    defaultThinking: true,
    defaultReasoningEffort: 'high',
    defaultMaxTokens: null,
    defaultStreaming: true,
    temperatureNote: '思考模式下不发送该参数',
    reasoningEffortNote: '非思考模式下无效',
    maxTokensNote: '留空由服务端自动决定',
    requestRules: _deepseekRules,
  );

  /// 内置预设列表（按展示顺序）。
  static const List<ModelPreset> builtins = [deepseekV4Pro, deepseekV4Flash];

  /// 自定义模型预设（无能力表时默认全开；请求体走用户模板，不走规则）。
  static const ModelPreset customPreset = ModelPreset(
    id: customId,
    displayName: '自定义模型',
    modelId: '',
    supportsStreaming: true,
    supportsThinking: true,
    supportsSearch: true,
    defaultTemperature: 1.0,
    defaultThinking: true,
    defaultReasoningEffort: 'high',
    defaultMaxTokens: null,
    defaultStreaming: true,
    temperatureNote: '由自定义请求体模板决定是否引用',
    reasoningEffortNote: '由自定义请求体模板决定是否引用',
    maxTokensNote: '由自定义请求体模板决定是否引用',
    requestRules: RequestParamRules([]),
  );

  /// 默认预设（未配置 / 测试环境回退）。
  static ModelPreset get defaultPreset => deepseekV4Pro;

  /// 按预设 id 查找（内置 + 自定义）；未知 id 回退 [defaultPreset]。
  static ModelPreset byId(String id) {
    if (id == customId) return customPreset;
    for (final p in builtins) {
      if (p.id == id) return p;
    }
    return defaultPreset;
  }

  /// 按模型名查找内置预设（用于旧配置迁移）；未命中返回 null。
  static ModelPreset? byModelId(String modelId) {
    for (final p in builtins) {
      if (p.modelId == modelId) return p;
    }
    return null;
  }

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
}
