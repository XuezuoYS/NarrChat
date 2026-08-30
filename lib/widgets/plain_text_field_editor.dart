import 'package:flutter/material.dart';

import '../utils/focus_utils.dart';
import 'editable_field_state.dart';

/// 单行纯文本子面板编辑器（侧边栏「当前时间」专用）。
///
/// - 视图模式：只读纯文本展示（内容为空时显示「（空）」占位）；
/// - 编辑模式：单行 [TextField]（编辑内容直接写入外部 [controller]）；
/// - 无内部工具栏：进入编辑 / 保存 / 取消全部由外部（侧边栏子模块标题栏）
///   通过 [EditableFieldState] 驱动；
/// - 保存时触发 [onSave] 持久化；取消时还原进入编辑前的文本（放弃修改）。
class PlainTextFieldEditor extends StatefulWidget {
  final TextEditingController controller;
  final String? hintText;
  final bool readOnly;

  /// 点击「保存」/退出编辑时回调（持久化当前内容）。
  final ValueChanged<String>? onSave;

  /// 进入 / 退出编辑模式时回调（供外部标题栏切换【保存】/【取消】按钮）。
  final ValueChanged<bool>? onEditingChanged;

  const PlainTextFieldEditor({
    super.key,
    required this.controller,
    this.hintText,
    this.readOnly = false,
    this.onSave,
    this.onEditingChanged,
  });

  @override
  State<PlainTextFieldEditor> createState() => PlainTextFieldEditorState();
}

class PlainTextFieldEditorState extends State<PlainTextFieldEditor>
    implements EditableFieldState {
  bool _editMode = false;

  /// 进入编辑时的文本快照，取消编辑时据此还原。
  String _editSnapshot = '';

  void _enterEdit() {
    if (widget.readOnly) return;
    _editSnapshot = widget.controller.text;
    setState(() => _editMode = true);
    widget.onEditingChanged?.call(true);
  }

  void _exitEdit({required bool save}) {
    _editMode = false;
    if (save) {
      widget.onSave?.call(widget.controller.text);
    } else {
      // 取消编辑：还原为进入编辑前的文本（放弃修改）。
      widget.controller.text = _editSnapshot;
    }
    widget.onEditingChanged?.call(false);
    setState(() {});
  }

  // —— EditableFieldState（供侧边栏模块标题栏驱动） ——
  @override
  bool get isEditing => _editMode;

  @override
  void enterEdit() => _enterEdit();

  @override
  void save() => _exitEdit(save: true);

  @override
  void cancel() => _exitEdit(save: false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: _editMode
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: _editMode
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: TextField(
                controller: widget.controller,
                onTapOutside: unfocusOnTapOutside,
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: widget.hintText ?? '',
                  isDense: true,
                  border: InputBorder.none,
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: widget.controller.text.trim().isEmpty
                  ? Text(
                      '（空）',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.outline,
                      ),
                    )
                  : Text(
                      widget.controller.text,
                      style: const TextStyle(fontSize: 14),
                    ),
            ),
    );
  }
}
