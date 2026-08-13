import 'package:flutter/material.dart';

import 'licenses_screen.dart';
import '../theme/app_theme.dart';
import '../utils/release_info.dart';
import '../widgets/ai_settings_form.dart';
import '../widgets/brand_logo.dart';
import '../widgets/cloud_sync_panel.dart';
import '../widgets/mod_management_panel.dart';
import '../widgets/settings_shell.dart';
import '../widgets/ui_settings_form.dart';

/// 全窗口设置界面。
///
/// 5 个子模块：
/// - AI 选择：模型预设 + 参数（始终可调）+ API 连接；
/// - UI 设置：全局字体等界面偏好；
/// - Mod 管理：查看预置 Mod，创建/编辑/导出/导入自定义 Mod；
/// - 云同步：WebDAV 云端备份 / 恢复；
/// - 关于：应用信息。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return SettingsShell(
      title: '设置',
      icon: Icons.settings,
      navItems: const [
        SettingsNavItem(icon: Icons.smart_toy_outlined, label: 'AI 选择'),
        SettingsNavItem(icon: Icons.palette_outlined, label: 'UI 设置'),
        SettingsNavItem(icon: Icons.extension_outlined, label: 'Mod 管理'),
        SettingsNavItem(icon: Icons.cloud_outlined, label: '云同步'),
        SettingsNavItem(icon: Icons.info_outline, label: '关于'),
      ],
      contentBuilder: (context, index) {
        switch (index) {
          case 0:
            return const AiSettingsForm();
          case 1:
            return const UiSettingsForm();
          case 2:
            return const ModManagementPanel();
          case 3:
            return const CloudSyncPanel();
          default:
            return const _AboutPanel();
        }
      },
    );
  }
}

/// 「关于」面板：应用基本信息。
class _AboutPanel extends StatefulWidget {
  const _AboutPanel();

  @override
  State<_AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<_AboutPanel> {
  late Future<String> _versionFuture;

  @override
  void initState() {
    super.initState();
    _versionFuture = ReleaseInfo.versionLabel();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部块：关于本软件信息。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
              decoration: BoxDecoration(
                color: context.narrColors.background,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: context.narrColors.divider),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const BrandLogo(size: 56),
                  const SizedBox(height: 14),
                  Text(
                    'NarrChat',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: context.narrColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FutureBuilder<String>(
                    future: _versionFuture,
                    builder: (context, snapshot) {
                      return _AboutRow(
                        label: '版本',
                        value: snapshot.data ?? '…',
                      );
                    },
                  ),
                  if (ReleaseInfo.flutterVersion.isNotEmpty) ...[const SizedBox(height: 12),
                    _AboutRow(
                      label: 'Flutter',
                      value: ReleaseInfo.flutterVersion,
                    ),
                  ],
                  const SizedBox(height: 14),
                  Text(
                    '本软件仅供创作参考，生成内容请仔细甄别。',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.narrColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 底部块：开放源代码许可入口（与上方信息块同级别）。
            _AboutEntry(
              icon: Icons.receipt_long_outlined,
              label: '开放源代码许可',
              onTap: () => LicensesScreen.open(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;

  const _AboutRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: context.narrColors.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: context.narrColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「关于」面板入口块：图标 + 文案 + 尾箭头，可点击跳转
/// （与上方「关于本软件」信息块同级别的独立卡片）。
class _AboutEntry extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AboutEntry({
    required this.icon,
    required this.label,
    required this.onTap,
  });

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
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 18, color: colors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 14, color: colors.textPrimary),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
