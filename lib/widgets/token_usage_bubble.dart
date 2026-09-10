import 'package:flutter/material.dart';

import '../models/round.dart';
import '../utils/formats.dart';

/// 悬浮气泡里的一行 Token 明细。
///
/// [value] 为 `null` 表示**无数据**（数据库无该值 / 模型未返回该字段），
/// 渲染为斜体「（无）」（见 [TokenUsageBubble]）。
class TokenUsageRow {
  final String label;
  final String? value;

  const TokenUsageRow(this.label, this.value);
}

/// 本轮 Token 计费明细气泡（点击 Token 栏弹出，点击气泡外关闭）。
///
/// 逐行展示：模型名、输入 token、缓存命中输入 token、缓存命中率、输出 token、
/// 总 token。无数据的行显示斜体「（无）」；气泡内文字可选中复制。
class TokenUsageBubble extends StatelessWidget {
  final Round round;

  const TokenUsageBubble({super.key, required this.round});

  /// 明细行（顺序即展示顺序）。
  ///
  /// 与渲染分离的纯函数：便于直接断言各桶与「无数据」的判定。
  static List<TokenUsageRow> rowsOf(Round round) {
    final modelName = round.modelName.trim();
    return [
      TokenUsageRow('模型名', modelName.isEmpty ? null : modelName),
      TokenUsageRow('输入 token', _countOf(round.tokensIn)),
      TokenUsageRow('缓存命中输入 token', _countOf(round.cachedTokensIn)),
      TokenUsageRow(
        '缓存命中率',
        Formats.formatCacheHitRate(round.cachedTokensIn, round.tokensIn),
      ),
      TokenUsageRow('输出 token', _countOf(round.tokensOut)),
      TokenUsageRow('总 token', _countOf(totalTokens(round))),
    ];
  }

  /// 总 token = 输入 + 输出。
  ///
  /// 两侧都无数据 → null（「（无）」）；只有一侧有数据时按已知侧求和。
  static int? totalTokens(Round round) {
    if (round.tokensIn == null && round.tokensOut == null) return null;
    return (round.tokensIn ?? 0) + (round.tokensOut ?? 0);
  }

  static String? _countOf(int? count) =>
      count == null ? null : Formats.formatTokenCount(count);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 6,
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        // 气泡内全部文字可选中复制（含拖动跨行选择）。
        child: SelectionArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final row in rowsOf(round)) _row(theme, row),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, TokenUsageRow row) {
    final labelStyle = TextStyle(
      fontSize: 11,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final valueStyle = TextStyle(
      fontSize: 11.5,
      color: theme.colorScheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final missing = row.value == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 118, child: Text(row.label, style: labelStyle)),
          Expanded(
            child: Text(
              missing ? Formats.noData : row.value!,
              style: missing
                  ? valueStyle.copyWith(fontStyle: FontStyle.italic)
                  : valueStyle,
            ),
          ),
        ],
      ),
    );
  }
}

/// 在 [context]（Token 栏）旁弹出 [round] 的 Token 用量气泡。
///
/// 点击气泡外任意位置即关闭（透明遮罩拦截，与 Flutter 下拉菜单同机制）；
/// 气泡优先贴 Token 栏上方，空间不足时翻到下方，并收拢在视口内。
Future<void> showTokenUsageBubble(BuildContext context, {required Round round}) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Future.value();
  // Overlay 坐标系（= 气泡的摆放坐标系）里的 Token 栏矩形。
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return Navigator.of(context).push(
    _TokenUsageBubbleRoute(round: round, anchor: anchor),
  );
}

/// 悬浮气泡路由：透明遮罩（点击外部关闭）+ 按 [anchor] 贴边摆放。
class _TokenUsageBubbleRoute extends PopupRoute<void> {
  final Round round;
  final Rect anchor;

  _TokenUsageBubbleRoute({required this.round, required this.anchor});

  @override
  Color get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => '关闭 Token 用量气泡';

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

/// 气泡摆放：优先贴在 Token 栏上方左对齐，空间不足时翻到下方，
/// 最后把水平方向收拢进视口（避免贴边时被裁掉）。
class _BubbleLayoutDelegate extends SingleChildLayoutDelegate {
  /// 气泡与 Token 栏之间的间距。
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
    final left = anchor.left.clamp(_margin, maxLeft < _margin ? _margin : maxLeft);
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
