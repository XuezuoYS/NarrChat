import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/ui_settings_provider.dart';
import '../screens/font_settings_screen.dart';
import '../services/system_fonts_service.dart';
import '../theme/app_theme.dart';

/// UI 设置子模块内容（通用设置面板内）：主题模式 + 字体设置入口。
///
/// 「字体设置」行本身不再承载字体/大小的具体交互，点按进入
/// [FontSettingsScreen] 二级页（字体样式选择 + 字体大小 6 档缩放）。
///
/// 设置保存到本地 JSON 配置文件（local_config/app_settings.json），不参与云同步。
class UiSettingsForm extends StatelessWidget {
  const UiSettingsForm({super.key});

  @override
  Widget build(BuildContext context) {
    final ui = context.watch<UiSettingsProvider>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildThemeSetting(context, ui),
        const SizedBox(height: 4),
        _buildFontEntry(context, ui),
      ],
    );
  }

  /// 主题模式设置：跟随系统（默认）/ 亮色 / 暗色。
  ///
  /// 窄屏时 SegmentedButton 独占一行并撑满宽度，避免挤压左侧文字描述；
  /// 宽屏保持 ListTile 横向布局。
  Widget _buildThemeSetting(BuildContext context, UiSettingsProvider ui) {
    final colors = context.narrColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;
        final segmented = SegmentedButton<AppThemeMode>(
          segments: narrow
              ? const [
                  ButtonSegment(
                    value: AppThemeMode.system,
                    label: Text('跟随系统'),
                  ),
                  ButtonSegment(value: AppThemeMode.light, label: Text('亮色')),
                  ButtonSegment(value: AppThemeMode.dark, label: Text('暗色')),
                ]
              : const [
                  ButtonSegment(
                    value: AppThemeMode.system,
                    icon: Icon(Icons.brightness_auto_outlined, size: 16),
                    label: Text('跟随系统'),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.light,
                    icon: Icon(Icons.light_mode_outlined, size: 16),
                    label: Text('亮色'),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.dark,
                    icon: Icon(Icons.dark_mode_outlined, size: 16),
                    label: Text('暗色'),
                  ),
                ],
          selected: {ui.themeMode},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => ui.setThemeMode(selection.first),
        );

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.brightness_6_outlined,
                    size: 24,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 16),
                  Text(
                    '主题',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Text(
                  '跟随系统（默认）：随系统亮暗自动切换',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: segmented),
            ],
          );
        }
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.brightness_6_outlined),
          title: const Text('主题'),
          subtitle: const Text('跟随系统（默认）：随系统亮暗自动切换'),
          trailing: segmented,
        );
      },
    );
  }

  /// 字体设置入口行：显示当前字体与当前缩放档位，点按进入二级页。
  Widget _buildFontEntry(BuildContext context, UiSettingsProvider ui) {
    final family = ui.fontFamily;
    final familyDisplay = family.isEmpty
        ? '系统默认'
        : (SystemFontsService.instance.displayNameOf(family) ?? family);
    return ListTile(
      key: const ValueKey('ui_settings_font_entry'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.font_download_outlined),
      title: const Text('字体设置'),
      subtitle: Text(
        '$familyDisplay（${ui.fontScaleLabel}）',
        style: TextStyle(
          fontFamily: family.isEmpty ? null : family,
          color: family.isEmpty
              ? context.narrColors.textSecondary
              : context.narrColors.textPrimary,
        ),
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => FontSettingsScreen.open(context),
    );
  }
}
