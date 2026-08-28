import 'package:flutter/material.dart';

import '../services/sync/sync_remote_store.dart';
import '../services/webdav_service.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';

/// 快照恢复方式。
enum SyncRestoreMode {
  /// 用该快照整体覆盖本地数据（删除本地后替换）。
  replace,

  /// 打开合并决策页逐本确认。
  merge,
}

/// 打开快照恢复对话框：展示「云端记录 #N」元信息，选择处理方式后统一确认。
///
/// 返回 [SyncRestoreMode]；取消 / Esc 返回 null。
Future<SyncRestoreMode?> showSyncRestoreDialog(
  BuildContext context, {
  required WebDavFile file,
}) {
  return showDialog<SyncRestoreMode>(
    context: context,
    builder: (_) => SyncRestoreDialog(file: file),
  );
}

/// 快照恢复对话框（新版命名与视觉）：
/// 头部展示代际 / 生成时间 / 大小，两个单选卡片选择处置方式。
class SyncRestoreDialog extends StatefulWidget {
  final WebDavFile file;

  const SyncRestoreDialog({super.key, required this.file});

  @override
  State<SyncRestoreDialog> createState() => _SyncRestoreDialogState();
}

class _SyncRestoreDialogState extends State<SyncRestoreDialog> {
  /// 默认选「合并」（安全侧）；「删除并恢复」需用户显式点选。
  SyncRestoreMode _mode = SyncRestoreMode.merge;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final file = widget.file;
    final gen = WebDavSyncStore.generationOf(file.name);
    return AlertDialog(
      title: const Text('恢复备份'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部：云端记录 #N + 生成时间与大小（新版命名信息）。
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.divider),
              ),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, size: 22, color: NarrChatTheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          gen == null ? file.name : '云端记录 #$gen',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: colors.textPrimary,
                          ),
                        ),
                        if (snapshotMetaOf(file).isNotEmpty)
                          Text(
                            snapshotMetaOf(file),
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors.textSecondary,
                            ),
                          ),
                        Text(
                          file.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            color: colors.textSecondary.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '请选择如何处理本地数据：',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            _RestoreOption(
              icon: Icons.merge_outlined,
              selected: _mode == SyncRestoreMode.merge,
              title: '合并本地数据',
              subtitle: '打开合并决策页逐本确认；合并结果将作为新版本同步到云端。',
              onTap: () => setState(() => _mode = SyncRestoreMode.merge),
            ),
            const SizedBox(height: 8),
            _RestoreOption(
              icon: Icons.delete_outline,
              selected: _mode == SyncRestoreMode.replace,
              title: '删除本地数据并恢复',
              subtitle: '用该快照整体覆盖本地数据，恢复结果将作为新版本同步到云端。',
              onTap: () => setState(() => _mode = SyncRestoreMode.replace),
            ),
            if (_mode == SyncRestoreMode.replace) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.historyBackground,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colors.historyHeader),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '本地现有数据将被整体删除，此操作无法撤销。',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_mode),
          child: Text(_mode == SyncRestoreMode.replace ? '删除并恢复' : '合并'),
        ),
      ],
    );
  }
}

/// 恢复方式选择卡片：可点选（选中侧以主题主色描边 + 单选图标）。
class _RestoreOption extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _RestoreOption({
    required this.icon,
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final borderColor = selected ? NarrChatTheme.primary : colors.divider;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? colors.userBubble : colors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: selected ? 1.4 : 1),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: selected ? NarrChatTheme.primary : colors.textSecondary,
            ),
            const SizedBox(width: 10),
            Icon(icon, size: 20, color: colors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 快照条目标题：`云端记录 #N`；解析失败回退文件名。
String snapshotLabelOf(WebDavFile file) {
  final gen = WebDavSyncStore.generationOf(file.name);
  return gen == null ? file.name : '云端记录 #$gen';
}

/// 快照条目标注：`时间 · 大小`（时间优先取文件名内嵌生成时间戳）。
String snapshotMetaOf(WebDavFile file) {
  final parts = <String>[];
  final t = WebDavSyncStore.snapshotTimeOf(file.name) ?? file.lastModified;
  if (t != null) parts.add(Formats.formatDateTime(t));
  if (file.size > 0) parts.add(Formats.formatBytes(file.size));
  return parts.join(' · ');
}
