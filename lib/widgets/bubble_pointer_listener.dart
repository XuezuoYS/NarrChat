import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 气泡级指针监听：桌面右键 / 触屏长按触发上下文菜单，触屏移动超过阈值
/// （与 [kTouchSlop] 一致）取消长按，避免上下滚动时误触。供气泡类组件复用。
///
/// [onContextMenu] 为 null 时不监听（等价于普通包裹）。
///
/// [hitTestBehavior] 决定**空白处**算不算命中：默认 [HitTestBehavior.deferToChild]
/// 只认真正命中的子级（如文字 / 按钮），正文块内的留白右键会落空；需要「整块
/// 内容区域都能右键」的调用点传 [HitTestBehavior.opaque]——此时监听层按自己的
/// 尺寸整块命中，子级交互照常不受影响。
class BubblePointerListener extends StatefulWidget {
  final Widget child;
  final void Function(Offset globalPosition)? onContextMenu;

  /// 命中测试行为；[onContextMenu] 为 null 时仍按普通包裹处理。
  final HitTestBehavior hitTestBehavior;

  const BubblePointerListener({
    super.key,
    required this.child,
    this.onContextMenu,
    this.hitTestBehavior = HitTestBehavior.deferToChild,
  });

  @override
  State<BubblePointerListener> createState() => _BubblePointerListenerState();
}

class _BubblePointerListenerState extends State<BubblePointerListener> {
  /// 长按判定计时器（触屏）。
  Timer? _longPressTimer;

  /// 手指按下时的位置；用于判断滑动时是否已离开长按范围。
  Offset? _downPosition;

  /// 手指移动超过该距离即视为「滑动」，取消长按（与 kTouchSlop 一致）。
  static const double _moveSlop = 18.0;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    final callback = widget.onContextMenu;
    if (callback == null) return;
    final isMouse = event.kind == PointerDeviceKind.mouse;
    final isRightClick = isMouse && event.buttons == kSecondaryMouseButton;
    _longPressTimer?.cancel();
    _downPosition = event.position;
    if (isRightClick) {
      callback(event.position);
      return;
    }
    // 触屏：长按触发上下文菜单。
    if (!isMouse) {
      _longPressTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) callback(event.position);
      });
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final down = _downPosition;
    if (down == null) return;
    // 手指移动超过阈值即视为滚动/拖动，取消长按，避免上下滑动时误弹菜单。
    if ((event.position - down).distance > _moveSlop) {
      _cancelLongPress();
    }
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _downPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // 无回调时保持旧语义（普通包裹）：不能悄悄放大命中区。
      behavior: widget.onContextMenu == null
          ? HitTestBehavior.deferToChild
          : widget.hitTestBehavior,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: (_) => _cancelLongPress(),
      onPointerCancel: (_) => _cancelLongPress(),
      child: widget.child,
    );
  }
}
