import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_locator.dart';
import 'chat_rail_handle.dart';
import 'chat_rail_motion.dart';

/// 对话页右侧的**小滑块**定位器：一颗居中的滑块 + 点开后的五个独立部件。
///
/// 为什么不是滚动条：滚动条拇指要"长度表示视口占比、位置表示进度"，在窗口化列表
/// 里这两个数只能来自几何模型，稍一变窗就跳；而用户要的是**上下拖动**就能翻页。
/// 所以这里做成一颗固定在垂直中央的小滑块：
/// - 拖动时滑块**跟着手指走**（限制在 [knobMaxTravel] 内），松手弹回中央；
/// - 滚动速度只跟"离中央多远"有关（速度驱动，不是位置映射）；
/// - 不做进度条：进度由中间胶囊的"当前轮 / 最大轮号"直接读。
///
/// 展开后是**五个各自独立**的部件（规格 §7.3 的形态），不是一个面板包住五个：
/// 4 个圆形按钮 + 1 个加宽的胶囊，间距 8dp，纵向居中。
class ChatRail extends StatefulWidget {
  const ChatRail({
    super.key,
    required this.locator,
    this.handle,
    this.isTouchPlatform,
    this.motion = const ChatRailMotion(),
  });

  /// 定位门面（跳转 / 速度 / 最大轮号 / 可见比例）。所有数字都向它要。
  final ChatLocator locator;

  /// 展开 / 收起的外部开关（点消息区收起、Esc 收起用）。不传则轨道自己管。
  final ChatRailHandle? handle;

  /// 是否触屏平台（决定内缩与透明度）；null = 按平台推断。
  final bool? isTouchPlatform;

  final ChatRailMotion motion;

  /// 滑块视觉宽度（拖动时用 [knobDraggingWidth]）：比滚动条拇指粗得多，
  /// 一眼能看出"这是个可以抓住的把手"。
  static const double knobWidth = 14;
  static const double knobDraggingWidth = 16;

  /// 滑块高度（圆角胶囊）。
  static const double knobHeight = 48;

  /// 滑块相对中央的上下行程；也是速度模型的满量程。
  static const double knobMaxTravel = 120;

  /// 拖动的死区（像素）：手抖这几像素不该让内容动。
  static const double knobDeadZone = 6;

  /// 交互命中带宽（透明）：滑块在中央，所以整条右缘都能按下开始拖。
  static const double hitWidth = 32;

  /// 轨道右侧内缩：桌面避开窗口边缘、触控避开系统返回手势。
  static const double gutterDesktop = 8;
  static const double gutterTouch = 20;

  /// 部件与命中带之间的间隙。
  static const double panelGap = 8;

  /// 圆形按钮直径。
  static const double itemHeight = 40;

  /// 中间胶囊尺寸（比按钮宽，页码才放得开）。
  static const double capsuleWidth = 120;
  static const double capsuleHeight = 44;

  /// 运行时占用的右侧总宽度（内缩 + 命中带 + 间隙 + 最宽的胶囊）。
  static const double reservedFromRight = gutterTouch + hitWidth;
  static const double reservedWidth =
      gutterTouch + hitWidth + panelGap + capsuleWidth;

  /// 五个部件堆叠后的总高：4 个按钮 + 1 个胶囊 + 4 个间距。
  static const double panelHeight = itemHeight * 4 + capsuleHeight + 8 * 4;

  /// 滑块命中区（测试与手势用它定位）。
  static const Key trackKey = ValueKey('chat-rail-track');

  /// 滑块本体（测试用它量位置 / 位移）。
  static const Key knobKey = ValueKey('chat-rail-knob');

  /// 面板划出 / 收起的时长、松手回中的时长。
  static const Duration expandDuration = Duration(milliseconds: 200);
  static const Duration collapseDuration = Duration(milliseconds: 160);
  static const Duration snapBackDuration = Duration(milliseconds: 180);

  /// 静止淡出的延迟与时长（仅触控）。
  static const Duration dimDelay = Duration(seconds: 2);
  static const Duration dimDuration = Duration(milliseconds: 600);

  @override
  State<ChatRail> createState() => _ChatRailState();
}

class _ChatRailState extends State<ChatRail> with TickerProviderStateMixin {
  /// 展开状态（外部可驱动）。
  late final ChatRailHandle _handle = widget.handle ?? ChatRailHandle();

  bool get _ownsHandle => widget.handle == null;

  /// 面板淡入淡出。
  late final AnimationController _panelController = AnimationController(
    vsync: this,
    duration: ChatRail.expandDuration,
    reverseDuration: ChatRail.collapseDuration,
  );

  /// 松手后滑块回中。
  late final AnimationController _snapController = AnimationController(
    vsync: this,
    duration: ChatRail.snapBackDuration,
  );

  /// 滑块相对中央的位移（正值 = 往下）。
  double _knobOffset = 0;
  double _dragStartY = 0;
  double _dragStartOffset = 0;
  bool _dragging = false;
  bool _hovering = false;
  bool _active = false;
  bool _editing = false;

  /// 拖动中显示的浮动胶囊。
  bool _floatingCapsule = false;

  Timer? _dimTimer;
  Timer? _floatTimer;

  final TextEditingController _jumpController = TextEditingController();
  final FocusNode _jumpFocus = FocusNode();

  bool get _isTouch => widget.isTouchPlatform ?? _platformIsTouch;

  bool get _platformIsTouch {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      default:
        return false;
    }
  }

  double get _gutter =>
      _isTouch ? ChatRail.gutterTouch : ChatRail.gutterDesktop;

  bool get _expanded => _handle.expanded;

  int get _maxRound => widget.locator.maxRoundIndex ?? 0;

  int get _currentRound => widget.locator.currentRoundIndex ?? 1;

  @override
  void initState() {
    super.initState();
    widget.locator.addListener(_onLocatorChanged);
    _handle.addListener(_onHandleChanged);
    _snapController.addListener(_onSnapTick);
    // 外部注入的 handle 可能已经是展开态（热重载 / 外部预置），对齐动画初值。
    _panelController.value = _expanded ? 1 : 0;
    _scheduleDim();
  }

  @override
  void didUpdateWidget(covariant ChatRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locator != widget.locator) {
      oldWidget.locator.removeListener(_onLocatorChanged);
      widget.locator.addListener(_onLocatorChanged);
    }
    if (oldWidget.handle != widget.handle) {
      if (_ownsHandle) _handle.removeListener(_onHandleChanged);
      if (oldWidget.handle != null) {
        oldWidget.handle!.removeListener(_onHandleChanged);
      }
      if (widget.handle != null) widget.handle!.addListener(_onHandleChanged);
    }
  }

  @override
  void dispose() {
    widget.locator.removeListener(_onLocatorChanged);
    if (widget.handle != null) widget.handle!.removeListener(_onHandleChanged);
    if (_ownsHandle) _handle.dispose();
    _dimTimer?.cancel();
    _floatTimer?.cancel();
    _snapController.removeListener(_onSnapTick);
    _panelController.dispose();
    _snapController.dispose();
    _jumpController.dispose();
    _jumpFocus.dispose();
    super.dispose();
  }

  void _onSnapTick() {
    if (!mounted) return;
    setState(() => _knobOffset = (_snapController.value - 1) * _snapFrom);
  }

  /// 回中动画的起点位移。
  double _snapFrom = 0;

  void _onHandleChanged() {
    if (!mounted) return;
    if (_expanded) {
      _panelController.forward();
    } else {
      _cancelEditing();
      _panelController.reverse();
    }
    setState(() {});
    _scheduleDim();
  }

  /// 滚动 / 交互时亮起来，静置 2 秒后淡到 25%（仅触控）。
  void _scheduleDim() {
    _dimTimer?.cancel();
    _setActive(true);
    if (!_isTouch) return;
    _dimTimer = Timer(ChatRail.dimDelay, () {
      if (!mounted || _dragging || _hovering || _expanded) return;
      _setActive(false);
    });
  }

  void _setActive(bool value) {
    if (_active == value || !mounted) return;
    setState(() => _active = value);
  }

  void _onLocatorChanged() {
    if (!mounted) return;
    setState(() {});
    if (_isTouch) _scheduleDim();
  }

  // ---------- 手势 ----------

  /// 按下（手势竞技场还没裁决）：先记基准点。
  ///
  /// 用 `onVerticalDragDown` 而不是 `DragStartDetails`：拖动被识别时（越过 slop）
  /// 起点已经是"现在"的位置，拿它当基准会把前半段位移吃掉（实测单步拖动 80px
  /// 时滑块纹丝不动）。按下点才是滑块该跟的基准。
  void _onDragDown(DragDownDetails details) {
    _snapController.stop();
    _dragStartY = details.globalPosition.dy;
    _dragStartOffset = _knobOffset;
    setState(() {
      _dragging = true;
      if (!_expanded) _floatingCapsule = true;
    });
    _scheduleDim();
  }

  void _onDragStart(DragStartDetails details) {
    HapticFeedback.selectionClick();
    _scheduleDim();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final raw =
        _dragStartOffset + (details.globalPosition.dy - _dragStartY);
    final offset = raw
        .clamp(-ChatRail.knobMaxTravel, ChatRail.knobMaxTravel)
        .toDouble();
    if (offset != _knobOffset) {
      setState(() => _knobOffset = offset);
    }
    // 速度只跟"离中央多远"有关：满量程 = 一颗滑块的行程。
    final velocity = offset.abs() < ChatRail.knobDeadZone
        ? 0.0
        : widget.motion.velocityFor(
            originY: 0,
            pointerY: offset,
            viewportHeight: ChatRail.knobMaxTravel,
          );
    widget.locator.scrollByVelocity(velocity);
    _scheduleDim();
  }

  void _onDragEnd() {
    widget.locator.stopVelocity();
    setState(() => _dragging = false);
    _snapBack();
    if (!_expanded) {
      if (_floatingCapsule) {
        // 胶囊停留 1.2 秒再淡出。
        _floatTimer?.cancel();
        _floatTimer = Timer(const Duration(milliseconds: 1200), () {
          if (!mounted) return;
          setState(() => _floatingCapsule = false);
        });
      }
    }
    _scheduleDim();
  }

  /// 松手回中（180ms easeOutCubic）。
  void _snapBack() {
    if (_knobOffset == 0) return;
    _snapFrom = _knobOffset;
    _snapController.forward(from: 0);
  }

  void _onTapTrack() {
    _handle.toggle();
    _scheduleDim();
  }

  // ---------- 动作 ----------

  void _jumpTop() {
    unawaited(widget.locator.jumpToTop());
    _scheduleDim();
  }

  void _jumpBottom() {
    unawaited(widget.locator.jumpToBottom());
    _scheduleDim();
  }

  void _previousRound() {
    final target = _currentRound - 1;
    if (target < 1) {
      _jumpTop();
      return;
    }
    unawaited(widget.locator.jumpToRound(target));
  }

  void _nextRound() {
    final target = _currentRound + 1;
    if (target > _maxRound) {
      _jumpBottom();
      return;
    }
    unawaited(widget.locator.jumpToRound(target));
  }

  void _startEditing() {
    setState(() {
      _editing = true;
      _jumpController.text = '$_currentRound';
    });
    _jumpFocus.requestFocus();
    _jumpController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _jumpController.text.length,
    );
  }

  void _cancelEditing() {
    if (!_editing) return;
    setState(() => _editing = false);
    _jumpFocus.unfocus();
  }

  void _submitJump([String? raw]) {
    final text = raw ?? _jumpController.text;
    final parsed = int.tryParse(text.trim());
    _cancelEditing();
    if (parsed == null) return;
    // 非法输入夹取到 [1, maxRound]，不报错（规格 §7.3）。
    final maxRound = math.max(1, _maxRound);
    final clamped = parsed.clamp(1, maxRound);
    unawaited(widget.locator.jumpToRound(clamped));
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final fraction = widget.locator.visibleFraction;
    // 内容不足一屏 / 只有一轮：没有可定位的东西，整条轨道不显示。
    if (fraction == null || fraction >= 1 || _maxRound <= 1) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final centerY = constraints.maxHeight / 2;
        final knobCenterY = centerY + _knobOffset;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            _buildPanelStack(theme, constraints),
            // 滑块：垂直居中，拖动时跟着手指走（有行程限制）。
            Positioned(
              top: knobCenterY - ChatRail.knobHeight / 2,
              right: _gutter + (ChatRail.hitWidth - ChatRail.knobWidth) / 2,
              width: ChatRail.knobWidth,
              height: ChatRail.knobHeight,
              child: IgnorePointer(
                key: ChatRail.knobKey,
                child: _buildKnob(theme),
              ),
            ),
            // 命中带：整条右缘都能按下开始拖（拖动按位移算，按在哪都不会跳）。
            Positioned(
              right: _gutter,
              top: 0,
              bottom: 0,
              width: ChatRail.hitWidth,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeUpDown,
                onEnter: (_) => setState(() => _hovering = true),
                onExit: (_) => setState(() => _hovering = false),
                child: GestureDetector(
                  key: ChatRail.trackKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: _onTapTrack,
                  onVerticalDragDown: _onDragDown,
                  onVerticalDragStart: _onDragStart,
                  onVerticalDragUpdate: _onDragUpdate,
                  onVerticalDragEnd: (_) => _onDragEnd(),
                  onVerticalDragCancel: _onDragEnd,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            // 收起态拖动：胶囊跟着滑块走，松开 1.2s 后淡出。
            if (!_expanded && _floatingCapsule)
              _buildFloatingCapsule(theme, constraints, centerY),
          ],
        );
      },
    );
  }

  /// 滑块本体：品牌色的圆角小胶囊，拖动 / 悬停时更实。
  Widget _buildKnob(ThemeData theme) {
    final primary = theme.colorScheme.primary;
    final emphasized = _dragging || _hovering;
    final opacity = _railOpacity;
    final width = _dragging ? ChatRail.knobDraggingWidth : ChatRail.knobWidth;
    return Opacity(
      opacity: opacity,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          width: width,
          height: ChatRail.knobHeight,
          decoration: BoxDecoration(
            color: primary.withValues(alpha: emphasized ? 0.95 : 0.6),
            borderRadius: BorderRadius.circular(width / 2),
            boxShadow: [
              BoxShadow(
                color: primary.withValues(alpha: emphasized ? 0.38 : 0.2),
                blurRadius: emphasized ? 10 : 6,
                offset: const Offset(0, 1),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 轨道 / 滑块的透明度：桌面常显，触控静置淡出、交互回亮。
  double get _railOpacity {
    if (!_isTouch) return _hovering || _dragging || _expanded ? 1 : 0.82;
    if (_hovering || _dragging || _expanded || _active) return 1;
    return 0.35;
  }

  /// 展开后的五个部件（各自有背景和形状，互不包裹）。
  Widget _buildPanelStack(ThemeData theme, BoxConstraints constraints) {
    final panelHeight = math.min(
      ChatRail.panelHeight,
      math.max(0, constraints.maxHeight - 24),
    );
    final top = math.max(12.0, (constraints.maxHeight - panelHeight) / 2);
    return Positioned(
      right: _gutter + ChatRail.hitWidth + ChatRail.panelGap,
      top: top,
      child: AnimatedBuilder(
        animation: _panelController,
        builder: (context, child) {
          final value = _panelController.value;
          if (value == 0) return const SizedBox.shrink();
          return IgnorePointer(
            ignoring: value < 1,
            child: Opacity(
              opacity: value,
              child: Transform.translate(
                // 从轨道左侧"划出"：收起时贴近滑块并透明。
                offset: Offset(20 * (1 - value), 0),
                child: child,
              ),
            ),
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _railChip(
              theme,
              tooltip: '顶部',
              icon: Icons.vertical_align_top,
              onTap: _jumpTop,
            ),
            const SizedBox(height: 8),
            _railChip(
              theme,
              tooltip: '上一轮',
              icon: Icons.keyboard_arrow_up,
              onTap: _previousRound,
            ),
            const SizedBox(height: 8),
            _buildCapsule(theme),
            const SizedBox(height: 8),
            _railChip(
              theme,
              tooltip: '下一轮',
              icon: Icons.keyboard_arrow_down,
              onTap: _nextRound,
            ),
            const SizedBox(height: 8),
            _railChip(
              theme,
              tooltip: '底部',
              icon: Icons.vertical_align_bottom,
              onTap: _jumpBottom,
            ),
          ],
        ),
      ),
    );
  }

  /// 收起态拖动时跟在滑块旁边的胶囊（只读，不挡手势）。
  Widget _buildFloatingCapsule(
    ThemeData theme,
    BoxConstraints constraints,
    double centerY,
  ) {
    final half = ChatRail.capsuleHeight / 2;
    final center = (centerY + _knobOffset)
        .clamp(half + 12, math.max(half + 12, constraints.maxHeight - half - 12))
        .toDouble();
    return Positioned(
      right: _gutter + ChatRail.hitWidth + ChatRail.panelGap,
      top: center - half,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: 1,
          duration: const Duration(milliseconds: 120),
          child: _buildCapsule(theme),
        ),
      ),
    );
  }

  /// 一个圆形按钮：自己的底色、细边框、轻阴影（不是一个面板里的图标）。
  Widget _railChip(
    ThemeData theme, {
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return _chipSurface(
      theme,
      width: ChatRail.itemHeight,
      height: ChatRail.itemHeight,
      radius: ChatRail.itemHeight / 2,
      onTap: onTap,
      tooltip: tooltip,
      child: Icon(
        icon,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// 中间胶囊：左半页码（可点开内联输入），右半跳转按钮。
  Widget _buildCapsule(ThemeData theme) {
    final onSurface = theme.colorScheme.onSurface;
    final variant = theme.colorScheme.onSurfaceVariant;
    final primary = theme.colorScheme.primary;
    return _chipSurface(
      theme,
      width: ChatRail.capsuleWidth,
      height: ChatRail.capsuleHeight,
      radius: ChatRail.capsuleHeight / 2,
      onTap: null,
      child: Row(
        children: [
          Expanded(
            child: _editing
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextField(
                      controller: _jumpController,
                      focusNode: _jumpFocus,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: onSurface,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: _submitJump,
                      onTapOutside: (_) => _cancelEditing(),
                    ),
                  )
                : InkWell(
                    onTap: _startEditing,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Center(
                        // 页码可能很长（四位数），放不下就整体缩放，不裁掉。
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '$_currentRound',
                                  style: TextStyle(
                                    color: onSurface,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextSpan(
                                  text: ' / ',
                                  style: TextStyle(color: variant),
                                ),
                                TextSpan(
                                  text: '$_maxRound',
                                  style: TextStyle(color: variant),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            style: const TextStyle(fontSize: 14, height: 1.1),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          Container(
            width: 1,
            height: 20,
            color: theme.colorScheme.outlineVariant,
          ),
          SizedBox(
            width: 34,
            child: InkWell(
              onTap: () => _submitJump(_jumpController.text),
              child: Icon(
                Icons.play_arrow_rounded,
                size: 18,
                color: primary.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 独立的"芯片"表面：Material 自带底色 + 圆角 + 轻阴影，外面一圈细边。
  ///
  /// 底色要随亮暗主题选：浅色主题里"内容面"是白色（背景浅灰），深色主题里
  /// `surface` 与背景几乎同色 —— 用 `surfaceContainerHighest` 才看得出是独立部件。
  Widget _chipSurface(
    ThemeData theme, {
    required double width,
    required double height,
    required double radius,
    required Widget child,
    VoidCallback? onTap,
    String? tooltip,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    final content = SizedBox(
      width: width,
      height: height,
      child: Material(
        color: isDark
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.surface,
        elevation: _hovering ? 3 : 2,
        shadowColor: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: isDark
                ? theme.colorScheme.outline.withValues(alpha: 0.5)
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: onTap == null
            ? child
            : InkWell(onTap: onTap, child: Center(child: child)),
      ),
    );
    return tooltip == null ? content : Tooltip(message: tooltip, child: content);
  }
}
