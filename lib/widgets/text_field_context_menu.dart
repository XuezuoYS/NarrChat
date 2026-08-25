import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/clipboard_paste_service.dart';

/// 文本输入框统一的右键菜单管理组件。
///
/// 为任意 `TextField` 提供样式一致的右键 / 长按菜单（全选、复制、粘贴、剪切），
/// 并把「粘贴」（含剪贴板图片）统一委托给 [pasteIntoTextInput] 处理。
///
/// 用法（聊天输入框 / 重新提问对话框等）：
/// ```dart
/// CallbackShortcuts(
///   bindings: textFieldPasteBindings(onPaste: _pasteFromClipboard),
///   child: TextField(
///     controller: _controller,
///     contextMenuBuilder: textFieldContextMenuBuilder(onPaste: _pasteFromClipboard),
///   ),
/// )
/// ```
/// 构建统一的 `TextField.contextMenuBuilder`。
///
/// - [onPaste]：粘贴命令（含图片处理）；为 null 时隐藏「粘贴」项。
/// - [readOnly]：为 true 时仅保留「全选」（表单只读场景也可复制）；默认 false。
EditableTextContextMenuBuilder textFieldContextMenuBuilder({
  required Future<void> Function() onPaste,
  bool readOnly = false,
}) {
  return (context, editableTextState) {
    final items = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: '全选',
        onPressed: () =>
            editableTextState.selectAll(SelectionChangedCause.toolbar),
      ),
      if (!readOnly)
        ContextMenuButtonItem(
          label: '复制',
          onPressed: () =>
              editableTextState.copySelection(SelectionChangedCause.toolbar),
        ),
      if (!readOnly)
        ContextMenuButtonItem(
          label: '粘贴',
          onPressed: () => onPaste(),
        ),
      if (!readOnly)
        ContextMenuButtonItem(
          label: '剪切',
          onPressed: () =>
              editableTextState.cutSelection(SelectionChangedCause.toolbar),
        ),
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  };
}

/// 供包裹 `TextField` 的 [CallbackShortcuts] 使用的 Ctrl+V 绑定，
/// 使快捷键粘贴与右键「粘贴」走同一处理逻辑。
Map<ShortcutActivator, VoidCallback> textFieldPasteBindings({
  required Future<void> Function() onPaste,
}) {
  return {
    const SingleActivator(LogicalKeyboardKey.keyV, control: true): onPaste,
  };
}

/// 把剪贴板内容粘贴进 [controller]：
/// - 文本插入光标处（替换当前选区；选区无效时追加到末尾）；
/// - 图片按 [acceptImages] 门控（识图模型）：成功经 [onImageAdded] 回调交给
///   调用方更新附件状态，超限 / 非识图经 [onNotice] 给出提示。
///
/// 通过回调注入字段状态更新，使聊天输入框与重新提问对话框复用同一套逻辑。
Future<void> pasteIntoTextInput({
  required ClipboardPasteService service,
  required TextEditingController controller,
  required bool acceptImages,
  required int imageSizeLimitMb,
  required bool convertJpgToJpeg,
  required void Function(String relPath) onImageAdded,
  void Function(String message)? onNotice,
}) async {
  final text = await service.readText();

  String? imageRelPath;
  String? imageWarning;
  if (acceptImages) {
    final img = await service.readImagePng(
      sizeLimitMb: imageSizeLimitMb,
      convertJpgToJpeg: convertJpgToJpeg,
    );
    imageRelPath = img.relPath;
    imageWarning = img.warning;
  } else if (await service.hasImage()) {
    imageWarning = '当前模型不支持识图，已忽略剪贴板图片';
  }

  if (imageRelPath != null) onImageAdded(imageRelPath);
  if (imageWarning != null) onNotice?.call(imageWarning);
  if (text != null && text.isNotEmpty) {
    insertTextAtCursor(controller, text);
  }
}

/// 在 [controller] 光标处插入 [text]（替换当前选区；选区无效时追加到末尾）。
void insertTextAtCursor(TextEditingController controller, String text) {
  final value = controller.value;
  final sel = value.selection;
  final start = sel.isValid ? sel.start : value.text.length;
  final end = sel.isValid ? sel.end : value.text.length;
  controller.value = TextEditingValue(
    text: value.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}
