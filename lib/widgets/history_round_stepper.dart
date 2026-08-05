import 'package:flutter/material.dart';

/// 历史轮次数步进器（Stepper），最小值为 1。
class HistoryRoundStepper extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const HistoryRoundStepper({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        const Expanded(
          child: Text('历史轮次数', style: TextStyle(fontSize: 14)),
        ),
        IconButton(
          onPressed: value > 1 ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
          tooltip: '减少',
        ),
        SizedBox(
          width: 40,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        IconButton(
          onPressed: () => onChanged(value + 1),
          icon: const Icon(Icons.add_circle_outline),
          tooltip: '增加',
        ),
        Text(
          '轮',
          style: TextStyle(color: theme.colorScheme.outline, fontSize: 13),
        ),
      ],
    );
  }
}
