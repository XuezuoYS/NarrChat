import 'package:flutter/material.dart';

import '../services/sync/sync_conflict.dart';
import '../theme/app_theme.dart';

/// 同步过程中弹出的「三选一」对话框。
///
/// 只在「PK 判不了、必须问人」时出现：主按钮进冲突决策页，另外两个选项
/// （采用云端 / 暂停同步）都带二次确认——确认框里取消就回到冲突决策。
Future<SyncConflictPromptResult> showSyncConflictPrompt(
  BuildContext context,
  List<SyncConflict> pending,
) async {
  final result = await showDialog<SyncConflictPromptResult>(
    context: context,
    builder: (dialogContext) => _SyncConflictPromptDialog(pending: pending),
  );
  return result ?? SyncConflictPromptResult.decide;
}

class _SyncConflictPromptDialog extends StatelessWidget {
  const _SyncConflictPromptDialog({required this.pending});

  final List<SyncConflict> pending;

  SyncConflict? get _first => pending.isEmpty ? null : pending.first;

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            message,
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _adoptRemote(BuildContext context) async {
    final count = pending.isEmpty ? 1 : pending.length;
    final confirmed = await _confirm(
      context,
      title: '采用云端备份？',
      message:
          '将用云端快照整份覆盖本地这 $count 项数据。\n\n'
          '本地还没上传的改动会丢失，且不能撤销。确定采用云端吗？',
      confirmLabel: '采用云端',
    );
    if (!context.mounted) return;
    Navigator.of(context).pop(
      confirmed
          ? SyncConflictPromptResult.adoptRemote
          : SyncConflictPromptResult.decide,
    );
  }

  Future<void> _pause(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: '暂停同步？',
      message:
          '将中止本次同步，并把同步模式改成「手动」：之后只有你点「同步」才会'
          '联网。\n\n可以随时在「设置 → 云同步」改回全自动。确定暂停吗？',
      confirmLabel: '暂停同步',
    );
    if (!context.mounted) return;
    Navigator.of(context).pop(
      confirmed
          ? SyncConflictPromptResult.pause
          : SyncConflictPromptResult.decide,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final conflict = _first;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      title: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colors.warning.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.sync_problem_outlined,
              size: 20,
              color: colors.warning,
            ),
          ),
          const SizedBox(width: 12),
          const Text('检测到同步冲突'),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本地与导入的云端快照都改过这些数据，PK 无法判定哪边更新，'
              '需要你决定怎么处理。',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colors.textPrimary,
              ),
            ),
            if (conflict != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: BorderRadius.circular(
                    NarrChatTheme.controlRadius,
                  ),
                  border: Border.all(color: colors.divider),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conflict.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '云端${conflict.remoteGenerationLabel} · '
                      '设备 ${conflict.remoteDeviceShort}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.textSecondary,
                      ),
                    ),
                    if (pending.length > 1) ...[
                      const SizedBox(height: 4),
                      Text(
                        '另有 ${pending.length - 1} 项也需要你选择',
                        style: TextStyle(fontSize: 11.5, color: colors.warning),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () =>
                      Navigator.of(context)
                          .pop(SyncConflictPromptResult.decide),
                  icon: const Icon(Icons.rule_folder_outlined, size: 18),
                  label: const Text('冲突决策（逐项选择）'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _adoptRemote(context),
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('采用云端备份'),
                ),
                TextButton.icon(
                  onPressed: () => _pause(context),
                  icon: const Icon(Icons.pause_circle_outline, size: 18),
                  label: const Text('暂停同步并改为手动'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: const [],
    );
  }
}
