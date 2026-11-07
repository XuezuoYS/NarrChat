import 'package:flutter/material.dart';

/// 统一菜单组件：集中管理右键/长按菜单的视觉样式，便于统一调整。
///
/// 菜单视觉常量定义在 `NarrChatTheme`（menuRadius），本文件提供两类可复用单元：
/// - [AppMenuAction]：菜单项（图标 + 文字），右键菜单共用；
/// - [showAppMenu]：以统一方式展示右键/长按上下文菜单。
///
/// 下拉选择字段已迁入设置组件套件的 `SettingsDropdownField`
/// （`lib/widgets/settings/settings_fields.dart`）。
class AppMenuAction extends StatelessWidget {
  /// 图标字体图标；与 [iconWidget] 二选一。
  final IconData? icon;

  /// 自绘 / 自定义图标（如 `GitBranchIcon`）；与 [icon] 二选一。
  ///
  /// 挂在菜单项里时统一按 18px、[color] 着色（外层套 [IconTheme]），
  /// 自定义组件只需读取 `IconTheme` 即可与字体图标同款。
  final Widget? iconWidget;

  final String label;
  final Color? color;

  const AppMenuAction({
    super.key,
    this.icon,
    this.iconWidget,
    required this.label,
    this.color,
  }) : assert(icon != null || iconWidget != null, '菜单项必须有图标');

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (iconWidget != null)
          IconTheme(
            data: IconThemeData(color: fg, size: 18),
            child: iconWidget!,
          )
        else
          Icon(icon!, size: 18, color: fg),
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
