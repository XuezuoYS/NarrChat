import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../services/cloud_backup/backup_catalog.dart';
import '../theme/app_theme.dart';
import '../widgets/app_empty_hint.dart';
import '../widgets/app_notice_overlay.dart';
import '../widgets/island_bar.dart';
import '../widgets/narr_chat_app_bar.dart';

/// 书籍回收站（二级页）。
///
/// 只列「本机是墓碑、云端仍有快照」的书：每本书一行，主标题书名，副标题
/// 两行（UUID / 删除时间 + 轮次）。点行进入管理：还原此书或彻底删除。
class BookRecycleBinPage extends StatelessWidget {
  const BookRecycleBinPage({super.key});

  /// 打开二级页。
  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const BookRecycleBinPage()));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final provider = context.watch<CloudSyncProvider>();
    final entries = provider.deletedBackupUnits;
    return IslandAwareScaffold(
      backgroundColor: colors.surface,
      appBarBuilder: (context, extraRow) => NarrChatAppBar(
        extraRowHeight: extraRow,
        title: '书籍回收站',
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: provider.isBusy ? null : () => _refresh(context),
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: AppEmptyHint(
                  icon: Icons.delete_sweep_outlined,
                  text: '回收站是空的。\n删除的书会保留一份最新云端备份在这里。',
                ),
              ),
            )
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildHeader(context, colors, entries.length),
                    const SizedBox(height: 16),
                    for (final entry in entries)
                      _buildEntryCard(context, colors, provider, entry),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _refresh(BuildContext context) async {
    final provider = context.read<CloudSyncProvider>();
    await provider.refreshBackups();
    if (!context.mounted) return;
    if (provider.error != null) {
      context.notices.error('刷新失败：${provider.error}');
    }
  }

  /// 头部：数量 + 每本只留最新一代 + 操作说明。
  Widget _buildHeader(BuildContext context, NarrChatColors colors, int count) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: errorColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.restore_from_trash_outlined,
              color: errorColor,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '共 $count 本已删除的书',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '每本书只保留最新一次云端备份。',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
                const SizedBox(height: 2),
                Text(
                  '还原会把书恢复到书籍列表；彻底删除会删掉这份备份，之后无法再还原。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 一本已删除书一行。
  Widget _buildEntryCard(
    BuildContext context,
    NarrChatColors colors,
    CloudSyncProvider provider,
    BackupUnitEntry entry,
  ) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: provider.isBusy ? null : () => _openManage(context, entry),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: errorColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.menu_book_outlined,
                    size: 20,
                    color: errorColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.bookTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'UUID：${entry.unit.refUuid}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        _deletedLine(entry),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openManage(BuildContext context, BackupUnitEntry entry) async {
    if (context.read<CloudSyncProvider>().isBusy) return;
    final action = await showDialog<_RecycleAction>(
      context: context,
      builder: (_) => _ManageDeletedBookDialog(entry: entry),
    );
    if (action == null || !context.mounted) return;

    final provider = context.read<CloudSyncProvider>();
    if (action == _RecycleAction.restore) {
      final error = await provider.restoreDeletedBook(entry);
      if (!context.mounted) return;
      if (error != null) {
        context.notices.error('还原失败：$error');
        return;
      }
      // 书已恢复到列表：回到云备份面板，活书列表已由 provider 更新。
      Navigator.of(context).pop();
      return;
    }

    // 管理弹窗之后再来一道确认，避免误触。
    final confirmed = await _confirmPurge(context, entry);
    if (confirmed != true || !context.mounted) return;
    final error = await provider.permanentlyDeleteDeletedBook(entry);
    if (!context.mounted) return;
    if (error != null) {
      context.notices.error('彻底删除失败：$error');
      return;
    }
    context.notices.success('已彻底删除《${entry.bookTitle}》的云端备份');
  }

  Future<bool> _confirmPurge(
    BuildContext context,
    BackupUnitEntry entry,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('彻底删除这本书的备份？'),
        content: Text(
          '将从云端删除《${entry.bookTitle}》的最后一份备份。'
          '删除后无法再还原这本书，它也会从回收站移除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

enum _RecycleAction { restore, purge }

/// 管理一本已删除书：详情 + 还原 / 彻底删除。
class _ManageDeletedBookDialog extends StatelessWidget {
  const _ManageDeletedBookDialog({required this.entry});

  final BackupUnitEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final errorColor = Theme.of(context).colorScheme.error;
    final size = BackupCatalog.formatSize(entry.latest.size);
    final backupLine = StringBuffer()
      ..write('第 ${entry.latestGeneration} 代 · ')
      ..write(BackupCatalog.formatTime(entry.latest.lastModified));
    if (size.isNotEmpty) backupLine.write(' · $size');
    return AlertDialog(
      title: Text('管理「${entry.bookTitle}」'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DetailLine(label: 'UUID', value: entry.unit.refUuid),
            _DetailLine(
              label: '删除时间',
              value: BackupCatalog.formatTime(entry.deletedAt),
            ),
            _DetailLine(
              label: '轮次',
              value: _roundText(entry.deletedRoundIndex),
            ),
            _DetailLine(label: '云端备份', value: backupLine.toString()),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(_RecycleAction.restore),
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('还原此书'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(_RecycleAction.purge),
              style: OutlinedButton.styleFrom(
                foregroundColor: errorColor,
                side: BorderSide(color: errorColor.withValues(alpha: 0.5)),
              ),
              icon: const Icon(Icons.delete_forever_outlined, size: 18),
              label: const Text('彻底删除'),
            ),
            const SizedBox(height: 6),
            Text(
              '彻底删除会删掉云端最后一份备份，之后无法再还原。',
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12, color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

String _deletedLine(BackupUnitEntry entry) {
  return '删除于 ${BackupCatalog.formatTime(entry.deletedAt)}'
      ' · ${_roundText(entry.deletedRoundIndex)}';
}

String _roundText(int? roundIndex) {
  if (roundIndex == null) return '轮次未知';
  if (roundIndex <= 0) return '尚无轮次';
  return '第 $roundIndex 轮';
}
