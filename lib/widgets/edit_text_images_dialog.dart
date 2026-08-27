import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/clipboard_paste_service.dart';
import '../services/image_import_service.dart';
import '../services/sync/image_revival.dart';
import '../utils/focus_utils.dart';
import 'image_preview.dart';
import 'markdown_editing_controller.dart';
import 'text_field_context_menu.dart';

/// 「修改并重新提问」对话框的返回结果：编辑后的文本 + 图片相对路径列表。
class EditTextImagesResult {
  final String text;
  final List<String> images;

  const EditTextImagesResult(this.text, this.images);
}

/// 打开「编辑文本 + 图片」对话框（识图模型可增删图片）。
///
/// - [allowImages] 为 false 时隐藏图片区（退化为纯文本编辑）；
/// - [imageImport] 与 [maxImageSizeMB] 用于「添加图片」（新增图片经哈希去重落盘）；
/// - [convertJpgToJpeg] 为 true 时把导入的 `.jpg` 落盘为 `.jpeg`；
/// - 取消返回 null；保存返回 [EditTextImagesResult]。
Future<EditTextImagesResult?> showEditTextImagesDialog(
  BuildContext context, {
  required String title,
  required String initial,
  List<String> initialImages = const [],
  required bool allowImages,
  required ImageImportService imageImport,
  required int maxImageSizeMB,
  bool convertJpgToJpeg = false,
}) {
  return showDialog<EditTextImagesResult>(
    context: context,
    builder: (ctx) => _EditTextImagesDialog(
      title: title,
      initial: initial,
      initialImages: initialImages,
      allowImages: allowImages,
      imageImport: imageImport,
      maxImageSizeMB: maxImageSizeMB,
      convertJpgToJpeg: convertJpgToJpeg,
    ),
  );
}

class _EditTextImagesDialog extends StatefulWidget {
  final String title;
  final String initial;
  final List<String> initialImages;
  final bool allowImages;
  final ImageImportService imageImport;
  final int maxImageSizeMB;
  final bool convertJpgToJpeg;

  const _EditTextImagesDialog({
    required this.title,
    required this.initial,
    required this.initialImages,
    required this.allowImages,
    required this.imageImport,
    required this.maxImageSizeMB,
    this.convertJpgToJpeg = false,
  });

  @override
  State<_EditTextImagesDialog> createState() => _EditTextImagesDialogState();
}

class _EditTextImagesDialogState extends State<_EditTextImagesDialog> {
  late final MarkdownEditingController _controller;
  late final List<String> _images;
  bool _importing = false;
  int _importDone = 0;
  int _importTotal = 0;

  @override
  void initState() {
    super.initState();
    _controller = MarkdownEditingController(text: widget.initial);
    _images = List.of(widget.initialImages);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    setState(() {
      _importing = true;
      _importDone = 0;
      _importTotal = 0;
    });
    try {
      final result = await widget.imageImport.importImages(
        sizeLimitMb: widget.maxImageSizeMB,
        convertJpgToJpeg: widget.convertJpgToJpeg,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _importDone = done;
            _importTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _images.addAll(result.paths);
        _importing = false;
      });
      _reviveImages(result.paths);
      if (result.warnings.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.warnings.join('\n'))),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('图片导入失败：$e')),
      );
    }
  }

  /// 从剪贴板粘贴：文本插入光标处；图片按 [allowImages] 开关加入图片列表。
  ///
  /// 供 Ctrl+V 与右键菜单「粘贴」复用（见 [textFieldContextMenuBuilder]），
  /// 统一走 [pasteIntoTextInput] 处理文本 / 图片与超限 / 非识图提示。
  Future<void> _pasteFromClipboard() async {
    final service = context.read<ClipboardPasteService>();
    // 先取 messenger，避免异步后使用失效的 context。
    final messenger = ScaffoldMessenger.of(context);
    await pasteIntoTextInput(
      service: service,
      controller: _controller,
      acceptImages: widget.allowImages,
      imageSizeLimitMb: widget.maxImageSizeMB,
      convertJpgToJpeg: widget.convertJpgToJpeg,
      onImageAdded: (rel) {
        if (mounted) setState(() => _images.add(rel));
        _reviveImages([rel]);
      },
      onNotice: (msg) => messenger.showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      ),
    );
  }

  /// 图片"再添加复活"：若 [paths] 命中待推送删除墓碑，取消删除意图。
  void _reviveImages(Iterable<String> paths) {
    final revival = context.read<ImageRevivalService>();
    for (final rel in paths) {
      revival.revive(rel);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = <Widget>[
      // 粘贴：Ctrl+V 与右键菜单「粘贴」共用 _pasteFromClipboard。
      CallbackShortcuts(
        bindings: textFieldPasteBindings(onPaste: _pasteFromClipboard),
        child: TextField(
          controller: _controller,
          onTapOutside: unfocusOnTapOutside,
          minLines: 10,
          maxLines: null,
          style: const TextStyle(fontSize: 13, height: 1.5),
          decoration: const InputDecoration(hintText: '内容'),
          contextMenuBuilder: textFieldContextMenuBuilder(
            onPaste: _pasteFromClipboard,
          ),
        ),
      ),
    ];

    if (widget.allowImages) {
      if (_images.isNotEmpty) {
        content.addAll([
          const SizedBox(height: 12),
          SizedBox(
            height: 72,
            child: ImagePreviewStrip(
              images: List.of(_images),
              size: 72,
              onTapImage: (_, i) =>
                  showImageViewer(context, List.of(_images), i),
              onRemove: (rel) => setState(() => _images.remove(rel)),
            ),
          ),
        ]);
      }
      content
        ..add(const SizedBox(height: 12))
        ..add(
          Row(
            children: [
              TextButton.icon(
                onPressed: _importing ? null : _import,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: const Text('添加图片'),
              ),
              const SizedBox(width: 8),
              if (_importing)
                Expanded(
                  child: Text(
                    _importTotal > 0
                        ? '正在导入 $_importDone/$_importTotal…'
                        : '正在导入…',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        );
    }

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: content,
        )),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            EditTextImagesResult(
              _controller.text,
              widget.allowImages ? List.of(_images) : const [],
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
