import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 拖动锚点语义：指针位置与拇指的关系。
enum ScrollDragAnchor {
  /// 保持「按下时拇指与指针的相对位置」：位移增量按内容/轨道比例换算，
  /// 按下瞬间不会跳动（自绘通用滚动条默认，与原生滚动条一致）。
  grab,

  /// 拇指中心始终跟随指针（快速定位导轨的所见即所得定位）。
  center,
}

/// 滚动条拇指几何与拖动数学（纯计算，无状态）。
///
/// 本类是「拇指尺寸 / 拇指位置 / 指针位置 → 目标滚动偏移」的唯一来源，
/// 由 [NarrChatScrollbar]（自绘滚动条底座）与快速定位导轨
/// （`QuickScrollRail`，见 `quick_scroll_rail.dart`）共用，保证两个滚动条
/// 的拇指几何与拖动手感永远一致（改一处、生效两处）。
///
/// 坐标约定与渲染树一致：轨道竖直向下，`0` = 轨道顶部，单位逻辑像素。
class ScrollThumbGeometry {
  const ScrollThumbGeometry._();

  /// 拇指高度：轨道高 ×（视口 / 内容），并限制在 `[minHeight, trackExtent]`。
  ///
  /// - 内容不溢出（`maxScrollExtent <= 0`）时比例 = 1 → 拇指即整条轨道
  ///   （调用方据此判空、整体不渲染）；
  /// - 不可用尺寸（轨道 ≤ 0 / 内容 ≤ 0）→ 0；
  /// - 拇指不会高于轨道，也不会矮于 [minHeight]（除非轨道本身更矮）。
  static double thumbHeight({
    required double trackExtent,
    required double viewportDimension,
    required double maxScrollExtent,
    required double minHeight,
  }) {
    if (trackExtent <= 0) return 0;
    final content = maxScrollExtent + viewportDimension;
    if (content <= 0) return 0;
    final frac = viewportDimension / content;
    return math.min(math.max(trackExtent * frac, minHeight), trackExtent);
  }

  /// 拇指顶部 y：按 `pixels / maxScrollExtent` 线性映射，越界值被夹取。
  static double thumbTop({
    required double trackExtent,
    required double thumbExtent,
    required double pixels,
    required double maxScrollExtent,
  }) {
    final travel = trackExtent - thumbExtent;
    if (travel <= 0 || maxScrollExtent <= 0) return 0;
    return (pixels / maxScrollExtent).clamp(0.0, 1.0) * travel;
  }

  /// 指针拖动 → 目标滚动偏移。
  ///
  /// 两种锚点（[ScrollDragAnchor]）语义：
  /// - [ScrollDragAnchor.grab]（通用滚动条默认）：保持「按下时拇指与指针的
  ///   相对位置」，位移增量按内容/轨道比例换算 → 按下瞬间不会跳动
  ///   （与原生滚动条一致）；
  /// - [ScrollDragAnchor.center]（快速定位导轨）：拇指中心始终跟随指针
  ///   （WPS 式所见即所得定位）。
  ///
  /// 返回 null 表示本次不可定位（轨道无法容纳拇指或不可滚动）；结果已夹取到
  /// `[minScrollExtent, maxScrollExtent]`。
  static double? pointerOffset({
    required Offset pointerPosition,
    required double trackExtent,
    required double thumbExtent,
    required double viewportDimension,
    required double maxScrollExtent,
    required double minScrollExtent,
    required ScrollDragAnchor dragAnchor,
    required double startOffset,
    required Offset startPointerPosition,
  }) {
    final travel = trackExtent - thumbExtent;
    final content = maxScrollExtent + viewportDimension;
    if (travel <= 0 || content <= 0) return null;
    final pixelsPerTrack = maxScrollExtent / travel;
    final target = switch (dragAnchor) {
      ScrollDragAnchor.grab =>
        startOffset +
            (pointerPosition.dy - startPointerPosition.dy) * pixelsPerTrack,
      ScrollDragAnchor.center =>
        (pointerPosition.dy - thumbExtent / 2) * pixelsPerTrack,
    };
    return target.clamp(minScrollExtent, maxScrollExtent);
  }
}

/// 自绘滚动条的空闲淡出延时（滚动结束 / 悬停离开后多久开始淡出）。
const Duration kScrollbarIdleDelay = Duration(milliseconds: 700);

/// 自绘滚动条拇指显隐动画时长。
const Duration kScrollbarFadeDuration = Duration(milliseconds: 120);

/// 自绘滚动条拇指宽度（通用滚动条与快速定位导轨共用，保证外观同源）。
const double kScrollbarThumbWidth = 10;

/// 拇指与右缘间距（两滚动条共用）。
const double kScrollbarThumbEdgeGap = 4;

/// 右缘命中带宽度：通用滚动条的悬停显隐区（与楼层跳转悬浮条等右缘控件
/// 保持不相交；快速定位导轨另用整条 28px 触屏命中带）。
const double kScrollbarHitBandWidth = 16;

/// 拇指拾取宽度（比拇指本体宽，便于点中拖动）。
const double kScrollbarThumbHitWidth = 16;

/// 自绘滚动条拇指内图案（无 / 上下三角 + 中心圆点）。
enum ThumbGlyph {
  /// 无图案（通用滚动条默认）。
  none,

  /// 顶部 ▲、底部 ▼、中心小圆点（快速定位导轨）。
  arrowsWithDot,
}

/// 拇指：圆角胶囊 + 阴影 + 可选内图案。
///
/// 通用滚动条与快速定位导轨共用本部件，仅 [glyph] 不同
/// （导轨多一对上下三角与中心圆点）。
class NarrChatScrollThumb extends StatelessWidget {
  const NarrChatScrollThumb({
    super.key,
    required this.dragging,
    this.glyph = ThumbGlyph.none,
  });

  /// 是否处于拖动中（拖动时取品牌主色）。
  final bool dragging;

  /// 拇指内图案。
  final ThumbGlyph glyph;

  /// 拇指圆角半径（= 宽度的一半 → 胶囊）。
  static const double radius = 5;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final color = dragging
        ? scheme.primary
        : (theme.scrollbarTheme.thumbColor?.resolve({}) ??
              scheme.onSurfaceVariant);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: switch (glyph) {
        ThumbGlyph.none => const SizedBox.expand(),
        ThumbGlyph.arrowsWithDot => const CustomPaint(
          painter: _ThumbGlyphPainter(glyphColor: Colors.white),
        ),
      },
    );
  }
}

/// 拇指内部图案：顶部 ▲、底部 ▼、中心小圆点。
class _ThumbGlyphPainter extends CustomPainter {
  const _ThumbGlyphPainter({required this.glyphColor});

  final Color glyphColor;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = glyphColor;
    final cx = size.width / 2;
    final w = 4.0;

    // ▲
    canvas.drawPath(
      Path()
        ..moveTo(cx, 2)
        ..lineTo(cx - w, 6)
        ..lineTo(cx + w, 6)
        ..close(),
      fill,
    );
    // ▼
    canvas.drawPath(
      Path()
        ..moveTo(cx - w, size.height - 6)
        ..lineTo(cx + w, size.height - 6)
        ..lineTo(cx, size.height - 2)
        ..close(),
      fill,
    );
    // 中心圆点（描边）。
    canvas.drawCircle(
      Offset(cx, size.height / 2),
      2.4,
      Paint()
        ..color = glyphColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(covariant _ThumbGlyphPainter oldDelegate) {
    return oldDelegate.glyphColor != glyphColor;
  }
}

/// 拖动中的轨道细竖线（衬托行刻度与拇指）。
class _TrackPainter extends CustomPainter {
  const _TrackPainter({required this.lineColor});

  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = lineColor
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant _TrackPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor;
  }
}

/// NarrChat 自绘滚动条的**通用底座**（两个滚动条组件共用）。
///
/// 用法：把目标滚动视图作为 [scrollable] 传入并共享 [controller]，组件在
/// 其上层叠加右缘拇指：
///
/// ```dart
/// NarrChatScrollbar(
///   controller: scrollController,
///   scrollable: ListView(controller: scrollController, ...),
/// )
/// ```
///
/// 承担职责（两个滚动条完全一致的部分）：
/// - 滚动内容时淡入显示圆形阴影拇指，空闲 [idleDelay] 后淡出；鼠标悬停
///   右缘命中带时保持显示；按住拇指拖动时保持显示；
/// - 按住拖动 = 连续定位（jumpTo 跟手，无固定时长动画）；
/// - 内容未溢出（`maxScrollExtent <= 0`）时整体不渲染（不占布局、不参与命中）；
/// - 拖动中的轨道细竖线绘制。
///
/// 差异化通过构造参数表达，[QuickScrollRail] 即本底座的一层“皮肤”：
/// - [thumbGlyph]：拇指内图案（导轨为上下三角 + 中心圆点）；
/// - [thumbMinHeight] / [dragAnchor] / [applyOnDown]：拇指最小高度与拖动锚点；
/// - [touchStrip] / [stripKey]：整条右缘命中带（触屏可按住任意位置定位）；
/// - [overlayBuilder] / [onDragStart] / [onDragEnd]：附加浮层（导轨目录浮层）。
///
/// ⚠️ 浮层排在拇指与拖动命中层**之下**：否则拖动时目录浮层会把拇指整条遮住
/// （见 [_NarrChatScrollbarState._buildThumbLayer] 中的层序说明）。
///
/// 两个滚动条组件**不各自实现**拇指几何与拖动数学：统一走
/// [ScrollThumbGeometry]。
class NarrChatScrollbar extends StatefulWidget {
  const NarrChatScrollbar({
    super.key,
    required this.controller,
    required this.scrollable,
    this.thumbGlyph = ThumbGlyph.none,
    this.thumbMinHeight = 40,
    this.thumbWidth = kScrollbarThumbWidth,
    this.thumbEdgeGap = kScrollbarThumbEdgeGap,
    this.hitBandWidth = kScrollbarHitBandWidth,
    this.touchStrip = false,
    this.stripKey,
    this.dragAnchor = ScrollDragAnchor.grab,
    this.applyOnDown = false,
    this.thumbFadeKey,
    this.overlayBuilder,
    this.onDragStart,
    this.onDragEnd,
    this.idleDelay = kScrollbarIdleDelay,
    this.fadeDuration = kScrollbarFadeDuration,
  });

  /// 目标滚动视图的控制器（由 `ScrollableDetails.controller` 提供，恒非空）。
  final ScrollController controller;

  /// 被包裹的滚动视图（本组件只在其上叠加绘制，不改变其布局约束）。
  final Widget scrollable;

  /// 拇指内图案。
  final ThumbGlyph thumbGlyph;

  /// 拇指最小高度（快速定位导轨为 64，普通滚动条为 40）。
  final double thumbMinHeight;

  /// 拇指宽度。
  final double thumbWidth;

  /// 拇指与右缘间距。
  final double thumbEdgeGap;

  /// 右缘命中带宽度（悬停显隐；[touchStrip] 为 true 时也是拖动命中宽度）。
  final double hitBandWidth;

  /// 是否把整条右缘命中带作为可拖动区（触屏按住任意位置定位）。
  final bool touchStrip;

  /// 拖动命中矩形的 key（快速定位导轨传 `quick_scroll_rail_strip`，
  /// 供测试按几何拖动；不传则不带 key）。
  final Key? stripKey;

  /// 拖动锚点语义（见 [ScrollThumbGeometry.pointerOffset]）。
  final ScrollDragAnchor dragAnchor;

  /// 按下（未移动）时是否立即按指针位置定位。
  ///
  /// - false（默认，通用滚动条）：按下不改变滚动位置，拖动时按位移增量定位，
  ///   避免「点一下滚动条内容就跳」；
  /// - true（触屏拖动路径）：手势已越过阈值，按下即按位置定位。
  final bool applyOnDown;

  /// 拇指淡入淡出动画的 key（供测试按 key 读取 opacity）。
  final Key? thumbFadeKey;

  /// 附加浮层内容（坐标原点与本组件同尺寸；轨道高由 [trackExtent] 给出）。
  ///
  /// 快速定位导轨用它在拖动时绘制目录浮层；通用滚动条不用（不渲染浮层）。
  /// 浮层排在拇指之下，命中与否由调用方自行决定（导轨用 IgnorePointer 关闭）。
  final Widget Function(BuildContext context, double trackExtent)?
  overlayBuilder;

  /// 拖动开始回调（快速定位导轨据此展开目录浮层）。
  final VoidCallback? onDragStart;

  /// 拖动结束回调（松手 / 取消；快速定位导轨据此收起目录浮层）。
  final VoidCallback? onDragEnd;

  /// 空闲淡出延时。
  final Duration idleDelay;

  /// 拇指显隐动画时长。
  final Duration fadeDuration;

  @override
  State<NarrChatScrollbar> createState() => _NarrChatScrollbarState();
}

class _NarrChatScrollbarState extends State<NarrChatScrollbar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: widget.fadeDuration,
    value: 0,
  );

  Timer? _idleTimer;

  /// 桌面端鼠标是否悬停在右缘（悬停期间不淡出）。
  bool _hovered = false;

  /// 是否处于拖动定位中。
  bool _dragging = false;

  /// 拖动中的原始指针 id（-1 = 无）。
  int _pointerId = -1;

  /// 拖动起点：指针位置与当时的滚动偏移（[ScrollDragAnchor.grab] 用）。
  Offset _startPointer = Offset.zero;
  double _startOffset = 0;

  ScrollPosition? get _position =>
      widget.controller.hasClients ? widget.controller.position : null;

  @override
  void dispose() {
    _idleTimer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 显隐状态机
  // ---------------------------------------------------------------------------

  /// 只响应本组件直接包裹的滚动视图（depth 0）。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0) {
      _showThumb();
    }
    return false;
  }

  void _showThumb() {
    _idleTimer?.cancel();
    if (_fade.value < 1) _fade.forward();
    _scheduleIdleFade();
  }

  void _scheduleIdleFade() {
    _idleTimer?.cancel();
    _idleTimer = Timer(widget.idleDelay, () {
      if (mounted && !_dragging && !_hovered) _fade.reverse();
    });
  }

  void _onHoverChange(bool hovering) {
    if (_hovered == hovering) return;
    setState(() => _hovered = hovering);
    if (hovering) {
      _showThumb();
    } else {
      _scheduleIdleFade();
    }
  }

  // ---------------------------------------------------------------------------
  // 拖动定位
  // ---------------------------------------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse &&
        event.kind != PointerDeviceKind.trackpad) {
      return;
    }
    _pointerId = event.pointer;
    // 指针事件挂在拇指拾取矩形上（局部坐标 ≠ 本组件坐标），统一用全局坐标换算。
    _beginDrag(event.position, applyPosition: widget.applyOnDown);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointerId || !_dragging) return;
    _applyDrag(event.position);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointerId) return;
    _endDrag();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointerId) return;
    _endDrag();
  }

  /// 触屏手势路径（仅 [NarrChatScrollbar.touchStrip] 启用）：
  /// 垂直拖动经手势竞技场（与抽屉横滑等横向手势竞争）。
  void _onTouchDragStart(DragStartDetails details) {
    _beginDrag(details.globalPosition, applyPosition: true);
  }

  void _onTouchDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _applyDrag(details.globalPosition);
  }

  /// 全局坐标 → 本组件（轨道）坐标；不可用（尚未布局）时返回 null。
  Offset? _toTrackOffset(Offset globalPosition) {
    final ro = context.findRenderObject();
    if (ro is! RenderBox) return null;
    return ro.globalToLocal(globalPosition);
  }

  void _beginDrag(Offset globalPosition, {required bool applyPosition}) {
    if (_dragging) return;
    final local = _toTrackOffset(globalPosition);
    if (local == null) return;
    _idleTimer?.cancel();
    _startPointer = local;
    final pos = _position;
    _startOffset = pos?.pixels ?? 0;
    setState(() => _dragging = true);
    _fade.forward();
    widget.onDragStart?.call();
    if (applyPosition) _applyDrag(globalPosition);
  }

  void _applyDrag(Offset globalPosition) {
    final pos = _position;
    if (pos == null) return;
    final localPosition = _toTrackOffset(globalPosition);
    if (localPosition == null) return;
    final trackExtent = context.size?.height ?? 0;
    if (trackExtent <= 0) return;
    final thumbExtent = ScrollThumbGeometry.thumbHeight(
      trackExtent: trackExtent,
      viewportDimension: pos.viewportDimension,
      maxScrollExtent: pos.maxScrollExtent,
      minHeight: widget.thumbMinHeight,
    );
    final target = ScrollThumbGeometry.pointerOffset(
      pointerPosition: localPosition,
      trackExtent: trackExtent,
      thumbExtent: thumbExtent,
      viewportDimension: pos.viewportDimension,
      maxScrollExtent: pos.maxScrollExtent,
      minScrollExtent: pos.minScrollExtent,
      dragAnchor: widget.dragAnchor,
      startOffset: _startOffset,
      startPointerPosition: _startPointer,
    );
    if (target == null) return;
    if ((pos.pixels - target).abs() > 0.5) {
      pos.jumpTo(target);
    }
  }

  void _endDrag() {
    if (!_dragging) return;
    _pointerId = -1;
    setState(() => _dragging = false);
    widget.onDragEnd?.call();
    _scheduleIdleFade();
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: widget.scrollable,
        ),
        // 拇指与命中层按滚动位置重建（只重建叠加层，不重建滚动视图子树）。
        AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) =>
                _buildOverlayLayers(context, constraints),
          ),
        ),
      ],
    );
  }

  Widget _buildOverlayLayers(BuildContext context, BoxConstraints constraints) {
    final pos = _position;
    if (pos == null) return const SizedBox.shrink();

    // 轨道高：Stack 中非定位子项（滚动视图）即为轨道尺寸，故取外层约束高度。
    final trackExtent = constraints.maxHeight;
    final thumbExtent = ScrollThumbGeometry.thumbHeight(
      trackExtent: trackExtent,
      viewportDimension: pos.viewportDimension,
      maxScrollExtent: pos.maxScrollExtent,
      minHeight: widget.thumbMinHeight,
    );
    // 不溢出 / 轨道未定尺寸 / 拇指未成形 → 整体不渲染（不占布局、不参与命中）。
    if (!trackExtent.isFinite ||
        trackExtent <= 0 ||
        pos.maxScrollExtent <= 0 ||
        thumbExtent <= 0) {
      return const SizedBox.shrink();
    }
    final thumbTop = ScrollThumbGeometry.thumbTop(
      trackExtent: trackExtent,
      thumbExtent: thumbExtent,
      pixels: pos.pixels,
      maxScrollExtent: pos.maxScrollExtent,
    );
    return _buildThumbLayer(
      context,
      trackExtent: trackExtent,
      thumbExtent: thumbExtent,
      thumbTop: thumbTop,
    );
  }

  Widget _buildThumbLayer(
    BuildContext context, {
    required double trackExtent,
    required double thumbExtent,
    required double thumbTop,
  }) {
    // 拇指拾取矩形：普通滚动条仅拇指所在的一小段（带外扩，便于点中）；
    // 触屏导轨是整条右缘（按住任意位置即可定位）。
    final double hitTop;
    final double hitHeight;
    if (widget.touchStrip) {
      hitTop = 0;
      hitHeight = trackExtent;
    } else {
      final hitExtent = math.max(thumbExtent, kScrollbarThumbHitWidth);
      hitTop = (thumbTop + thumbExtent / 2 - hitExtent / 2).clamp(
        0.0,
        math.max(0.0, trackExtent - hitExtent),
      );
      hitHeight = math.min(hitExtent, trackExtent);
    }
    // 拖动中展示的轨道细竖线（导轨的刻度衬托）。
    final trackColor = Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: 0.5);

    return Stack(
      children: [
        // 右缘命中带：悬停显隐。
        // ⚠️ 必须给 MouseRegion 一个确定尺寸的子项：它自身不是 RenderBox，
        // 无子项时布局尺寸为 0，鼠标经过会触发
        // 「Cannot hit test a render box with no size」异常。
        // 命中带自身不阻挡下层内容的指针事件（Listener/MouseRegion 不消费命中）。
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: widget.hitBandWidth,
          child: MouseRegion(
            key: const Key('narr_chat_scrollbar_hit_band'),
            onEnter: (_) => _onHoverChange(true),
            onHover: (_) => _onHoverChange(true),
            onExit: (_) => _onHoverChange(false),
            child: const SizedBox.expand(),
          ),
        ),
        // 拖动中的轨道细竖线（贴右缘命中带中线）。
        if (_dragging)
          Positioned(
            top: 0,
            bottom: 0,
            right: widget.hitBandWidth / 2 - 1,
            width: 2,
            child: CustomPaint(painter: _TrackPainter(lineColor: trackColor)),
          ),
        // 附加浮层（导轨目录浮层）。
        // ⚠️ 必须排在拇指与拖动命中层**之下**：浮层由调用方用 IgnorePointer
        // 关闭命中，但若叠在拇指之上，会把「快速定位条」整条遮住（拖动态看不到
        // 拇指位置，也无法继续拖动）。
        if (widget.overlayBuilder != null)
          Positioned.fill(
            child: widget.overlayBuilder!(context, trackExtent),
          ),
        // 拇指：淡入淡出 + 命中态保持显示。
        Positioned(
          top: thumbTop,
          right: widget.thumbEdgeGap,
          width: widget.thumbWidth,
          height: thumbExtent,
          child: FadeTransition(
            key: widget.thumbFadeKey,
            opacity: _fade,
            child: IgnorePointer(
              child: NarrChatScrollThumb(
                dragging: _dragging,
                glyph: widget.thumbGlyph,
              ),
            ),
          ),
        ),
        // 拇指拖动命中矩形（透明，仅捕获指针）。
        Positioned(
          top: hitTop,
          right:
              widget.thumbEdgeGap -
              (kScrollbarThumbHitWidth - widget.thumbWidth) / 2,
          width: kScrollbarThumbHitWidth,
          height: hitHeight,
          child: Listener(
            key: widget.stripKey,
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: MouseRegion(
              onEnter: (_) => _onHoverChange(true),
              onHover: (_) => _onHoverChange(true),
              onExit: (_) => _onHoverChange(false),
              child: widget.touchStrip
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragStart: _onTouchDragStart,
                      onVerticalDragUpdate: _onTouchDragUpdate,
                      onVerticalDragEnd: (_) => _endDrag(),
                      onVerticalDragCancel: _endDrag,
                    )
                  : const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }
}

/// 全局默认滚动行为：用自绘 [NarrChatScrollbar] 替换 Flutter 原生 `Scrollbar`。
///
/// 与默认 [MaterialScrollBehavior] 的差异**仅限滚动条**：
/// - 纵向 + 桌面平台（Windows / Linux / macOS）→ 叠加 [NarrChatScrollbar]；
/// - 横向 → 保持默认（原生不加滚动条；需要横向滚动条处继续显式使用 `Scrollbar`）；
/// - 触屏平台（Android / iOS / Fuchsia）→ 保持默认（不加滚动条；快速定位导轨等
///   触屏交互不受影响）。
///
/// overscroll 指示器行为不覆写（完全沿用 [MaterialScrollBehavior]）。
class NarrChatScrollBehavior extends MaterialScrollBehavior {
  const NarrChatScrollBehavior();

  /// 指定平台 / 轴向下，是否由 [NarrChatScrollbar] 接管滚动条。
  static bool shouldShowScrollbar({
    required AxisDirection direction,
    required TargetPlatform platform,
  }) {
    if (axisDirectionToAxis(direction) != Axis.vertical) return false;
    return switch (platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      TargetPlatform.android ||
      TargetPlatform.fuchsia ||
      TargetPlatform.iOS => false,
    };
  }

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final platform = getPlatform(context);
    if (!NarrChatScrollBehavior.shouldShowScrollbar(
      direction: details.direction,
      platform: platform,
    )) {
      return super.buildScrollbar(context, child, details);
    }
    final controller = details.controller;
    // 防御：拿不到控制器时退回默认行为（不抛断言）。
    if (controller == null) return child;
    return NarrChatScrollbar(controller: controller, scrollable: child);
  }
}
