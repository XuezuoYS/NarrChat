import 'package:flutter/material.dart';

import '../models/round.dart';
import '../models/token_usage.dart';
import '../utils/formats.dart';
import 'token_usage_bubble.dart';

/// AI 气泡底部的「元信息」胶囊：模型名 + 输入 / 输出 Token。
///
/// **整块可点**：弹出 [TokenUsageBubble] 展示本轮 Token 计费明细。
/// 启用子模型时外显 **主 + 子总计**，模型名后加「+ 子模型」，避免少算第二步；
/// 未启用子模型时行为与旧版完全一致。
///
/// 布局：宽度够时单行（模型名在左、Token 在右）；不够时仅把 Token 换到下一行；
/// 极限挤压时两段各自省略。Wrap 只有两个子项，故最多两行。
class TokenUsagePill extends StatelessWidget {
  final Round round;

  const TokenUsagePill({super.key, required this.round});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usage = RoundTokenUsage.of(round);
    final mainName = usage.main.modelName.trim();
    final modelName = usage.hasSubagent
        ? (mainName.isEmpty ? '子模型' : '$mainName + 子模型')
        : mainName;
    final metaStyle = TextStyle(
      fontSize: 11,
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final radius = BorderRadius.circular(8);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: () => showTokenUsageBubble(context, round: round),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                '输入 Tokens: ${Formats.formatTokenCount(usage.total.tokensIn)}'
                '  ·  输出 Tokens: ${Formats.formatTokenCount(usage.total.tokensOut)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: metaStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
