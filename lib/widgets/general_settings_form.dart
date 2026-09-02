import 'package:flutter/material.dart';

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
/// - 实验性设置：尚未开放（占位）。
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

/// 「实验性设置」子模块内容：暂无实验性功能，仅占位。
class _ExperimentalSettingsSection extends StatelessWidget {
  const _ExperimentalSettingsSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        '暂无实验性功能，敬请期待。',
        style: TextStyle(
          fontSize: 13,
          color: context.narrColors.textSecondary,
        ),
      ),
    );
  }
}
