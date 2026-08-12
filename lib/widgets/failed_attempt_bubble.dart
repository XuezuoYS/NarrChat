import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/failed_attempt.dart';
import 'action_button.dart';
import 'app_menu.dart';
import 'bubble_pointer_listener.dart';
import 'chat_bubble.dart';

/// 「失败条目」气泡：用户输入气泡 + AI 红色提示框（已截断 / 生成失败 + 原因）
/// + 底部操作（重新提问 / 修改并重新提问 / 清除失败条目）。
///
/// 整块支持右键 / 长按弹出上下文菜单（复制输入 / 重新提问 / 修改并重新提问 / 清除）。
class FailedAttemptBubble extends StatelessWidget {
  final FailedAttempt attempt;
  final VoidCallback onRetry;
  final VoidCallback onEditAndRetry;
  final VoidCallback onClear;

  const FailedAttemptBubble({
    super.key,
    required this.attempt,
    required this.onRetry,
    required this.onEditAndRetry,
    required this.onClear,
  });

  void _showMenu(BuildContext context, Offset position) {
    showAppMenu<String>(
      context: context,
      position: position,
      items: [
        const PopupMenuItem(
          value: 'retry',
          child: AppMenuAction(icon: Icons.replay, label: '重新提问'),
        ),
        const PopupMenuItem(
          value: 'editRetry',
          child: AppMenuAction(icon: Icons.edit_note, label: '修改并重新提问'),
        ),
        const PopupMenuItem(
          value: 'copy',
          child: AppMenuAction(icon: Icons.copy_outlined, label: '复制输入'),
        ),
        const PopupMenuItem(
          value: 'clear',
          child: AppMenuAction(
            icon: Icons.delete_outline,
            label: '清除失败条目',
            color: Color(0xFFE5484D),
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'retry':
          onRetry();
        case 'editRetry':
          onEditAndRetry();
        case 'copy':
          Clipboard.setData(ClipboardData(text: attempt.userInput));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('已复制'),
                duration: Duration(seconds: 1),
              ),
            );
          }
        case 'clear':
          onClear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;
    return BubblePointerListener(
      onContextMenu: (pos) => _showMenu(context, pos),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 用户输入气泡（无独立菜单，由外层统一处理）。
          ChatBubble(isUser: true, text: attempt.userInput),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: _FailureBox(attempt: attempt, errorColor: errorColor),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              ActionButton(
                icon: Icons.replay,
                label: '重新提问',
                onPressed: onRetry,
              ),
              ActionButton(
                icon: Icons.edit_note,
                label: '修改并重新提问',
                onPressed: onEditAndRetry,
              ),
              ActionButton(
                icon: Icons.delete_outline,
                label: '清除失败条目',
                color: errorColor,
                onPressed: onClear,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 失败条目的红色提示框：标题「已截断」/「生成失败」，非截断时展示失败原因。
class _FailureBox extends StatelessWidget {
  final FailedAttempt attempt;
  final Color errorColor;

  const _FailureBox({required this.attempt, required this.errorColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: errorColor.withValues(alpha: 0.06),
        border: Border.all(color: errorColor, width: 1.2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 16, color: errorColor),
              const SizedBox(width: 6),
              Text(
                attempt.isTruncated ? '已截断' : '生成失败',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: errorColor,
                ),
              ),
            ],
          ),
          if (!attempt.isTruncated) ...[
            const SizedBox(height: 6),
            SelectableText(
              attempt.errorMessage,
              // 抑制默认右键菜单，统一由外层 BubblePointerListener 处理。
              contextMenuBuilder: (context, editableTextState) =>
                  const SizedBox.shrink(),
              style: TextStyle(fontSize: 13, height: 1.5, color: errorColor),
            ),
          ],
        ],
      ),
    );
  }
}
