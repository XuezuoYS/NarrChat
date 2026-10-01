import 'package:flutter/material.dart';

import '../models/book.dart';

/// 「记忆总结轮次合并」档位选择器：0（不开启）/ 5 / 10。
///
/// 档位清单与越界收敛的**单一真源**是 [Book.memorySummaryRoundTiers] /
/// [Book.normalizeMemorySummaryRounds]：库中出现未支持的数值时，本控件按 0
/// 展示（选中「0（不开启）」），并随该书的保存把 0 写回库内。
class MemorySummaryRoundSelector extends StatelessWidget {
  /// 控件标题（与注释文案同处一处，改一处同步生效）。
  static const String label = '记忆总结轮次合并';

  /// 档位小字注释：档位语义 + 「已合并条目不受后续变更影响」。
  static const String note = '压缩历史记忆，0为不开启，固定数值为压缩的每项包含轮次，'
      '如5对应1-5、6-10；已合并的条目在关闭后或调整其它档位后不会变更。';

  /// 档位显示文案（本控件与合并预览同一口径）。
  static String tierText(int tier) => tier == 0 ? '0（不开启）' : '$tier';

  /// 当前档位（未支持的数值按 0 展示）。
  final int value;

  /// 档位变更回调：只会回调受支持档位。
  final ValueChanged<int> onChanged;

  const MemorySummaryRoundSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(label, style: TextStyle(fontSize: 14)),
        const SizedBox(height: 6),
        SegmentedButton<int>(
          segments: [
            for (final tier in Book.memorySummaryRoundTiers)
              ButtonSegment<int>(
                value: tier,
                label: Text(tierText(tier)),
              ),
          ],
          selected: {Book.normalizeMemorySummaryRounds(value)},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
        const SizedBox(height: 6),
        Text(
          note,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.outline,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}
