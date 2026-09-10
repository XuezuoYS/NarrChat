import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/agent_mode_level.dart';
import '../providers/experimental_settings_provider.dart';
import '../services/local_config_service.dart';
import '../services/update_check_flow.dart';
import '../theme/app_theme.dart';
import 'ui_settings_form.dart';

/// 「通用设置」设置面板。
///
/// 三个子模块同一页面纵向分区（分区标题样式与 API 设置的
/// 「图片设置 / 模型设置」一致）：
/// - UI 设置：全局字体、主题等界面偏好（即时生效）；
/// - 其它设置：应用行为类杂项（如「检查更新」开关）；
/// - 实验性设置：实验性功能档位（如「Agent 模式」三档：关 / Lv.1 / Lv.2）。
///
/// 设置保存到本地 JSON 配置文件（local_config/app_settings.json），不参与云同步。
class GeneralSettingsForm extends StatelessWidget {
  const GeneralSettingsForm({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '通用设置',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '界面显示偏好与应用行为等本地配置，保存到本地配置文件（不参与云同步）。',
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 20),
        const _SubSection(title: 'UI 设置', child: UiSettingsForm()),
        const _SubSection(title: '其它设置', child: _OtherSettingsSection()),
        const _SubSection(
          title: '实验性设置',
          child: _ExperimentalSettingsSection(),
        ),
      ],
    );
  }
}

/// 设置面板子分区：小标题（样式同 API 设置「图片设置 / 模型设置」）+ 内容。
class _SubSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _SubSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 6),
        child,
        const SizedBox(height: 20),
      ],
    );
  }
}

/// 「其它设置」子模块内容：目前包含「检查更新」开关（默认开启）。
class _OtherSettingsSection extends StatefulWidget {
  const _OtherSettingsSection();

  @override
  State<_OtherSettingsSection> createState() => _OtherSettingsSectionState();
}

class _OtherSettingsSectionState extends State<_OtherSettingsSection> {
  /// 「检查更新」开关（默认开启；从本地配置读取，读取失败按默认值）。
  bool _updateCheckEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadUpdateCheckEnabled();
  }

  /// 读取「检查更新」开关（本地明文配置文件；读取失败按默认开启）。
  Future<void> _loadUpdateCheckEnabled() async {
    var enabled = true;
    try {
      final config = await LocalConfigService.read();
      enabled = UpdateCheckFlow.updateCheckEnabledFrom(config);
    } catch (_) {
      // 配置不可用（如测试环境无 path_provider）时按默认开启。
    }
    if (mounted) setState(() => _updateCheckEnabled = enabled);
  }

  /// 切换「检查更新」开关：先生效再持久化，保存失败不影响本次会话。
  void _toggleUpdateCheck(bool value) {
    setState(() => _updateCheckEnabled = value);
    LocalConfigService.update({UpdateCheckFlow.keyUpdateCheckEnabled: value})
        .catchError((Object e) {
      debugPrint('检查更新开关保存失败：$e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.divider),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _toggleUpdateCheck(!_updateCheckEnabled),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.system_update_alt_outlined,
                  size: 18,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '检查更新',
                        style: TextStyle(
                          fontSize: 14,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '启动时检查新版本（每天最多一次）',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: const ValueKey('other_update_check_switch'),
                  value: _updateCheckEnabled,
                  onChanged: _toggleUpdateCheck,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「实验性设置」子模块内容：Agent 模式档位（默认「无 / 使用传统 Chat 方式」）。
///
/// 档位与平台接入协议**正交**（见 RoundProvider 矩阵化分派）：
/// - 协议（OpenAI Chat / Response 兼容）只决定请求体与线路格式；
/// - **Lv.1**：仅历史（记忆总结）工具 + 联网；正文输出 5 个区块（排除记忆总结），
///   历史由工具读写（正文轮先读、维护轮每轮必发地写）；
/// - **Lv.2**：完整 Agent（六个状态工具：世界 / 角色 / 历史各一读一写 + 联网）；
///   正文只输出 3 个小节，状态全部由工具维护。
///
/// 交互与文案分工：
/// - **整张卡片任意位置可点**即可展开档位菜单（不必对准右侧箭头）；
/// - 卡片内只保留**简要**介绍（工具 / 两阶段 + 指示器限制 + 破坏性变更声明），
///   各档位的差异写在**下拉选项内**（[AgentModeLevel.menuDetail]）；
/// - 菜单用 [MenuAnchor]（与对话页模型选择器同款交互）而非 `DropdownButton`：
///   后者的展开热区只覆盖按钮本身。
class _ExperimentalSettingsSection extends StatefulWidget {
  const _ExperimentalSettingsSection();

  @override
  State<_ExperimentalSettingsSection> createState() =>
      _ExperimentalSettingsSectionState();
}

class _ExperimentalSettingsSectionState
    extends State<_ExperimentalSettingsSection> {
  /// 简要介绍：工具 / 两阶段 + 指示器限制 + 破坏性变更声明（细节在选项内）。
  static const String _agentModeDescription =
      '实验性功能（默认「无」）：启用后调用自定义工具（narrchat_*）走两阶段生成，'
      '由 Agent 托管部分状态——各档位托管范围见下拉选项说明。'
      '⚠ 档位开启期间，模型已支持的功能（思考 / 流式 / 搜索）无法通过对话页'
      '指示器关闭；未来更新可能对本功能做出破坏性变更，正确性不保证。';

  void _setLevel(AgentModeLevel level) {
    // Provider 内先乐观生效并异步持久化（保存失败仅记录）。
    context.read<ExperimentalSettingsProvider>().setAgentModeLevel(level);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final experimental = context.watch<ExperimentalSettingsProvider>();
    final current = experimental.agentModeLevel;
    return MenuAnchor(
      // 与对话页模型选择器同款动画与圆角；选项带标题 + 一行说明。
      animated: true,
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      menuChildren: [
        for (final level in AgentModeLevel.values)
          MenuItemButton(
            key: ValueKey('experimental_agent_mode_option_${level.id}'),
            onPressed: () => _setLevel(level),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      level == current
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      size: 13,
                      color: level == current
                          ? Theme.of(context).colorScheme.primary
                          : colors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      level.menuTitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            level == current ? FontWeight.w600 : FontWeight.normal,
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 17, top: 2),
                  child: Text(
                    level.menuDetail,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
      ],
      builder: (context, controller, _) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.divider),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: const ValueKey('experimental_agent_mode_card'),
            borderRadius: BorderRadius.circular(16),
            // 整卡可点：展开 / 收起档位菜单（不必对准右侧箭头）。
            onTap: () => controller.isOpen
                ? controller.close()
                : controller.open(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Agent 模式',
                          style: TextStyle(
                            fontSize: 14,
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _agentModeDescription,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 当前档位展示（纯展示；点击热区由整卡承担）：
                  // 将来追加档位只需扩展 [AgentModeLevel]，此处与对话页徽标自动跟随。
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        current.label,
                        key: const ValueKey('experimental_agent_mode_label'),
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textPrimary,
                        ),
                      ),
                      Icon(
                        controller.isOpen
                            ? Icons.arrow_drop_up
                            : Icons.arrow_drop_down,
                        size: 18,
                        color: colors.textSecondary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
