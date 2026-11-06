import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_notice.dart';
import '../providers/cloud_sync_provider.dart';
import '../services/cloud_backup/backup_catalog.dart';
import '../services/cloud_backup/backup_unit.dart';
import '../services/webdav_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_empty_hint.dart';
import '../widgets/app_notice_overlay.dart';
import '../widgets/backup_unit_badge.dart';
import '../widgets/island_bar.dart';
import '../widgets/narr_chat_app_bar.dart';

/// 某个库在云端的代次列表（二级页）。
///
/// 顶层「云端备份」列表只列库（Library 库 / Mod 库 / 书籍《书名》库），
/// 点进来才看到代次：新 → 旧，每一代都能整份还原本地对应的库。
class BackupUnitPage extends StatelessWidget {
  const BackupUnitPage({super.key, required this.entry});

  /// 要展示的库（含全部快照，新 → 旧）。
  final BackupUnitEntry entry;

  /// 打开二级页。
  static Future<void> open(BuildContext context, BackupUnitEntry entry) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => BackupUnitPage(entry: entry)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final provider = context.watch<CloudSyncProvider>();
    return IslandAwareScaffold(
      backgroundColor: colors.surface,
      appBarBuilder: (context, extraRow) => NarrChatAppBar(
        extraRowHeight: extraRow,
        title: entry.displayName,
      ),
      body: entry.snapshots.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: AppEmptyHint(
                  icon: Icons.cloud_off_outlined,
                  text: '这个库在云端还没有备份',
                ),
              ),
            )
          // 宽屏下与设置页同一套骨架：内容列限宽 860、靠上排布。
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildHeader(context, colors),
                    const SizedBox(height: 16),
                    for (var i = 0; i < entry.snapshots.length; i++)
                      _buildGenerationCard(
                        context,
                        colors,
                        provider,
                        entry.snapshots[i],
                        isLatest: i == 0,
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  /// 头部：库名 + 代数概况 + 最新一代时间 + 操作说明。
  Widget _buildHeader(BuildContext context, NarrChatColors colors) {
    final latest = entry.latest;
    final sizeText = BackupCatalog.formatSize(latest.size);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BackupUnitBadge(kind: entry.unit.kind, size: 44, filled: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '共 ${entry.totalCount} 代 · 最新第 ${entry.latestGeneration} 代',
                      style: TextStyle(fontSize: 12, color: colors.textSecondary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '最新备份：${BackupCatalog.formatTime(latest.lastModified)}'
                      '${sizeText.isEmpty ? '' : ' · $sizeText'}',
                      style: TextStyle(fontSize: 11, color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '点某一代右侧的还原按钮，可整份覆盖本地对应的数据；本机还没备份的改动会丢失。',
            style: TextStyle(fontSize: 12, height: 1.4, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  /// 一代一张卡：代数 + 时间 / 大小 + 还原按钮。
  Widget _buildGenerationCard(
    BuildContext context,
    NarrChatColors colors,
    CloudSyncProvider provider,
    WebDavFile file, {
    required bool isLatest,
  }) {
    final generation = BackupUnit.generationOfSnapshotName(file.name);
    final time = BackupCatalog.formatTime(file.lastModified);
    final size = BackupCatalog.formatSize(file.size);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            size: 20,
            color: colors.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '第 $generation 代',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    if (isLatest) ...[
                      const SizedBox(width: 6),
                      const _LatestPill(),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$time${size.isEmpty ? '' : ' · $size'}',
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '下载并恢复此版本',
            icon: const Icon(Icons.cloud_download_outlined, size: 20),
            color: NarrChatTheme.primary,
            onPressed: provider.isBusy
                ? null
                : () => _restore(context, file, generation),
          ),
        ],
      ),
    );
  }

  /// 还原：确认 → 整份替换本地对应库 → 提示结果。
  Future<void> _restore(
    BuildContext context,
    WebDavFile file,
    int generation,
  ) async {
    final provider = context.read<CloudSyncProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('用这个备份覆盖本地？'),
        content: Text(
          '将用云端快照「${entry.displayName} · 第 $generation 代」整份替换本地的这项数据，'
          '本机还没备份的改动会丢失。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('替换'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final error = await provider.restoreSnapshot(
      file.name,
      label: entry.displayName,
    );
    if (!context.mounted) return;
    context.notices.show(
      error == null ? '已用第 $generation 代覆盖本地数据' : '处理失败：$error',
      kind: error == null ? NoticeKind.success : NoticeKind.error,
    );
  }
}

/// 「最新」小徽章（品牌色淡底）。
class _LatestPill extends StatelessWidget {
  const _LatestPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: NarrChatTheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        '最新',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: NarrChatTheme.primary,
        ),
      ),
    );
  }
}
