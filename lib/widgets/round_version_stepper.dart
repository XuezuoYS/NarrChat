import 'package:flutter/material.dart';

/// 代次控件（`← x/y →`）：在当前轮的历次生成之间切换。
///
/// - [current] 为 `null` = 失败态（「临时代」，无编号），仍可 `← 还原上一代`；
/// - 单代不显示控件（显隐由调用方按 [RoundVersionInfo.switchable] / `prevUuid` 判断）；
/// - **控件自身不换行**：整体限宽 + `FittedBox` 缩放，保证在气泡 footer 的 `Wrap`
///   里永远占第一行且不溢出（其余按钮可换行到后续行）；
/// - 文案不写「共 N 版」（序号可跳步），代号口径是 `第 x 代 / 最新第 y 代`。
class RoundVersionStepper extends StatelessWidget {
  static const Key stepperKey = Key('round_version_stepper');
  static const Key prevKey = Key('round_version_prev');
  static const Key nextKey = Key('round_version_next');

  /// 当前代号；`null` = 临时代（失败态，无编号）。
  final int? current;

  /// 本分组最大存活代号。
  final int latest;

  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// 生成中 / 不可切换 → false（整体置灰且不可点）。
  final bool enabled;

  /// 悬浮说明（例：`'第 3 代 / 最新第 7 代'`）。
  final String? tooltip;

  const RoundVersionStepper({
    super.key,
    required this.current,
    required this.latest,
    this.onPrev,
    this.onNext,
    this.enabled = true,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = theme.colorScheme.onSurfaceVariant;
    final disabledColor = theme.disabledColor;
    final label = current == null ? '临时' : '$current/$latest';
    final text = tooltip ?? (current == null ? '临时代（可还原上一代）' : '第 $current 代 / 最新第 $latest 代');

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 132),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Tooltip(
          message: text,
          child: Row(
            key: stepperKey,
            mainAxisSize: MainAxisSize.min,
            children: [
              _arrow(
                key: prevKey,
                icon: Icons.chevron_left,
                onPressed: enabled ? onPrev : null,
                color: enabled ? activeColor : disabledColor,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.1,
                    fontWeight: FontWeight.w500,
                    color: enabled ? activeColor : disabledColor,
                  ),
                ),
              ),
              _arrow(
                key: nextKey,
                icon: Icons.chevron_right,
                onPressed: enabled ? onNext : null,
                color: enabled ? activeColor : disabledColor,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 紧凑箭头（28×28）：与既有 `ActionButton` 的视觉密度协调。
  Widget _arrow({
    required Key key,
    required IconData icon,
    required VoidCallback? onPressed,
    required Color color,
  }) {
    return IconButton(
      key: key,
      icon: Icon(icon, size: 18),
      onPressed: onPressed,
      color: color,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      splashRadius: 16,
    );
  }
}
