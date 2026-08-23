import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/image_store.dart';

/// 图片缩略图：解析相对路径 → 显示图片；文件缺失显示灰色占位块
/// （破损图标 + 原文件名 + 「图片已丢失」）。
class ImageThumbnail extends StatelessWidget {
  final String relPath;

  /// 缩略图边长。
  final double size;

  /// 是否显示右上角删除按钮。
  final VoidCallback? onRemove;

  /// 点击回调（通常打开全屏查看）。
  final VoidCallback? onTap;

  const ImageThumbnail({
    super.key,
    required this.relPath,
    this.size = 120,
    this.onRemove,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: FutureBuilder<String>(
        future: ImageStore.resolveAbsolute(relPath),
        builder: (context, snapshot) {
          final Widget inner;
          if (snapshot.hasError) {
            inner = _MissingImage(relPath);
          } else {
            inner = _FileImage(absPath: snapshot.data ?? '', relPath: relPath);
          }
          if (onTap == null && onRemove == null) return inner;
          return Stack(
            children: [
              if (onTap != null)
                GestureDetector(onTap: onTap, child: inner)
              else
                inner,
              if (onRemove != null)
                Positioned(
                  top: 2,
                  right: 2,
                  child: _RemoveBadge(onPressed: onRemove!),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 单个已存在图片文件（加载失败回退占位）。
class _FileImage extends StatelessWidget {
  final String absPath;
  final String relPath;

  const _FileImage({required this.absPath, required this.relPath});

  @override
  Widget build(BuildContext context) {
    final file = File(absPath);
    if (!file.existsSync()) return _MissingImage(relPath);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.file(
        file,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => _MissingImage(relPath),
      ),
    );
  }
}

/// 文件缺失 / 读取失败的灰色占位块。
class _MissingImage extends StatelessWidget {
  final String relPath;

  const _MissingImage(this.relPath);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image_outlined, size: 24, color: scheme.outline),
          const SizedBox(height: 4),
          Text(
            ImageStore.fileNameOf(relPath),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: scheme.outline),
          ),
          const SizedBox(height: 2),
          Text(
            '图片已丢失',
            style: TextStyle(fontSize: 9, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

/// 缩略图右上角的删除小圆钮。
///
/// 注意：不能用 `Ink(decoration: ...)` 绘制圆钮背景——`Ink` 会把装饰画到最近的
/// `Material` 上，而该 `Material` 在图片之下，导致圆钮的圆底/描边/阴影被图片盖住
/// 而“不生效”。这里改用 `Material` 本体承载颜色/圆角描边/阴影，作为真实 widget
/// 绘制在图片之上，`InkWell` 让点击水波显示在圆钮上。
class _RemoveBadge extends StatelessWidget {
  final VoidCallback onPressed;

  const _RemoveBadge({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.2),
      elevation: 2,
      shape: const CircleBorder(
        // side: BorderSide(color: Colors.black, width: 0),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: const SizedBox(
          width: 18,
          height: 18,
          child: Icon(Icons.close, size: 12, color: Colors.white),
        ),
      ),
    );
  }
}

/// 横向滚动的图片预览条（气泡正文上方 / 输入框待发送上方复用）。
class ImagePreviewStrip extends StatelessWidget {
  final List<String> images;

  /// 点击单张图片回调。为空则仅缩略图。
  final void Function(String relPath)? onTapImage;

  /// 每张图的可选删除回调。
  final void Function(String relPath)? onRemove;

  final double size;

  const ImagePreviewStrip({
    super.key,
    required this.images,
    this.onTapImage,
    this.onRemove,
    this.size = 96,
  });

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: size,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final rel = images[i];
          return ImageThumbnail(
            relPath: rel,
            size: size,
            onTap: onTapImage == null ? null : () => onTapImage!(rel),
            onRemove: onRemove == null ? null : () => onRemove!(rel),
          );
        },
      ),
    );
  }
}

/// 打开全屏图片查看页。
Future<void> showImageViewer(BuildContext context, String relPath) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ImageViewerPage(relPath: relPath)),
  );
}

/// 全屏图片查看页：点击 / 拖拽缩放（InteractiveViewer），右上角关闭。
///
/// - 单击图片或空白区域（非按钮）退出查看器；
/// - 底部提供「保存到本地」按钮：通过系统保存面板选取目标路径并复制图片。
class ImageViewerPage extends StatelessWidget {
  final String relPath;

  const ImageViewerPage({super.key, required this.relPath});

  /// 将图片复制到用户选择的本地路径（取消返回 null；失败给出提示）。
  Future<void> _save(BuildContext context, String absPath) async {
    final file = File(absPath);
    if (!file.existsSync()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片文件已丢失，无法保存')),
        );
      }
      return;
    }
    final name = ImageStore.fileNameOf(relPath);
    final outPath = await FilePicker.platform.saveFile(
      dialogTitle: '保存图片',
      fileName: name.isEmpty ? 'image.png' : name,
      type: FileType.image,
    );
    if (outPath == null || !context.mounted) return;
    try {
      await file.copy(outPath);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存到 $outPath')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败，请重试')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        // 单击图片 / 空白区域退出查看器；按钮命中优先于背景单击，不会误关。
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(),
          child: FutureBuilder<String>(
            future: ImageStore.resolveAbsolute(relPath),
            builder: (context, snapshot) {
              final Widget imageArea;
              if (snapshot.hasError) {
                imageArea = Center(child: _MissingImage(relPath));
              } else {
                final file = File(snapshot.data ?? '');
                imageArea = Center(
                  child: file.existsSync()
                      ? InteractiveViewer(
                          minScale: 0.5,
                          maxScale: 5,
                          child: Image.file(file, fit: BoxFit.contain),
                        )
                      : _MissingImage(relPath),
                );
              }
              final absPath = snapshot.data;
              return Stack(
                children: [
                  Positioned.fill(child: imageArea),
                  // 右上角关闭按钮。
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  // 底部「保存到本地」按钮。
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: Colors.white24,
                            foregroundColor: Colors.white,
                            side: BorderSide.none,
                          ),
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('保存到本地'),
                          onPressed: absPath == null
                              ? null
                              : () => _save(context, absPath),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
