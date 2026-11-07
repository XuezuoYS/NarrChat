import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 默认书籍封面资源（2:3 比例）。
///
/// 当前书籍还没有自定义封面字段，所有书先用这张图兜底；
/// 后续接入真实封面时只需替换 [BookCover.asset] 的来源。
const String kDefaultBookCoverAsset = 'assets/girl1.png';

/// 书籍封面：固定 2:3、圆角，并按显示尺寸限制解码宽度。
///
/// 默认图是 1696×2528 的大图，直接原图解码会把内存和首帧时间拖得很长；
/// 这里按「显示宽度 × devicePixelRatio」限制 `cacheWidth`，列表/网格各自
/// 只解码到够用的尺寸。
class BookCover extends StatelessWidget {
  /// 显示宽度（高度固定为宽度的 1.5 倍）。
  final double width;

  /// 圆角半径。
  final double radius;

  /// 封面资源路径。
  final String asset;

  const BookCover({
    super.key,
    required this.width,
    this.radius = 12,
    this.asset = kDefaultBookCoverAsset,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final rawCacheWidth = (width * MediaQuery.devicePixelRatioOf(context))
        .ceil();
    final cacheWidth = rawCacheWidth < 96
        ? 96
        : (rawCacheWidth > 800 ? 800 : rawCacheWidth);
    return SizedBox(
      width: width,
      height: width * 3 / 2,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: Image.asset(
          asset,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          // 资源缺失时不要露出破图：用同色底 + 书图标兜底。
          errorBuilder: (context, error, stackTrace) => ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: Center(
              child: Icon(
                Icons.menu_book_outlined,
                size: 24,
                color: colors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
