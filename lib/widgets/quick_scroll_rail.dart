import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

/// 快速定位滚动锚点注册器（由宿主 State 持有，随生命周期释放）。
///
/// 为每个唯一路径生成**同一实例**的 [GlobalKey]，目录条目与内容锚点
/// 透过本注册器共享 key——注意 [GlobalObjectKey] 以 `identical` 比较，
/// 运行时拼出的相同字符串并不是同一实例，不能跨处共享。
class TocAnchorRegistry {
  final Map<String, GlobalKey> _keys = {};

  /// 取（或创建）指定路径的稳定锚点 key；同路径跨重建返回同一实例。
  GlobalKey keyFor(String path) =>
      _keys.putIfAbsent(path, GlobalKey.new);

  /// 指定路径锚点在当前元素树中的 context；锚点尚未挂载时返回 null。
  BuildContext? contextOf(String path) => _keys[path]?.currentContext;
}

/// 快速定位滚动条目。
///
/// [offsetResolver] 在需要时懒解析「该条目对齐到视口顶」的滚动偏移；
/// 返回 null 表示锚点当前不存在（组件会在布局与当前条目判定中跳过该条目）。
class QuickScrollEntry {
  QuickScrollEntry({
    required this.id,
    required this.label,
    this.level = 0,
    required this.offsetResolver,
  });

  /// 稳定标识（仅用于测试/日志，不做比较语义）。
  final Object id;

  /// 目录标题（单行，超出限宽省略号）。
  final String label;

  /// 层级：用于标题左侧缩进（每级 [QuickScrollRail.levelIndent] px）。
  final int level;

  /// 该条目对齐视口顶时的滚动偏移；锚点不存在时返回 null。
  final double? Function() offsetResolver;
}

/// 快速定位滚动导轨（WPS 手机端式边缘快速定位，全局可复用组件）。
///
/// 用法：把目标滚动视图作为 [scrollable] 传入并共享 [controller]：
///
/// ```dart
/// QuickScrollRail(
///   controller: scrollController,
///   entries: entries,
///   scrollable: CustomScrollView(controller: scrollController, slivers: ...),
/// )
/// ```
///
/// 行为约定（对齐 WPS 手机端体验）：
/// - 滚动内容时淡入显示圆形阴影拇指（自带上下三角箭头图案），空闲
///   [QuickScrollRail.idleDelay] 后淡出；桌面端鼠标悬停右缘时保持显示；
/// - 按住导轨任意位置拖动 → 右缘向左展开「[panelColor] 纯色 → 透明」的水平
///   渐变浮层，目录标题沿轨道按文档位置堆叠、随拖动整体移动，**当前标题
///   垂直对齐拇指中心**；上下到达边缘的标题渐变淡出；
/// - 仅拖动过程中连续滚动（jumpTo 跟手）；松手后目录浮层立即消失；
/// - 内容未溢出（maxScrollExtent <= 0）时整体不渲染；
/// - 内部自动以 [ScrollConfiguration.copyWith] 禁用目标滚动视图的原生
///   滚动条（本导轨承担滚动定位职责），其它位置的滚动条不受影响。
///
/// 触控与鼠标拖动两条路径：触控经手势竞技场（与抽屉横滑等横向手势竞争，
/// 垂直意图由导轨获胜）；鼠标/触控板走原始指针事件（无需滑动手势阈值）。
class QuickScrollRail extends StatefulWidget {
  const QuickScrollRail({
    super.key,
    required this.controller,
    required this.entries,
    required this.scrollable,
    this.panelColor,
    this.labelMaxWidthRatio = 0.7,
  });

  /// 目标滚动视图的控制器。
  final ScrollController controller;

  /// 目录条目（按文档顺序给出；内部按解析出的偏移排序）。
  final List<QuickScrollEntry> entries;

  /// 被包裹的滚动视图（本组件会禁用其原生滚动条）。
  final Widget scrollable;

  /// 浮层渐变底色（左透明 → 右 [panelColor]）。
  /// 默认取 [NarrChatColors.surface]（经 `context.narrColors`），亮色即纯白。
  final Color? panelColor;

  /// 标题最大宽度 = 屏幕宽度 × 此比例，再受宿主宽度约束钳制。
  final double labelMaxWidthRatio;

  /// 导轨命中区宽度（触控友好）。
  static const double hitWidth = 28;

  /// 拇指宽度。
  static const double thumbWidth = 10;

  /// 拇指与右缘间距。
  static const double thumbEdgeGap = 4;

  /// 拇指最小高度。
  static const double thumbMinHeight = 64;

  /// 目录行高。
  static const double labelRowHeight = 22;

  /// 目录层级缩进（每级）。
  static const double levelIndent = 12;

  /// 标题上下边缘淡出高度。
  static const double edgeFadeHeight = 24;

  /// 空闲淡出延时。
  static const Duration idleDelay = Duration(milliseconds: 700);

  /// 拇指显隐动画时长。
  static const Duration fadeDuration = Duration(milliseconds: 120);

  /// 目录浮层淡入时长（隐藏为立即消失，见行为约定）。
  static const Duration overlayInDuration = Duration(milliseconds: 120);

  /// 根据锚点 [BuildContext] 求「对齐到视口顶」的滚动偏移；不可用时返回 null。
  ///
  /// 适用于非虚拟化场景（侧栏等全量布局）：锚点挂 [GlobalObjectKey] 后，
  /// 由 `offsetResolver` 闭包调用此方法懒解析，天然跟随内容的展开/收起。
  static double? revealOffsetOf(BuildContext? anchorContext) {
    if (anchorContext == null) return null;
    final ro = anchorContext.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return null;
    final vp = RenderAbstractViewport.of(ro);
    return vp.getOffsetToReveal(ro, 0.0).offset;
  }

  @override
  State<QuickScrollRail> createState() => _QuickScrollRailState();
}

class _QuickScrollRailState extends State<QuickScrollRail>
    with TickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: QuickScrollRail.fadeDuration,
    value: 0,
  );

  /// 目录浮层淡入控制器（隐藏为立即置 0，见行为约定）。
  late final AnimationController _overlayFade = AnimationController(
    vsync: this,
    duration: QuickScrollRail.overlayInDuration,
    value: 0,
  );
  Timer? _idleTimer;

  /// 桌面端鼠标是否悬停在导轨命中区（悬停期间不淡出）。
  bool _hovered = false;

  /// 是否处于拖动定位中（目录浮层随拖动显示）。
  bool _dragging = false;

  /// 当前指针的设备类型（区分鼠标原始事件与触控手势）。
  PointerDeviceKind? _downKind;

  /// 鼠标/触控板拖动中的原始指针 id。
  int _pointerId = -1;

  /// 拖动中的指针/手势位置（导轨局部坐标 dy 有效）。
  Offset? _dragPosition;

  ScrollPosition? get _position =>
      widget.controller.hasClients ? widget.controller.position : null;

  @override
  void dispose() {
    _idleTimer?.cancel();
    _fade.dispose();
    _overlayFade.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 显隐状态机
  // ---------------------------------------------------------------------------

  bool _onScrollNotification(ScrollNotification notification) {
    // 只响应本导轨直接包裹的滚动视图（depth 0）。
    if (notification.depth == 0) {
      _showThumb();
    }
    return false;
  }

  void _showThumb() {
    _idleTimer?.cancel();
    if (_fade.value < 1) _fade.forward();
    _idleTimer = Timer(QuickScrollRail.idleDelay, () {
      if (mounted && !_dragging && !_hovered) _fade.reverse();
    });
  }

  void _onHoverChange(bool hovering) {
    if (_hovered == hovering) return;
    setState(() => _hovered = hovering);
    if (hovering) {
      _showThumb();
    } else {
      _idleTimer?.cancel();
      _idleTimer = Timer(QuickScrollRail.idleDelay, () {
        if (mounted && !_dragging && !_hovered) _fade.reverse();
      });
    }
  }

  // ---------------------------------------------------------------------------
  // 拖动定位
  // ---------------------------------------------------------------------------

  /// 仅鼠标/触控板由原始指针拖动（无需等待手势阈值）。
  void _onPointerDown(PointerDownEvent event) {
    _downKind = event.kind;
    if (event.kind != PointerDeviceKind.mouse &&
        event.kind != PointerDeviceKind.trackpad) {
      return;
    }
    _pointerId = event.pointer;
    _dragPosition = event.localPosition;
    // 按下即进入拖动态（浮层随之出现），但未移动前不跳转——
    // 纯单击（无位移）不改变滚动位置（轨道的定位仅由拖动触发）。
    _beginDrag(applyPosition: false);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointerId || !_dragging) return;
    _dragPosition = event.localPosition;
    _applyDrag();
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointerId) return;
    _endDrag();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointerId) return;
    _endDrag();
  }

  /// 触控手势路径：垂直拖动在竞技场中与抽屉横滑等横向手势竞争。
  void _onTouchDragStart(DragStartDetails details) {
    if (_downKind != PointerDeviceKind.touch) return;
    _dragPosition = details.localPosition;
    // 手势已滑过阈值才开始 → 移动已发生，按下即按位移定位。
    _beginDrag(applyPosition: true);
  }

  void _onTouchDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _dragPosition = details.localPosition;
    _applyDrag();
  }

  void _beginDrag({required bool applyPosition}) {
    if (_dragging) return;
    _idleTimer?.cancel();
    setState(() => _dragging = true);
    _fade.forward();
    _overlayFade.forward();
    if (applyPosition) _applyDrag();
  }

  void _applyDrag() {
    final pos = _position;
    final local = _dragPosition;
    if (pos == null || local == null) return;
    final trackH = context.size?.height ?? 0;
    if (trackH <= 0) return;
    final thumbH = _thumbHeight(trackH, pos);
    if (trackH - thumbH <= 0) return;
    final frac = ((local.dy - thumbH / 2) / (trackH - thumbH)).clamp(0.0, 1.0);
    final target = (frac * pos.maxScrollExtent)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((pos.pixels - target).abs() > 0.5) {
      pos.jumpTo(target);
    }
  }

  void _endDrag() {
    if (!_dragging) return;
    _pointerId = -1;
    _downKind = null;
    // 目录浮层立即消失（无淡出）；拇指走空闲淡出。
    _overlayFade.value = 0;
    setState(() {
      _dragging = false;
      _dragPosition = null;
    });
    _idleTimer?.cancel();
    _idleTimer = Timer(QuickScrollRail.idleDelay, () {
      if (mounted && !_dragging && !_hovered) _fade.reverse();
    });
  }

  // ---------------------------------------------------------------------------
  // 几何
  // ---------------------------------------------------------------------------

  double _thumbHeight(double trackH, ScrollPosition pos) {
    final content = pos.maxScrollExtent + pos.viewportDimension;
    if (content <= 0) return 0;
    final frac = pos.viewportDimension / content;
    return math
        .min(math.max(trackH * frac, QuickScrollRail.thumbMinHeight), trackH);
  }

  /// 计算滚动偏移 → 轨道的比例映射（与原生滚动条同语义：拇指中心 ↔ 偏移）。

  /// 解析并排序条目偏移；[offsetResolver] 返回 null 的条目被跳过。
  List<(QuickScrollEntry, double)> _resolveSorted() {
    final resolved = <(QuickScrollEntry, double)>[];
    for (final e in widget.entries) {
      final o = e.offsetResolver();
      if (o != null && o.isFinite) resolved.add((e, o));
    }
    resolved.sort((a, b) {
      final c = a.$2.compareTo(b.$2);
      // 相同偏移时保持参数顺序（Dart 的 List.sort 不稳定）。
      return c != 0 ? c : widget.entries.indexOf(a.$1) - widget.entries.indexOf(b.$1);
    });
    return resolved;
  }

  /// 单帧的目录行布局（供浮层与轨道点共用）。
  ///
  /// WPS 式「目录列表」：全部节点按固定行高排成一张列表，**当前条目行
  /// 恒对齐拇指中心**，其余行以 ± 行高在其上下排开；列表随当前条目整体
  /// 平移（拖动时与拇指联动），溢出屏幕的行由上下边缘渐变淡出。
  /// 不按文档比例散布（条目多与少都同样是一整列，无密集模式兜底）。
  List<_RowLayout> _computeRows({
    required List<(QuickScrollEntry, double)> resolved,
    required double trackH,
    required double thumbH,
    required double maxExtent,
    required double pixels,
  }) {
    if (resolved.isEmpty) return const [];
    // 锚点偏移先钳制到可滚动范围：文档末尾锚点无法「对齐视口顶」滚动
    // （reveal 偏移可超过 maxExtent），按 maxExtent 折叠后与拇指几何一致。
    double clampO(double o) => math.min(o, maxExtent);
    // 当前条目：最后一个「钳制后对齐偏移 <= 视口偏移」的条目（视口顶语义）。
    var currentIdx = 0;
    for (var i = 0; i < resolved.length; i++) {
      if (clampO(resolved[i].$2) <= pixels + 4) currentIdx = i;
    }
    final thumbCenter = thumbH / 2 +
        (trackH - thumbH > 0 && maxExtent > 0
            ? (pixels / maxExtent).clamp(0.0, 1.0) * (trackH - thumbH)
            : 0.0);
    final rowH = QuickScrollRail.labelRowHeight;
    return [
      for (var i = 0; i < resolved.length; i++)
        _RowLayout(
          entry: resolved[i].$1,
          offset: resolved[i].$2,
          y: thumbCenter + (i - currentIdx) * rowH,
          isCurrent: i == currentIdx,
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: widget.scrollable,
          ),
        ),
        if (widget.entries.isNotEmpty)
          Positioned.fill(
            child: AnimatedBuilder(
              animation: Listenable.merge(
                [widget.controller, _fade, _overlayFade],
              ),
              builder: (context, _) => LayoutBuilder(
                builder: (context, constraints) {
                  final pos = _position;
                  if (pos == null ||
                      pos.maxScrollExtent <= 0 ||
                      constraints.maxHeight <= 0) {
                    return const SizedBox.shrink();
                  }
                  return _buildRailContent(
                    context,
                    trackH: constraints.maxHeight,
                    hostW: constraints.maxWidth,
                    pos: pos,
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRailContent(
    BuildContext context, {
    required double trackH,
    required double hostW,
    required ScrollPosition pos,
  }) {
    final thumbH = _thumbHeight(trackH, pos);
    // 拇指位置随滚动像素钳制（防御：pixels 可能瞬时越界）。
    final pixelsFrac = pos.maxScrollExtent > 0
        ? (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0)
        : 0.0;
    final thumbTop = (trackH - thumbH) * pixelsFrac;
    final resolved = _resolveSorted();
    final rows = _computeRows(
      resolved: resolved,
      trackH: trackH,
      thumbH: thumbH,
      maxExtent: pos.maxScrollExtent,
      pixels: pos.pixels,
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 目录浮层：右缘向左的水平渐变 + 沿轨道的标题堆叠（仅拖动时存在；
        // 松手立即移除，不常驻树中——避免给宿主页面带来无谓的文本节点）。
        if (_dragging || _overlayFade.value > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: FadeTransition(
                key: const Key('quick_scroll_rail_overlay'),
                opacity: _overlayFade,
                child: _buildOverlay(
                  context,
                  hostW: hostW,
                  trackH: trackH,
                  rows: rows,
                ),
              ),
            ),
          ),
        // 右缘导轨命中区。
        Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: QuickScrollRail.hitWidth,
            height: trackH,
            child: MouseRegion(
              onEnter: (_) => _onHoverChange(true),
              onExit: (_) => _onHoverChange(false),
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerCancel,
                child: GestureDetector(
                  key: const Key('quick_scroll_rail_strip'),
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: _onTouchDragStart,
                  onVerticalDragUpdate: _onTouchDragUpdate,
                  onVerticalDragEnd: (_) => _endDrag(),
                  onVerticalDragCancel: _endDrag,
                  child: Stack(
                    children: [
                      // 轨道（仅拖动时）：细竖线。
                      if (_dragging && rows.isNotEmpty)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _TrackPainter(
                              lineColor: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant
                                  .withValues(alpha: 0.5),
                              trackH: trackH,
                            ),
                          ),
                        ),
                      // 拇指：圆角胶囊 + 阴影 + 上下三角 + 中心圆点。
                      Positioned(
                        top: thumbTop,
                        right: QuickScrollRail.thumbEdgeGap,
                        width: QuickScrollRail.thumbWidth,
                        height: thumbH,
                        child: FadeTransition(
                          key: const Key('quick_scroll_rail_thumb_fade'),
                          opacity: _fade,
                          child: _RailThumb(dragging: _dragging),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOverlay(
    BuildContext context, {
    required double hostW,
    required double trackH,
    required List<_RowLayout> rows,
  }) {
    final panelColor =
        widget.panelColor ?? Theme.of(context).colorScheme.surface;
    final screenW = MediaQuery.sizeOf(context).width;
    final maxLabelW = screenW * widget.labelMaxWidthRatio;
    // 标题行左边界：文本可用宽度 = min(屏宽×比例, 宿主宽) − 右缘留白，
    // 超出限宽单行省略（限宽默认屏宽 70%）。
    final rowLeft = math.max(0.0, hostW - maxLabelW);
    final visibleRows = [
      for (final r in rows)
        if (r.y >= -QuickScrollRail.labelRowHeight &&
            r.y <= trackH + QuickScrollRail.labelRowHeight)
          r,
    ];

    return ClipRect(
      child: Stack(
        children: [
            // 右（纯白）→ 左（透明）水平渐变底。
            Positioned.fill(
              child: DecoratedBox(
                key: const Key('quick_scroll_rail_gradient'),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      panelColor.withValues(alpha: 0),
                      panelColor.withValues(alpha: 1),
                    ],
                  ),
                ),
              ),
            ),
            // 标题行：上下边缘垂直渐隐（到面板边缘淡出）。
            // ⚠️ 必须用 dstIn：只按蒙版「透明度」调制子内容；srcIn 会把
            // 子内容整体着色成蒙版颜色（白色）→ 白色面板上文字不可见。
            Positioned.fill(
              child: ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.white,
                    Colors.white,
                    Colors.transparent,
                  ],
                  stops: [0.0, 0.05, 0.95, 1.0],
                ).createShader(
                  Rect.fromLTWH(
                    0,
                    0,
                    bounds.width,
                    bounds.height,
                  ),
                ),
                blendMode: BlendMode.dstIn,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final r in visibleRows)
                      _buildLabelRow(context, r, rowLeft),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLabelRow(BuildContext context, _RowLayout row, double rowLeft) {
    final scheme = Theme.of(context).colorScheme;
    final labelColor = row.isCurrent
        ? Theme.of(context).colorScheme.onSurface
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final opacity = row.isCurrent ? 1.0 : 0.75;
    final rowRight = QuickScrollRail.hitWidth / 2 +
        6 +
        row.entry.level * QuickScrollRail.levelIndent;

    return Positioned(
      top: row.y - QuickScrollRail.labelRowHeight / 2,
      right: rowRight,
      left: rowLeft,
      height: QuickScrollRail.labelRowHeight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              row.entry.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                // 当前条目略放大加粗（对齐图 2「当前标题醒目、贴近拇指」）。
                fontSize: row.isCurrent ? 13.5 : 12,
                fontWeight: row.isCurrent ? FontWeight.w700 : FontWeight.w400,
                color: labelColor.withValues(alpha: opacity),
              ),
            ),
          ),
          // 连接刻度线（连接标题与轨道点）。
          Padding(
            padding: const EdgeInsets.only(left: 6, right: 2),
            child: Container(
              width: 12,
              height: 2,
              color: scheme.outlineVariant.withValues(
                alpha: row.isCurrent ? 0.9 : 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单帧目录行布局结果。
class _RowLayout {
  const _RowLayout({
    required this.entry,
    required this.offset,
    required this.y,
    required this.isCurrent,
  });

  final QuickScrollEntry entry;
  final double offset;
  final double y;
  final bool isCurrent;
}

/// 轨道绘制（仅拖动时）：细竖线，衬托行刻度与拇指。
class _TrackPainter extends CustomPainter {
  const _TrackPainter({required this.lineColor, required this.trackH});

  final Color lineColor;
  final double trackH;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final line = Paint()
      ..color = lineColor
      ..strokeWidth = 2;
    canvas.drawLine(Offset(cx, 0), Offset(cx, trackH), line);
  }

  @override
  bool shouldRepaint(covariant _TrackPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor || oldDelegate.trackH != trackH;
  }
}

/// 拇指：圆角胶囊 + 阴影 + 上下三角箭头 + 中心圆点。
class _RailThumb extends StatelessWidget {
  const _RailThumb({required this.dragging});

  final bool dragging;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = dragging
        ? scheme.primary
        : (Theme.of(context).scrollbarTheme.thumbColor?.resolve({}) ??
            scheme.onSurfaceVariant);
    return Container(
      key: const Key('quick_scroll_rail_thumb'),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(QuickScrollRail.thumbWidth / 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: CustomPaint(
        painter: _ThumbGlyphPainter(glyphColor: Colors.white),
      ),
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
