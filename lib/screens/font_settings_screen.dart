import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/ui_settings_provider.dart';
import '../services/system_fonts_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_notice_overlay.dart';
import '../widgets/font_picker_dialog.dart';

/// 「字体设置」二级页（由「通用设置 → UI 设置 → 字体设置」进入）。
///
/// 页面结构（自上而下）：顶栏 / 预览块 / 字体选择 / 大小选择。
/// - 顶栏：左侧返回（与系统返回键同一逻辑），右侧「重置」「保存」；
/// - 预览块：以草稿字体实时预览（缩放倍率由全局 `textScaler` 提供，不在此叠加）；
/// - 字体选择：点按弹出 [FontPickerDialog] 选择系统字体；
/// - 大小选择：滑杆 6 档（-30% / -15% / 0%（默认）/ +15% / +30% / +45%）。
///
/// 页内改动先存**草稿态**（不即时落盘），点「保存」才写入 [UiSettingsProvider]
/// 与应用全局；返回时若存在未保存改动则提示「保存 / 不保存 / 取消」。
class FontSettingsScreen extends StatefulWidget {
  const FontSettingsScreen({super.key});

  /// 打开字体设置二级页（全窗口）。
  ///
  /// 保存成功时把选定的字体大小档位（[FontScaleLevel.offset] 偏移量）写回
  /// [UiSettingsProvider]；「不保存」返回时不写回，全局设置保持原值。
  static Future<void> open(BuildContext context) async {
    final selected = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => const FontSettingsScreen()),
    );
    if (selected == null || !context.mounted) return;
    await context.read<UiSettingsProvider>().setFontScaleIndex(selected);
  }

  @override
  State<FontSettingsScreen> createState() => _FontSettingsScreenState();
}

class _FontSettingsScreenState extends State<FontSettingsScreen> {
  /// 草稿字体族名（空字符串表示系统默认）。
  late String _draftFamily;

  /// 草稿字体大小档位偏移量（0 = 0% = 默认，可为负）。
  late int _draftScaleIndex;

  /// 是否正在保存（保存期间禁用顶栏两个按钮，防重复提交）。
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final ui = context.read<UiSettingsProvider>();
    _draftFamily = ui.fontFamily;
    _draftScaleIndex = ui.fontScaleIndex;
  }

  /// 是否存在未保存改动（与全局设置逐项比较）。
  bool get _isDirty {
    final ui = context.read<UiSettingsProvider>();
    return _draftFamily != ui.fontFamily ||
        _draftScaleIndex != ui.fontScaleIndex;
  }

  /// 草稿档位的展示标签（如 `0%` / `+15%`）。
  String get _draftLabel => FontScaleLevel.fromOffset(_draftScaleIndex).label;

  /// 草稿档位的文字缩放倍率（预览块按它实时缩放）。
  double get _draftMultiplier =>
      FontScaleLevel.fromOffset(_draftScaleIndex).scale;

  /// 草稿字体的展示名（当前所选字体已加载时优先中文名）。
  String get _draftFontDisplay {
    if (_draftFamily.isEmpty) return '系统默认';
    return SystemFontsService.instance.displayNameOf(_draftFamily) ??
        _draftFamily;
  }

  /// 保存：先应用字体样式（加载失败则提示并留在页内），再写回大小档位。
  ///
  /// 成功返回 true（字体样式与档位都已落盘）。
  Future<bool> _save() async {
    final ui = context.read<UiSettingsProvider>();
    final notices = context.notices;
    setState(() => _isSaving = true);
    final fontOk = await ui.setFontFamily(_draftFamily);
    if (!mounted) return false;
    if (!fontOk) {
      setState(() => _isSaving = false);
      notices.error('字体加载失败，已保持原设置');
      return false;
    }
    await ui.setFontScaleIndex(_draftScaleIndex);
    if (!mounted) return false;
    setState(() => _isSaving = false);
    notices.success('已保存');
    return true;
  }

  /// 「保存」按钮：保存成功后返回上一级（同时刷新入口行副标题）。
  Future<void> _saveAndExit() async {
    if (_isSaving) return;
    if (await _save() && mounted) {
      Navigator.of(context).pop(_draftScaleIndex);
    }
  }

  /// 「重置」：字体样式回系统默认、大小回默认档（0%），需再点「保存」才落盘。
  void _reset() {
    setState(() {
      _draftFamily = '';
      _draftScaleIndex = FontScaleLevel.defaultLevel.offset;
    });
  }

  /// 返回（顶栏按钮与系统返回键共用）：有未保存改动时先提示。
  Future<void> _handleBack() async {
    if (!_isDirty) {
      Navigator.of(context).pop();
      return;
    }
    final choice = await showDialog<_UnsavedChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存修改？'),
        content: const Text('字体设置已修改，是否保存？'),
        actions: [
          TextButton(
            key: const ValueKey('font_settings_unsaved_cancel'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_UnsavedChoice.cancel),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('font_settings_unsaved_discard'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_UnsavedChoice.discard),
            child: const Text('不保存'),
          ),
          FilledButton(
            key: const ValueKey('font_settings_unsaved_save'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_UnsavedChoice.save),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _UnsavedChoice.save:
        if (await _save() && mounted) {
          Navigator.of(context).pop(_draftScaleIndex);
        }
      case _UnsavedChoice.discard:
        Navigator.of(context).pop();
      case _UnsavedChoice.cancel:
      case null:
        break;
    }
  }

  /// 选择字体样式：草稿态生效（不即时落盘，保存时才应用全局）。
  ///
  /// 选中后立即注册字体到引擎，使预览块能立刻以该字体渲染；
  /// 加载失败不阻断选择（预览临时回退默认字体）。
  Future<void> _pickFont() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => FontPickerDialog(current: _draftFamily),
    );
    if (selected == null || !mounted) return;
    setState(() => _draftFamily = selected);
    if (selected.isNotEmpty) {
      await SystemFontsService.instance.loadFont(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听 Provider：若全局字体/档位在别处变化，脏判定与副标题保持一致。
    context.watch<UiSettingsProvider>();
    final colors = context.narrColors;
    return PopScope(
      // 拦截系统返回键，与顶栏返回按钮共用「未保存改动」确认逻辑。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: BackButton(
            key: const ValueKey('font_settings_back'),
            onPressed: _handleBack,
          ),
          title: const Text('字体设置'),
          actions: [
            // 与「保存」等尺寸的白底按钮（AppBar 的 FilledButton 前景色
            // 由 appBarTheme 的 foregroundColor 提供），便于识别为操作按钮。
            FilledButton.icon(
              key: const ValueKey('font_settings_reset'),
              onPressed: _isSaving ? null : _reset,
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('重置'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const ValueKey('font_settings_save'),
              onPressed: _isSaving ? null : _saveAndExit,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(_isSaving ? '保存中…' : '保存'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPreview(colors),
                  const SizedBox(height: 20),
                  _buildFontSection(colors),
                  const SizedBox(height: 20),
                  _buildSizeSection(colors),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 预览块：按**草稿**字体与档位实时渲染样例文本。
  Widget _buildPreview(NarrChatColors colors) {
    final fontFamily = _draftFamily.isEmpty ? null : _draftFamily;
    return _SectionCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            icon: Icons.visibility_outlined,
            title: '预览',
            colors: colors,
            trailing: Text(
              _draftLabel,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 用草稿倍率覆盖全局 textScaler：拖动滑杆时预览即时变化
          // （预览不叠加两重缩放）。
          MediaQuery.withClampedTextScaling(
            minScaleFactor: _draftMultiplier,
            maxScaleFactor: _draftMultiplier,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _previewCn,
                  key: const ValueKey('font_settings_preview_cn'),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    fontFamily: fontFamily,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _previewEn,
                  key: const ValueKey('font_settings_preview_en'),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    fontFamily: fontFamily,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 字体选择区：点按整行弹出字体对话框（与预览块同一套头部样式）。
  Widget _buildFontSection(NarrChatColors colors) {
    return _SectionCard(
      colors: colors,
      padding: EdgeInsets.zero,
      child: Stack(
        children: [
          // 整行可点：点击热区覆盖标题与当前字体值。
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('font_settings_font_tile'),
                onTap: _pickFont,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionHeader(
                  icon: Icons.font_download_outlined,
                  title: '字体样式',
                  colors: colors,
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _draftFontDisplay,
                  style: TextStyle(
                    // 与预览一致：以所选字体渲染当前值，便于直接比对。
                    fontSize: 13,
                    fontFamily: _draftFamily.isEmpty ? null : _draftFamily,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 大小选择区：滑杆（6 档）+ 与刻度精确对齐的档位标签。
  Widget _buildSizeSection(NarrChatColors colors) {
    // 滑杆按 0..5 的序号取值，偏移量与序号的换算集中在此（避免散落魔法数）。
    const levelCount = FontScaleLevel.maxOffset - FontScaleLevel.minOffset + 1;
    final sliderValue = (_draftScaleIndex - FontScaleLevel.minOffset).toDouble();
    return _SectionCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeader(
            icon: Icons.format_size_outlined,
            title: '字体大小',
            colors: colors,
            trailing: Text(
              _draftLabel,
              key: const ValueKey('font_settings_scale_label'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 滑杆与档位标签共用 [trackInset] 左右内边距，使 6 个标签的中心
          // 与滑杆 6 个刻度（含首尾）严格对齐；标签取自然宽度居中且禁止换行
          // （窄屏放不下时省略号，绝不折行）。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _trackInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Slider(
                  key: const ValueKey('font_settings_scale_slider'),
                  min: 0,
                  max: (levelCount - 1).toDouble(),
                  divisions: levelCount - 1,
                  value: sliderValue,
                  label: _draftLabel,
                  onChanged: (value) => setState(
                    () => _draftScaleIndex =
                        FontScaleLevel.minOffset + value.round(),
                  ),
                ),
                Row(
                  children: [
                    for (final level in FontScaleLevel.values)
                      Expanded(
                        child: Text(
                          level.label,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: level.offset == _draftScaleIndex
                                ? Theme.of(context).colorScheme.primary
                                : colors.textSecondary,
                            fontWeight: level.offset == _draftScaleIndex
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 滑杆轨道左右内边距（Material 滑杆的固定 tap target 内缩）：
/// 刻度位于 `[inset, width - inset]`，档位标签行使用同一内边距即可对齐。
const double _trackInset = 24;

/// 预览样例文本（中文；两段、含中英混排与标点，末尾为数字尾缀）。
const String _previewCn =
    '现在，这位自称蓝色大肥鱼的小女仆牵起裙摆，转了一圈，问：“诶？你认为我这样好看嘛？主人……会喜欢我这样嘛？”\n'
    '而那位穿著漢服的姑娘將團扇掩住嘴唇，輕笑著不知道說了什麼，只見小女僕羞著臉錘了她兩下。“才不會呢！”她嬌嗔道。\n'
    '0123456789';

/// 预览样例文本（上段中文的英文翻译，同样两段 + 数字尾缀）。
const String _previewEn =
    'Now, this little maid who calls herself the Big Blue Fat Fish lifted her '
    'skirt and twirled around, asking, "Eh? Do you think I look good like this? '
    'Would Master... like me this way?"\n'
    'Meanwhile, the girl in Hanfu covered her lips with a round fan and laughed '
    'softly, saying something none could hear, until the little maid, blushing, '
    'pounded her twice. "No way!" she pouted.\n'
    '0123456789';

/// 分区头部：图标 + 标题（+ 右侧当前值），三个分区共用同一套样式。
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final NarrChatColors colors;
  final Widget? trailing;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.colors,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: colors.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// 未保存改动的处理选择。
enum _UnsavedChoice { save, discard, cancel }

/// 卡片式分区容器（背景 + 圆角 + 细边框）。
///
/// 背景色由不透明 [Material] 承载（而非 [Container] 的 DecoratedBox）：
/// 容器内可能出现 ListTile 等依赖最近 Material 绘制墨迹的组件，
/// 用带背景色的 DecoratedBox 包裹会触发
/// 「ListTile background color or ink splashes may be invisible」断言
/// （与 `settings_shell.dart` 的同类处理一致）。
class _SectionCard extends StatelessWidget {
  final NarrChatColors colors;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _SectionCard({
    required this.colors,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.divider),
      ),
      // 圆角裁剪，避免 Material 的不透明背景溢出圆角。
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: colors.surface,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
