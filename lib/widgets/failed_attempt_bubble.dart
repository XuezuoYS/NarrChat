import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/failed_attempt.dart';
import 'action_button.dart';
import 'app_menu.dart';
import 'app_notice_overlay.dart';
import 'bubble_pointer_listener.dart';
import 'chat_bubble.dart';
import 'markdown_preview.dart';

/// 「失败条目」气泡：用户输入气泡 + AI 红色提示框（已截断 / 生成失败 + 原因）
/// + 底部操作（代次控件 / 刷新本轮 / 修改并重新提问 / RAW / 清除失败条目）。
///
/// 整块支持右键 / 长按弹出上下文菜单（复制输入 / 刷新本轮 / 修改并重新提问 /
/// RAW / 清除）。RAW 入口**恒在**（无数据时由调用方的提示说明），不随数据显隐。
///
/// 「刷新本轮」与正常轮次是**同一入口**（同一确认框、同一 Provider 路径），
/// 这里只是宿主不同：输入 / 图片来自失败条目、轮号取「本该产生的那一轮」。
class FailedAttemptBubble extends StatelessWidget {
  final FailedAttempt attempt;

  /// 「刷新本轮」回调（失败条目：以失败时的输入重刷那一轮）。
  final VoidCallback onRefresh;
  final VoidCallback onEditAndRetry;
  final VoidCallback onClear;

  /// RAW 查看回调（必传）：有数据即打开 RAW 对话框，无数据由实现给出提示。
  final VoidCallback onViewRaw;

  /// 代次控件（失败态：`current = null` + 只给 `← 还原上一代`）；
  /// null = 该分组没有可还原的存活代，不显示。
  final Widget? versionStepper;

  const FailedAttemptBubble({
    super.key,
    required this.attempt,
    required this.onRefresh,
    required this.onEditAndRetry,
    required this.onClear,
    required this.onViewRaw,
    this.versionStepper,
  });

  void _showMenu(BuildContext context, Offset position) {
    showAppMenu<String>(
      context: context,
      position: position,
      items: [
        const PopupMenuItem(
          value: 'refresh',
          child: AppMenuAction(icon: Icons.replay, label: '刷新本轮'),
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
          value: 'raw',
          child: AppMenuAction(icon: Icons.raw_on, label: 'RAW'),
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
        case 'refresh':
          onRefresh();
        case 'editRetry':
          onEditAndRetry();
        case 'copy':
          Clipboard.setData(ClipboardData(text: attempt.userInput));
          if (context.mounted) {
            context.notices.success('已复制', dwell: const Duration(seconds: 1));
          }
        case 'raw':
          onViewRaw();
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
          ChatBubble(isUser: true, text: attempt.userInput, images: attempt.userImages),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: _FailureBox(attempt: attempt, errorColor: errorColor),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 2,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ?versionStepper,
              ActionButton(
                icon: Icons.replay,
                label: '刷新本轮',
                onPressed: onRefresh,
              ),
              ActionButton(
                icon: Icons.edit_note,
                label: '修改并重新提问',
                onPressed: onEditAndRetry,
              ),
              ActionButton(
                icon: Icons.raw_on,
                label: 'RAW',
                onPressed: onViewRaw,
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
            // 失败原因原文（纯文本，不走 Markdown）：外层统一选中容器负责
            // 选中/复制与默认菜单抑制（同气泡正文的约定），故此处不再用
            // `SelectableText`——它自带一套独立选区（`EditableText`），在外层
            // `SelectionArea` 下会成为选区硬边界，跨条目连续选中到此为止。
            PlainTextPreview(
              data: attempt.errorMessage,
              base: TextStyle(fontSize: 13, height: 1.5, color: errorColor),
            ),
          ],
        ],
      ),
    );
  }
}
