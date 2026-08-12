import 'package:flutter/material.dart';

import '../models/round.dart';
import 'action_button.dart';

/// AI 气泡底部控件：
/// - Token 用量（只读文本）
/// - 查看本轮侧边栏
/// - 刷新本轮
/// - 删除本轮
class AiBubbleActions extends StatelessWidget {
  final Round round;
  final VoidCallback onViewSidebar;
  final VoidCallback onDelete;
  final VoidCallback onRefresh;

  const AiBubbleActions({
    super.key,
    required this.round,
    required this.onViewSidebar,
    required this.onDelete,
    required this.onRefresh,
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
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
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
            ActionButton(
              icon: Icons.view_sidebar_outlined,
              label: '查看侧边栏',
              onPressed: onViewSidebar,
            ),
            ActionButton(
              icon: Icons.refresh,
              label: '刷新本轮',
              onPressed: onRefresh,
            ),
            ActionButton(
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
