import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_locator.dart';
import 'chat_rail_handle.dart';
import 'chat_rail_motion.dart';

/// 对话页右侧的定位轨：一条细轨 + 拇指，点开变成一列跳转按钮。
///
/// 为什么不用 Flutter 的 [Scrollbar]：`Scrollbar` 的拇指位置/长度读的是
/// 滚动容器的 `maxScrollExtent`，而窗口化之后那个值只反映"当前这一窗"，
/// 全书进度会跳来跳去。这里一律读定位层（[ChatLocator]），一个数说话。
///
/// 形态（规格 §7）：
/// - 轨道：视觉 3dp（拖动时 6dp）、命中 24dp、右侧内缩桌面 8dp / 触控 20dp；
/// - 拇指：高 = `max(24, 轨道高 × 视口/总高)`，位置**始终等于真实进度**（不跟手）；
/// - 面板：宽 64dp，4 个 40dp 圆形按钮 + 1 个 40dp 胶囊，间距 8dp，总高 232dp；
/// - 收起态拖动只弹中间胶囊，跟随**拇指**纵向并夹取安全区。
class ChatRail extends StatefulWidget {
  const ChatRail({
    super.key,
    required this.locator,
    this.handle,
    this.isTouchPlatform,
    this.motion = const ChatRailMotion(),
  });

  /// 定位门面（进度 / 跳转 / 速度 / 最大轮号）。所有数字都向它要。
  final ChatLocator locator;

  /// 展开 / 收起的外部开关（点消息区收起、Esc 收起用）。不传则轨道自己管。
  final ChatRailHandle? handle;

  /// 是否触屏平台（决定内缩与透明度）；null = 按平台推断。
  final bool? isTouchPlatform;

  final ChatRailMotion motion;

  /// 轨道视觉宽度（拖动时用 [draggingTrackWidth]）。
  static const double trackWidth = 3;
  static const double draggingTrackWidth = 6;

  /// 轨道命中宽度。
  static const double hitWidth = 24;

  /// 轨道右侧内缩：桌面避开窗口边缘、触控避开系统返回手势。
  static const double gutterDesktop = 8;
  static const double gutterTouch = 20;

  /// 轨道从其父级右缘起占用的宽度（内缩 + 命中区）。
  ///
  /// 展开面板与浮动胶囊会再向左多占一段，但那是瞬态；输入面板的按钮行只需要
  /// 让开这一段，否则最右侧的按钮正好压在命中带里点不动（触控端实测整个按钮
  /// 右半都收不到点击）。
  static const double reservedFromRight = gutterTouch + hitWidth;

  /// 从父级右缘到面板右缘的距离（面板贴在轨道左侧）。
  static const double panelRightInset = hitWidth + gutterTouch + 4;

  /// 轨道命中区（测试与手势竞技场用它定位）。
  static const Key trackKey = ValueKey('chat-rail-track');

  /// 面板宽度。
  static const double panelWidth = 64;

  /// 一个按钮的高度/直径。
  static const double itemHeight = 40;

  /// 面板总高：5 项 + 4 个间距。
  static const double panelHeight = itemHeight * 5 + 8 * 4;

  /// 轨道纵向内缩（安全区上下各留一点）。
  static const double trackInset = 12;

  /// 面板划出 / 收起的时长（规格 §7.8）。
  static const Duration expandDuration = Duration(milliseconds: 200);
  static const Duration collapseDuration = Duration(milliseconds: 160);

  /// 静止淡出的延迟与时长。
  static const Duration dimDelay = Duration(seconds: 2);
  static const Duration dimDuration = Duration(milliseconds: 600);

  @override
  State<ChatRail> createState() => _ChatRailState();
}

class _ChatRailState extends State<ChatRail> with SingleTickerProviderStateMixin {
  /// 展开状态（外部可驱动）。
  late final ChatRailHandle _handle = widget.handle ?? ChatRailHandle();

  bool get _ownsHandle => widget.handle == null;

  /// 面板划出 / 收起。
  late final AnimationController _panelController = AnimationController(
    vsync: this,
    duration: ChatRail.expandDuration,
    reverseDuration: ChatRail.collapseDuration,
  );

  bool _dragging = false;
  bool _hovering = false;
  bool _active = false;
  bool _editing = false;

  /// 收起态拖动时是否显示跟随拇指的胶囊。
  bool _floatingCapsule = false;

  double _originY = 0;

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

  double get _progress => widget.locator.progress ?? 0;

  @override
  void initState() {
    super.initState();
    widget.locator.addListener(_onLocatorChanged);
    _handle.addListener(_onHandleChanged);
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
    _panelController.dispose();
    _jumpController.dispose();
    _jumpFocus.dispose();
    super.dispose();
  }

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
    if (_active == value) return;
    if (!mounted) return;
    setState(() => _active = value);
  }

  void _onLocatorChanged() {
    if (!mounted) return;
    setState(() {});
    // 滚动中保持常亮（触控静置才淡出）。
    if (_isTouch) _scheduleDim();
  }

  double _trackHeight(double maxHeight) =>
      math.max(0, maxHeight - ChatRail.trackInset * 2);

  // ---------- 手势 ----------

  void _onDragStart(DragStartDetails details) {
    HapticFeedback.selectionClick();
    setState(() {
      _dragging = true;
      _originY = details.globalPosition.dy;
      if (!_expanded) _floatingCapsule = true;
    });
    _scheduleDim();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final velocity = widget.motion.velocityFor(
      originY: _originY,
      pointerY: details.globalPosition.dy,
      // 满量程 = 1 个消息视口高（不是轨道高，也不是整个聊天区高）。
      viewportHeight: widget.locator.viewportDimension ?? 0,
    );
    widget.locator.scrollByVelocity(velocity);
    _scheduleDim();
  }

  void _onDragEnd() {
    widget.locator.stopVelocity();
    setState(() => _dragging = false);
    if (!_expanded && _floatingCapsule) {
      // 松手后胶囊停留 1.2 秒再淡出（收起态拖动才有）。
      _floatTimer?.cancel();
      _floatTimer = Timer(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        setState(() => _floatingCapsule = false);
      });
    }
    _scheduleDim();
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
    final color = theme.colorScheme.onSurface;
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = _trackHeight(constraints.maxHeight);
        final thumbHeight = ChatRailMotion.thumbHeight(
          trackHeight: trackHeight,
          visibleFraction: fraction,
        );
        final thumbTop = ChatRailMotion.thumbTop(
          trackHeight: trackHeight,
          thumbHeight: thumbHeight,
          progress: _progress,
        );
        final opacity = _railOpacity;
        return Stack(
          children: [
            // 面板先画（在轨道下方），展开时从轨道左侧划出。
            _buildPanelLayer(color, theme, constraints),
            Positioned(
              right: _gutter + (ChatRail.hitWidth - ChatRail.trackWidth) / 2,
              top: ChatRail.trackInset,
              height: trackHeight,
              width: ChatRail.trackWidth,
              child: IgnorePointer(
                child: Opacity(
                  opacity: opacity,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: _dragging
                          ? ChatRail.draggingTrackWidth
                          : ChatRail.trackWidth,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 拇指：位置永远等于真实进度（拖动期间也不跟手）。
            Positioned(
              right: _gutter + (ChatRail.hitWidth - 8) / 2,
              top: ChatRail.trackInset + thumbTop,
              width: 8,
              height: thumbHeight,
              child: IgnorePointer(
                child: Opacity(
                  opacity: opacity,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: _dragging ? 8 : 5,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 命中区 + 手势（轨道永远在最上层、永远可拖）。
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
                  onVerticalDragStart: _onDragStart,
                  onVerticalDragUpdate: _onDragUpdate,
                  onVerticalDragEnd: (_) => _onDragEnd(),
                  onVerticalDragCancel: _onDragEnd,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            // 收起态拖动：胶囊跟随**拇指**（手指是速度输入，拇指才是位置）。
            if (!_expanded && _floatingCapsule)
              _buildFloatingCapsule(
                color,
                theme,
                constraints,
                thumbTop,
                thumbHeight,
              ),
          ],
        );
      },
    );
  }

  /// 轨道 / 拇指的透明度：桌面常显 70%，触控静置淡到 25%、交互回 70%。
  double get _railOpacity {
    if (!_isTouch) return _hovering || _dragging || _expanded ? 0.9 : 0.7;
    if (_hovering || _dragging || _expanded || _active) return 0.7;
    return 0.25;
  }

  Widget _buildPanelLayer(
    Color color,
    ThemeData theme,
    BoxConstraints constraints,
  ) {
    final panelHeight = math.min(
      ChatRail.panelHeight,
      math.max(0, constraints.maxHeight - 24),
    );
    final top = math.max(12.0, (constraints.maxHeight - panelHeight) / 2);
    // `Positioned` 必须是 Stack 的直接子项：动画包在它里面，不能反过来。
    return Positioned(
      right: ChatRail.panelRightInset,
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
                // 从轨道左侧"划出"：收起时贴近轨道并透明。
                offset: Offset(24 * (1 - value), 0),
                child: child,
              ),
            ),
          );
        },
        child: _buildPanel(color, theme),
      ),
    );
  }

  Widget _buildFloatingCapsule(
    Color color,
    ThemeData theme,
    BoxConstraints constraints,
    double thumbTop,
    double thumbHeight,
  ) {
    final half = ChatRail.itemHeight / 2;
    final minCenter = half + 12;
    final maxCenter = math.max(
      minCenter,
      constraints.maxHeight - half - 12,
    );
    final center = (ChatRail.trackInset + thumbTop + thumbHeight / 2)
        .clamp(minCenter, maxCenter)
        .toDouble();
    return Positioned(
      right: ChatRail.panelRightInset,
      top: center - half,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: 1,
          duration: const Duration(milliseconds: 120),
          child: _buildCapsule(color, theme, compact: true),
        ),
      ),
    );
  }

  Widget _buildPanel(Color color, ThemeData theme) {
    return Container(
      width: ChatRail.panelWidth,
      height: ChatRail.panelHeight,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.96),
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          ],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _RailButton(
            icon: Icons.vertical_align_top,
            tooltip: '顶部',
            onTap: _jumpTop,
          ),
          const SizedBox(height: 8),
          _RailButton(
            icon: Icons.keyboard_arrow_up,
            tooltip: '上一轮',
            onTap: _previousRound,
          ),
          const SizedBox(height: 8),
          _buildCapsule(color, theme),
          const SizedBox(height: 8),
          _RailButton(
            icon: Icons.keyboard_arrow_down,
            tooltip: '下一轮',
            onTap: _nextRound,
          ),
          const SizedBox(height: 8),
          _RailButton(
            icon: Icons.vertical_align_bottom,
            tooltip: '底部',
            onTap: _jumpBottom,
          ),
        ],
      ),
    );
  }

  /// 中间胶囊：左半数字（可点开内联输入），右半跳转按钮。
  Widget _buildCapsule(Color color, ThemeData theme, {bool compact = false}) {
    final label = '$_currentRound / $_maxRound';
    return Container(
      width: ChatRail.panelWidth,
      height: ChatRail.itemHeight,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Expanded(
            child: _editing && !compact
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: TextField(
                      controller: _jumpController,
                      focusNode: _jumpFocus,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelMedium,
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
                    onTap: compact ? null : _startEditing,
                    child: Center(
                      child: Text(
                        label,
                        style: theme.textTheme.labelMedium,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  ),
          ),
          Container(
            width: 1,
            height: 20,
            color: color.withValues(alpha: 0.2),
          ),
          SizedBox(
            width: 22,
            child: InkWell(
              onTap: compact ? null : () => _submitJump(_jumpController.text),
              child: Icon(
                Icons.play_arrow_rounded,
                size: 16,
                color: color.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板里的圆形按钮（40dp）。
class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: ChatRail.itemHeight / 2,
        child: SizedBox(
          width: ChatRail.itemHeight,
          height: ChatRail.itemHeight,
          child: Icon(icon, size: 20, color: color.withValues(alpha: 0.8)),
        ),
      ),
    );
  }
}
