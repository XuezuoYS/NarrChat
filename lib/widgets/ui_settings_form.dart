import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/default_cover_style.dart';
import '../providers/ui_settings_provider.dart';
import '../screens/font_settings_screen.dart';
import '../services/system_fonts_service.dart';
import '../theme/app_theme.dart';
import 'settings/settings_kit.dart';

/// UI 设置子模块内容（通用设置面板内）：主题模式 + 默认封面 + 字体设置入口。
///
/// 三行放在同一张 [SettingsCard] 里，行间用分隔线区分；控件统一来自
/// 设置组件套件（分段选择行 / 下拉行 / 入口行）。
///
/// 「字体设置」行本身不承载字体/大小的具体交互，点按进入
/// [FontSettingsScreen] 二级页（字体样式选择 + 字体大小 6 档缩放）。
///
/// 设置保存到本地 JSON 配置文件（local_config/app_settings.json），不参与云同步。
class UiSettingsForm extends StatelessWidget {
  const UiSettingsForm({super.key});

  @override
  Widget build(BuildContext context) {
    final ui = context.watch<UiSettingsProvider>();
    return SettingsCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildThemeSetting(ui),
          const Divider(height: 1, indent: 14, endIndent: 14),
          _buildDefaultCoverSetting(ui),
          const Divider(height: 1, indent: 14, endIndent: 14),
          _buildFontEntry(context, ui),
        ],
      ),
    );
  }

  /// 主题模式设置：跟随系统（默认）/ 亮色 / 暗色。
  ///
  /// 窄屏时分段控件换到标题下方并撑满宽度（[SettingsSegmentedRow] 自动处理），
  /// 宽屏保持与标题 / 说明同行。
  Widget _buildThemeSetting(UiSettingsProvider ui) {
    return SettingsSegmentedRow<AppThemeMode>(
      icon: Icons.brightness_6_outlined,
      title: '主题',
      subtitle: '跟随系统（默认）：随系统亮暗自动切换',
      value: ui.themeMode,
      options: const [
        SettingsSegment(
          value: AppThemeMode.system,
          label: '跟随系统',
          icon: Icons.brightness_auto_outlined,
        ),
        SettingsSegment(
          value: AppThemeMode.light,
          label: '亮色',
          icon: Icons.light_mode_outlined,
        ),
        SettingsSegment(
          value: AppThemeMode.dark,
          label: '暗色',
          icon: Icons.dark_mode_outlined,
        ),
      ],
      onChanged: (mode) => ui.setThemeMode(mode),
    );
  }

  /// 默认封面设置：书籍未设置封面时，首页展示插画 1 / 程序生成的灰底书名封面。
  ///
  /// 整行任意位置可点展开菜单（[SettingsSelectRow]）；行容器保留原有
  /// `ui_settings_default_cover` / `ui_settings_default_cover_menu` 两个 key。
  Widget _buildDefaultCoverSetting(UiSettingsProvider ui) {
    return SettingsSelectRow<DefaultCoverStyle>(
      icon: Icons.image_outlined,
      title: '默认封面',
      subtitle: '当未设置书籍封面时，首页展示的封面内容',
      value: ui.defaultCoverStyle,
      labelOf: (style) => style.label,
      options: [
        for (final style in DefaultCoverStyle.values)
          SettingsSelectOption(value: style, label: style.label),
      ],
      onSelected: (style) => ui.setDefaultCoverStyle(style),
      rowKey: const ValueKey('ui_settings_default_cover'),
      valueKey: const ValueKey('ui_settings_default_cover_menu'),
    );
  }

  /// 字体设置入口行：显示当前字体与当前缩放档位，点按进入二级页。
  Widget _buildFontEntry(BuildContext context, UiSettingsProvider ui) {
    final family = ui.fontFamily;
    final familyDisplay = family.isEmpty
        ? '系统默认'
        : (SystemFontsService.instance.displayNameOf(family) ?? family);
    return SettingsLinkRow(
      icon: Icons.font_download_outlined,
      title: '字体设置',
      // 与旧版一致：入口行直接用所选字体渲染当前值，便于识别。
      subtitleWidget: Text(
        '$familyDisplay（${ui.fontScaleLabel}）',
        style: TextStyle(
          fontSize: 11.5,
          height: 1.4,
          fontFamily: family.isEmpty ? null : family,
          color: context.narrColors.textSecondary,
        ),
      ),
      onTap: () => FontSettingsScreen.open(context),
      rowKey: const ValueKey('ui_settings_font_entry'),
    );
  }
}
