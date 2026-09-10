import 'package:flutter/material.dart';

import '../models/round.dart';
import '../utils/formats.dart';
import 'token_usage_bubble.dart';

/// AI 气泡底部的「元信息」胶囊：模型名 + 输入 / 输出 Token。
///
/// **整块可点**：弹出 [TokenUsageBubble] 展示本轮 Token 计费明细
/// （模型名、输入 / 缓存命中输入 / 缓存命中率 / 输出 / 总 token）。
///
/// 布局：宽度够时单行（模型名在左、Token 在右）；不够时仅把 Token 换到下一行；
/// 极限挤压时两段各自省略。Wrap 只有两个子项，故最多两行。
class TokenUsagePill extends StatelessWidget {
  final Round round;

  const TokenUsagePill({super.key, required this.round});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final modelName = round.modelName.trim();
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
                '输入 Tokens: ${Formats.formatTokenCount(round.tokensIn)}'
                '  ·  输出 Tokens: ${Formats.formatTokenCount(round.tokensOut)}',
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
