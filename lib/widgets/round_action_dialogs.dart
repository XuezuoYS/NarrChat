import 'package:flutter/material.dart';

import '../models/round.dart';

/// 删除轮次选项。
enum DeleteRoundChoice { single, all }

/// “删除本轮”对话框：提供“仅删除本轮”与“删除本轮及后续所有轮次”两个选项。
Future<DeleteRoundChoice?> showDeleteRoundDialog(
  BuildContext context,
  Round round,
) {
  return showDialog<DeleteRoundChoice>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('删除本轮（第 ${round.roundIndex} 轮）'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(DeleteRoundChoice.single),
          child: const Row(
            children: [
              Icon(Icons.delete_outline, size: 22),
              SizedBox(width: 12),
              Expanded(child: Text('仅删除本轮')),
            ],
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(DeleteRoundChoice.all),
          child: const Row(
            children: [
              Icon(Icons.delete_sweep_outlined, size: 22),
              SizedBox(width: 12),
              Expanded(child: Text('删除本轮及后续所有轮次')),
            ],
          ),
        ),
      ],
    ),
  );
}

/// “重新提问”二次确认对话框。
///
/// 与「刷新本轮」合并：删除本轮及后续所有轮次，再以该轮的用户输入重新请求 AI。
Future<bool> showReAskConfirmDialog(BuildContext context, Round round) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重新提问'),
      content: Text('将删除本轮及后续所有轮次，并以“第 ${round.roundIndex} 轮”的用户输入重新请求 AI。是否继续？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('继续'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 删除书籍确认对话框。
Future<bool> showDeleteBookConfirmDialog(BuildContext context, String title) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除书籍'),
      content: Text('确定删除书籍「$title」吗？该书籍的全部轮次将一并删除，且无法恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return result ?? false;
}
