import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// 支持 Markdown 渲染的文本编辑组件。
///
/// - 默认显示 Markdown 预览；
/// - 点击标题栏的编辑图标或双击进入原始文本编辑模式；
/// - 与外部通过同一个 [TextEditingController] 通信，父级保存时读取 `controller.text`。
class MarkdownField extends StatefulWidget {
  final TextEditingController controller;
  final String? hintText;
  final bool readOnly;

  /// 编辑模式下文本变化时实时回调（用于侧边栏自动保存）。
  final ValueChanged<String>? onChanged;

  /// 点击「完成」时回调（立即保存，不经过防抖）。
  final ValueChanged<String>? onSave;

  const MarkdownField({
    super.key,
    required this.controller,
    this.hintText,
    this.readOnly = false,
    this.onChanged,
    this.onSave,
  });

  @override
  State<MarkdownField> createState() => _MarkdownFieldState();
}

class _MarkdownFieldState extends State<MarkdownField> {
  bool _editMode = false;
  late final TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.controller.text);
    widget.controller.addListener(_syncFromExternal);
    _editController.addListener(_onEditChanged);
  }

  void _syncFromExternal() {
    if (!_editMode && _editController.text != widget.controller.text) {
      _editController.text = widget.controller.text;
    }
  }

  void _onEditChanged() {
    if (_editMode) {
      widget.onChanged?.call(_editController.text);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromExternal);
    _editController.removeListener(_onEditChanged);
    _editController.dispose();
    super.dispose();
  }

  void _enterEdit() {
    if (widget.readOnly) return;
    setState(() {
      _editMode = true;
      _editController.text = widget.controller.text;
    });
  }

  void _exitEdit({required bool save}) {
    // 先退出编辑模式，再同步文本：避免回写/还原时触发 onChanged 造成多余的自动保存。
    _editMode = false;
    if (save) {
      widget.controller.text = _editController.text;
      widget.onSave?.call(_editController.text);
    } else {
      _editController.text = widget.controller.text;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 0),
            child: Row(
              children: [
                Icon(
                  _editMode ? Icons.edit_note : Icons.visibility_outlined,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _editMode ? '原始文本编辑' : 'Markdown 预览 · 点击右侧按钮编辑',
                    style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
                  ),
                ),
                if (!widget.readOnly)
                  TextButton.icon(
                    onPressed: _editMode ? () => _exitEdit(save: true) : _enterEdit,
                    icon: Icon(
                      _editMode ? Icons.check : Icons.edit_outlined,
                      size: 14,
                    ),
                    label: Text(_editMode ? '完成' : '编辑'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 内容区
          _editMode
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    controller: _editController,
                    maxLines: null,
                    minLines: 5,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.4,
                    ),
                    decoration: InputDecoration(
                      hintText: widget.hintText ?? '输入 Markdown 文本…',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                )
              : widget.controller.text.trim().isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        '（空）',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(10),
                      child: MarkdownBody(
                        data: widget.controller.text,
                        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                          p: const TextStyle(fontSize: 13, height: 1.5),
                        ),
                      ),
                    ),
        ],
      ),
    );
  }
}
