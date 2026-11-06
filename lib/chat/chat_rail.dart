import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_locator.dart';
import 'chat_rail_motion.dart';

/// 对话页右侧的定位轨：一条细轨 + 拇指，点开变成一列跳转按钮。
///
/// 为什么不用 Flutter 的 [Scrollbar]：`Scrollbar` 的拇指位置/长度读的是
/// 滚动容器的 `maxScrollExtent`，而窗口化之后那个值只反映"当前这一窗"，
/// 全书进度会跳来跳去。这里一律读几何模型（经 [ChatLocator]）。
///
/// 形态（规格 §7）：
/// - 轨道：视觉 3dp（拖动时 6dp）、命中 24dp、右侧内缩桌面 8dp / 触控 20dp；
/// - 拇指：高 = `max(24, 轨道高 × 视口/总高)`，位置**始终等于真实进度**（不跟手）；
/// - 面板：宽 64dp，4 个 40dp 圆形按钮 + 1 个 40dp 胶囊，间距 8dp，总高 232dp；
/// - 收起态拖动只弹中间胶囊，跟随拇指纵向并夹取安全区。
class ChatRail extends StatefulWidget {
  const ChatRail({
    super.key,
    required this.locator,
    required this.totalRounds,
    required this.viewportHeight,
    this.visibleFraction = 1,
    this.isTouchPlatform,
    this.motion = const ChatRailMotion(),
  });

  /// 定位门面（进度/跳转/速度）。
  final ChatLocator locator;

  /// 全书轮数（胶囊右侧显示、跳转输入的上限）。
  final int totalRounds;

  /// 消息区可视高度（速度模型的满量程 = 1 个视口高）。
  final double viewportHeight;

  /// 当前视口占全书高度的比例（决定拇指长度）；≥ 1 时整条轨道没有意义。
  final double visibleFraction;

  /// 是否触屏平台（决定内缩与透明度）；null = 按平台推断。
  final bool? isTouchPlatform;

  final ChatRailMotion motion;

  /// 轨道视觉宽度（拖动时用 [draggingTrackWidth]）。
  static const double trackWidth = 3;
  static const double draggingTrackWidth = 6;

  /// 轨道命中宽度。
  static const double hitWidth = 24;

  /// 轨道命中区（测试与手势竞技场用它定位）。
  static const Key trackKey = ValueKey('chat-rail-track');

  /// 面板宽度。
  static const double panelWidth = 64;

  /// 一个按钮的高度/直径。
  static const double itemHeight = 40;

  /// 面板总高：5 项 + 4 个间距。
  static const double panelHeight = itemHeight * 5 + 8 * 4;

  @override
  State<ChatRail> createState() => _ChatRailState();
}

class _ChatRailState extends State<ChatRail> {
  bool _expanded = false;
  bool _dragging = false;
  bool _hovering = false;
  bool _dimmed = false;
  bool _editing = false;

  /// 收起态拖动时是否显示跟随拇指的胶囊。
  bool _floatingCapsule = false;

  double _originY = 0;

  Timer? _dimTimer;
  Timer? _floatTimer;
  Timer? _capsuleTimer;

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

  double get _gutter => _isTouch ? 20 : 8;

  int get _currentRound => widget.locator.currentRoundIndex ?? 1;

  double get _progress => widget.locator.progress ?? 0;

  @override
  void initState() {
    super.initState();
    widget.locator.addListener(_onLocatorChanged);
    _scheduleDim();
  }

  @override
  void didUpdateWidget(covariant ChatRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locator != widget.locator) {
      oldWidget.locator.removeListener(_onLocatorChanged);
      widget.locator.addListener(_onLocatorChanged);
    }
  }

  @override
  void dispose() {
    widget.locator.removeListener(_onLocatorChanged);
    _dimTimer?.cancel();
    _floatTimer?.cancel();
    _capsuleTimer?.cancel();
    _jumpController.dispose();
    _jumpFocus.dispose();
    super.dispose();
  }

  /// 滚动/交互时亮起来，静置 2 秒后淡到 25%（触控），桌面保持 70%。
  void _scheduleDim() {
    _dimTimer?.cancel();
    if (_dimmed) setState(() => _dimmed = false);
    if (!_isTouch) return;
    _dimTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _dragging || _hovering || _expanded) return;
      setState(() => _dimmed = true);
    });
  }

  void _onLocatorChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleDim();
  }

  double get _trackTop => 12;

  double get _trackBottom => 12;

  double _trackHeight(double maxHeight) => maxHeight - _trackTop - _trackBottom;

  // ---------- 手势 ----------

  void _onDragStart(DragStartDetails details) {
    HapticFeedback.selectionClick();
    setState(() {
      _dragging = true;
      _originY = details.globalPosition.dy;
      if (!_expanded) {
        _floatingCapsule = true;
      }
    });
    _scheduleDim();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final velocity = widget.motion.velocityFor(
      originY: _originY,
      pointerY: details.globalPosition.dy,
      viewportHeight: widget.viewportHeight,
    );
    widget.locator.scrollByVelocity(velocity);
    if (!_expanded) {
      _floatTimer?.cancel();
    }
    _scheduleDim();
  }

  void _onDragEnd() {
    widget.locator.stopVelocity();
    setState(() => _dragging = false);
    if (!_expanded && _floatingCapsule) {
      // 松手后胶囊停留 1.2 秒再淡出。
      _floatTimer?.cancel();
      _floatTimer = Timer(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        setState(() => _floatingCapsule = false);
      });
    }
    _scheduleDim();
  }

  void _onTap() {
    setState(() {
      _expanded = !_expanded;
      if (!_expanded) _cancelEditing();
    });
    _scheduleDim();
  }

  // ---------- 动作 ----------

  void _jumpTop() => widget.locator.jumpToTop();

  void _jumpBottom() => widget.locator.jumpToBottom();

  void _previousRound() {
    final target = _currentRound - 1;
    if (target < 1) {
      _jumpTop();
      return;
    }
    widget.locator.jumpToRound(target);
  }

  void _nextRound() {
    final target = _currentRound + 1;
    if (target > widget.totalRounds) {
      _jumpBottom();
      return;
    }
    widget.locator.jumpToRound(target);
  }

  void _startEditing() {
    _capsuleTimer?.cancel();
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
    setState(() => _editing = false);
    _jumpFocus.unfocus();
  }

  void _submitJump([String? raw]) {
    final text = raw ?? _jumpController.text;
    final parsed = int.tryParse(text.trim());
    if (parsed == null) {
      _cancelEditing();
      return;
    }
    _cancelEditing();
    // 非法输入夹取到 [1, max]，不报错（规格 §7.3）。
    final clamped = parsed.clamp(1, widget.totalRounds < 1 ? 1 : widget.totalRounds);
    widget.locator.jumpToRound(clamped);
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    // 内容不足一屏：没有可滚动的东西，整条轨道不显示。
    if (widget.totalRounds <= 1 || widget.visibleFraction >= 1) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface;
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = _trackHeight(constraints.maxHeight);
        final thumbHeight = ChatRailMotion.thumbHeight(
          trackHeight: trackHeight,
          visibleFraction: widget.visibleFraction,
        );
        final thumbTop = ChatRailMotion.thumbTop(
          trackHeight: trackHeight,
          thumbHeight: thumbHeight,
          progress: _progress,
        );
        final opacity = _dimmed ? 0.25 : (_isTouch ? 0.4 : 0.7);
        return Stack(
          children: [
            if (_expanded)
              Positioned(
                right: _gutter + ChatRail.hitWidth + 4,
                top: 0,
                bottom: 0,
                width: ChatRail.panelWidth,
                child: Center(
                  child: _buildPanel(color, theme),
                ),
              ),
            Positioned(
              right: _gutter + (ChatRail.hitWidth - ChatRail.trackWidth) / 2,
              top: _trackTop,
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
            // 拇指：位置永远等于真实进度。
            Positioned(
              right: _gutter + (ChatRail.hitWidth - 8) / 2,
              top: _trackTop + thumbTop,
              width: 8,
              height: thumbHeight,
              child: IgnorePointer(
                child: Opacity(
                  opacity: opacity,
                  child: Center(
                    child: Container(
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
            // 命中区 + 手势。
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
                  onTap: _onTap,
                  onVerticalDragStart: _onDragStart,
                  onVerticalDragUpdate: _onDragUpdate,
                  onVerticalDragEnd: (_) => _onDragEnd(),
                  onVerticalDragCancel: _onDragEnd,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            if (!_expanded && _floatingCapsule)
              _buildFloatingCapsule(color, theme, constraints, thumbTop, thumbHeight),
          ],
        );
      },
    );
  }

  /// 收起态拖动时跟随**拇指**的胶囊（不跟手指：手指是速度输入，拇指才是位置）。
  Widget _buildFloatingCapsule(
    Color color,
    ThemeData theme,
    BoxConstraints constraints,
    double thumbTop,
    double thumbHeight,
  ) {
    final half = ChatRail.itemHeight / 2;
    final minCenter = half + 12;
    final maxCenter = (constraints.maxHeight - half - 12) > minCenter
        ? constraints.maxHeight - half - 12
        : minCenter;
    final center = (_trackTop + thumbTop + thumbHeight / 2)
        .clamp(minCenter, maxCenter)
        .toDouble();
    return Positioned(
      right: _gutter + ChatRail.hitWidth + 8,
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
    return AnimatedOpacity(
      opacity: 1,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: Container(
        width: ChatRail.panelWidth,
        height: ChatRail.panelHeight,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
            colors: [
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.95),
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
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
      ),
    );
  }

  /// 中间胶囊：左半数字（可点开内联输入），右半跳转按钮。
  Widget _buildCapsule(Color color, ThemeData theme, {bool compact = false}) {
    final label = '$_currentRound / ${widget.totalRounds}';
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
            child: _editing
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
