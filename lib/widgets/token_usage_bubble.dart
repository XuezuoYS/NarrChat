import 'package:flutter/material.dart';

import '../models/round.dart';
import '../models/token_usage.dart';
import '../utils/formats.dart';
import 'markdown_preview.dart';

/// 本轮 Token 计费明细卡（点击 Token 栏弹出，点击卡外关闭）。
///
/// 展示口径：
/// - **未启用子模型**（`round_stack` 四个子模型字段全 NULL）：只显示主模型；
/// - **启用子模型**：分别显示主模型、子模型、总计三组统计；
/// - 任何缺失值都显示斜体「（无）」，`0` 照常显示为 `0`。
///
/// 每组统计包含：模型名、输入 token、缓存命中输入 token、输出 token、
/// 缓存命中率与总 token（输入 + 输出）。卡片内文字可选中复制，并与其他
/// 可选中区域同一套交互（[SelectableTextArea]：鼠标拖拽 / 触屏双击选中后
/// 自动弹出「复制 / 全选」工具条）。
class TokenUsageBubble extends StatelessWidget {
  final Round round;

  const TokenUsageBubble({super.key, required this.round});

  @override
  Widget build(BuildContext context) {
    final usage = RoundTokenUsage.of(round);
    final theme = Theme.of(context);
    return Material(
      elevation: 6,
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: usage.hasSubagent ? 340 : 300),
        child: SelectableTextArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(theme, usage),
                const SizedBox(height: 8),
                _buildSection(
                  theme,
                  usage.main,
                  sectionKey: const ValueKey('token_usage_main_section'),
                  showBadge: usage.hasSubagent,
                ),
                if (usage.hasSubagent) ...[
                  const SizedBox(height: 8),
                  Divider(
                    height: 1,
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildSection(
                    theme,
                    usage.subagent!,
                    sectionKey: const ValueKey('token_usage_subagent_section'),
                    showBadge: true,
                  ),
                  const SizedBox(height: 8),
                  _buildSection(
                    theme,
                    usage.total,
                    sectionKey: const ValueKey('token_usage_total_section'),
                    showBadge: true,
                    highlight: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, RoundTokenUsage usage) {
    return Row(
      children: [
        Icon(Icons.token_outlined, size: 15, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Text(
          'Token 用量',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const Spacer(),
        if (usage.hasSubagent)
          Text(
            '主模型 + 子模型',
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  /// 一组统计（主 / 子 / 总计）的分区。
  Widget _buildSection(
    ThemeData theme,
    TokenUsageStats stats, {
    required Key sectionKey,
    required bool showBadge,
    bool highlight = false,
  }) {
    final scheme = theme.colorScheme;
    final roleKey = _roleKeyOf(stats.role);
    final labelStyle = TextStyle(
      fontSize: 10.5,
      height: 1.2,
      color: scheme.onSurfaceVariant,
    );
    final valueStyle = TextStyle(
      fontSize: 13.5,
      height: 1.15,
      fontWeight: highlight ? FontWeight.w700 : FontWeight.w600,
      color: highlight ? scheme.primary : scheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      key: sectionKey,
      padding: highlight
          ? const EdgeInsets.fromLTRB(10, 8, 10, 8)
          : EdgeInsets.zero,
      decoration: highlight
          ? BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (showBadge) ...[
                _badge(theme, _labelOf(stats.role), highlight: highlight),
                const SizedBox(width: 8),
              ],
              if (stats.role == TokenUsageRole.total)
                Expanded(
                  child: Text(
                    '主模型 + 子模型',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Expanded(
                  child: Text(
                    stats.displayModelName,
                    key: ValueKey('token_usage_${roleKey}_model_name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _metric(
                  labelStyle,
                  valueStyle,
                  label: '输入',
                  value: stats.tokensIn,
                  valueKey: ValueKey('token_usage_${roleKey}_input'),
                ),
              ),
              Expanded(
                child: _metric(
                  labelStyle,
                  valueStyle,
                  label: '缓存命中输入',
                  value: stats.cachedTokensIn,
                  valueKey: ValueKey('token_usage_${roleKey}_cached'),
                ),
              ),
              Expanded(
                child: _metric(
                  labelStyle,
                  valueStyle,
                  label: '输出',
                  value: stats.tokensOut,
                  valueKey: ValueKey('token_usage_${roleKey}_output'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: Text(
                  '缓存命中率 ${stats.cacheHitRateText}',
                  key: ValueKey('token_usage_${roleKey}_cache_rate'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '总 token ${stats.totalTokensText}',
                key: ValueKey('token_usage_${roleKey}_total'),
                maxLines: 1,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
                  color: highlight ? scheme.primary : scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(
    TextStyle labelStyle,
    TextStyle valueStyle, {
    required String label,
    required int? value,
    required Key valueKey,
  }) {
    final missing = value == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: labelStyle,
        ),
        const SizedBox(height: 2),
        Text(
          Formats.formatTokenCount(value),
          key: valueKey,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: missing
              ? valueStyle.copyWith(
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w400,
                  color: labelStyle.color,
                  fontSize: 12.5,
                )
              : valueStyle,
        ),
      ],
    );
  }

  Widget _badge(ThemeData theme, String label, {bool highlight = false}) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: highlight ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }

  static String _roleKeyOf(TokenUsageRole role) => switch (role) {
    TokenUsageRole.main => 'main',
    TokenUsageRole.subagent => 'subagent',
    TokenUsageRole.total => 'total',
  };

  static String _labelOf(TokenUsageRole role) => switch (role) {
    TokenUsageRole.main => '主模型',
    TokenUsageRole.subagent => '子模型',
    TokenUsageRole.total => '总计',
  };
}

/// 在 [context]（Token 栏）旁弹出 [round] 的 Token 用量卡。
///
/// 点击卡外任意位置即关闭（透明遮罩拦截，与 Flutter 下拉菜单同机制）；
/// 卡片优先贴 Token 栏上方，空间不足时翻到下方，并收拢在视口内。
Future<void> showTokenUsageBubble(
  BuildContext context, {
  required Round round,
}) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Future.value();
  // Overlay 坐标系（= 卡片的摆放坐标系）里的 Token 栏矩形。
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return Navigator.of(context)
      .push(_TokenUsageBubbleRoute(round: round, anchor: anchor));
}

/// 悬浮卡路由：透明遮罩（点击外部关闭）+ 按 [anchor] 贴边摆放。
class _TokenUsageBubbleRoute extends PopupRoute<void> {
  final Round round;
  final Rect anchor;

  _TokenUsageBubbleRoute({required this.round, required this.anchor});

  @override
  Color get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => '关闭 Token 用量卡';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return CustomSingleChildLayout(
      delegate: _BubbleLayoutDelegate(anchor: anchor),
      child: TokenUsageBubble(round: round),
    );
  }
}

/// 卡片摆放：优先贴在 Token 栏上方左对齐，空间不足时翻到下方，
/// 最后把水平方向收拢进视口（避免贴边时被裁掉）。
class _BubbleLayoutDelegate extends SingleChildLayoutDelegate {
  /// 卡片与 Token 栏之间的间距。
  static const double _gap = 6;

  /// 与视口边缘的安全距离。
  static const double _margin = 8;

  final Rect anchor;

  const _BubbleLayoutDelegate({required this.anchor});

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = size.width - childSize.width - _margin;
    final left = anchor.left.clamp(
      _margin,
      maxLeft < _margin ? _margin : maxLeft,
    );
    final above = anchor.top - _gap - childSize.height;
    if (above >= _margin) return Offset(left, above);
    final below = anchor.bottom + _gap;
    if (below + childSize.height + _margin <= size.height) {
      return Offset(left, below);
    }
    return Offset(left, _margin);
  }

  @override
  bool shouldRelayout(_BubbleLayoutDelegate oldDelegate) =>
      oldDelegate.anchor != anchor;
}
