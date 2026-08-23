import '../models/ai_platform.dart';
import '../models/api_type.dart';
import 'app_config.dart';

/// 内置默认平台与模型相关的默认值。
///
/// 默认平台为「DeepSeek 开放平台」（OpenAI 兼容接入），预置 v4 Pro / v4 Flash /
/// v4 Flash Vision Exp（识图）三个模型；未来新增内置模型只需在此追加，无需改动 UI 或构建器。
class AiPlatforms {
  AiPlatforms._();

  /// 内置默认平台的稳定 id。
  static const String defaultPlatformId = '__default__';

  /// 预置 DeepSeek V4 Pro 模型。
  static const AiModel deepseekV4Pro = AiModel(
    id: 'deepseek-v4-pro',
    temperature: 1.0,
    reasoningEffort: 'high',
  );

  /// 预置 DeepSeek V4 Flash 模型。
  static const AiModel deepseekV4Flash = AiModel(
    id: 'deepseek-v4-flash',
    temperature: 1.0,
    reasoningEffort: 'high',
  );

  /// 预置 DeepSeek V4 Flash Vision Exp 模型（识图，多模态视觉模型）。
  static const AiModel deepseekV4FlashVisionExp = AiModel(
    id: 'deepseek-v4-flash-vision-exp',
    temperature: 1.0,
    reasoningEffort: 'high',
    supportsStreaming: true,
    supportsThinking: true,
    supportsSearch: true,
    supportsVision: true,
  );

  /// 默认平台（DeepSeek 开放平台）。
  static AiPlatform buildDefaultPlatform() {
    return AiPlatform(
      id: defaultPlatformId,
      displayName: '默认（DeepSeek 开放平台）',
      apiType: ApiType.openAiCompatible,
      baseUrl: AppConfig.defaultApiBaseUrlEffective,
      isBuiltin: true,
      models: const [deepseekV4Pro, deepseekV4Flash, deepseekV4FlashVisionExp],
    );
  }

  /// 默认平台（每次返回新实例，避免共享可变引用）。
  static AiPlatform get defaultPlatform => buildDefaultPlatform();

  /// 默认选中的模型 id（与旧版默认预设一致）。
  static String get defaultModelId => deepseekV4Pro.id;

  /// 回退使用的请求体规则（OpenAI 兼容）。
  static RequestParamRules get defaultRules => ApiType.openAiCompatible.requestRules;

  /// 回退使用的参考模型（用于无设置注入的测试 / 降级路径）。
  static AiModel get defaultModel => deepseekV4Pro;

  /// 回退使用的能力：联网搜索（取自默认模型能力）。
  static bool get defaultSupportsSearch => defaultModel.supportsSearch;

  /// 回退使用的默认思考 / 流式值（取自默认模型能力）。
  static bool get defaultThinking => defaultModel.supportsThinking;
  static bool get defaultStreaming => defaultModel.supportsStreaming;
}
