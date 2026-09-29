import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// 常量：驻场岛嵌入顶栏的尺寸与断点（唯一来源，供统一顶栏与岛共用）
// ---------------------------------------------------------------------------

/// 嵌入断点：顶栏宽度窄于此值时，改为「向下多出一行」放岛。
const double kIslandEmbedBreakpoint = 760;

/// 顶栏附加行高（窄屏 / 宽度预算不足时）。
const double kIslandRowHeight = 28;

/// 收起态胶囊高度（嵌入顶栏时）。
const double kIslandPillHeight = 28;

/// 岛的最小可用宽度：预算低于此值即改走附加行。
const double kIslandMinWidth = 140;

/// 岛最多占顶栏宽的比例（左右按钮不对称时的兜底上限）。
const double kIslandMaxBarFraction = 0.42;

/// 标题保底宽度基准（约 8 个汉字宽；实际按全局字号缩放）。
const double kIslandTitleMinWidth = 88;

/// 岛与标题、岛与两侧按钮之间的最小间距。
const double kIslandTitleGap = 12;

/// 展开态槽位收缩后的小标记尺寸（点击可把岛收回顶栏）。
const double kIslandMarkerSize = 24;

/// 顶栏高度动画时长（附加行拉出 / 收回）。
const Duration kIslandRowDuration = Duration(milliseconds: 200);

/// 驻场岛「嵌入顶栏 / 脱离悬浮」的协作控制器。
///
/// 由 `AppNoticeOverlay` 创建并挂在作用域里（[IslandBarScope]）：
/// - **顶栏侧**（`NarrChatAppBar`）把「岛该待在哪个矩形」通过 [slotRect] 发布出去
///   （槽位是不可见占位框，岛本体由应用级 overlay 画在同一位置）；
/// - **岛侧**（`PinnedNoticeIsland`）汇报「有无内容 / 是否已展开」，并按 [slotRect]
///   决定嵌入顶栏还是脱离成悬浮卡片；
/// - **页面侧**（[IslandAwareScaffold]）只订阅 [extraRowHeight] 逐帧重建脚手架，
///   让顶栏高度平滑地拉出 / 收回附加行（body 作为 child 不参与重建）。
class IslandBarController {
  IslandBarController({required TickerProvider vsync})
      : _row = AnimationController(vsync: vsync, duration: kIslandRowDuration) {
    _row.addListener(() {
      extraRowHeight.value = _row.value * kIslandRowHeight;
    });
  }

  final AnimationController _row;

  /// 顶栏附加行当前高度（0 ~ [kIslandRowHeight]），逐帧变化。
  final ValueNotifier<double> extraRowHeight = ValueNotifier<double>(0);

  /// 岛当前是否有内容（由岛汇报；统一顶栏据此决定是否占槽位）。
  final ValueNotifier<bool> islandActive = ValueNotifier<bool>(false);

  /// 岛是否已展开并从顶栏脱离（由岛汇报；统一顶栏据此把槽位收缩为小标记）。
  final ValueNotifier<bool> islandExpanded = ValueNotifier<bool>(false);

  /// 岛收起时应处的矩形（全局坐标）；无顶栏槽位的页面为 null（岛回退为悬浮）。
  final ValueNotifier<Rect?> slotRect = ValueNotifier<Rect?>(null);

  /// 当前顶栏的矩形（全局坐标）：岛展开时据此把悬浮卡片放在顶栏下方。
  final ValueNotifier<Rect?> barRect = ValueNotifier<Rect?>(null);

  bool _active = false;
  bool _twoRow = false;
  bool _disposed = false;

  /// 是否处于「顶栏向下多一行」形态（由统一顶栏按宽度预算汇报）。
  bool get twoRow => _twoRow;

  /// 岛汇报「有无内容」。
  void setIslandActive(bool value) {
    if (_disposed || islandActive.value == value) return;
    _active = value;
    islandActive.value = value;
    _syncRow();
  }

  /// 岛汇报「是否已展开（脱离）」。
  void setIslandExpanded(bool value) {
    if (_disposed || islandExpanded.value == value) return;
    islandExpanded.value = value;
  }

  /// 顶栏汇报「是否走附加行形态」（按当前宽度预算判定）。
  void setTwoRow(bool value) {
    if (_disposed || _twoRow == value) return;
    _twoRow = value;
    _syncRow();
  }

  /// 槽位测量结果（不可见占位框的全局矩形）。
  ///
  /// 槽位的清空是「帧后」投递的：页面销毁 / 应用退出时可能晚于本控制器销毁，
  /// 因此必须用 [_disposed] 兜住，否则会命中「已释放的 ValueNotifier」断言。
  void publishSlotRect(Rect? rect) {
    if (_disposed || slotRect.value == rect) return;
    slotRect.value = rect;
  }

  /// 顶栏测量结果（统一顶栏每帧后汇报；用于悬浮位置贴住顶栏下缘）。
  void publishBarRect(Rect? rect) {
    if (_disposed || barRect.value == rect) return;
    barRect.value = rect;
  }

  /// 按「有内容 + 需要附加行」驱动附加行高度动画。
  void _syncRow() {
    if (_active && _twoRow) {
      _row.forward();
    } else {
      _row.reverse();
    }
  }

  void dispose() {
    _disposed = true;
    _row.dispose();
    extraRowHeight.dispose();
    islandActive.dispose();
    islandExpanded.dispose();
    slotRect.dispose();
    barRect.dispose();
  }
}

/// 把 [IslandBarController] 交给页面子树（统一顶栏 / 感知脚手架读取）。
class IslandBarScope extends InheritedWidget {
  const IslandBarScope({
    super.key,
    required this.controller,
    required super.child,
  });

  /// 当前作用域内的控制器；无岛宿主（如独立查看器窗口）时为 null。
  final IslandBarController? controller;

  static IslandBarController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<IslandBarScope>()?.controller;

  @override
  bool updateShouldNotify(IslandBarScope oldWidget) =>
      oldWidget.controller != controller;
}

/// 不可见槽位：只负责把自身矩形发布给岛（岛由应用级 overlay 画在同一位置）。
///
/// 宽度由统一顶栏按预算算出（展开态收缩为小标记尺寸），因此它同时决定
/// 「标题被挤压多少」与「岛 / 标记画在哪」。
class IslandSlot extends StatefulWidget {
  const IslandSlot({super.key, required this.width, required this.height});

  final double width;
  final double height;

  @override
  State<IslandSlot> createState() => _IslandSlotState();
}

class _IslandSlotState extends State<IslandSlot> {
  final GlobalKey _key = GlobalKey();
  IslandBarController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = IslandBarScope.maybeOf(context);
    _schedulePublish();
  }

  @override
  void didUpdateWidget(covariant IslandSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _schedulePublish();
    }
  }

  @override
  void dispose() {
    // 槽位随页面销毁：清掉发布过的矩形（帧后执行，避免在 build 期触发重建），
    // 岛据此回退为顶部悬浮。
    final controller = _controller;
    if (controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.publishSlotRect(null);
      });
    }
    super.dispose();
  }

  void _schedulePublish() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      _controller?.publishSlotRect(box.localToGlobal(Offset.zero) & box.size);
    });
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(key: _key, width: widget.width, height: widget.height);
}

/// 感知驻场岛的页面脚手架：只有顶栏随「附加行高度」逐帧重建。
///
/// [appBarBuilder] 收到当前附加行高度（0 ~ [kIslandRowHeight]；0 表示单行形态），
/// 交给统一顶栏 `NarrChatAppBar`；[body] 作为 `child` 传入，不随高度动画重建。
class IslandAwareScaffold extends StatelessWidget {
  const IslandAwareScaffold({
    super.key,
    required this.appBarBuilder,
    required this.body,
    this.backgroundColor,
    this.resizeToAvoidBottomInset,
  });

  final PreferredSizeWidget Function(
    BuildContext context,
    double extraRowHeight,
  ) appBarBuilder;
  final Widget body;
  final Color? backgroundColor;
  final bool? resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    final controller = IslandBarScope.maybeOf(context);
    if (controller == null) {
      // 无岛宿主（独立窗口等）：退化为普通 Scaffold。
      return Scaffold(
        backgroundColor: backgroundColor,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        appBar: appBarBuilder(context, 0),
        body: body,
      );
    }
    return ValueListenableBuilder<double>(
      valueListenable: controller.extraRowHeight,
      builder: (context, extra, child) => Scaffold(
        backgroundColor: backgroundColor,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        appBar: appBarBuilder(context, extra),
        body: child,
      ),
      child: body,
    );
  }
}
