import 'package:flutter/material.dart';

import '../models/round.dart';

/// AI 气泡底部控件：
/// - Token 用量（只读文本）
/// - 查看本轮侧边栏
/// - 刷新本轮
/// - 查看调试信息（仅最新一轮，展示发送的 Prompt 与 AI 原始返回）
/// - 删除本轮
class AiBubbleActions extends StatelessWidget {
  final Round round;
  final VoidCallback onViewSidebar;
  final VoidCallback onDelete;
  final VoidCallback onRefresh;
  final VoidCallback? onViewDebug;

  const AiBubbleActions({
    super.key,
    required this.round,
    required this.onViewSidebar,
    required this.onDelete,
    required this.onRefresh,
    this.onViewDebug,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '输入 Tokens: ${round.tokensIn}  ·  输出 Tokens: ${round.tokensOut}',
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF5F6368),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 2,
          runSpacing: 2,
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _ActionButton(
              icon: Icons.view_sidebar_outlined,
              label: '查看侧边栏',
              onPressed: onViewSidebar,
            ),
            _ActionButton(
              icon: Icons.refresh,
              label: '刷新本轮',
              onPressed: onRefresh,
            ),
            if (onViewDebug != null)
              _ActionButton(
                icon: Icons.bug_report_outlined,
                label: '调试',
                onPressed: onViewDebug!,
              ),
            _ActionButton(
              icon: Icons.delete_outline,
              label: '删除本轮',
              color: theme.colorScheme.error,
              onPressed: onDelete,
            ),
          ],
        ),
      ],
    );
  }
}

/// 小号操作按钮。
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = color ?? theme.colorScheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
