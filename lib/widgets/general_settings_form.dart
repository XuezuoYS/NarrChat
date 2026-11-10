import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/agent_mode_level.dart';
import '../providers/experimental_settings_provider.dart';
import 'other_settings_section.dart';
import 'settings/settings_kit.dart';
import 'ui_settings_form.dart';

/// 「通用设置」设置面板。
///
/// 三个子模块同一页面纵向分区（统一使用设置组件套件的分区头 + 卡片）：
/// - UI 设置：全局字体、主题等界面偏好（即时生效）；
/// - 其它设置：应用行为类杂项（「检查更新」开关 + 预发布版本开关 +
///   「立即检查更新」入口）；
/// - 实验性设置：实验性功能档位（如「Agent 模式」两档：无 / Agent Lv.1）。
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
          title: '实验性设置',
          child: _ExperimentalSettingsSection(),
        ),
      ],
    );
  }
}

/// 「实验性设置」子模块内容：Agent 模式档位（默认「无 / 使用传统 Chat 方式」）。
///
/// 档位与平台接入协议**正交**（见 RoundProvider 矩阵化分派）：
/// - 协议（OpenAI Chat / Response 兼容）只决定请求体与线路格式；
/// - **Lv.1**：仅历史（记忆总结）工具 + 联网；正文输出 5 个区块（排除记忆总结），
///   每轮三段：调研（读史 + 按需联网）→ 同一回合「推演剧情 + 落记忆条目」→
///   输出正文（维护轮只作兜底）。
///
/// 历史上的完整 Agent（Lv.2，六工具 + 正文三小节）**已移除**：世界 / 角色工具
/// 与多栏目缺口框架仍留在代码里作为后续档位的基础设施，当前不注册；旧配置值
/// `2` 与旧布尔键回落「关」（见 `ExperimentalSettingsProvider.load`）。
///
/// 交互与文案分工：
/// - **整行任意位置可点**即可展开档位菜单（不必对准右侧箭头）；
/// - 行内只保留**简要**介绍（工具 / 分阶段生成 + 指示器限制 + 破坏性变更声明），
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
  /// 简要介绍：工具 / 分阶段生成 + 指示器限制 + 破坏性变更声明（细节在选项内）。
  static const String _agentModeDescription =
      '实验性功能（默认「无」）：启用后调用自定义工具（narrchat_*）走分阶段生成'
      '（调研 → 记忆 → 正文），由 Agent 托管部分状态——托管范围见下拉选项说明。'
      '⚠ 档位开启期间，模型已支持的功能（思考 / 流式 / 搜索）无法通过对话页'
      '指示器关闭；未来更新可能对本功能做出破坏性变更，正确性不保证。';

  void _setLevel(AgentModeLevel level) {
    // Provider 内先乐观生效并异步持久化（保存失败仅记录）。
    context.read<ExperimentalSettingsProvider>().setAgentModeLevel(level);
  }

  void _toggleReduceReasoning(bool reduce) {
    context
        .read<ExperimentalSettingsProvider>()
        .setReduceReasoningReplay(reduce);
  }

  @override
  Widget build(BuildContext context) {
    final experimental = context.watch<ExperimentalSettingsProvider>();
    return SettingsCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildLevelMenu(experimental),
          const Divider(height: 1, indent: 14, endIndent: 14),
          _buildReasoningReplaySwitch(experimental),
        ],
      ),
    );
  }

  /// Agent 档位下拉行（整行可点展开菜单；选项带标题 + 一行说明）。
  Widget _buildLevelMenu(ExperimentalSettingsProvider experimental) {
    return SettingsSelectRow<AgentModeLevel>(
      icon: Icons.psychology_outlined,
      title: 'Agent 模式',
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

  /// 「精简思考回传」开关行（Agent 模式专用；默认关）。
  Widget _buildReasoningReplaySwitch(ExperimentalSettingsProvider experimental) {
    return SettingsSwitchRow(
      icon: Icons.compress_outlined,
      title: '精简思考回传',
      subtitle: 'Agent 模式专用（默认关）：开启后回传思考只保留首段与末段'
          '（单段则原样），降低每帧重发历史的输入 token。'
          '⚠ 会改写思考原文——自定义网关要求思考完整时请保持关闭。',
      value: experimental.reduceReasoningReplay,
      switchKey: const ValueKey('experimental_reduce_reasoning_switch'),
      onChanged: _toggleReduceReasoning,
    );
  }
}
