import 'api_type.dart';

/// 平台下单个模型的配置。
///
/// 每个模型携带发送给 API 的 [id]、对话框显示用的 [shortLabel]（简写标识，
/// 为空则回退到 [id]）、以及当前有效参数（[temperature] / [reasoningEffort] /
/// [maxTokens]）；[requestTemplate] 非空时请求体走自定义 JSON 模板路径。
class AiModel {
  /// 实际发送给 API 的模型名（平台内唯一）。
  final String id;

  /// 简写标识：用于用户自定义对话框内的显示；为空则按 [id] 显示。
  final String shortLabel;

  /// 采样温度。
  final double temperature;

  /// 推理强度（`reasoning_effort`，思考模式下生效）。
  final String reasoningEffort;

  /// 最大输出 Tokens（null 表示不限制，由服务端决定）。
  final int? maxTokens;

  /// 可选的自定义请求体 JSON 模板（OpenAI 兼容，支持占位符）；
  /// 非空时以模板直发，否则按所属平台 [AiPlatform.apiType] 的规则构建。
  final String? requestTemplate;

  const AiModel({
    required this.id,
    this.shortLabel = '',
    this.temperature = 1.0,
    this.reasoningEffort = 'high',
    this.maxTokens,
    this.requestTemplate,
  });

  /// 对话框显示名：简写标识非空用简写标识，否则回退模型名（[id]）。
  String get displayLabel => shortLabel.trim().isNotEmpty ? shortLabel.trim() : id;

  AiModel copyWith({
    String? id,
    String? shortLabel,
    double? temperature,
    String? reasoningEffort,
    int? maxTokens,
    String? requestTemplate,
  }) {
    return AiModel(
      id: id ?? this.id,
      shortLabel: shortLabel ?? this.shortLabel,
      temperature: temperature ?? this.temperature,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      maxTokens: maxTokens ?? this.maxTokens,
      requestTemplate: requestTemplate ?? this.requestTemplate,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'shortLabel': shortLabel,
      'temperature': temperature,
      'reasoningEffort': reasoningEffort,
      if (maxTokens != null && maxTokens! > 0) 'maxTokens': maxTokens,
      if (requestTemplate != null && requestTemplate!.trim().isNotEmpty)
        'requestTemplate': requestTemplate,
    };
  }

  factory AiModel.fromJson(Map<String, dynamic> json) {
    return AiModel(
      id: json['id'] as String? ?? '',
      shortLabel: json['shortLabel'] as String? ?? '',
      temperature: (json['temperature'] as num?)?.toDouble() ?? 1.0,
      reasoningEffort: json['reasoningEffort'] as String? ?? 'high',
      maxTokens: (json['maxTokens'] as num?)?.toInt(),
      requestTemplate: json['requestTemplate'] as String?,
    );
  }
}

/// 一个 AI 接入平台（provider）：连接配置 + 接入协议 + 该平台自己的模型列表。
///
/// 对应 DeepSeek Harness 的 `providers[].models[]` 组织方式：
/// 平台持有 baseUrl / API 类型（[apiType]）与列表（[models]），API Key 走系统
/// 安全存储（见 `AiSettingsProvider`），不在此配置中。
class AiPlatform {
  /// 平台稳定标识（内置平台为 `__default__`；自定义平台为生成的 id）。
  final String id;

  /// 展示名称。
  final String displayName;

  /// 接入协议（决定请求体规则 / 能力表 / 参数说明）。
  final ApiType apiType;

  /// 接口地址。
  final String baseUrl;

  /// 是否内置平台（默认 DeepSeek 开放平台）——不可删除。
  final bool isBuiltin;

  /// 该平台下的模型列表（至少保留一个）。
  final List<AiModel> models;

  const AiPlatform({
    required this.id,
    required this.displayName,
    required this.apiType,
    required this.baseUrl,
    this.isBuiltin = false,
    required this.models,
  });

  /// 接入协议 id（持久化用）。
  String get apiTypeId => apiType.id;

  /// 平台的默认模型（模型列表至少一个，取第一个作为兜底）。
  AiModel get defaultModel => models.first;

  /// 按模型 id 查找；未命中返回 null。
  AiModel? modelById(String modelId) {
    for (final m in models) {
      if (m.id == modelId) return m;
    }
    return null;
  }

  /// 按模型 id 查找；未命中回退默认模型。
  AiModel modelOrFirst(String modelId) => modelById(modelId) ?? defaultModel;

  AiPlatform copyWith({
    String? id,
    String? displayName,
    ApiType? apiType,
    String? baseUrl,
    bool? isBuiltin,
    List<AiModel>? models,
  }) {
    return AiPlatform(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      apiType: apiType ?? this.apiType,
      baseUrl: baseUrl ?? this.baseUrl,
      isBuiltin: isBuiltin ?? this.isBuiltin,
      models: models ?? this.models,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'displayName': displayName,
      'apiTypeId': apiType.id,
      'baseUrl': baseUrl,
      'isBuiltin': isBuiltin,
      'models': [for (final m in models) m.toJson()],
    };
  }

  factory AiPlatform.fromJson(Map<String, dynamic> json) {
    final rawModels = (json['models'] as List<dynamic>?) ?? const [];
    final models = <AiModel>[
      for (final e in rawModels)
        AiModel.fromJson((e as Map).cast<String, dynamic>()),
    ];
    return AiPlatform(
      id: json['id'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      apiType: ApiType.byId(
        json['apiTypeId'] as String? ?? ApiType.openAiCompatibleId,
      ),
      baseUrl: json['baseUrl'] as String? ?? '',
      isBuiltin: json['isBuiltin'] as bool? ?? false,
      models: models,
    );
  }
}

/// 平台配置集合：平台列表 + 当前选中项（用于持久化 / 迁移）。
class AiPlatformsConfig {
  final List<AiPlatform> platforms;
  final String selectedPlatformId;
  final String selectedModelId;

  const AiPlatformsConfig({
    required this.platforms,
    required this.selectedPlatformId,
    required this.selectedModelId,
  });

  Map<String, dynamic> toJson() {
    return {
      'platforms': [for (final p in platforms) p.toJson()],
      'selectedPlatformId': selectedPlatformId,
      'selectedModelId': selectedModelId,
    };
  }
}
