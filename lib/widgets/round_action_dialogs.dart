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

/// 「删除此代」确认对话框（单代删除）。
///
/// 体验与「删除本轮」一致：同一个气泡扩展菜单入口 + 二次确认。
/// 文案如实交代落点（自动切换到第几代 / 本轮剩余几代）与代价
/// （以该代为基础生成的后续轮次内容一并移除且无法恢复）。
Future<bool> showDeleteGenerationConfirmDialog(
  BuildContext context, {
  required int roundIndex,
  required int currentSerial,
  required int fallbackSerial,
  required int remaining,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除此代'),
      content: Text(
        '将删除第 $roundIndex 轮的第 $currentSerial 代，'
        '并自动切换到第 $fallbackSerial 代（本轮剩余 $remaining 代）。\n'
        '以该代为基础生成的后续轮次内容会一并移除，且无法恢复。',
      ),
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

/// 「刷新本轮」二次确认对话框（**唯一入口的确认框**）。
///
/// 「刷新本轮」= 删除该轮起的投影行，再以该轮的用户输入重新请求 AI（新增一代，
/// 旧代留在版本树可切回）。气泡底部按钮、气泡右键菜单、失败条目按钮/菜单都走这一处
/// 文案：**不提示「会丢失后续内容」**——旧版本与后续轮次都保留在版本树里，
/// 切换代次即可取回，喊「丢失」只会吓人。
Future<bool> showRefreshRoundConfirmDialog(
  BuildContext context,
  int roundIndex,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('刷新本轮'),
      content: Text(
        '将重新生成第 $roundIndex 轮，并以该轮的用户输入重新请求 AI。是否继续？',
      ),
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
