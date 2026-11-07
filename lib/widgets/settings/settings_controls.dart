import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'settings_layout.dart';

/// 设置页统一交互控件：设置行 / 开关行 / 复选行 / 下拉行 / 分段选择。
///
/// 统一约定：
/// - 整行是点击热区（`SettingsRow` 内为 [InkWell]），行内控件（Switch /
///   Checkbox / TextField / IconButton）命中时只由控件自身处理，不会重复触发；
/// - 圆角统一取 [NarrChatTheme.controlRadius]，动效统一取
///   [NarrChatTheme.motionFast] / [NarrChatTheme.motionNormal] /
///   [NarrChatTheme.motionCurve]；
/// - 颜色全部来自 [NarrChatColors] 与 [ColorScheme]，不写死。

/// 设置行基座：整行可点、悬停/按压高亮、可选图标与尾部控件。
class SettingsRow extends StatelessWidget {
  /// 左侧图标（与 [leading] 二选一）。
  final IconData? icon;

  /// 左侧自定义控件（如 Switch 或徽章）；优先级高于 [icon]。
  final Widget? leading;

  /// 行标题（单行省略）。
  final String title;

  /// 行副标题（最多 3 行省略）。
  final String? subtitle;

  /// 自定义副标题控件（用于需要特殊字体的值，如字体预览）；优先于 [subtitle]。
  final Widget? subtitleWidget;

  /// 行尾控件（开关 / 下拉值 / 箭头 / 按钮组等）。
  final Widget? trailing;

  /// 整行点击回调；null 时本行不可点（但仍可包含可交互的尾部控件）。
  final VoidCallback? onTap;

  /// 是否可用（false 时整行降对比且不可点）。
  final bool enabled;

  /// 行内边距。
  final EdgeInsetsGeometry padding;

  /// 行 InkWell 的 key（测试 / 自动化定位用）。
  final Key? rowKey;

  const SettingsRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    this.rowKey,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final effectiveOnTap = enabled ? onTap : null;
    final row = InkWell(
      key: rowKey,
      onTap: effectiveOnTap,
      borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
      hoverColor: NarrChatTheme.primary.withValues(alpha: 0.05),
      splashColor: NarrChatTheme.primary.withValues(alpha: 0.08),
      child: Padding(
        padding: padding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 12),
            ] else if (icon != null) ...[
              Icon(icon, size: 20, color: colors.textSecondary),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  if (subtitleWidget != null) ...[
                    const SizedBox(height: 2),
                    subtitleWidget!,
                  ] else if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ],
          ],
        ),
      ),
    );
    if (!enabled) return Opacity(opacity: 0.5, child: row);
    return row;
  }
}

/// 导航 / 选择入口行：尾部固定右箭头，整行可点。
class SettingsLinkRow extends StatelessWidget {
  /// 左侧图标（可选）。
  final IconData? icon;

  /// 行标题。
  final String title;

  /// 行副标题（可选）。
  final String? subtitle;

  /// 自定义副标题控件（如字体预览）；优先于 [subtitle]。
  final Widget? subtitleWidget;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 行 InkWell 的 key。
  final Key? rowKey;

  const SettingsLinkRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    required this.onTap,
    this.rowKey,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleWidget: subtitleWidget,
      onTap: onTap,
      rowKey: rowKey,
      trailing: Icon(
        Icons.chevron_right,
        size: 20,
        color: context.narrColors.textSecondary,
      ),
    );
  }
}

/// 开关行：**整行任意位置**点击切换；开关本体也保留自己的点击。
///
/// 行 [InkWell] 与 [Switch] 各自处理手势：点开关只触发 Switch 的
/// `onChanged`，点行其它位置只触发行的 `onChanged(!value)`，不会切换两次。
class SettingsSwitchRow extends StatelessWidget {
  /// 左侧图标（可选）。
  final IconData? icon;

  /// 行标题。
  final String title;

  /// 行副标题（可选）。
  final String? subtitle;

  /// 当前值。
  final bool value;

  /// 切换回调；null 表示禁用。
  final ValueChanged<bool>? onChanged;

  /// 开关本体的 key（测试 / 自动化定位用）。
  final Key? switchKey;

  /// 行 InkWell 的 key。
  final Key? rowKey;

  const SettingsSwitchRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.switchKey,
    this.rowKey,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return MergeSemantics(
      child: SettingsRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        enabled: enabled,
        onTap: enabled ? () => onChanged!(!value) : null,
        rowKey: rowKey,
        trailing: Switch(
          key: switchKey,
          value: value,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// 复选行（多选列表项）：整行任意位置点击切换，复选本体也可单独点击。
class SettingsCheckboxRow extends StatelessWidget {
  /// 左侧图标（可选）。
  final IconData? icon;

  /// 行标题。
  final String title;

  /// 行副标题（可选）。
  final String? subtitle;

  /// 复选前方的自定义内容（如「将覆盖」徽标）。
  final Widget? trailing;

  /// 当前是否选中（公开只读，便于测试断言）。
  final bool value;

  /// 切换回调；null 表示禁用。
  final ValueChanged<bool>? onChanged;

  /// 复选本体的 key。
  final Key? checkboxKey;

  /// 行 InkWell 的 key。
  final Key? rowKey;

  const SettingsCheckboxRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.value,
    required this.onChanged,
    this.checkboxKey,
    this.rowKey,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return MergeSemantics(
      child: SettingsRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        enabled: enabled,
        onTap: enabled ? () => onChanged!(!value) : null,
        rowKey: rowKey,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (trailing != null) ...[
              trailing!,
              const SizedBox(width: 10),
            ],
            Checkbox(
              key: checkboxKey,
              value: value,
              onChanged: onChanged == null
                  ? null
                  : (checked) => onChanged!(checked ?? false),
            ),
          ],
        ),
      ),
    );
  }
}

/// 下拉选择项：标题 + 可选说明 + 自定义 key。
class SettingsSelectOption<T> {
  /// 选项值。
  final T value;

  /// 选项标题（菜单内展示）。
  final String label;

  /// 选项说明（菜单内标题下方的小字，可选）。
  final String? detail;

  /// 菜单项的 key（测试 / 自动化定位用）。
  final Key? key;

  const SettingsSelectOption({
    required this.value,
    required this.label,
    this.detail,
    this.key,
  });
}

/// 下拉选择行：**整行任意位置**点击展开/收起菜单。
///
/// 视觉：左侧图标 + 标题/副标题 + 右侧当前值（切换时淡入）+ 可旋转箭头；
/// 菜单：圆角继承主题 menuTheme，**右边缘对齐行内的下拉箭头**（而不是默认
/// 的左对齐），每项带勾选图标与可选说明。
class SettingsSelectRow<T> extends StatefulWidget {
  /// 菜单右边缘与行右内边距的距离（与设置行 14 的水平内边距一致，
  /// 使菜单右边缘正好落在箭头右缘）。
  static const double _menuRightInset = 14;

  /// 左侧图标（可选）。
  final IconData? icon;

  /// 行标题。
  final String title;

  /// 行副标题（可选）。
  final String? subtitle;

  /// 当前值（不在 [options] 中时右侧显示「—」）。
  final T value;

  /// 可选值列表。
  final List<SettingsSelectOption<T>> options;

  /// 选中回调。
  final ValueChanged<T> onSelected;

  /// 当前值的展示文案（菜单里用 option.label，行尾可能用更短的值，如「关」）。
  final String Function(T value)? labelOf;

  /// 下拉菜单宽度（默认 320；窄屏会按屏宽收窄）。
  ///
  /// 菜单固定宽度并右对齐后，才能稳定地贴在行尾箭头下方。
  final double menuWidth;

  /// 行 InkWell 的 key。
  final Key? rowKey;

  /// 行尾当前值 Text 的 key。
  final Key? valueKey;

  /// 是否可用。
  final bool enabled;

  const SettingsSelectRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.options,
    required this.onSelected,
    this.labelOf,
    this.menuWidth = 320,
    this.rowKey,
    this.valueKey,
    this.enabled = true,
  });

  @override
  State<SettingsSelectRow<T>> createState() => _SettingsSelectRowState<T>();
}

class _SettingsSelectRowState<T> extends State<SettingsSelectRow<T>> {
  bool _open = false;

  /// 当前值文案：优先 labelOf，其次匹配选项的标题，最后「—」。
  String get _currentLabel {
    if (widget.labelOf != null) return widget.labelOf!(widget.value);
    for (final option in widget.options) {
      if (option.value == widget.value) return option.label;
    }
    return '—';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final enabled = widget.enabled && widget.options.isNotEmpty;
    final duration = SettingsMotion.of(context, NarrChatTheme.motionNormal);
    // 菜单固定宽度并右对齐：右边缘落在行内下拉箭头的右缘（扣掉行内边距），
    // 避免默认 bottomStart 把菜单挂在行左缘、离箭头很远。
    // 菜单不宽于行内容区，窄屏自动收窄。
    return LayoutBuilder(
      builder: (context, constraints) {
        final rowWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final maxMenuWidth = rowWidth - SettingsSelectRow._menuRightInset * 2;
        final menuWidth = widget.menuWidth > maxMenuWidth
            ? (maxMenuWidth < 160 ? 160.0 : maxMenuWidth)
            : widget.menuWidth;
        return MenuAnchor(
          animated: true,
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomEnd,
            fixedSize: WidgetStatePropertyAll(Size(menuWidth, double.infinity)),
          ),
          alignmentOffset: Offset(
            -menuWidth - SettingsSelectRow._menuRightInset,
            0,
          ),
          onOpen: () {
            if (mounted) setState(() => _open = true);
          },
          onClose: () {
            if (mounted) setState(() => _open = false);
          },
          menuChildren: [
            for (final option in widget.options)
              SizedBox(
                width: menuWidth,
                child: MenuItemButton(
                  key: option.key,
                  onPressed: enabled
                      ? () {
                          if (option.value == widget.value) return;
                          widget.onSelected(option.value);
                        }
                      : null,
                  child: _buildOption(context, option),
                ),
              ),
          ],
          builder: (context, controller, _) {
            return MergeSemantics(
              child: InkWell(
                key: widget.rowKey,
                onTap: !enabled
                    ? null
                    : () {
                        if (controller.isOpen) {
                          controller.close();
                        } else {
                          controller.open();
                        }
                      },
                borderRadius: BorderRadius.circular(
                  NarrChatTheme.controlRadius,
                ),
                hoverColor: NarrChatTheme.primary.withValues(alpha: 0.05),
                splashColor: NarrChatTheme.primary.withValues(alpha: 0.08),
                child: AnimatedContainer(
                  duration: SettingsMotion.of(
                    context,
                    NarrChatTheme.motionFast,
                  ),
                  curve: NarrChatTheme.motionCurve,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: _open
                        ? NarrChatTheme.primary.withValues(alpha: 0.06)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(
                      NarrChatTheme.controlRadius,
                    ),
                  ),
                  child: Opacity(
                    opacity: enabled ? 1 : 0.5,
                    child: Row(
                      children: [
                        if (widget.icon != null) ...[
                          Icon(
                            widget.icon,
                            size: 20,
                            color: colors.textSecondary,
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: colors.textPrimary,
                                ),
                              ),
                              if (widget.subtitle != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  widget.subtitle!,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    height: 1.4,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        AnimatedSwitcher(
                          duration: SettingsMotion.of(
                            context,
                            NarrChatTheme.motionFast,
                          ),
                          switchInCurve: NarrChatTheme.motionCurve,
                          switchOutCurve: NarrChatTheme.motionCurve,
                          transitionBuilder: (child, animation) {
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.12),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            );
                          },
                          child: Text(
                            _currentLabel,
                            key: widget.valueKey ??
                                ValueKey<String>(_currentLabel),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        AnimatedRotation(
                          turns: _open ? 0.5 : 0,
                          duration: duration,
                          curve: NarrChatTheme.motionCurve,
                          child: Icon(
                            Icons.expand_more,
                            size: 18,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 菜单项内容：勾选图标 + 标题 +（可选）说明。
  ///
  /// 不用 Flexible/Expanded：菜单面板按固有宽度排版，横向可能是无界约束；
  /// 说明文字用最大宽度约束自然换行即可。
  Widget _buildOption(BuildContext context, SettingsSelectOption<T> option) {
    final colors = context.narrColors;
    final primary = Theme.of(context).colorScheme.primary;
    final selected = option.value == widget.value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              size: 14,
              color: selected ? primary : colors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              option.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? primary : colors.textPrimary,
              ),
            ),
          ],
        ),
        if (option.detail != null)
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                option.detail!,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 分段选择的一项。
class SettingsSegment<T> {
  /// 选项值。
  final T value;

  /// 选项标签。
  final String label;

  /// 选项图标（可选）。
  final IconData? icon;

  /// 选项说明（可选；有说明时分段控件变为「图标 + 标题 + 两行说明」的大号样式）。
  final String? description;

  const SettingsSegment({
    required this.value,
    required this.label,
    this.icon,
    this.description,
  });
}

/// 分段选择（单选）：圆角轨道 + 弹性滑动的高亮片。
///
/// - 紧凑模式：图标 + 标签（主题模式 / Mod 标签页）；
/// - 说明模式：图标 + 标题 + 两行说明（云同步模式），保留原有大号选项观感；
/// - 选项等分宽度、文字超长省略；高度按内容自适应（不写死，兼容文字缩放）。
class SettingsSegmented<T> extends StatelessWidget {
  /// 当前值。
  final T value;

  /// 选项列表（至少 2 项）。
  final List<SettingsSegment<T>> options;

  /// 选择回调。
  final ValueChanged<T> onChanged;

  /// 是否可用。
  final bool enabled;

  /// 轨道容器的 key（测试 / 自动化定位用）。
  final Key? trackKey;

  const SettingsSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
    this.trackKey,
  }) : assert(options.length > 1, '分段选择至少需要 2 个选项');

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final scheme = Theme.of(context).colorScheme;
    final selectedIndex = options.indexWhere((option) => option.value == value);
    final highlightIndex = selectedIndex < 0 ? 0 : selectedIndex;
    final hasDescription = options.any((option) => option.description != null);
    final duration = SettingsMotion.of(context, NarrChatTheme.motionNormal);
    final alignment = options.length == 1
        ? Alignment.center
        : Alignment(-1 + 2 * highlightIndex / (options.length - 1), 0);
    return Container(
      key: trackKey,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
        border: Border.all(color: colors.divider),
      ),
      child: IntrinsicHeight(
        child: Stack(
          children: [
            // 底层：弹性滑动的高亮片（宽度 = 1/n，跟随选中项）。
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedAlign(
                  duration: duration,
                  curve: NarrChatTheme.motionCurve,
                  alignment: alignment,
                  child: FractionallySizedBox(
                    widthFactor: 1 / options.length,
                    heightFactor: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          borderRadius: BorderRadius.circular(
                            NarrChatTheme.controlRadius - 3,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 上层：等分选项（整块可点）。
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < options.length; i++)
                  Expanded(
                    child: _buildOption(
                      context,
                      options[i],
                      selected: i == highlightIndex,
                      hasDescription: hasDescription,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOption(
    BuildContext context,
    SettingsSegment<T> option, {
    required bool selected,
    required bool hasDescription,
  }) {
    final colors = context.narrColors;
    final primary = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      selected: selected,
      label: option.label,
      child: InkWell(
        onTap: enabled ? () => onChanged(option.value) : null,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius - 3),
        hoverColor: NarrChatTheme.primary.withValues(alpha: 0.04),
        splashColor: NarrChatTheme.primary.withValues(alpha: 0.08),
        child: Padding(
          padding: hasDescription
              ? const EdgeInsets.symmetric(horizontal: 10, vertical: 10)
              : const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (option.icon != null) ...[
                    Icon(
                      option.icon,
                      size: hasDescription ? 20 : 16,
                      color: selected ? primary : colors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: hasDescription ? 14 : 13,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: selected
                            ? colors.textPrimary
                            : colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              if (option.description != null) ...[
                const SizedBox(height: 6),
                Text(
                  option.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 分段选择行：宽屏行内右侧放分段控件，窄屏（< [stackBelowWidth]）改为
/// 「标题/副标题 + 下一行撑满分段」，避免挤压文字（主题设置使用）。
class SettingsSegmentedRow<T> extends StatelessWidget {
  /// 左侧图标（可选）。
  final IconData? icon;

  /// 行标题。
  final String title;

  /// 行副标题（可选）。
  final String? subtitle;

  /// 当前值。
  final T value;

  /// 选项列表。
  final List<SettingsSegment<T>> options;

  /// 选择回调。
  final ValueChanged<T> onChanged;

  /// 低于该宽度时分段控件换到下一行（默认 560）。
  final double stackBelowWidth;

  /// 行 InkWell 的 key。
  final Key? rowKey;

  const SettingsSegmentedRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
    this.stackBelowWidth = 560,
    this.rowKey,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final segmented = SettingsSegmented<T>(
      value: value,
      options: options,
      onChanged: onChanged,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < stackBelowWidth;
        if (!narrow) {
          // 行尾控件必须给有限宽度：Row 的非 flex 子级拿到的是无界宽度约束，
          // 分段控件内部的 Expanded 需要有限宽度才能排版。
          final segmentedWidth =
              (constraints.maxWidth * 0.42).clamp(260.0, 360.0).toDouble();
          return SettingsRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            rowKey: rowKey,
            trailing: SizedBox(width: segmentedWidth, child: segmented),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20, color: colors.textSecondary),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: colors.textPrimary,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.4,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              segmented,
            ],
          ),
        );
      },
    );
  }
}

/// 可切换标签（多选）：整枚标签可点，选中态主色浅底 + 勾选图标。
///
/// 内部仍使用 [ChoiceChip]：保留 Material 自带的选中动画与现有测试定位。
class SettingsToggleChip extends StatelessWidget {
  /// 标签文字。
  final String label;

  /// 是否选中。
  final bool selected;

  /// 点击回调（点击即切换）。
  final VoidCallback onTap;

  /// 未选中时的图标（默认 `add`；选中时统一显示勾）。
  final IconData? icon;

  /// 悬停提示（可选）。
  final String? tooltip;

  const SettingsToggleChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chip = ChoiceChip(
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      avatar: Icon(
        selected ? Icons.check : (icon ?? Icons.add),
        size: 16,
        color: selected ? scheme.primary : scheme.outline,
      ),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
      selectedColor: scheme.primary.withValues(alpha: 0.12),
      backgroundColor: Colors.transparent,
      side: BorderSide(
        color: selected
            ? scheme.primary.withValues(alpha: 0.4)
            : scheme.outlineVariant,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      onSelected: (_) => onTap(),
    );
    if (tooltip == null) return chip;
    return Tooltip(message: tooltip!, child: chip);
  }
}
