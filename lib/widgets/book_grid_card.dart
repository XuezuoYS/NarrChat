import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/default_cover_style.dart';
import '../theme/app_theme.dart';
import 'book_cover.dart';

/// 网格卡片封面圆角。
const double _kCoverRadius = 12;

/// 标题字号 / 行高 / 最大行数（与 [bookGridItemExtent] 共享）。
const double _kTitleFontSize = 13;
const double _kTitleLineHeight = 1.35;
const int _kTitleMaxLines = 3;

/// 分类字号 / 行高。
const double _kCategoryFontSize = 12;
const double _kCategoryLineHeight = 1.3;

/// 封面与标题、标题与分类的间距。
const double _kCoverTextGap = 8;
const double _kTitleCategoryGap = 4;

/// 卡片底部留白（吸收字高取整误差）。
const double _kBottomCushion = 2;

/// 网格卡片除封面外的固定文字块高度。
double _gridTextBlockHeight(TextScaler textScaler) {
  final titleLine = textScaler.scale(_kTitleFontSize) * _kTitleLineHeight;
  final categoryLine =
      textScaler.scale(_kCategoryFontSize) * _kCategoryLineHeight;
  return _kCoverTextGap +
      titleLine * _kTitleMaxLines +
      _kTitleCategoryGap +
      categoryLine +
      _kBottomCushion;
}

/// 首页网格单格的高度（用于 `SliverGridDelegate.mainAxisExtent`）。
///
/// 封面严格 2:3；文字区固定预留 3 行标题 + 1 行分类，保证同一行卡片底边
/// 对齐。`+1` 是取整余量，避免实际宽度有小数时封面高度比预估多出半像素
/// 导致 RenderFlex 溢出。
double bookGridItemExtent(double cardWidth, TextScaler textScaler) {
  return cardWidth * 3 / 2 + _gridTextBlockHeight(textScaler) + 1;
}

/// 首页方格模式下的单本书卡片。
///
/// - 点击进入对话页；
/// - 桌面右键 / 触屏长按触发上下文菜单（删除）。长按用 [InkWell.onLongPress]
///   参与手势竞技场，保证不会在菜单弹出后又误触发一次 onTap。
class BookGridCard extends StatelessWidget {
  final Book book;
  final VoidCallback onTap;

  /// 上下文菜单回调，参数为全局坐标（触屏长按取卡片中心）。
  final void Function(Offset globalPosition)? onContextMenu;

  /// 书籍未设置封面时使用的默认封面样式。
  final DefaultCoverStyle coverStyle;

  const BookGridCard({
    super.key,
    required this.book,
    required this.onTap,
    this.onContextMenu,
    this.coverStyle = DefaultCoverStyle.illustration1,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BookCover(
              width: width,
              radius: _kCoverRadius,
              title: book.title,
              style: coverStyle,
            ),
            const SizedBox(height: _kCoverTextGap),
            Text(
              book.title,
              maxLines: _kTitleMaxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _kTitleFontSize,
                height: _kTitleLineHeight,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: _kTitleCategoryGap),
            // 分类紧贴标题实际占用的行数，不强行推到“三行标题”的底部；
            // 卡片外框高度仍按 3 行预留，保证同一行卡片底边对齐。
            Text(
              book.category.isEmpty ? '未设置类别' : book.category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _kCategoryFontSize,
                height: _kCategoryLineHeight,
                color: colors.textSecondary,
              ),
            ),
          ],
        );
      },
    );

    return GestureDetector(
      onSecondaryTapDown: onContextMenu == null
          ? null
          : (details) => onContextMenu!(details.globalPosition),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onContextMenu == null
              ? null
              : () {
                  // 长按没有指针位置回调，用卡片中心作为菜单锚点即可。
                  final box = context.findRenderObject() as RenderBox?;
                  final anchor = box != null && box.hasSize
                      ? box.localToGlobal(box.size.center(Offset.zero))
                      : Offset.zero;
                  onContextMenu!(anchor);
                },
          borderRadius: BorderRadius.circular(_kCoverRadius),
          hoverColor: NarrChatTheme.primary.withValues(alpha: 0.04),
          splashColor: NarrChatTheme.primary.withValues(alpha: 0.08),
          child: content,
        ),
      ),
    );
  }
}
