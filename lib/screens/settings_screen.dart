import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/api_settings_form.dart';
import '../widgets/coming_soon_panel.dart';
import '../widgets/settings_shell.dart';

/// 全窗口设置界面。
///
/// 5 个子模块：
/// - API 设置：完整可用的接口参数配置；
/// - UI 设置 / Mod 管理 / 云同步：暂未开发，显示「未来开发」占位；
/// - 关于：应用信息。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsShell(
      title: '设置',
      icon: Icons.settings,
      navItems: const [
        SettingsNavItem(icon: Icons.api_outlined, label: 'API 设置'),
        SettingsNavItem(icon: Icons.palette_outlined, label: 'UI 设置'),
        SettingsNavItem(icon: Icons.extension_outlined, label: 'Mod 管理'),
        SettingsNavItem(icon: Icons.cloud_outlined, label: '云同步'),
        SettingsNavItem(icon: Icons.info_outline, label: '关于'),
      ],
      contentBuilder: (context, index) {
        switch (index) {
          case 0:
            return const ApiSettingsForm();
          case 1:
            return const ComingSoonPanel(
              icon: Icons.palette_outlined,
              title: 'UI 设置',
              description: '自定义主题、字体大小、气泡样式等界面选项。',
            );
          case 2:
            return const ComingSoonPanel(
              icon: Icons.extension_outlined,
              title: 'Mod 管理',
              description: '安装与管理扩展 Mod，为剧情创作添加额外能力。',
            );
          case 3:
            return const ComingSoonPanel(
              icon: Icons.cloud_outlined,
              title: '云同步',
              description: '将书籍、角色设定与剧情进度同步到云端。',
            );
          default:
            return const _AboutPanel();
        }
      },
    );
  }
}

/// 「关于」面板：应用基本信息。
class _AboutPanel extends StatelessWidget {
  const _AboutPanel();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F8),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: NarrChatTheme.divider),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: NarrChatTheme.brandGradient,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.auto_awesome,
                  size: 28, color: Colors.white),
            ),
            const SizedBox(height: 14),
            const Text(
              'NarrChat',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: NarrChatTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '你的 AI 叙事交互引擎',
              style: TextStyle(
                fontSize: 13,
                color: NarrChatTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            const _AboutRow(label: '版本', value: '1.0.0'),
            const _AboutRow(label: '模型', value: 'DeepSeek V4（OpenAI 兼容）'),
            const _AboutRow(label: '平台', value: 'Android / Windows'),
            const SizedBox(height: 12),
            const Text(
              '本软件仅供创作参考，生成内容请仔细甄别。',
              style: TextStyle(fontSize: 11, color: NarrChatTheme.textSecondary),
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
            style: const TextStyle(
              fontSize: 13,
              color: NarrChatTheme.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              color: NarrChatTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
