import 'package:flutter/material.dart';

import '../providers/cloud_sync_provider.dart';
import '../services/sync/sync_conflict.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';
import '../widgets/markdown_preview.dart';
import '../widgets/memory_summary_round_selector.dart';
import 'settings/settings_kit.dart';

/// 打开「本地 vs 云端」对比预览。
///
/// 两路并行加载（本地读 store、云端临时下载那一代快照），每侧独立失败；
/// 长文本默认折叠，展开后才用 Markdown 渲染，避免一次排版整本书。
Future<void> showSyncConflictPreview(
  BuildContext context,
  SyncConflict conflict,
  CloudSyncProvider provider,
) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _SyncConflictPreviewDialog(conflict: conflict, provider: provider),
  );
}

class _SyncConflictPreviewDialog extends StatefulWidget {
  const _SyncConflictPreviewDialog({
    required this.conflict,
    required this.provider,
  });

  final SyncConflict conflict;
  final CloudSyncProvider provider;

  @override
  State<_SyncConflictPreviewDialog> createState() =>
      _SyncConflictPreviewDialogState();
}

class _SyncConflictPreviewDialogState
    extends State<_SyncConflictPreviewDialog> {
  bool _loading = true;
  String? _error;
  SyncSidePreview? _local;
  SyncSidePreview? _remote;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<SyncSidePreview>([
        widget.provider.loadConflictPreview(
          widget.conflict,
          SyncPreviewSide.local,
        ),
        widget.provider.loadConflictPreview(
          widget.conflict,
          SyncPreviewSide.remote,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _local = results[0];
        _remote = results[1];
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.compare_arrows,
                    size: 20,
                    color: NarrChatTheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '对比预览 · ${widget.conflict.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '左：本地 · 右：云端${widget.conflict.remoteGenerationLabel}'
                          '（设备 ${widget.conflict.remoteDeviceShort}）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.divider),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colors = context.narrColors;
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(height: 12),
            Text(
              '正在读取两侧内容（云端需要下载'
              '${widget.conflict.remoteGenerationLabel}快照）…',
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 26,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 10),
              Text(
                '读取预览失败',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              SelectableText(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final local = _local;
    final remote = _remote;
    if (local == null || remote == null) {
      return const SizedBox.shrink();
    }
    return switch (widget.conflict.kind) {
      _ when local.book != null && remote.book != null => _buildBook(
        context,
        local.book!,
        remote.book!,
      ),
      _ when local.mods != null && remote.mods != null => _buildMods(
        context,
        local.mods!,
        remote.mods!,
      ),
      _ when local.library != null && remote.library != null => _buildLibrary(
        context,
        local.library!,
        remote.library!,
      ),
      _ => const SizedBox.shrink(),
    };
  }

  // --- 书籍 -------------------------------------------------------------------

  Widget _buildBook(
    BuildContext context,
    BookSidePreview local,
    BookSidePreview remote,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        _compactRow(context, '书名', local.title, remote.title),
        _compactRow(context, '分类', local.category, remote.category),
        _compactRow(
          context,
          '历史轮次',
          '${local.historyRounds}',
          '${remote.historyRounds}',
        ),
        _compactRow(
          context,
          MemorySummaryRoundSelector.label,
          MemorySummaryRoundSelector.tierText(local.memorySummaryRounds),
          MemorySummaryRoundSelector.tierText(remote.memorySummaryRounds),
        ),
        _compactRow(
          context,
          '代数（round_stack 行数）',
          '${local.roundGenerationCount}',
          '${remote.roundGenerationCount}',
        ),
        _compactRow(
          context,
          '最新轮次',
          local.latestRoundIndex > 0 ? '第 ${local.latestRoundIndex} 轮' : '暂无轮次',
          remote.latestRoundIndex > 0
              ? '第 ${remote.latestRoundIndex} 轮'
              : '暂无轮次',
        ),
        _compactRow(
          context,
          '最近一轮时间',
          _timeText(local.latestRoundAt),
          _timeText(remote.latestRoundAt),
        ),
        _compactRow(
          context,
          '世界书',
          '${local.worldBookCount} 条',
          '${remote.worldBookCount} 条',
        ),
        _compactRow(
          context,
          '启用的 Mod',
          local.modNames.isEmpty ? '（无）' : local.modNames.join('、'),
          remote.modNames.isEmpty ? '（无）' : remote.modNames.join('、'),
        ),
        const SizedBox(height: 6),
        _LongCompareField(
          label: '基础设定',
          localText: local.baseSetting,
          remoteText: remote.baseSetting,
        ),
        _LongCompareField(
          label: '文笔要求',
          localText: local.writingRequirements,
          remoteText: remote.writingRequirements,
        ),
        _LongCompareField(
          label: '文笔参考',
          localText: local.writingStyle,
          remoteText: remote.writingStyle,
        ),
        _LongCompareField(
          label: '全局前置提示',
          localText: local.globalPrePrompt,
          remoteText: remote.globalPrePrompt,
        ),
        _LongCompareField(
          label: '全局后置提示',
          localText: local.globalPostPrompt,
          remoteText: remote.globalPostPrompt,
        ),
        _LongCompareField(
          label: '角色层级',
          localText: local.roleHierarchy,
          remoteText: remote.roleHierarchy,
        ),
        _LongCompareField(
          label: '最近一轮 · 用户输入',
          localText: local.latestUserInput,
          remoteText: remote.latestUserInput,
        ),
        _LongCompareField(
          label: '最近一轮 · 正文摘要',
          localText: local.latestNarrative,
          remoteText: remote.latestNarrative,
          markdown: true,
        ),
      ],
    );
  }

  // --- Mod 库 -----------------------------------------------------------------

  Widget _buildMods(
    BuildContext context,
    ModsSidePreview local,
    ModsSidePreview remote,
  ) {
    final colors = context.narrColors;
    final localByUuid = {for (final mod in local.mods) mod.uuid: mod};
    final remoteByUuid = {for (final mod in remote.mods) mod.uuid: mod};
    final uuids = <String>{...localByUuid.keys, ...remoteByUuid.keys}.toList()
      ..sort((a, b) {
        final na = (localByUuid[a] ?? remoteByUuid[a])!.name;
        final nb = (localByUuid[b] ?? remoteByUuid[b])!.name;
        return na.compareTo(nb);
      });
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        _compactRow(
          context,
          'Mod 数量',
          '${local.aliveCount} 个',
          '${remote.aliveCount} 个',
        ),
        const SizedBox(height: 6),
        if (uuids.isEmpty)
          Text(
            '两侧都没有 Mod。',
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        for (final uuid in uuids)
          _buildModTile(context, uuid, localByUuid[uuid], remoteByUuid[uuid]),
      ],
    );
  }

  Widget _buildModTile(
    BuildContext context,
    String uuid,
    ModEntryPreview? local,
    ModEntryPreview? remote,
  ) {
    final colors = context.narrColors;
    final (label, color) = _modDiffLabel(context, local, remote);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SettingsCard(
        radius: NarrChatTheme.controlRadius - 2,
        color: colors.background,
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  (local ?? remote)?.name ?? '（未命名 Mod）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _chip(context, label, color),
            ],
          ),
          subtitle: Text(
            '${_shortUuid(uuid)} · ${local == null ? '仅云端有' : (remote == null ? '仅本地有' : '两侧都有')}',
            style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
          ),
          children: [
            _compactRow(
              context,
              '是否删除',
              _deletedText(local),
              _deletedText(remote),
            ),
            _compactRow(
              context,
              '修改时间',
              _timeText(local?.updatedAt),
              _timeText(remote?.updatedAt),
            ),
            _compactRow(
              context,
              '世界书',
              '${local?.worldBookCount ?? 0} 条',
              '${remote?.worldBookCount ?? 0} 条',
            ),
            _LongCompareField(
              label: '描述',
              localText: local?.description ?? '',
              remoteText: remote?.description ?? '',
            ),
            _LongCompareField(
              label: '前置词',
              localText: local?.prePrompt ?? '',
              remoteText: remote?.prePrompt ?? '',
            ),
            _LongCompareField(
              label: '后置词',
              localText: local?.postPrompt ?? '',
              remoteText: remote?.postPrompt ?? '',
            ),
            _LongCompareField(
              label: '系统提示',
              localText: local?.systemPrompt ?? '',
              remoteText: remote?.systemPrompt ?? '',
              markdown: true,
            ),
          ],
        ),
      ),
    );
  }

  (String, Color) _modDiffLabel(
    BuildContext context,
    ModEntryPreview? local,
    ModEntryPreview? remote,
  ) {
    final colors = context.narrColors;
    if (local == null) return ('仅云端', colors.warning);
    if (remote == null) return ('仅本地', colors.warning);
    final same =
        local.name == remote.name &&
        local.description == remote.description &&
        local.prePrompt == remote.prePrompt &&
        local.postPrompt == remote.postPrompt &&
        local.systemPrompt == remote.systemPrompt &&
        local.worldBookCount == remote.worldBookCount &&
        local.deleted == remote.deleted;
    return same ? ('一致', colors.success) : ('内容不同', colors.warning);
  }

  // --- 书架 -------------------------------------------------------------------

  Widget _buildLibrary(
    BuildContext context,
    LibrarySidePreview local,
    LibrarySidePreview remote,
  ) {
    final colors = context.narrColors;
    final localByUuid = {
      for (final book in [...local.alive, ...local.deleted])
        book.bookUuid: book,
    };
    final remoteByUuid = {
      for (final book in [...remote.alive, ...remote.deleted])
        book.bookUuid: book,
    };
    final aliveUuids = <String>{
      ...local.alive.map((book) => book.bookUuid),
      ...remote.alive.map((book) => book.bookUuid),
    }.toList();
    final deletedUuids = <String>{
      ...local.deleted.map((book) => book.bookUuid),
      ...remote.deleted.map((book) => book.bookUuid),
    }.toList();
    String titleOf(String uuid) =>
        localByUuid[uuid]?.title ??
        remoteByUuid[uuid]?.title ??
        _shortUuid(uuid);
    aliveUuids.sort((a, b) => titleOf(a).compareTo(titleOf(b)));
    deletedUuids.sort((a, b) => titleOf(a).compareTo(titleOf(b)));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        _compactRow(
          context,
          '书架规模',
          '活书 ${local.alive.length} · 已删除 ${local.deleted.length}',
          '活书 ${remote.alive.length} · 已删除 ${remote.deleted.length}',
        ),
        const SizedBox(height: 8),
        Text(
          '活书',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        if (aliveUuids.isEmpty)
          Text(
            '（两侧都没有活书）',
            style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
          ),
        for (final uuid in aliveUuids)
          _libraryRow(
            context,
            uuid,
            titleOf(uuid),
            localByUuid[uuid],
            remoteByUuid[uuid],
          ),
        const SizedBox(height: 12),
        Text(
          '已删除（回收站）',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        if (deletedUuids.isEmpty)
          Text(
            '（两侧都没有已删除的书）',
            style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
          ),
        for (final uuid in deletedUuids)
          _libraryRow(
            context,
            uuid,
            titleOf(uuid),
            localByUuid[uuid],
            remoteByUuid[uuid],
          ),
      ],
    );
  }

  Widget _libraryRow(
    BuildContext context,
    String uuid,
    String title,
    LibraryBookPreview? local,
    LibraryBookPreview? remote,
  ) {
    final colors = context.narrColors;
    final (label, color) = _libraryDiffLabel(context, local, remote);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius - 3),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.trim().isEmpty ? '（无书名）' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_shortUuid(uuid)}'
                  '${local?.deletedAt == null && remote?.deletedAt == null ? '' : ' · 删除于 ${_timeText(local?.deletedAt ?? remote?.deletedAt)}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _chip(context, label, color),
        ],
      ),
    );
  }

  (String, Color) _libraryDiffLabel(
    BuildContext context,
    LibraryBookPreview? local,
    LibraryBookPreview? remote,
  ) {
    final colors = context.narrColors;
    if (local == null) return ('仅云端', colors.warning);
    if (remote == null) return ('仅本地', colors.warning);
    if (local.isDeleted != remote.isDeleted) {
      return ('删除状态不同', colors.warning);
    }
    return ('一致', colors.success);
  }

  // --- 部件 -------------------------------------------------------------------

  Widget _compactRow(
    BuildContext context,
    String label,
    String local,
    String remote,
  ) {
    final colors = context.narrColors;
    final different = local != remote;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
          ),
          Expanded(child: _compareCell(context, '本地', local, different)),
          const SizedBox(width: 10),
          Expanded(child: _compareCell(context, '云端', remote, different)),
        ],
      ),
    );
  }

  Widget _compareCell(
    BuildContext context,
    String side,
    String text,
    bool different,
  ) {
    final colors = context.narrColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: different
            ? colors.warning.withValues(alpha: 0.07)
            : colors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: different
              ? colors.warning.withValues(alpha: 0.35)
              : colors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            side,
            style: TextStyle(fontSize: 10, color: colors.textSecondary),
          ),
          const SizedBox(height: 2),
          SelectableText(
            text.trim().isEmpty ? '（无）' : text,
            maxLines: 2,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.4,
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  static String _deletedText(ModEntryPreview? mod) {
    if (mod == null) return '（无）';
    return mod.deleted ? '已删除' : '正常';
  }

  static String _timeText(DateTime? time) =>
      time == null ? '未知' : Formats.formatDateTime(time);

  static String _shortUuid(String uuid) =>
      uuid.length <= 8 ? uuid : uuid.substring(0, 8);
}

/// 长文本字段对比：折叠时只给两行摘要，展开后用 Markdown 渲染两侧全文。
class _LongCompareField extends StatefulWidget {
  const _LongCompareField({
    required this.label,
    required this.localText,
    required this.remoteText,
    this.markdown = false,
  });

  final String label;
  final String localText;
  final String remoteText;
  final bool markdown;

  @override
  State<_LongCompareField> createState() => _LongCompareFieldState();
}

class _LongCompareFieldState extends State<_LongCompareField> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final local = widget.localText.trim();
    final remote = widget.remoteText.trim();
    if (local.isEmpty && remote.isEmpty) return const SizedBox.shrink();
    final different = local != remote;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SettingsCard(
        radius: NarrChatTheme.controlRadius - 2,
        color: colors.background,
        child: ExpansionTile(
          key: PageStorageKey<String>('long-${widget.label}'),
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          initiallyExpanded: _expanded,
          onExpansionChanged: (value) => setState(() => _expanded = value),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: (different ? colors.warning : colors.success)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  different ? '有差异' : '一致',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: different ? colors.warning : colors.success,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Text(
            _summaryText(local, remote),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
          ),
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final sideBySide = constraints.maxWidth >= 520;
                final localBlock = _content(context, '本地', local);
                final remoteBlock = _content(context, '云端', remote);
                if (!sideBySide) {
                  return Column(
                    children: [
                      localBlock,
                      const SizedBox(height: 8),
                      remoteBlock,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: localBlock),
                    const SizedBox(width: 10),
                    Expanded(child: remoteBlock),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _summaryText(String local, String remote) {
    final l = local.isEmpty ? '（无）' : local.replaceAll('\n', ' ');
    final r = remote.isEmpty ? '（无）' : remote.replaceAll('\n', ' ');
    if (l == r) return l;
    return '本地：$l\n云端：$r';
  }

  Widget _content(BuildContext context, String side, String text) {
    final colors = context.narrColors;
    final body = text.isEmpty
        ? Text(
            '（无）',
            style: TextStyle(
              fontSize: 11.5,
              fontStyle: FontStyle.italic,
              color: colors.textSecondary,
            ),
          )
        : widget.markdown
        ? ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: MarkdownPreview(
                data: text,
                base: const TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
          )
        : SelectableText(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: colors.textPrimary,
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          side,
          style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
        ),
        const SizedBox(height: 3),
        body,
      ],
    );
  }
}
