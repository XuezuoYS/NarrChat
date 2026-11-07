import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../utils/focus_utils.dart';

/// 设置页统一输入组件：文本框 / 密码框 / 搜索框 / 下拉字段 / 只读展示框。
///
/// 关键约定：**不要**再手写 `border: OutlineInputBorder()`——那会把主题里的
/// 12 圆角覆盖成 Flutter 默认的 4 圆角。本文件所有字段都不传 `border`，
/// 完全继承 [InputDecorationTheme]。
///
/// 多行输入仍可直接传入 `MarkdownEditingController`（它是
/// `TextEditingController` 的子类），不会破坏 Markdown 高亮逻辑。

/// 统一输入框：单行 / 多行共用，圆角、填充、聚焦描边全部来自主题。
class SettingsTextField extends StatelessWidget {
  /// 文本控制器（由调用方持有与释放）。
  final TextEditingController controller;

  /// 标签（浮在输入框上，供测试按 `decoration.labelText` 定位）。
  final String? label;

  /// 占位提示。
  final String? hint;

  /// 辅助说明。
  final String? helperText;

  /// 错误说明。
  final String? errorText;

  /// 字数统计文案（设空字符串可隐藏计数器）。
  final String? counterText;

  /// 最大长度。
  final int? maxLength;

  /// 键盘类型。
  final TextInputType? keyboardType;

  /// 输入格式化。
  final List<TextInputFormatter>? inputFormatters;

  /// 是否为密码输入。
  final bool obscureText;

  /// 是否可用。
  final bool enabled;

  /// 是否只读（仍可选中/复制，不能编辑；预览弹窗使用）。
  final bool readOnly;

  /// 是否自动聚焦。
  final bool autofocus;

  /// 前缀图标。
  final Widget? prefixIcon;

  /// 后缀控件（如清空 / 显示密码）。
  final Widget? suffixIcon;

  /// 后缀文本（如 `MB`）。
  final String? suffixText;

  /// 自定义文字样式（多行默认 13 / 1.45，单行默认 14）。
  final TextStyle? style;

  /// 文字变化回调。
  final ValueChanged<String>? onChanged;

  /// 提交回调。
  final ValueChanged<String>? onSubmitted;

  /// 点击外部回调（默认统一取消焦点）。
  final TapRegionCallback? onTapOutside;

  /// 最小行数（多行）。
  final int? minLines;

  /// 最大行数（默认 1；传 null 表示不限行）。
  final int? maxLines;

  /// 内部 TextField 的 key（测试 / 自动化定位用）。
  final Key? fieldKey;

  const SettingsTextField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.helperText,
    this.errorText,
    this.counterText,
    this.maxLength,
    this.keyboardType,
    this.inputFormatters,
    this.obscureText = false,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.prefixIcon,
    this.suffixIcon,
    this.suffixText,
    this.style,
    this.onChanged,
    this.onSubmitted,
    this.onTapOutside = unfocusOnTapOutside,
    this.minLines,
    this.maxLines = 1,
    this.fieldKey,
  });

  @override
  Widget build(BuildContext context) {
    final multiline =
        (maxLines == null || maxLines! > 1) || (minLines ?? 1) > 1;
    return TextField(
      key: fieldKey,
      controller: controller,
      enabled: enabled,
      readOnly: readOnly,
      autofocus: autofocus,
      obscureText: obscureText,
      enableSuggestions: !obscureText,
      autocorrect: !obscureText,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      maxLength: maxLength,
      minLines: minLines,
      maxLines: maxLines,
      style: style ??
          TextStyle(
            fontSize: multiline ? 13 : 14,
            height: multiline ? 1.45 : null,
          ),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      onTapOutside: onTapOutside,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helperText,
        errorText: errorText,
        counterText: counterText,
        suffixText: suffixText,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        isDense: true,
        // 不传 border：圆角与描边颜色统一由主题提供。
      ),
    );
  }
}

/// 密码输入框：自管明文/隐藏状态与眼睛按钮（API Key 等）。
class SettingsSecretField extends StatefulWidget {
  /// 文本控制器（由调用方持有与释放）。
  final TextEditingController controller;

  /// 标签。
  final String label;

  /// 占位提示。
  final String? hint;

  /// 内部 TextField 的 key。
  final Key? fieldKey;

  const SettingsSecretField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.fieldKey,
  });

  @override
  State<SettingsSecretField> createState() => _SettingsSecretFieldState();
}

class _SettingsSecretFieldState extends State<SettingsSecretField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return SettingsTextField(
      fieldKey: widget.fieldKey,
      controller: widget.controller,
      label: widget.label,
      hint: widget.hint,
      obscureText: _obscured,
      suffixIcon: IconButton(
        icon: Icon(_obscured ? Icons.visibility_off : Icons.visibility),
        tooltip: _obscured ? '显示' : '隐藏',
        onPressed: () => setState(() => _obscured = !_obscured),
      ),
    );
  }
}

/// 统一搜索框：前置搜索图标 + 有内容时显示清空按钮。
class SettingsSearchField extends StatelessWidget {
  /// 文本控制器。
  final TextEditingController controller;

  /// 占位提示。
  final String hint;

  /// 文字变化回调。
  final ValueChanged<String>? onChanged;

  /// 清空回调（按钮显示与否由控制器内容自动决定）。
  final VoidCallback? onClear;

  /// 内部 TextField 的 key。
  final Key? fieldKey;

  const SettingsSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onClear,
    this.fieldKey,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return SettingsTextField(
          fieldKey: fieldKey,
          controller: controller,
          hint: hint,
          onChanged: onChanged,
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: controller.text.isEmpty || onClear == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: '清空搜索',
                  onPressed: onClear,
                ),
        );
      },
    );
  }
}

/// 统一下拉表单字段（原 `AppDropdown` 迁入，并改为右对齐菜单）。
///
/// 与 [SettingsSelectRow] 同一套菜单视觉：
/// - 点击整块字段展开 / 收起菜单；
/// - 菜单固定宽度，**右边缘对齐字段右侧的下拉箭头**（不再默认贴左）；
/// - 选中项带勾选图标，菜单圆角继承主题 menuTheme。
class SettingsDropdownField<T> extends StatelessWidget {
  /// 菜单右边缘与字段右边缘的距离（视觉上贴近下拉箭头）。
  static const double _menuRightInset = 14;

  /// 标签。
  final String label;

  /// 当前值。
  final T? value;

  /// 选项。
  final List<DropdownMenuItem<T>> items;

  /// 选择回调（null 表示禁用）。
  final ValueChanged<T?>? onChanged;

  /// 辅助说明（可选）。
  final String? helperText;

  /// 菜单固定宽度（默认 [NarrChatTheme.dropdownMenuWidth]；窄屏自动收窄）。
  final double menuWidth;

  /// 字段 InkWell 的 key（测试 / 自动化定位用）。
  final Key? fieldKey;

  const SettingsDropdownField({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.helperText,
    this.menuWidth = NarrChatTheme.dropdownMenuWidth,
    this.fieldKey,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final scheme = Theme.of(context).colorScheme;
    DropdownMenuItem<T>? selected;
    for (final item in items) {
      if (item.value == value) {
        selected = item;
        break;
      }
    }
    final display = selected == null
        ? const SizedBox.shrink()
        : DefaultTextStyle(
            style: TextStyle(fontSize: 14, color: colors.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: selected.child,
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        final fieldWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final maxMenuWidth = fieldWidth - _menuRightInset * 2;
        final effectiveMenuWidth = menuWidth > maxMenuWidth
            ? (maxMenuWidth < 120 ? 120.0 : maxMenuWidth)
            : menuWidth;
        return MenuAnchor(
          animated: true,
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomEnd,
            fixedSize: WidgetStatePropertyAll(
              Size(effectiveMenuWidth, double.infinity),
            ),
          ),
          alignmentOffset: Offset(-effectiveMenuWidth - _menuRightInset, 0),
          menuChildren: [
            for (final item in items)
              SizedBox(
                width: effectiveMenuWidth,
                child: MenuItemButton(
                  onPressed: item.enabled && onChanged != null
                      ? () => onChanged!(item.value)
                      : null,
                  child: Row(
                    children: [
                      Icon(
                        item.value == value
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        size: 14,
                        color: item.value == value
                            ? scheme.primary
                            : colors.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: DefaultTextStyle(
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: item.value == value
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: item.value == value
                                ? scheme.primary
                                : colors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          child: item.child,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          builder: (context, controller, _) {
            return MergeSemantics(
              child: InkWell(
                key: fieldKey,
                onTap: onChanged == null
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
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: label,
                    helperText: helperText,
                    isDense: true,
                    enabled: onChanged != null,
                    suffixIcon: Icon(
                      Icons.arrow_drop_down,
                      size: 20,
                      color: colors.textSecondary,
                    ),
                    // 不传 border：沿用主题的 12 圆角。
                  ),
                  child: display,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 只读展示框：视觉与相邻输入框一致，点击触发 [onTap]（如弹窗修改）。
///
/// 不是 `TextField`：点击不会弹键盘，值只读展示。
class SettingsReadonlyField extends StatelessWidget {
  /// 标签。
  final String label;

  /// 展示值。
  final String value;

  /// 点击回调。
  final VoidCallback onTap;

  /// 尾部图标（默认编辑图标）。
  final IconData suffixIcon;

  /// InkWell 的 key（测试 / 自动化定位用）。
  final Key? fieldKey;

  const SettingsReadonlyField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.suffixIcon = Icons.edit_outlined,
    this.fieldKey,
  });

  @override
  Widget build(BuildContext context) {
    final inputTheme = Theme.of(context).inputDecorationTheme;
    final border =
        inputTheme.enabledBorder ?? inputTheme.border ?? const OutlineInputBorder();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: fieldKey,
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: Icon(suffixIcon, size: 16),
            contentPadding: inputTheme.contentPadding,
            filled: true,
            fillColor: inputTheme.fillColor,
            enabledBorder: border,
            focusedBorder: border,
            border: border,
          ),
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: context.narrColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
