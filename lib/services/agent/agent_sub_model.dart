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

/// Chat 页模型菜单里「当前子模型」一行的展示数据：模型名 + 思考强度。
///
/// 这是**展示**口径，不是生成口径：
/// - 未配置 / 选择失效 / 恰好与当前主模型相同 → [sameAsMain] 为 true，
///   展示主模型与主模型当前强度（生成侧也会折叠成未启用）；
/// - 其它情况展示子模型自己的名称与强度（用户选过用选过的，没选过用默认）；
/// - 任一侧不支持思考 → 强度显示「无思考」。
class ChatSubagentHint {
  const ChatSubagentHint({
    required this.sameAsMain,
    required this.modelLabel,
    required this.effortLabel,
  });

  final bool sameAsMain;
  final String modelLabel;
  final String effortLabel;

  /// 菜单内一行摘要；调用方再补「子模型」前缀。
  String get summary => sameAsMain
      ? '与当前模型相同（$modelLabel · $effortLabel）'
      : '$modelLabel · $effortLabel';
}

/// 解析 Chat 页菜单里的子模型提示。
///
/// [mainReasoningEffort] 传 Chat 页当前记住的主模型强度（通常
/// `AiSettingsProvider.reasoningEffort`）。
ChatSubagentHint resolveChatSubagentHint({
  required List<AiPlatform> platforms,
  required String mainPlatformId,
  required String mainModelId,
  required String mainReasoningEffort,
  required String configuredPlatformId,
  required String configuredModelId,
  required String configuredReasoningEffort,
}) {
  final mainPlatform = _platformById(platforms, mainPlatformId);
  final mainModel =
      mainPlatform?.modelById(mainModelId) ?? mainPlatform?.defaultModel;
  final mainLabel = mainModel?.displayLabel ?? mainModelId;
  final mainEffort = mainModel == null || !mainModel.supportsThinking
      ? '无思考'
      : (mainReasoningEffort.trim().isNotEmpty
            ? mainReasoningEffort.trim()
            : mainModel.effectiveReasoningEffort);

  final target = findAgentSubModel(
    platforms: platforms,
    platformId: configuredPlatformId,
    modelId: configuredModelId,
  );
  final sameAsMain =
      target == null ||
      (target.platform.id == mainPlatformId.trim() &&
          target.model.id == mainModelId.trim());
  if (sameAsMain) {
    return ChatSubagentHint(
      sameAsMain: true,
      modelLabel: mainLabel,
      effortLabel: mainEffort,
    );
  }

  final configured = configuredReasoningEffort.trim();
  final effort = target.model.supportsThinking
      ? (configured.isNotEmpty
            ? configured
            : target.model.effectiveReasoningEffort)
      : '无思考';
  return ChatSubagentHint(
    sameAsMain: false,
    modelLabel: target.model.displayLabel,
    effortLabel: effort,
  );
}

AiPlatform? _platformById(List<AiPlatform> platforms, String id) {
  final wanted = id.trim();
  if (wanted.isEmpty) return null;
  for (final platform in platforms) {
    if (platform.id == wanted) return platform;
  }
  return null;
}
