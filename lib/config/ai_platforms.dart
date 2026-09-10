import 'dart:convert';

import '../models/ai_platform.dart';
import '../models/api_type.dart';
import 'app_config.dart';

/// 软件内置预置的平台与模型（"软件本体预置"）。
///
/// 分层模型（与 DeepSeek Harness 的「命名空间 → 用户层」一致）：
/// - **内置预置层**：本文件的常量，永远存在，是缺失时的兜底；
/// - **用户层**：`local_config/app_settings.json` 的 `ai` 命名空间（见
///   `AiSettingsProvider`）。该键缺失 / 为空 / 不可读 ⇒ 视为遵循内置预置
///   （[resolvePlatforms]），UI 提示"当前为内置默认"；用户保存后写入
///   完整副本，可手工修改或转移到其它机器。
///
/// 当前预置一个平台（DeepSeek 开放平台，OpenAI Response API 兼容接入），
/// 预置 v4 Pro / v4 Flash / v4 Flash Vision Exp（识图）三个模型；未来新增
/// 内置平台只需在 [buildPresetPlatforms] 追加，UI 会按其 id 自动提供
/// 平台级「重置为内置预置」。
class AiPlatforms {
  AiPlatforms._();

  /// 内置 DeepSeek 开放平台的稳定 id。
  static const String deepseekPlatformId = '__default__';

  /// 内置默认平台的稳定 id（= 预置列表第一个平台）。
  static const String defaultPlatformId = deepseekPlatformId;

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

  // ---------------------------------------------------------------------------
  // 预置平台注册表
  // ---------------------------------------------------------------------------

  /// 内置预置平台列表（每次返回全新实例，避免共享可变引用）。
  static List<AiPlatform> buildPresetPlatforms() => [buildDeepseekPlatform()];

  /// 内置预置平台列表。
  static List<AiPlatform> get presetPlatforms => buildPresetPlatforms();

  /// 内置默认平台（DeepSeek 开放平台）。
  ///
  /// 默认使用「OpenAI Response API 兼容」协议——协议只决定请求体 / 线路
  /// 格式；AGENT 模式（两阶段生成 + 自定义工具）由「设置 → 通用设置 →
  /// 实验性功能」的独立开关控制（默认关闭），与协议选择正交。
  static AiPlatform buildDeepseekPlatform() {
    return AiPlatform(
      id: deepseekPlatformId,
      displayName: '默认（DeepSeek 开放平台）',
      apiType: ApiType.openAiResponses,
      baseUrl: AppConfig.defaultApiBaseUrlEffective,
      models: const [deepseekV4Pro, deepseekV4Flash, deepseekV4FlashVisionExp],
    );
  }

  /// 默认平台（预置列表第一个）。
  static AiPlatform get defaultPlatform => presetPlatforms.first;

  /// 按 id 取内置预置平台；非预置 id 返回 null。
  static AiPlatform? presetFor(String platformId) {
    for (final platform in presetPlatforms) {
      if (platform.id == platformId) return platform;
    }
    return null;
  }

  /// 是否为内置预置平台的 id。
  static bool isPresetId(String platformId) => presetFor(platformId) != null;

  /// 平台是否与内置预置完全一致（全字段深比较；非预置 id → false）。
  static bool isPresetUnchanged(AiPlatform platform) {
    final preset = presetFor(platform.id);
    if (preset == null) return false;
    return _samePlatform(preset, platform);
  }

  /// 平台列表是否与内置预置完全一致（数量、顺序与逐项全字段）。
  static bool matchesPresets(List<AiPlatform> platforms) {
    final presets = presetPlatforms;
    if (platforms.length != presets.length) return false;
    for (var i = 0; i < presets.length; i++) {
      if (platforms[i].id != presets[i].id) return false;
      if (!_samePlatform(presets[i], platforms[i])) return false;
    }
    return true;
  }

  /// 解析用户层 `platforms` → 有效平台列表。
  ///
  /// - 不可读（null / 非数组）或为空数组 ⇒ 内置预置；
  /// - 逐项解析并丢弃非法项（id 为空、无模型），全被丢弃 ⇒ 内置预置；
  /// - 合法项原样保留（含用户自定义平台与全部模型参数）。
  static List<AiPlatform> resolvePlatforms(Object? rawUserPlatforms) {
    if (rawUserPlatforms is! List) return presetPlatforms;
    final parsed = <AiPlatform>[];
    for (final entry in rawUserPlatforms) {
      if (entry is! Map) continue;
      final platform = AiPlatform.fromJson(entry.cast<String, dynamic>());
      if (platform.id.trim().isEmpty || platform.models.isEmpty) continue;
      parsed.add(platform);
    }
    return parsed.isEmpty ? presetPlatforms : parsed;
  }

  /// 按 toJson 全字段深比较（键序由 toJson 固定；新增字段自动纳入比较）。
  static bool _samePlatform(AiPlatform a, AiPlatform b) =>
      jsonEncode(a.toJson()) == jsonEncode(b.toJson());

  // ---------------------------------------------------------------------------
  // 无设置注入时的回退值（测试 / 降级路径）
  // ---------------------------------------------------------------------------

  /// 默认选中的模型 id（预置平台的默认模型）。
  static String get defaultModelId => defaultPlatform.defaultModel.id;

  /// 回退使用的请求体规则（默认平台协议 = Response API 兼容）。
  static RequestParamRules get defaultRules =>
      ApiType.openAiResponses.requestRules;

  /// 回退使用的参考模型（用于无设置注入的测试 / 降级路径）。
  static AiModel get defaultModel => defaultPlatform.defaultModel;

  /// 回退使用的能力：联网搜索（取自默认模型能力）。
  static bool get defaultSupportsSearch => defaultModel.supportsSearch;

  /// 回退使用的默认思考 / 流式值（取自默认模型能力）。
  static bool get defaultThinking => defaultModel.supportsThinking;
  static bool get defaultStreaming => defaultModel.supportsStreaming;
}
