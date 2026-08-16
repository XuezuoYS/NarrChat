import 'package:flutter/material.dart';

import '../models/round.dart';
import 'action_button.dart';

/// AI 气泡底部控件：
/// - Token 用量（只读文本）
/// - 查看本轮侧边栏
/// - RAW（查看请求/返回原始数据，仅存在数据时显示）
/// - 刷新本轮
/// - 删除本轮
class AiBubbleActions extends StatelessWidget {
  final Round round;
  final VoidCallback onViewSidebar;
  final VoidCallback onDelete;
  final VoidCallback onRefresh;

  /// RAW 查看回调（null = 本轮无 RAW 数据，不显示按钮）。
  final VoidCallback? onViewRaw;

  const AiBubbleActions({
    super.key,
    required this.round,
    required this.onViewSidebar,
    required this.onDelete,
    required this.onRefresh,
    this.onViewRaw,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final modelName = round.modelName.trim();
    // 模型名（{{model}} 解析值）与 Token 用量放同一「元信息」胶囊内：
    // 宽度够时单行（模型名在左、Token 在右）；不够时仅把 Token 换到下一行；
    // 极限挤压时两段各自省略。Wrap 只有两个子项，故最多两行。
    final metaStyle = TextStyle(
      fontSize: 11,
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: [FontFeature.tabularFigures()],
    );
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
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (modelName.isNotEmpty)
                Text(
                  modelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: metaStyle.copyWith(fontWeight: FontWeight.w600),
                ),
              Text(
                '输入 Tokens: ${round.tokensIn}  ·  输出 Tokens: ${round.tokensOut}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: metaStyle,
              ),
            ],
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
            if (onViewRaw != null)
              ActionButton(
                icon: Icons.raw_on,
                label: 'RAW',
                onPressed: onViewRaw!,
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
