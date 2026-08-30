import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 宽屏 Chat 页右侧栏左缘的宽度拖拽手柄。
///
/// 职责单一：捕获横向拖动 / 双击并维护 hover、按下视觉，**不持有宽度语义**。
/// 宽度换算由调用方完成（[onDragUpdate] 只上报指针水平位移，向左为负 = 侧栏变宽），
/// 便于复用与独立测试。
class SidebarResizeDivider extends StatefulWidget {
  /// 拖动中回调：参数为该帧指针水平位移 dx（逻辑像素）。
  final ValueChanged<double> onDragUpdate;

  /// 松手 / 手势取消回调：调用方在此提交（持久化）宽度。
  final VoidCallback onDragEnd;

  /// 双击回调：通常用于恢复默认宽度。
  final VoidCallback? onReset;

  /// 命中条宽度（按侧栏左缘垂直条展示，触屏亦可命中）。
  final double hitWidth;

  const SidebarResizeDivider({
    super.key,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.onReset,
    this.hitWidth = 12,
  });

  @override
  State<SidebarResizeDivider> createState() => _SidebarResizeDividerState();
}

class _SidebarResizeDividerState extends State<SidebarResizeDivider> {
  bool _hovering = false;
  bool _dragging = false;

  void _setDragging(bool dragging) {
    if (_dragging == dragging) return;
    setState(() => _dragging = dragging);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final active = _hovering || _dragging;
    return SizedBox(
      width: widget.hitWidth,
      height: double.infinity,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          key: const Key('sidebar_resize_divider'),
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => _setDragging(true),
          onHorizontalDragUpdate: (details) =>
              widget.onDragUpdate(details.delta.dx),
          onHorizontalDragEnd: (_) {
            _setDragging(false);
            widget.onDragEnd();
          },
          onHorizontalDragCancel: () {
            _setDragging(false);
            widget.onDragEnd();
          },
          onDoubleTap: widget.onReset,
          // 视觉竖线左侧对齐：常态 1px 分隔线色，hover/拖动时 3px 主色。
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: active ? 3 : 1,
              decoration: BoxDecoration(
                color: active
                    ? Theme.of(context).colorScheme.primary
                    : colors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
