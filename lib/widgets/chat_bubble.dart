import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

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
  Timer? _longPressTimer;

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

  void _cancelLongPress() {
    _longPressTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    final showAction = !widget.isUser &&
        widget.recommendedAction != null &&
        widget.recommendedAction!.trim().isNotEmpty;

    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: (_) => _cancelLongPress(),
      onPointerCancel: (_) => _cancelLongPress(),
      child: Align(
        // 用户靠右，AI 靠左。
        alignment: widget.isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth.clamp(240, 560)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!widget.isUser)
                _avatar(theme, Icons.auto_awesome, const Color(0xFF7C4DFF)),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: widget.isUser
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        gradient: widget.isUser
                            ? LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  theme.colorScheme.primaryContainer,
                                  theme.colorScheme.primaryContainer
                                      .withValues(alpha: 0.55),
                                ],
                              )
                            : null,
                        color: widget.isUser ? null : theme.colorScheme.surface,
                        border: widget.isUser
                            ? null
                            : Border.all(color: theme.colorScheme.outlineVariant),
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: Radius.circular(widget.isUser ? 16 : 4),
                          bottomRight: Radius.circular(widget.isUser ? 4 : 16),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.04),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SelectableText(
                            widget.text,
                            // 抑制默认右键菜单，统一使用自定义气泡菜单（避免双菜单）。
                            contextMenuBuilder:
                                (context, editableTextState) =>
                                    const SizedBox.shrink(),
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.5,
                              color: widget.isUser
                                  ? theme.colorScheme.onPrimaryContainer
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          // 推荐下一步：位于气泡内部，可复制。
                          if (showAction) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Divider(
                                height: 1,
                                color: theme.colorScheme.outlineVariant
                                    .withValues(alpha: 0.7),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  Icons.flag_outlined,
                                  size: 14,
                                  color: theme.colorScheme.tertiary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '推荐下一步',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.tertiary,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            SelectableText(
                              widget.recommendedAction!,
                              contextMenuBuilder: (context, editableTextState) =>
                                  const SizedBox.shrink(),
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (widget.footer != null) ...[
                      const SizedBox(height: 6),
                      widget.footer!,
                    ],
                  ],
                ),
              ),
              if (widget.isUser) const SizedBox(width: 8),
              if (widget.isUser)
                _avatar(theme, Icons.person, const Color(0xFF5C6BC0)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatar(ThemeData theme, IconData icon, Color color) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.85), color],
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, size: 18, color: Colors.white),
    );
  }
}

