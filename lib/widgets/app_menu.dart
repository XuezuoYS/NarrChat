import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 统一菜单组件：集中管理右键/长按菜单与下拉菜单的视觉样式，便于统一调整。
///
/// 视觉常量（圆角、下拉宽度）定义在 [NarrChatTheme]（menuRadius / dropdownMenuWidth），
/// 本文件提供三类可复用单元：
/// - [AppMenuAction]：菜单项（图标 + 文字），右键菜单与下拉菜单共用；
/// - [showAppMenu]：以统一方式展示右键/长按上下文菜单；
/// - [AppDropdown]：统一样式的下拉选择字段。
class AppMenuAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const AppMenuAction({
    super.key,
    required this.icon,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: fg),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(fontSize: 13, color: fg),
        ),
      ],
    );
  }
}

/// 展示统一风格的右键/长按上下文菜单。
///
/// 菜单视觉（圆角、颜色、投影）来自主题 `popupMenuTheme`（见 NarrChatTheme）。
Future<T?> showAppMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<PopupMenuEntry<T>> items,
}) {
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    ),
    items: items,
  );
}

/// 统一样式的下拉选择字段。
///
/// 输入框外观与其它表单字段一致（圆角描边 + 标签），下拉菜单固定宽度并带圆角。
/// 注：该 Flutter 版本（3.44.8）的 `DropdownButtonFormField` 不提供 `menuWidth`
/// 参数（下拉菜单宽度默认等于输入框宽度，宽屏下会非常宽），因此改用
/// `InputDecorator + DropdownButton` 组合以获得完整控制。
class AppDropdown<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const AppDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          // 与相邻输入框等高（dense 模式下按钮高度 32，否则默认 48 会明显偏高）。
          isDense: true,
          // 固定菜单宽度，避免宽屏下菜单与输入框同宽。
          menuWidth: NarrChatTheme.dropdownMenuWidth,
          // 圆角菜单，与右键/长按菜单共用同一圆角常量。
          borderRadius: BorderRadius.circular(NarrChatTheme.menuRadius),
          style: const TextStyle(
            fontSize: 14,
            color: NarrChatTheme.textPrimary,
          ),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
