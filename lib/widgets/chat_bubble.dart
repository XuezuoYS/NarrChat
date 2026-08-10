import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../theme/app_theme.dart';
import 'brand_logo.dart';

/// 聊天气泡。
///
/// 布局约定：用户气泡靠右，AI 气泡靠左。
/// - [recommendedAction]：AI 气泡正文下方的「推荐下一步」，位于气泡内部且可复制。
/// - [footer]：气泡下方操作区（Token 用量、查看侧边栏、刷新、调试、删除等）。
/// - [onContextMenu]：右键（桌面）或长按（触屏）时回调，传入全局坐标用于弹出菜单。
class ChatBubble extends StatefulWidget {
  final bool isUser;
  final String text;
  final String? recommendedAction;
  final Widget? footer;
  final void Function(Offset globalPosition)? onContextMenu;

  const ChatBubble({
    super.key,
    required this.isUser,
    required this.text,
    this.recommendedAction,
    this.footer,
    this.onContextMenu,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble> {
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
    final theme = Theme.of(context);
    final maxWidth = MediaQuery.sizeOf(context).width * 0.8;
    final showAction = !widget.isUser &&
        widget.recommendedAction != null &&
        widget.recommendedAction!.trim().isNotEmpty;

    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: (_) => _cancelLongPress(),
      onPointerCancel: (_) => _cancelLongPress(),
      child: Align(
        // 用户靠右，AI 靠左（模仿 DeepSeek：无气泡、纯文本消息流）。
        alignment: widget.isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth.clamp(240, 680)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!widget.isUser) ...[
                const BrandLogo(size: 30),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: widget.isUser
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    // 正文：AI 为无气泡纯文本；用户消息带浅色气泡。
                    if (widget.isUser)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 9),
                        decoration: BoxDecoration(
                          color: context.narrColors.userBubble,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: SelectableText(
                          widget.text,
                          // 抑制默认右键菜单，统一使用自定义气泡菜单（避免双菜单）。
                          contextMenuBuilder: (context, editableTextState) =>
                              const SizedBox.shrink(),
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.65,
                            color: context.narrColors.textPrimary,
                          ),
                        ),
                      )
                    else
                      SelectableText(
                        widget.text,
                        // 抑制默认右键菜单，统一使用自定义气泡菜单（避免双菜单）。
                        contextMenuBuilder: (context, editableTextState) =>
                            const SizedBox.shrink(),
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.65,
                          color: context.narrColors.textPrimary,
                        ),
                      ),
                    // 推荐下一步：AI 正文下方，极简样式。
                    if (showAction) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.flag_outlined,
                                  size: 13,
                                  color: NarrChatTheme.primary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '推荐下一步',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: NarrChatTheme.primary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            SelectableText(
                              widget.recommendedAction!,
                              contextMenuBuilder:
                                  (context, editableTextState) =>
                                      const SizedBox.shrink(),
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: context.narrColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (widget.footer != null) ...[
                      const SizedBox(height: 6),
                      widget.footer!,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

}

