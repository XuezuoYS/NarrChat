import 'package:flutter/material.dart';

import '../models/default_cover_style.dart';
import 'book_cover_image.dart';

/// 默认书籍封面资源（2:3 比例）。
///
/// 书籍没有自定义封面（`book_meta.book_cover_img` 为 NULL）时用它兜底；
/// 有自定义封面时显示用户裁好的那张图（见 [BookCover.coverImg]）。
const String kDefaultBookCoverAsset = 'assets/girl1.png';

/// 生成封面的纸感底色（上浅下深）。
const Color _kPaperTop = Color(0xFFECEAE5);
const Color _kPaperBottom = Color(0xFFD2CFC8);

/// 生成封面的墨色（书名 / 装饰线 / 小字）。
const Color _kInk = Color(0xFF34373B);

/// 书籍封面：固定 2:3、圆角。
///
/// 显示优先级：
/// - 有 [coverImg]（自定义封面的图片相对路径）→ 显示用户裁好的图；图丢了或
///   解码失败时**回落默认封面**（首页不出现灰块）；
/// - 没有自定义封面 → 按 [style] 展示默认封面：
///   - [DefaultCoverStyle.illustration1]：默认插画（按显示宽度限制解码尺寸）；
///   - [DefaultCoverStyle.noIllustration]：程序生成的纸感封面（细内框、小字品牌、
///     书名与装饰线），内容为书名。
class BookCover extends StatelessWidget {
  /// 显示宽度（高度固定为宽度的 1.5 倍）。
  final double width;

  /// 圆角半径。
  final double radius;

  /// 插画封面资源路径。
  final String asset;

  /// 书名（生成封面时显示；插画封面不使用）。
  final String title;

  /// 默认封面样式（仅在没有自定义封面时生效）。
  final DefaultCoverStyle style;

  /// 自定义封面的图片相对路径（`img/<哈希>.<扩展名>`）；null = 没有自定义封面。
  final String? coverImg;

  const BookCover({
    super.key,
    required this.width,
    this.radius = 12,
    this.asset = kDefaultBookCoverAsset,
    this.title = '',
    this.style = DefaultCoverStyle.illustration1,
    this.coverImg,
  });

  @override
  Widget build(BuildContext context) {
    final cover = coverImg;
    final Widget inner;
    if (cover == null || cover.isEmpty) {
      inner = _buildDefaultCover(context);
    } else {
      inner = BookCoverImage(
        relPath: cover,
        width: width,
        radius: 0,
        // 封面读不出来时退回默认封面：首页宁可看默认封面，也不看灰块。
        fallback: _buildDefaultCover(context),
      );
    }
    return SizedBox(
      width: width,
      height: width * 3 / 2,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: inner,
      ),
    );
  }

  /// 默认封面（没有自定义封面 / 自定义封面读不出来时使用）。
  Widget _buildDefaultCover(BuildContext context) {
    return style == DefaultCoverStyle.noIllustration
        ? _buildGeneratedCover()
        : _buildIllustration(context);
  }

  /// 默认插画；资源缺失时退化为生成封面，不露破图。
  Widget _buildIllustration(BuildContext context) {
    final rawCacheWidth = (width * MediaQuery.devicePixelRatioOf(context))
        .ceil();
    final cacheWidth = rawCacheWidth < 96
        ? 96
        : (rawCacheWidth > 800 ? 800 : rawCacheWidth);
    return Image.asset(
      asset,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      errorBuilder: (context, error, stackTrace) => _buildGeneratedCover(),
    );
  }

  /// 程序生成的纸感简约封面。
  ///
  /// 组成：浅灰纸底 + 淡圆环 + 细内框 + 顶部小字品牌 + 居中书名装饰块。
  /// 小尺寸（列表缩略图）只保留内框、书名首字和一条短线，避免拥挤。
  Widget _buildGeneratedCover() {
    const decoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_kPaperTop, _kPaperBottom],
      ),
    );
    final trimmed = title.trim();
    final display = trimmed.isEmpty ? '未命名' : trimmed;

    if (width < 96) {
      return DecoratedBox(
        decoration: decoration,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.all(width * 0.08),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _kInk.withValues(alpha: 0.22),
                      width: 0.7,
                    ),
                  ),
                ),
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    String.fromCharCodes(display.runes.take(1)),
                    maxLines: 1,
                    style: TextStyle(
                      color: _kInk,
                      fontSize: width * 0.4,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                  SizedBox(height: width * 0.07),
                  _rule(width * 0.24, alpha: 0.3),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final wordmarkSize = (width * 0.052).clamp(6.0, 9.0).toDouble();
    final titleSize = (width * 0.12).clamp(12.0, 17.0).toDouble();

    return DecoratedBox(
      decoration: decoration,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 淡圆环：给纸面一点构图感，不抢书名。
          Positioned(
            right: -width * 0.34,
            top: -width * 0.22,
            width: width,
            height: width,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _kInk.withValues(alpha: 0.07),
                  width: 1,
                ),
              ),
            ),
          ),
          // 细内框。
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.all(width * 0.07),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _kInk.withValues(alpha: 0.22),
                    width: 0.8,
                  ),
                ),
              ),
            ),
          ),
          // 顶部小字品牌。
          Positioned(
            top: width * 0.105,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                'NARRCHAT',
                maxLines: 1,
                style: TextStyle(
                  color: _kInk.withValues(alpha: 0.42),
                  fontSize: wordmarkSize,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.3,
                  height: 1,
                ),
              ),
            ),
          ),
          // 居中书名块：装饰线 + 书名 + 短线。
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: width * 0.15),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _rule(width * 0.1),
                      SizedBox(width: width * 0.025),
                      _dot(width * 0.03),
                      SizedBox(width: width * 0.025),
                      _rule(width * 0.1),
                    ],
                  ),
                  SizedBox(height: width * 0.06),
                  Text(
                    display,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _kInk,
                      fontSize: titleSize,
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                      letterSpacing: 0.4,
                    ),
                  ),
                  SizedBox(height: width * 0.06),
                  _rule(width * 0.14, alpha: 0.28),
                ],
              ),
            ),
          ),
          // 底部小圆点，和顶部品牌呼应。
          Positioned(
            bottom: width * 0.105,
            left: 0,
            right: 0,
            child: Center(child: _dot(width * 0.022, alpha: 0.25)),
          ),
        ],
      ),
    );
  }

  /// 一条装饰细线。
  Widget _rule(double width, {double alpha = 0.32}) {
    return Container(
      width: width,
      height: 1,
      color: _kInk.withValues(alpha: alpha),
    );
  }

  /// 装饰圆点。
  Widget _dot(double size, {double alpha = 0.4}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _kInk.withValues(alpha: alpha),
      ),
    );
  }
}
