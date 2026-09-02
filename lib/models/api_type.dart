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

/// API 的请求体动态组合规则集合（声明式、纯数据）。
///
/// 各规则按 [rules] 中的顺序合并，后出现的同名字段覆盖先出现的。
/// 不同 API 类型可通过不同规则组合定义各自的请求体结构，无需改动构建器。
class RequestParamRules {
  final List<ParamRule> rules;

  const RequestParamRules(this.rules);
}

/// API 类型（接入协议）：决定请求体组合规则、能力表与参数说明。
///
/// 每种接入协议（如 OpenAI 兼容 / 后续的 Anthropic 等）对应一套 [requestRules]、
/// 能力表（[supportsStreaming] / [supportsThinking] / [supportsSearch]）与参数说明。
///
/// 一个平台（[AiPlatform]）引用一个 [ApiType]；未来新增协议只需在此追加一个常量。
class ApiType {
  /// 稳定标识（配置文件中 `apiTypeId` 与之一致）。
  final String id;

  /// 展示名称。
  final String displayName;

  // ---- 能力表 ----
  final bool supportsStreaming;
  final bool supportsThinking;
  final bool supportsSearch;

  // ---- AGENT 相关的协议能力位 ----
  /// 是否支持 `tool_choice`（`auto` / `required` / `none`）。
  ///
  /// AGENT 状态轮靠它强制调用工具；不支持的服务端会在运行中自动降级为
  /// 「只发工具 + 提示词强制」，不消耗整轮预算。
  final bool supportsToolChoice;
  // ---- 请求体动态组合规则 ----
  final RequestParamRules requestRules;

  // ---- 参数次级说明 ----
  final String? temperatureNote;
  final String? reasoningEffortNote;
  final String? maxTokensNote;

  const ApiType({
    required this.id,
    required this.displayName,
    required this.supportsStreaming,
    required this.supportsThinking,
    required this.supportsSearch,
    this.supportsToolChoice = false,
    required this.requestRules,
    this.temperatureNote,
    this.reasoningEffortNote,
    this.maxTokensNote,
  });

  /// OpenAI 兼容 API（Chat Completions 协议）。
  ///
  /// DeepSeek 官方请求体动态组合规则（OpenAI 兼容）：
  /// - 始终注入：model / messages / stream / thinking（官方默认开启，必须显式声明）
  ///   与 max_tokens（留空时移除该键）；
  /// - 思考模式：追加 reasoning_effort，不发送 temperature；
  /// - 非思考模式：追加 temperature，不发送 reasoning_effort；
  /// - 流式：追加 stream_options.include_usage 以统计 Token；
  /// - 联网搜索：追加 tools。
  static const ApiType openAiCompatible = ApiType(
    id: openAiCompatibleId,
    displayName: 'OpenAI Chat API 兼容',
    supportsStreaming: true,
    supportsThinking: true,
    supportsSearch: true,
    requestRules: RequestParamRules([
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
    ]),
    temperatureNote: '思考模式下不发送该参数',
    reasoningEffortNote: '非思考模式下无效',
    maxTokensNote: '留空由服务端自动决定',
  );

  /// OpenAI 兼容 API 类型 id。
  static const String openAiCompatibleId = 'openai-compatible';

  /// OpenAI Response API 兼容（AGENT 模式协议）。
  ///
  /// 按官方兼容实现组织请求体（以 DeepSeek Responses API 兼容性明细为准）：
  /// - 始终注入：model / instructions / input / stream / max_output_tokens
  ///   （instructions 为空时移除该键；input 取 messages 数组，responses 的
  ///   message item 与 chat 消息结构兼容，含 image 的 user 消息由适配层转换）；
  /// - 思考模式：reasoning.effort（low/high/max），不发送 temperature；
  /// - 非思考模式：temperature + **reasoning.effort = "none"**——DeepSeek 思考
  ///   模式**默认开启**（默认 high），Responses 格式以 `reasoning.effort` 控制，
  ///   `none` 表示关闭；省略该字段等于思考开启（修复「关闭思考后仍在思考」）；
  /// - 联网搜索：tools（function 类型，与 Chat 协议一致）。
  ///
  /// 启用该协议的平台自动进入 AGENT 模式（行级状态工具 + 工作副本合并）。
  static const ApiType openAiResponses = ApiType(
    id: openAiResponsesId,
    displayName: 'OpenAI Response API 兼容',
    supportsStreaming: true,
    supportsThinking: true,
    supportsSearch: true,
    supportsToolChoice: true,
    requestRules: RequestParamRules([
      ParamRule(ParamCondition.always, {
        'model': '{{model}}',
        'instructions': '{{instructions}}',
        'input': '{{messages}}',
        'stream': '{{stream}}',
        'max_output_tokens': '{{max_tokens}}',
        // AGENT 两阶段：正文轮 auto，状态轮 required（强制调工具）。
        // 放在 always（而非 search）：有状态续接帧不重发 tools，但仍需
        // tool_choice；null（Chat 模式 / 服务商不支持）时整键省略 →
        // Chat 请求体逐字节不变。
        'tool_choice': '{{tool_choice}}',
      }),
      ParamRule(ParamCondition.thinking, {
        'reasoning': {'effort': '{{reasoning_effort}}'},
      }),
      ParamRule(ParamCondition.notThinking, {
        'temperature': '{{temperature}}',
        'reasoning': {'effort': 'none'},
      }),
      ParamRule(ParamCondition.search, {
        'tools': '{{tools}}',
      }),
    ]),
    temperatureNote: '思考模式下不发送该参数',
    reasoningEffortNote: '非思考模式下强制 effort=none（关闭思考）',
    maxTokensNote: '留空由服务端自动决定',
  );

  /// OpenAI Response API 兼容类型 id。
  static const String openAiResponsesId = 'openai-responses';

  /// 是否 Response API 协议（AGENT 模式）。
  bool get isResponses => id == openAiResponses.id;

  /// 按 [id] 查找；未知 id 回退 [openAiCompatible]。
  static ApiType byId(String id) {
    if (id == openAiResponses.id) return openAiResponses;
    if (id == openAiCompatible.id) return openAiCompatible;
    return openAiCompatible;
  }

  /// 当前支持的 API 类型列表（按展示顺序；默认平台协议在前）。
  static List<ApiType> get all => [openAiResponses, openAiCompatible];
}
