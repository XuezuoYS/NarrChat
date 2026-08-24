import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../services/image_store.dart';
import 'image_viewer_window.dart';

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
            inner = MissingImage(relPath);
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
    if (!file.existsSync()) return MissingImage(relPath);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.file(
        file,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => MissingImage(relPath),
      ),
    );
  }
}

/// 文件缺失 / 读取失败的灰色占位块。
class MissingImage extends StatelessWidget {
  final String relPath;

  const MissingImage(this.relPath, {super.key});

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

  /// 点击单张图片回调（`relPath` + 所在序号）。为空则仅缩略图。
  final void Function(String relPath, int index)? onTapImage;

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
            onTap:
                onTapImage == null ? null : () => onTapImage!(rel, i),
            onRemove: onRemove == null ? null : () => onRemove!(rel),
          );
        },
      ),
    );
  }
}

/// 打开图片查看器。
///
/// [images] 为当前一组图片（同一轮次的全部图片），[initialIndex] 为点击的那张序号。
/// - Windows 桌面端：打开**独立系统窗口**（左右箭头 + 滚轮缩放 + 拖动平移）；
/// - 其它平台：主窗口内 photo_view 查看器（左右滑动 + 双指缩放）。
Future<void> showImageViewer(
  BuildContext context,
  List<String> images,
  int initialIndex,
) async {
  if (Platform.isWindows && await _tryOpenImageViewerWindow(images, initialIndex)) {
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ImageViewerPage(images: images, initialIndex: initialIndex),
    ),
  );
}

/// 尝试打开桌面端独立图片查看器窗口；成功返回 true，失败返回 false（调用方回退到应用内查看器）。
Future<bool> _tryOpenImageViewerWindow(List<String> images, int initialIndex) async {
  try {
    await WindowController.create(
      WindowConfiguration(
        arguments:
            ImageWindowArgs(images: images, index: initialIndex).encode(),
        hiddenAtLaunch: true,
      ),
    );
    return true;
  } catch (e) {
    debugPrint('打开图片查看器窗口失败，回退到应用内查看器: $e');
    return false;
  }
}

/// 将图片复制到用户选择的本地路径（取消返回 null；失败给出提示）。
/// 供移动端应用内查看器与桌面端独立窗口查看器复用。
Future<void> saveImageFile(
  BuildContext context, {
  required String relPath,
  required String absPath,
}) async {
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

/// 全屏图片查看页：左右滑动切换 + 双指缩放（photo_view）。
///
/// - 未放大时左右滑动 → 上一张 / 下一张；放大后可平移查看、缩回后再滑动切换；
/// - 双指缩放可扩展至铺满全屏（覆盖画面），不再被“原比例留黑边”限制；
/// - 顶部显示页码（如 2/5）与关闭按钮，底部提供「保存到本地」；
/// - 单击图片或空白区域（非按钮）退出查看器。
class ImageViewerPage extends StatefulWidget {
  final List<String> images;
  final int initialIndex;

  const ImageViewerPage({super.key, required this.images, this.initialIndex = 0});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  // 一次性解析全部绝对路径（相对 `img/...` → 磁盘路径）。
  // 单个解析失败（如测试环境无 path_provider）时回退相对路径，交由
  // PhotoView 的 errorBuilder 显示占位，避免整批失败导致无限加载转圈。
  late final Future<List<String>> _absPaths = Future.wait(
    widget.images.map((rel) async {
      try {
        return await ImageStore.resolveAbsolute(rel);
      } catch (_) {
        return rel;
      }
    }),
  );

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 将图片复制到用户选择的本地路径（复用共享 [saveImageFile]）。
  Future<void> _save(BuildContext context, String relPath, String absPath) =>
      saveImageFile(context, relPath: relPath, absPath: absPath);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: FutureBuilder<List<String>>(
          future: _absPaths,
          builder: (context, snapshot) {
            final absPaths = snapshot.data;
            return Stack(
              children: [
                // 图片画布：PhotoViewGallery（左右滑动换图 + 双指缩放；单击退出）。
                Positioned.fill(
                  child: absPaths == null
                      ? const Center(
                          child: Icon(
                            Icons.image_outlined,
                            color: Colors.white24,
                            size: 48,
                          ),
                        )
                      : PhotoViewGallery(
                          pageController: _pageController,
                          backgroundDecoration: const BoxDecoration(color: Colors.black),
                          onPageChanged: (i) => setState(() => _index = i),
                          pageOptions: [
                            for (var i = 0; i < widget.images.length; i++)
                              PhotoViewGalleryPageOptions(
                                imageProvider: FileImage(File(absPaths[i])),
                                errorBuilder: (context, error, stackTrace) =>
                                    MissingImage(widget.images[i]),
                                // 初始整图可见（contained）；双指放大可扩展到铺满全屏并继续放大。
                                minScale: PhotoViewComputedScale.contained,
                                maxScale: PhotoViewComputedScale.covered * 3,
                                // 单击图片/空白区域退出查看器（不影响双指缩放与左右滑动）。
                                onTapUp: (ctx, _, _) =>
                                    Navigator.of(ctx).pop(),
                              ),
                          ],
                        ),
                ),
                // 顶部页码指示（如 2/5）。
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_index + 1}/${widget.images.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
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
                        onPressed: absPaths == null
                            ? null
                            : () =>
                                _save(context, widget.images[_index], absPaths[_index]),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
