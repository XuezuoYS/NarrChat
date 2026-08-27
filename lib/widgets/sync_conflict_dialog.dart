import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 同步冲突的用户选择。
enum SyncConflictAction {
  /// 取消本次同步，并把同步模式改为手动。
  cancelSync,

  /// 进入冲突解决页（合并决策页）逐本确认。
  resolve,
}

/// 打开同步冲突对话框。
///
/// 仅当同步检出「真冲突」（双方都改过同一部件）时调用。返回用户选择；
/// 关闭对话框（Esc / 点空白）视为 [SyncConflictAction.cancelSync]。
Future<SyncConflictAction> showSyncConflictDialog(BuildContext context) {
  return showDialog<SyncConflictAction>(
    context: context,
    builder: (ctx) => const _SyncConflictDialog(),
  ).then((action) => action ?? SyncConflictAction.cancelSync);
}

class _SyncConflictDialog extends StatelessWidget {
  const _SyncConflictDialog();

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return AlertDialog(
      title: const Text('检测到同步冲突'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: colors.warning.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.sync_problem_outlined,
                      size: 20, color: colors.warning),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '本地与云端在同一本书 / Mod 上都有修改，无法自动合并。'
                    '请选择如何处理：',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '「解决冲突」会打开合并决策页逐本对比；「取消同步」将中止本次同步，'
              '并暂停自动同步（切换为手动模式），稍后可从云端备份列表恢复/合并。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.close, size: 18),
          label: const Text('取消同步'),
          onPressed: () =>
              Navigator.of(context).pop(SyncConflictAction.cancelSync),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.merge_outlined, size: 18),
          label: const Text('解决冲突'),
          onPressed: () => Navigator.of(context).pop(SyncConflictAction.resolve),
        ),
      ],
    );
  }
}
