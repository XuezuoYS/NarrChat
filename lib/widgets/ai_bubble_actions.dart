import 'package:flutter/material.dart';

import '../models/round.dart';
import 'action_button.dart';
import 'token_usage_pill.dart';

/// AI 气泡底部控件：
/// - 代次控件（修改还原：`← x/y →`，仅 ≥2 存活代时由调用方传入）
/// - Token 栏（模型名 + 输入 / 输出 Token，整块可点 → 弹出计费明细气泡）
/// - 查看本轮侧边栏
/// - RAW（查看请求/返回原始数据，仅存在数据时显示）
/// - 刷新本轮
/// - 按意见修改（紧邻「刷新本轮」右侧）
/// - 删除本轮
class AiBubbleActions extends StatelessWidget {
  final Round round;
  final VoidCallback onViewSidebar;
  final VoidCallback onDelete;
  final VoidCallback onRefresh;

  /// 「按意见修改」回调（以填写的意见重写本轮；新增一代，旧代可切回）。
  final VoidCallback onModifyByOpinion;

  /// RAW 查看回调（null = 本轮无 RAW 数据，不显示按钮）。
  final VoidCallback? onViewRaw;

  /// 代次控件（null = 不显示）；恒占 `Wrap` 首位（控件自身不换行）。
  final Widget? versionStepper;

  const AiBubbleActions({
    super.key,
    required this.round,
    required this.onViewSidebar,
    required this.onDelete,
    required this.onRefresh,
    required this.onModifyByOpinion,
    this.onViewRaw,
    this.versionStepper,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TokenUsagePill(round: round),
        const SizedBox(height: 4),
        Wrap(
          spacing: 2,
          runSpacing: 2,
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ?versionStepper,            ActionButton(
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
              icon: Icons.edit_note,
              label: '按意见修改',
              onPressed: onModifyByOpinion,
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
