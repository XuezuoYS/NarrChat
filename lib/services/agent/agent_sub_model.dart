import '../../models/ai_platform.dart';

/// 非创作步（第二步·状态维护）要使用的**子模型**目标：平台 + 模型。
///
/// 设置页只保存平台 / 模型两个 id；生成前由 [findAgentSubModel] /
/// [resolveAgentSubModel] 还原成真实对象。模型对象本身携带温度、思考、
/// 最大输出与流式能力，生成侧按这些能力为维护步单独组装请求。
class AgentSubModel {
  const AgentSubModel({required this.platform, required this.model});

  final AiPlatform platform;
  final AiModel model;

  String get modelId => model.id;
}

/// 仅按配置解析平台 / 模型，**不做「与主模型相同」的折叠**。
///
/// 设置页需要知道用户原始选的是哪一项（即使它恰好与当前主模型相同），
/// 以便打开模型选择器时勾选正确的行。空 id、平台不存在、模型不存在都返回
/// null（等价于「跟随主模型」）。
AgentSubModel? findAgentSubModel({
  required List<AiPlatform> platforms,
  required String platformId,
  required String modelId,
}) {
  final wantedPlatform = platformId.trim();
  final wantedModel = modelId.trim();
  if (wantedPlatform.isEmpty || wantedModel.isEmpty) return null;
  for (final platform in platforms) {
    if (platform.id != wantedPlatform) continue;
    final model = platform.modelById(wantedModel);
    if (model == null) return null;
    return AgentSubModel(platform: platform, model: model);
  }
  return null;
}

/// 生成侧使用的**有效子模型**：配置与当前主模型完全相同（同平台同模型）时
/// 返回 null。
///
/// 同平台同模型本来就是同一个服务商模型，缓存前缀照常命中；如果再按「子模型」
/// 记一份 token，统计会出现两份完全相同的数字。这里刻意折叠成「未启用」，
/// 让 `round_stack` 的四个子模型字段保持全 NULL。
AgentSubModel? resolveAgentSubModel({
  required List<AiPlatform> platforms,
  required String configuredPlatformId,
  required String configuredModelId,
  required String mainPlatformId,
  required String mainModelId,
}) {
  final target = findAgentSubModel(
    platforms: platforms,
    platformId: configuredPlatformId,
    modelId: configuredModelId,
  );
  if (target == null) return null;
  if (target.platform.id == mainPlatformId.trim() &&
      target.model.id == mainModelId.trim()) {
    return null;
  }
  return target;
}
