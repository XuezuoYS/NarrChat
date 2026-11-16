import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/agent_mode_level.dart';
import '../models/ai_platform.dart';
import '../providers/ai_settings_provider.dart';
import '../providers/experimental_settings_provider.dart';
import '../services/agent/agent_sub_model.dart';
import 'other_settings_section.dart';
import 'settings/settings_kit.dart';
import 'ui_settings_form.dart';

/// 「通用设置」设置面板。
///
/// 三个子模块同一页面纵向分区（统一使用设置组件套件的分区头 + 卡片）：
/// - UI 设置：全局字体、主题等界面偏好（即时生效）；
/// - 其它设置：应用行为类杂项（「检查更新」开关 + 预发布版本开关 +
///   「立即检查更新」入口）；
/// - 会话工作模式（实验性）：Agent 模式档位（无 / Lv.1）、非创作步子模型、
///   思考链压缩两级开关；分区标题与卡片内各行标题都带黄色「（实验性）」标注。
///
/// 设置保存到本地 JSON 配置文件（local_config/app_settings.json），不参与云同步。
class GeneralSettingsForm extends StatelessWidget {
  const GeneralSettingsForm({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsPageHeader(
          title: '通用设置',
          description: '界面显示偏好与应用行为等本地配置，保存到本地配置文件（不参与云同步）。',
        ),
        SettingsSection(
          icon: Icons.palette_outlined,
          title: 'UI 设置',
          // UiSettingsForm 自身即统一卡片（三行同卡）。
          child: UiSettingsForm(),
        ),
        SettingsSection(
          icon: Icons.system_update_alt_outlined,
          title: '其它设置',
          // OtherSettingsSection 自身即统一卡片（自动检查 / 预发布 /
          // 立即检查三行同卡）。
          child: OtherSettingsSection(),
        ),
        SettingsSection(
          icon: Icons.science_outlined,
          // 实验性功能独立分区：分区标题与卡片内各行标题都带黄色标注。
          title: '会话工作模式',
          experimental: true,
          child: _ExperimentalSettingsSection(),
        ),
      ],
    );
  }
}

/// 「会话工作模式（实验性）」子模块内容：Agent 模式档位（默认「无 / 使用传统
/// Chat 方式」）+ 非创作步子模型（默认跟随主模型）+ Agent 模式专用的思考链
/// 压缩开关（主开关默认开；子开关默认关，仅主开关开启时显示）。
///
/// 档位与平台接入协议**正交**（见 RoundProvider 矩阵化分派）：
/// - 协议（OpenAI Chat / Response 兼容）只决定请求体与线路格式；
/// - **Lv.1**：仅历史（记忆总结）工具 + 联网；正文输出 5 个区块（排除记忆总结），
///   每轮两步：第一步调研（读史 + 按需联网）后直接写正文；第二步在正文完成后
///   单独发新请求维护记忆总结；所有步结束后统一入库。token 按主 / 子模型分桶
///   （第一步归主模型，第二步启用子模型时归子模型）。
///
/// 历史上的完整 Agent（Lv.2，六工具 + 正文三小节）**已移除**：世界 / 角色工具
/// 与多栏目缺口框架仍留在代码里作为后续档位的基础设施，当前不注册；旧配置值
/// `2` 与旧布尔键回落「关」（见 `ExperimentalSettingsProvider.load`）。
///
/// 交互与文案分工：
/// - **整行任意位置可点**即可展开档位菜单（不必对准右侧箭头）；
/// - 行内只保留**简要**介绍（工具 / 分步生成 + 指示器限制 + 破坏性变更声明），
///   各档位的差异写在**下拉选项内**（[AgentModeLevel.menuDetail]）；
/// - 下拉行为统一由 [SettingsSelectRow] 提供（整行点击 + 菜单圆角继承主题）。
class _ExperimentalSettingsSection extends StatefulWidget {
  const _ExperimentalSettingsSection();

  @override
  State<_ExperimentalSettingsSection> createState() =>
      _ExperimentalSettingsSectionState();
}

class _ExperimentalSettingsSectionState
    extends State<_ExperimentalSettingsSection> {
  /// 简要介绍：工具 / 两步生成 + 指示器限制 + 破坏性变更声明（细节在选项内）。
  static const String _agentModeDescription =
      '实验性功能（默认「无」）：启用后调用自定义工具（narrchat_*）走两步生成'
      '（第一步调研并写正文 → 第二步单独维护记忆总结），由 Agent 托管记忆总结——'
      '托管范围见下拉选项说明。'
      '⚠ 档位开启期间，模型已支持的功能（思考 / 流式 / 搜索）无法通过对话页'
      '指示器关闭；未来更新可能对本功能做出破坏性变更，正确性不保证。';

  void _setLevel(AgentModeLevel level) {
    // Provider 内先乐观生效并异步持久化（保存失败仅记录）。
    context.read<ExperimentalSettingsProvider>().setAgentModeLevel(level);
  }

  void _toggleCompressNonBodyReasoning(bool value) {
    context.read<ExperimentalSettingsProvider>().setCompressNonBodyReasoning(
      value,
    );
  }

  void _toggleCompressAllReasoning(bool value) {
    context.read<ExperimentalSettingsProvider>().setCompressAllReasoning(value);
  }

  @override
  Widget build(BuildContext context) {
    final experimental = context.watch<ExperimentalSettingsProvider>();
    final aiSettings = context.watch<AiSettingsProvider>();
    return SettingsCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildLevelMenu(experimental),
          const Divider(height: 1, indent: 14, endIndent: 14),
          _buildSubagentModelRow(experimental, aiSettings),
          const Divider(height: 1, indent: 14, endIndent: 14),
          _buildCompressNonBodySwitch(experimental),
          // 子开关只在主开关开启时存在；关闭主开关时连同状态一起复位。
          if (experimental.compressNonBodyReasoning) ...[
            const Divider(height: 1, indent: 14, endIndent: 14),
            _buildCompressAllSwitch(experimental),
          ],
        ],
      ),
    );
  }

  /// Agent 档位下拉行（整行可点展开菜单；选项带标题 + 一行说明）。
  Widget _buildLevelMenu(ExperimentalSettingsProvider experimental) {
    return SettingsSelectRow<AgentModeLevel>(
      icon: Icons.psychology_outlined,
      title: 'Agent 模式',
      experimental: true,
      subtitle: _agentModeDescription,
      value: experimental.agentModeLevel,
      // 行尾展示短标签（关 / Lv.1），菜单里展示语义化标题与说明。
      labelOf: (level) => level.label,
      options: [
        for (final level in AgentModeLevel.values)
          SettingsSelectOption(
            value: level,
            label: level.menuTitle,
            detail: level.menuDetail,
            key: ValueKey('experimental_agent_mode_option_${level.id}'),
          ),
      ],
      onSelected: _setLevel,
      rowKey: const ValueKey('experimental_agent_mode_card'),
      valueKey: const ValueKey('experimental_agent_mode_label'),
    );
  }

  /// 子模型行的灰字说明（包含用户要求的缓存 / 成本提示原句）。
  static const String _subagentModelDescription =
      'Agent 模式专用（仅第二步状态维护）。跨模型无法使用缓存命中，'
      '请确保子模型成本足够低；否则请选择「与当前激活主模型一致」。';

  /// 非创作步（第二步状态维护）模型选择行：跟随主模型 / 具体模型。
  Widget _buildSubagentModelRow(
    ExperimentalSettingsProvider experimental,
    AiSettingsProvider aiSettings,
  ) {
    // 行尾按「原始选择」显示：具体模型（即使恰好等于主模型）显示模型名；
    // 未配置 / 失效显示跟随主模型。生成侧是否真的拆分由 resolver 决定。
    final target = findAgentSubModel(
      platforms: aiSettings.platforms,
      platformId: experimental.subagentPlatformId,
      modelId: experimental.subagentModelId,
    );
    final configuredEffort = experimental.subagentReasoningEffort.trim();
    final label = target == null
        ? '与当前激活主模型一致'
        : target.model.supportsThinking
        ? '${target.model.displayLabel} · '
              '${configuredEffort.isNotEmpty ? configuredEffort : target.model.effectiveReasoningEffort}'
        : '${target.model.displayLabel} · 无思考';
    final scheme = Theme.of(context).colorScheme;
    return SettingsRow(
      icon: Icons.alt_route,
      title: '非创作步所使用的模型（子模型）',
      experimental: true,
      rowKey: const ValueKey('experimental_subagent_model_card'),
      onTap: () => _pickSubagentModel(experimental, aiSettings),
      // 灰字提示 + 当前选择放在副标题里：窄列（设置页内容 229）也放得下，
      // 不必把模型名硬塞进行尾造成 RenderFlex overflow。
      subtitleWidget: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _subagentModelDescription,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                '当前：',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              Flexible(
                child: Text(
                  label,
                  key: const ValueKey('experimental_subagent_model_label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      trailing: Icon(
        Icons.expand_more,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  /// 打开子模型选择器；选择结果立即写入本地配置（与 Agent 档位同一个交互口径）。
  Future<void> _pickSubagentModel(
    ExperimentalSettingsProvider experimental,
    AiSettingsProvider aiSettings,
  ) async {
    final choice =
        await showDialog<
          ({String platformId, String modelId, String reasoningEffort})
        >(
          context: context,
          builder: (context) => _SubagentModelDialog(
            platforms: aiSettings.platforms,
            mainPlatformId: aiSettings.selectedPlatformId,
            mainModelId: aiSettings.model,
            selectedPlatformId: experimental.subagentPlatformId,
            selectedModelId: experimental.subagentModelId,
            selectedReasoningEffort: experimental.subagentReasoningEffort,
          ),
        );
    if (choice == null || !mounted) return;
    // Provider 内先乐观生效并异步持久化（与 Agent 档位 / 压缩开关同一口径），
    // 不在这里 await 磁盘写入。
    experimental.setSubagentModel(
      choice.platformId,
      choice.modelId,
      reasoningEffort: choice.reasoningEffort,
    );
  }

  /// 主开关：「压缩非正文步模型所获取到的思考链」（默认开）。
  Widget _buildCompressNonBodySwitch(
    ExperimentalSettingsProvider experimental,
  ) {
    return SettingsSwitchRow(
      icon: Icons.compress_outlined,
      title: '压缩非正文步模型所获取到的思考链',
      experimental: true,
      subtitle:
          'Agent 模式专用（默认开）：第一步（调研 + 正文）视为正文步，'
          '思考链完整保留；只压缩第二步维护收到的前面思考链。'
          '压缩规则：多段只保留首段与末段（单段原样）。'
          '⚠ 会改写回传给模型的思考原文——自定义网关要求完整思考时请关闭。',
      value: experimental.compressNonBodyReasoning,
      switchKey: const ValueKey(
        'experimental_compress_non_body_reasoning_switch',
      ),
      onChanged: _toggleCompressNonBodyReasoning,
    );
  }

  /// 子开关：「压缩所有回合的思考链」（默认关；仅主开关开启时显示）。
  Widget _buildCompressAllSwitch(ExperimentalSettingsProvider experimental) {
    return SettingsSwitchRow(
      icon: Icons.compress,
      title: '压缩所有回合的思考链',
      experimental: true,
      subtitle:
          '默认关：开启后第一步的调研 / 正文回合也压缩思考链；'
          '仅在上一项开启时显示并生效。⚠ 同样会改写思考原文。',
      value: experimental.compressAllReasoning,
      switchKey: const ValueKey('experimental_compress_all_reasoning_switch'),
      onChanged: _toggleCompressAllReasoning,
    );
  }
}

/// 子模型选择对话框：顶部「与当前激活主模型一致」+ 按平台分组的模型列表；
/// 点击支持思考的模型后进入二级「思考强度」面板（与 Chat 页模型选择器同款
/// 交互：模型列表 → 强度面板 → 选中生效）。
///
/// 返回「平台 id + 模型 id + 思考强度」；平台 / 模型为空串 = 跟随主模型，
/// 强度为空串 = 使用该模型自己的默认强度。真正是否拆分请求由
/// `resolveAgentSubModel` 在生成前判断（同平台同模型会自动折叠成未启用）。
class _SubagentModelDialog extends StatefulWidget {
  const _SubagentModelDialog({
    required this.platforms,
    required this.mainPlatformId,
    required this.mainModelId,
    required this.selectedPlatformId,
    required this.selectedModelId,
    required this.selectedReasoningEffort,
  });

  final List<AiPlatform> platforms;
  final String mainPlatformId;
  final String mainModelId;
  final String selectedPlatformId;
  final String selectedModelId;
  final String selectedReasoningEffort;

  @override
  State<_SubagentModelDialog> createState() => _SubagentModelDialogState();
}

class _SubagentModelDialogState extends State<_SubagentModelDialog> {
  // 二级强度面板的临时目标；null = 当前显示模型列表。
  String? _targetPlatformId;
  String? _targetModelId;

  AiPlatform? get _targetPlatform {
    final id = _targetPlatformId;
    if (id == null) return null;
    for (final platform in widget.platforms) {
      if (platform.id == id) return platform;
    }
    return null;
  }

  AiModel? get _targetModel {
    final platform = _targetPlatform;
    final id = _targetModelId;
    if (platform == null || id == null) return null;
    return platform.modelById(id);
  }

  void _resetTarget() {
    setState(() {
      _targetPlatformId = null;
      _targetModelId = null;
    });
  }

  void _openStrength(AiPlatform platform, AiModel model) {
    setState(() {
      _targetPlatformId = platform.id;
      _targetModelId = model.id;
    });
  }

  /// 某个模型当前生效的强度：当前选中的子模型用记住的强度，其它模型用默认值。
  String _effectiveEffortFor(AiPlatform platform, AiModel model) {
    final configured = widget.selectedReasoningEffort.trim();
    if (platform.id == widget.selectedPlatformId &&
        model.id == widget.selectedModelId &&
        configured.isNotEmpty) {
      return configured;
    }
    return model.effectiveReasoningEffort;
  }

  /// 强度选项：模型配置的档位去重；当前值不在列表时补到首位（不静默改写）。
  List<String> _effortOptionsFor(AiModel model, String current) {
    final seen = <String>{};
    final options = <String>[];
    for (final raw in model.effectiveReasoningEffortOptions) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      if (seen.add(value)) options.add(value);
    }
    if (!seen.contains(current)) options.insert(0, current);
    return options;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final targetPlatform = _targetPlatform;
    final targetModel = _targetModel;
    final size = MediaQuery.sizeOf(context);
    // 窄屏（手机 / 分屏）按可用宽度收窄；高度也留出标题与按钮空间。
    final width = (size.width - 96).clamp(260.0, 440.0).toDouble();
    final height = (size.height - 220).clamp(240.0, 420.0).toDouble();
    return AlertDialog(
      key: const ValueKey('subagent_model_dialog'),
      title: const Text(
        '非创作步所使用的模型（子模型）',
        key: ValueKey('subagent_model_dialog_title'),
      ),
      content: SizedBox(
        width: width,
        height: height,
        child: targetPlatform != null && targetModel != null
            ? _buildStrengthPanel(scheme, targetPlatform, targetModel)
            : _buildModelList(scheme),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _buildModelList(ColorScheme scheme) {
    final selected = findAgentSubModel(
      platforms: widget.platforms,
      platformId: widget.selectedPlatformId,
      modelId: widget.selectedModelId,
    );
    final mainPlatform = _platformById(widget.mainPlatformId);
    final mainModel =
        mainPlatform?.modelById(widget.mainModelId) ??
        mainPlatform?.defaultModel;
    return ListView(
      children: [
        ListTile(
          key: const ValueKey('subagent_model_follow_main'),
          selected: selected == null,
          selectedTileColor: scheme.primary.withValues(alpha: 0.07),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Icon(
            selected == null ? Icons.check_circle : Icons.circle_outlined,
            size: 20,
            color: selected == null ? scheme.primary : scheme.onSurfaceVariant,
          ),
          title: const Text(
            '与当前激活主模型一致',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            mainPlatform == null || mainModel == null
                ? '跟随对话页当前选中的模型'
                : '当前主模型：${mainPlatform.displayName} / '
                      '${mainModel.displayLabel}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          onTap: () =>
              Navigator.of(context)
                  .pop((platformId: '', modelId: '', reasoningEffort: '')),
        ),
        const Divider(height: 16),
        if (widget.platforms.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
            child: Text(
              '尚无可选模型，请先在 API 设置中添加平台与模型。',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        for (final platform in widget.platforms) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
            child: Text(
              platform.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final model in platform.models)
            _modelTile(scheme, platform, model, selected),
        ],
      ],
    );
  }

  Widget _modelTile(
    ColorScheme scheme,
    AiPlatform platform,
    AiModel model,
    AgentSubModel? selected,
  ) {
    final picked =
        selected != null &&
        selected.platform.id == platform.id &&
        selected.model.id == model.id;
    final isMain =
        platform.id == widget.mainPlatformId && model.id == widget.mainModelId;
    final supportsThinking = model.supportsThinking;
    final subtitle = supportsThinking && picked
        ? '${model.id} · 思考强度 ${_effectiveEffortFor(platform, model)}'
        : model.id;
    return ListTile(
      key: ValueKey('subagent_model_option_${platform.id}_${model.id}'),
      selected: picked,
      selectedTileColor: scheme.primary.withValues(alpha: 0.07),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Icon(
        picked ? Icons.check_circle : Icons.circle_outlined,
        size: 20,
        color: picked ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        model.displayLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: picked ? FontWeight.w600 : FontWeight.w400,
          color: picked ? scheme.primary : scheme.onSurface,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isMain) ...[_mainBadge(scheme), const SizedBox(width: 6)],
          if (supportsThinking)
            Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant)
          else
            Text(
              '无思考',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
      onTap: supportsThinking
          ? () => _openStrength(platform, model)
          : () => Navigator.of(context).pop((
              platformId: platform.id,
              modelId: model.id,
              reasoningEffort: '',
            )),
    );
  }

  Widget _buildStrengthPanel(
    ColorScheme scheme,
    AiPlatform platform,
    AiModel model,
  ) {
    final current = _effectiveEffortFor(platform, model);
    final options = _effortOptionsFor(model, current);
    return ListView(
      children: [
        Row(
          children: [
            IconButton(
              key: const ValueKey('subagent_model_strength_back'),
              onPressed: _resetTarget,
              icon: const Icon(Icons.arrow_back, size: 20),
              tooltip: '返回模型列表',
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '选择思考强度',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const Divider(height: 8),
        for (final effort in options)
          ListTile(
            key: ValueKey(
              'subagent_model_effort_${platform.id}_${model.id}_$effort',
            ),
            selected: effort == current,
            selectedTileColor: scheme.primary.withValues(alpha: 0.07),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            leading: Icon(
              effort == current ? Icons.check_circle : Icons.circle_outlined,
              size: 20,
              color: effort == current
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
            title: Text(
              effort,
              style: TextStyle(
                fontSize: 14,
                color: effort == current ? scheme.primary : scheme.onSurface,
                fontWeight: effort == current
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
            onTap: () => Navigator.of(context).pop((
              platformId: platform.id,
              modelId: model.id,
              reasoningEffort: effort,
            )),
          ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
          child: Text(
            '强度选项来自该模型配置，只用于非创作步（第二步状态维护）。',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _mainBadge(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '主模型',
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }

  AiPlatform? _platformById(String id) {
    for (final platform in widget.platforms) {
      if (platform.id == id) return platform;
    }
    return null;
  }
}
