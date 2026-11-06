import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 在 [anchorContext] 下方贴着它的右缘弹出 [builder] 内容（小窗）。
///
/// 与 [showDialog] 的区别（分支列表要的正是这三点）：
/// - **不居中、不暗化背景**：遮罩完全透明，只有内容自身的阴影体现悬浮；
/// - **贴着触发点**：右缘对齐 [anchorContext] 的右缘、向下留 [gap]；
///   下方放不下时翻到上方，并始终收拢在视口内；
/// - **点窗外任意位置关闭**：遮罩盖住全屏，因此点触发按钮本身也会先关闭
///   （不会「关掉又立刻重开」）。
///
/// 内容高度上限取 `视口高 × 60%` 与 [maxHeight] 的较小值，超出内部滚动；
/// 宽度上限 [maxWidth]（内容自己可以更窄）。
Future<void> showAnchoredPopup({
  required BuildContext context,
  required BuildContext anchorContext,
  required WidgetBuilder builder,
  String barrierLabel = '关闭',
  double gap = 6,
  EdgeInsets margin = const EdgeInsets.all(8),
  double maxWidth = 320,
  double maxHeight = 420,
}) {
  final anchorBox = anchorContext.findRenderObject() as RenderBox?;
  final overlayBox =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (anchorBox == null ||
      !anchorBox.hasSize ||
      overlayBox == null ||
      !overlayBox.hasSize) {
    return Future<void>.value();
  }
  // Overlay 坐标系 = 气泡的摆放坐标系（与 Token 用量气泡同一口径）。
  final anchor =
      anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox) &
      anchorBox.size;
  return Navigator.of(context).push<void>(
    _AnchoredPopupRoute(
      anchor: anchor,
      builder: builder,
      barrierLabel: barrierLabel,
      gap: gap,
      margin: margin,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    ),
  );
}

/// 透明遮罩（点击外部关闭）+ 按锚点摆放的悬浮路由。
class _AnchoredPopupRoute extends PopupRoute<void> {
  _AnchoredPopupRoute({
    required this.anchor,
    required this.builder,
    required this.barrierLabel,
    required this.gap,
    required this.margin,
    required this.maxWidth,
    required this.maxHeight,
  });

  final Rect anchor;
  final WidgetBuilder builder;
  final double gap;
  final EdgeInsets margin;
  final double maxWidth;
  final double maxHeight;

  @override
  final String barrierLabel;

  @override
  Color get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  /// 关闭略快于打开：退场拖沓会比「消失得慢」更显僵硬。
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 130);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // 入场：淡入 + 以**右上角为原点**轻缩放 + 轻微下落。
    // 为什么在 buildPage 里做（而不是包整页）：本路由的页面是整屏的
    // CustomSingleChildLayout，缩放/位移只作用在面板本体上，锚点位置才不会跟着抖。
    final fade = animation.drive(CurveTween(curve: Curves.easeOut));
    final scale = animation.drive(
      Tween<double>(begin: 0.92, end: 1).chain(
        CurveTween(curve: Curves.easeOutCubic),
      ),
    );
    final slide = animation.drive(
      Tween<Offset>(
        begin: const Offset(0, -0.035),
        end: Offset.zero,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
    );
    return CustomSingleChildLayout(
      delegate: _AnchoredPopupLayout(
        anchor: anchor,
        gap: gap,
        margin: margin,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ),
      child: FadeTransition(
        opacity: fade,
        child: ScaleTransition(
          scale: scale,
          alignment: Alignment.topRight,
          child: SlideTransition(
            position: slide,
            // Material：路由页挂在 Overlay 下，没有页面 Scaffold 的 Material
            // 祖先；面板里的 InkWell / 按钮都需要它。透明类型不改变内容外观。
            child: Material(
              type: MaterialType.transparency,
              // Builder：让内容拿到路由内的 context，闭包里可 `Navigator.pop`。
              child: Builder(builder: builder),
            ),
          ),
        ),
      ),
    );
  }
}

/// 摆放：右缘对齐锚点右缘并贴在锚点下方；空间不够就翻到上方，
/// 最后把水平 / 垂直都收拢进视口。
class _AnchoredPopupLayout extends SingleChildLayoutDelegate {
  const _AnchoredPopupLayout({
    required this.anchor,
    required this.gap,
    required this.margin,
    required this.maxWidth,
    required this.maxHeight,
  });

  final Rect anchor;
  final double gap;
  final EdgeInsets margin;
  final double maxWidth;
  final double maxHeight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final viewportWidth = math.max(
      0.0,
      constraints.maxWidth - margin.horizontal,
    );
    final viewportHeight = math.max(
      0.0,
      constraints.maxHeight - margin.vertical,
    );
    // 「小窗」：不铺满整屏；分支多时由内容自己滚动。
    final cappedHeight = math.min(maxHeight, constraints.maxHeight * 0.6);
    return BoxConstraints(
      maxWidth: math.min(maxWidth, viewportWidth),
      maxHeight: math.min(cappedHeight, viewportHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = math.max(
      margin.left,
      size.width - childSize.width - margin.right,
    );
    final left = (anchor.right - childSize.width)
        .clamp(margin.left, maxLeft)
        .toDouble();
    final below = anchor.bottom + gap;
    if (below + childSize.height + margin.bottom <= size.height) {
      return Offset(left, below);
    }
    final above = anchor.top - gap - childSize.height;
    if (above >= margin.top) return Offset(left, above);
    // 上下都放不下：贴顶（高度已被 60% 视口上限收进屏内）。
    return Offset(left, margin.top);
  }

  @override
  bool shouldRelayout(_AnchoredPopupLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.gap != gap ||
      oldDelegate.margin != margin ||
      oldDelegate.maxWidth != maxWidth ||
      oldDelegate.maxHeight != maxHeight;
}
