import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/ui_settings_provider.dart';
import '../services/system_fonts_service.dart';
import '../theme/app_theme.dart';

/// UI 设置面板：全局字体选择（列出系统可用字体，按真实字体名预览）。
///
/// 设置保存到本地 JSON 配置文件（local_config/app_settings.json），不参与云同步。
class UiSettingsForm extends StatefulWidget {
  const UiSettingsForm({super.key});

  @override
  State<UiSettingsForm> createState() => _UiSettingsFormState();
}

class _UiSettingsFormState extends State<UiSettingsForm> {
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _ensureScanned();
  }

  Future<void> _ensureScanned() async {
    if (SystemFontsService.instance.isScanned) return;
    setState(() => _scanning = true);
    await SystemFontsService.instance.scan();
    if (mounted) setState(() => _scanning = false);
  }

  @override
  Widget build(BuildContext context) {
    final ui = context.watch<UiSettingsProvider>();
    final colors = context.narrColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'UI 设置',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '界面显示偏好，保存到本地配置文件（不参与云同步）。',
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 20),
        _buildThemeSetting(context, ui),
        const SizedBox(height: 4),
        _buildFontSetting(context, ui),
      ],
    );
  }

  /// 主题模式设置：跟随系统（默认）/ 亮色 / 暗色。
  Widget _buildThemeSetting(BuildContext context, UiSettingsProvider ui) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.brightness_6_outlined),
      title: const Text('主题'),
      subtitle: const Text('跟随系统（默认）：随系统亮暗自动切换'),
      trailing: SegmentedButton<AppThemeMode>(
        segments: const [
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
        onSelectionChanged: (selection) =>
            ui.setThemeMode(selection.first),
      ),
    );
  }

  Widget _buildFontSetting(BuildContext context, UiSettingsProvider ui) {
    if (_scanning) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text('正在扫描系统字体…'),
      );
    }
    final fonts = SystemFontsService.instance.fonts;
    final current = ui.fontFamily;
    if (fonts.isEmpty) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.font_download_off_outlined),
        title: Text('全局字体'),
        subtitle: Text('未检测到可用字体'),
      );
    }
    final currentFont = _findFont(current);
    final display = current.isEmpty
        ? '系统默认'
        : (currentFont?.displayName ?? current);
    final secondary =
        currentFont != null && currentFont.displayName != currentFont.familyName
        ? currentFont.familyName
        : null;
    final colors = context.narrColors;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.font_download_outlined),
      title: const Text('全局字体'),
      subtitle: Text(
        secondary == null ? display : '$display（$secondary）',
        style: TextStyle(
          fontFamily: current.isEmpty ? null : current,
          color: current.isEmpty ? colors.textSecondary : colors.textPrimary,
        ),
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => _pickFont(context, ui),
    );
  }

  SystemFont? _findFont(String familyName) {
    for (final f in SystemFontsService.instance.fonts) {
      if (f.familyName == familyName) return f;
    }
    return null;
  }

  Future<void> _pickFont(BuildContext context, UiSettingsProvider ui) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _FontPickerDialog(current: ui.fontFamily),
    );
    if (selected == null || !context.mounted) return;
    final ok = await ui.setFontFamily(selected);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('字体加载失败，已保持原设置')));
    }
  }
}

/// 系统字体选择对话框：列出全部可用字体（以对应字体渲染名称预览）。
class _FontPickerDialog extends StatelessWidget {
  final String current;

  const _FontPickerDialog({required this.current});

  @override
  Widget build(BuildContext context) {
    final fonts = SystemFontsService.instance.fonts;
    return AlertDialog(
      title: const Text('选择全局字体'),
      content: SizedBox(
        width: 380,
        height: 440,
        child: ListView.builder(
          itemCount: fonts.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return ListTile(
                dense: true,
                selected: current.isEmpty,
                title: const Text('系统默认'),
                onTap: () => Navigator.of(context).pop(''),
              );
            }
            final font = fonts[index - 1];
            // 中文字体优先显示中文名（如 微软雅黑），附英文族名作副标题。
            final showEn = font.displayName != font.familyName;
            return ListTile(
              dense: true,
              selected: current == font.familyName,
              title: Text(
                font.displayName,
                style: TextStyle(fontFamily: font.familyName),
              ),
              subtitle: showEn ? Text(font.familyName) : null,
              onTap: () => Navigator.of(context).pop(font.familyName),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
