import 'dart:io';

import 'package:flutter/material.dart';

import '../services/image_store.dart';

/// 自定义书籍封面图：固定 2:3 取景框内的三态显示。
///
/// 状态与兜底：
/// - 路径为空（`book_meta.book_cover_img` 为 NULL）→ [fallback] 或灰底
///   「未设置封面」；
/// - 路径解析失败（非法路径）/ 文件不存在 / 解码失败 → [fallback] 或灰底
///   「图片已损坏」；
/// - 正常 → 文件图片，`BoxFit.cover` + 居中：库里存的图不是 2:3 时
///   **居中等比放大**裁切，绝不拉伸变形。
///
/// [fallback] 专供首页使用：没有封面或封面坏了都回落「默认封面」（插画 1 /
/// 程序生成封面），所以首页永远不会出现灰块；书籍设置页不传 [fallback]，
/// 直接按上述状态显示灰底提示，方便用户判断「是不是还没设」。
class BookCoverImage extends StatelessWidget {
  /// 图片相对路径（`img/<哈希>.<扩展名>`，相对 `user_data/`）。
  final String? relPath;

  /// 显示宽度（高度恒为宽度的 1.5 倍）。
  final double width;

  /// 圆角半径（外层已经裁过一次时可传 0）。
  final double radius;

  /// 没有图片 / 图片读不出来时的替代内容；为 null 时显示灰底提示文案。
  final Widget? fallback;

  const BookCoverImage({
    super.key,
    required this.relPath,
    required this.width,
    this.radius = 0,
    this.fallback,
  });

  /// 低于该宽度只显示图标：36px 的列表缩略图放不下「未设置封面」这行字。
  static const double _textMinWidth = 64;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: width * 3 / 2,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: _buildContent(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final path = relPath;
    if (path == null || path.isEmpty) {
      return _unavailable(context, '未设置封面');
    }
    // 根目录已知时同步判断文件在不在：首帧就能给出正确结果，不会先闪一下灰底。
    if (ImageStore.canResolveSync) {
      final String absolute;
      try {
        absolute = ImageStore.resolveAbsoluteSync(path);
      } on ImageFormatException {
        return _unavailable(context, '图片已损坏');
      }
      return _fileImage(context, absolute);
    }
    // 冷启动第一帧（用户数据目录还没解析出来）：解析完成后再决定。
    return FutureBuilder<String>(
      future: ImageStore.resolveAbsolute(path),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _placeholder(context, null);
        }
        if (snapshot.hasError) return _unavailable(context, '图片已损坏');
        return _fileImage(context, snapshot.data ?? '');
      },
    );
  }

  /// 绝对路径对应的图片；文件不存在或解码失败都落到「不可用」。
  Widget _fileImage(BuildContext context, String absolutePath) {
    final file = File(absolutePath);
    if (absolutePath.isEmpty || !file.existsSync()) {
      return _unavailable(context, '图片已损坏');
    }
    // 按显示宽度限制解码尺寸：首页可能同时挂着几十张封面，
    // 不限制的话每张都按 600×900 全量解码，内存吃不消。
    final rawCacheWidth = (width * MediaQuery.devicePixelRatioOf(context))
        .ceil();
    final cacheWidth = rawCacheWidth < 96
        ? 96
        : (rawCacheWidth > 800 ? 800 : rawCacheWidth);
    return Image.file(
      file,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => _unavailable(context, '图片已损坏'),
    );
  }

  /// 没有可用图片时的内容：首页回落默认封面，其余场景显示灰底提示。
  Widget _unavailable(BuildContext context, String message) {
    final fallback = this.fallback;
    if (fallback != null) return fallback;
    return _placeholder(context, message);
  }

  /// 灰底占位块：图标 + 可选文案（[message] 为 null 时只有灰底与图标）。
  Widget _placeholder(BuildContext context, String? message) {
    final scheme = Theme.of(context).colorScheme;
    final label = message;
    final canShowText = width >= _textMinWidth;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: width * 0.08),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_outlined,
                size: (width * 0.26).clamp(14.0, 28.0).toDouble(),
                color: scheme.outline,
              ),
              if (label != null && canShowText) ...[
                SizedBox(height: width * 0.05),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: (width * 0.11).clamp(9.0, 12.0).toDouble(),
                    height: 1.3,
                    color: scheme.outline,
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
