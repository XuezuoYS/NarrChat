import 'package:flutter/material.dart';

import '../services/database_merge_service.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';
import '../widgets/book_merge_preview.dart';

/// 数据库合并冲突决策页面。
///
/// - 左侧返回 = 取消导入；
/// - 右上「合并」→ 确认对话框（带变更摘要）→ 执行合并；
/// - 列表逐书展示状态：冲突（两侧轮次/最后时间 + 预览 + 保留导入/本地）、
///   仅导入有（可预览 + 可取消导入）、仅本地有 / 两者全一致（提示）。
/// - 合并前可逐本切换保留侧，并有批量快捷动作。
///
/// 本次仅提供页面与[DatabaseMergeService]配套；未接入云同步 / 本地导入流程。
class DatabaseMergeScreen extends StatefulWidget {
  final DatabaseMergePlan plan;

  /// 合并在哪里执行；为 null 时使用 [DatabaseMergeService.applyPlanIntoLocal]。
  final Future<DatabaseMergeResult> Function(
    DatabaseMergePlan plan,
    Map<String, MergeBookDecision> bookDecisions,
    Map<String, ModMergeDecision> modDecisions,
  )?
  onApply;

  const DatabaseMergeScreen({super.key, required this.plan, this.onApply});

  static Future<void> open(
    BuildContext context, {
    required DatabaseMergePlan plan,
    Future<DatabaseMergeResult> Function(
      DatabaseMergePlan plan,
      Map<String, MergeBookDecision> bookDecisions,
      Map<String, ModMergeDecision> modDecisions,
    )?
    onApply,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DatabaseMergeScreen(plan: plan, onApply: onApply),
      ),
    );
  }

  @override
  State<DatabaseMergeScreen> createState() => _DatabaseMergeScreenState();
}

class _DatabaseMergeScreenState extends State<DatabaseMergeScreen> {
  late Map<String, MergeBookDecision> _decision;
  late Map<String, ModMergeDecision> _modDecision;
  bool _applying = false;
  bool _autoSelectExpanded = false;

  DatabaseMergePlan get plan => widget.plan;

  @override
  void initState() {
    super.initState();
    // 打开时先执行一次「按轮次时间最新」，与底部「自动勾选」菜单共用同一套逻辑，
    // 避免「打开默认值」与「按轮次时间最新」两处重复实现。
    _decision = _computeDecisions(_BulkRule.newest);
    // Mod 无时间/轮次，默认保留导入，不受「按轮次时间最新」影响。
    _modDecision = _computeModDecisions(_BulkRule.newest);
  }

  MergeBookDecision _decisionOf(String title) =>
      _decision[title] ?? MergeBookDecision.keepLocal;

  void _setDecision(String title, MergeBookDecision value) {
    setState(() => _decision[title] = value);
  }

  ModMergeDecision _modDecisionOf(String name) =>
      _modDecision[name] ?? ModMergeDecision.keepLocal;

  void _setModDecision(String name, ModMergeDecision value) {
    setState(() => _modDecision[name] = value);
  }

  /// 按规则计算全部书籍的决策（纯函数，供初始化与「自动勾选」菜单共用）。
  Map<String, MergeBookDecision> _computeDecisions(_BulkRule rule) {
    return {
      for (final e in plan.entries) e.title: _decisionFor(e, rule),
    };
  }

  /// 按规则计算全部 Mod 的决策：仅「全本地/全导入」影响 Mod；
  /// 「按轮次时间最新 / 按轮次数最多」对 Mod 无意义，保持不变（默认）。
  Map<String, ModMergeDecision> _computeModDecisions(_BulkRule rule) {
    return {
      for (final e in plan.modEntries) e.name: _modDecisionFor(e, rule),
    };
  }

  ModMergeDecision _modDecisionFor(ModMergeEntry e, _BulkRule rule) {
    if (e.status == ModMergeStatus.localOnly ||
        e.status == ModMergeStatus.identical) {
      return ModMergeDecision.keepLocal;
    }
    // 仅导入有的 Mod 始终导入。
    if (e.status == ModMergeStatus.importOnly) {
      return ModMergeDecision.import;
    }
    // conflict
    return switch (rule) {
      _BulkRule.allLocal => ModMergeDecision.keepLocal,
      _BulkRule.allImport => ModMergeDecision.import,
      _BulkRule.newest || _BulkRule.mostRounds => e.defaultDecision,
    };
  }

  MergeBookDecision _decisionFor(BookMergeEntry e, _BulkRule rule) {
    switch (e.status) {
      case MergeBookStatus.localOnly:
      case MergeBookStatus.identical:
        return MergeBookDecision.keepLocal;
      case MergeBookStatus.importOnly:
        // 仅导入有的书始终导入，不做调整。
        return MergeBookDecision.keepImported;
      case MergeBookStatus.conflict:
        final imported = e.imported!;
        final local = e.local!;
        switch (rule) {
          case _BulkRule.allLocal:
            return MergeBookDecision.keepLocal;
          case _BulkRule.allImport:
            return MergeBookDecision.keepImported;
          case _BulkRule.newest:
            // 保留最后更新时间较新的一侧；时间相同 / 未知默认保留本地。
            final i = imported.lastTime;
            final l = local.lastTime;
            if (i != null && (l == null || i.isAfter(l))) {
              return MergeBookDecision.keepImported;
            }
            if (l != null && (i == null || l.isAfter(i))) {
              return MergeBookDecision.keepLocal;
            }
            return MergeBookDecision.keepLocal;
          case _BulkRule.mostRounds:
            // 保留轮次较多的一侧；轮次相同默认保留本地。
            return imported.roundsCount > local.roundsCount
                ? MergeBookDecision.keepImported
                : MergeBookDecision.keepLocal;
        }
    }
  }

  void _applyRule(_BulkRule rule) {
    setState(() {
      _decision = _computeDecisions(rule);
      _modDecision = _computeModDecisions(rule);
    });
  }

  Future<void> _onMerge() async {
    if (_applying) return;
    final summary = plan.summarize(_decision);
    final modSummary = plan.summarizeMods(_modDecision);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _MergeConfirmDialog(
        summary: summary,
        modSummary: modSummary,
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _applying = true);
    try {
      final apply = widget.onApply ??
          (DatabaseMergePlan p, Map<String, MergeBookDecision> bd,
                  Map<String, ModMergeDecision> md) =>
              DatabaseMergeService.applyPlanIntoLocal(p, bd, md);
      final result = await apply(
        plan,
        Map.of(_decision),
        Map.of(_modDecision),
      );
      if (!mounted) return;
      _showResultAndPop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('合并失败：$e')),
      );
    }
  }

  void _showResultAndPop(DatabaseMergeResult result) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '合并完成：导入书籍 ${result.booksAdded}、'
          '替换书籍 ${result.booksReplaced}、跳过 ${result.booksSkipped}、'
          '轮次 ${result.roundsAdded}、世界书 ${result.worldBookAdded}、'
          '导入 Mod ${result.modsAdded}、替换 Mod ${result.modsReplaced}、'
          '重命名 Mod ${result.modsRenamed}',
        ),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('数据库合并'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '取消导入',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_applying)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            FilledButton.icon(
              onPressed: _onMerge,
              icon: const Icon(Icons.merge_outlined, size: 18),
              label: const Text('合并'),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSummaryHeader(context),
          const Divider(height: 1),
          Expanded(
            child: (plan.entries.isEmpty && plan.modEntries.isEmpty)
                ? const Center(child: Text('无可合并的书籍 / Mod'))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    children: [
                      for (final e in plan.entries) _buildEntryCard(context, e),
                      if (plan.modEntries.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Mod（${plan.modEntries.length}）',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: context.narrColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        for (final m in plan.modEntries)
                          _buildModCard(context, m),
                      ],
                    ],
                  ),
          ),
          _buildAutoSelectBar(context),
        ],
      ),
    );
  }

  Widget _buildSummaryHeader(BuildContext context) {
    final colors = context.narrColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '书籍 ${plan.entries.length} 本 · 冲突 ${plan.conflictCount} · '
            '仅导入有 ${plan.importOnlyCount} · '
            '仅本地有 ${plan.localOnlyCount} · 全一致 ${plan.identicalCount}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          if (plan.modEntries.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Mod ${plan.modEntries.length} 个 · 冲突 ${plan.modConflictCount} · '
              '仅导入有 ${plan.modImportOnlyCount} · '
              '仅本地有 ${plan.modLocalOnlyCount} · 全一致 ${plan.modIdenticalCount}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            '比较两边的书籍 / Mod，「仅导入有」为新增；冲突书的轮次/设置等任一不同即触发。'
            '请在合并前逐项选择，也可用底部「自动勾选」快速统一选择。',
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  /// 底部「自动勾选」扩展菜单：收起/展开，展开后提供四种快速统一选择。
  Widget _buildAutoSelectBar(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () =>
                setState(() => _autoSelectExpanded = !_autoSelectExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    _autoSelectExpanded
                        ? Icons.expand_more
                        : Icons.expand_less,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '自动勾选',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '一键统一选择',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_autoSelectExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _bulkChip(context, _BulkRule.allLocal, '全本地'),
                  _bulkChip(context, _BulkRule.allImport, '全导入'),
                  _bulkChip(context, _BulkRule.newest, '按轮次时间最新'),
                  _bulkChip(context, _BulkRule.mostRounds, '按轮次数最多'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _bulkChip(BuildContext context, _BulkRule rule, String label) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
      onPressed: () => _applyRule(rule),
    );
  }

  Widget _buildEntryCard(BuildContext context, BookMergeEntry entry) {
    final colors = context.narrColors;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _StatusBadge(status: entry.status),
            ],
          ),
          const SizedBox(height: 10),
          switch (entry.status) {
            MergeBookStatus.conflict => _buildConflict(context, entry),
            MergeBookStatus.importOnly => _buildImportOnly(context, entry),
            MergeBookStatus.localOnly => _buildSingleSide(
                context,
                entry.local!,
                '仅本地有',
              ),
            MergeBookStatus.identical => Text(
                '两者全一致，保留本地，无需处理。',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
          },
        ],
      ),
    );
  }

  /// [side] 的最后更新时间是否严格晚于 [other]，用于最后时间的绿色高亮。
  bool _isNewerTime(BookMergeSide side, BookMergeSide other) {
    final t = side.lastTime;
    if (t == null) return false;
    final o = other.lastTime;
    return o == null || t.isAfter(o);
  }

  Widget _buildConflict(BuildContext context, BookMergeEntry entry) {
    final colors = context.narrColors;
    final decision = _decisionOf(entry.title);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _SideCard(
                label: '导入的备份',
                side: entry.imported!,
                selected: decision == MergeBookDecision.keepImported,
                colors: colors,
                onPreview: () => showBookMergePreview(
                  context,
                  title: entry.title,
                  label: '导入的备份',
                  side: entry.imported!,
                ),
                onSelect: () => _setDecision(
                  entry.title,
                  MergeBookDecision.keepImported,
                ),
                highlightRounds: entry.imported!.roundsCount >
                    entry.local!.roundsCount,
                highlightTime: _isNewerTime(entry.imported!, entry.local!),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SideCard(
                label: '本地',
                side: entry.local!,
                selected: decision == MergeBookDecision.keepLocal,
                colors: colors,
                onPreview: () => showBookMergePreview(
                  context,
                  title: entry.title,
                  label: '本地',
                  side: entry.local!,
                ),
                onSelect: () => _setDecision(
                  entry.title,
                  MergeBookDecision.keepLocal,
                ),
                highlightRounds: entry.local!.roundsCount >
                    entry.imported!.roundsCount,
                highlightTime: _isNewerTime(entry.local!, entry.imported!),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SegmentedButton<MergeBookDecision>(
          segments: const [
            ButtonSegment(
              value: MergeBookDecision.keepImported,
              label: Text('保留导入'),
            ),
            ButtonSegment(
              value: MergeBookDecision.keepLocal,
              label: Text('保留本地'),
            ),
          ],
          selected: {decision},
          onSelectionChanged: (s) =>
              _setDecision(entry.title, s.first),
          showSelectedIcon: false,
        ),
      ],
    );
  }

  Widget _buildImportOnly(BuildContext context, BookMergeEntry entry) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SideCard(
          label: '导入的备份',
          side: entry.imported!,
          selected: false,
          colors: context.narrColors,
          onPreview: () => showBookMergePreview(
            context,
            title: entry.title,
            label: '导入的备份',
            side: entry.imported!,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              Icons.arrow_downward,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              '仅导入有，将导入此书',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSingleSide(
    BuildContext context,
    BookMergeSide side,
    String label,
  ) {
    return _SideCard(
      label: label,
      side: side,
      selected: false,
      colors: context.narrColors,
      onPreview: () => showBookMergePreview(
        context,
        title: side.book.title,
        label: label,
        side: side,
      ),
    );
  }

  Widget _buildModCard(BuildContext context, ModMergeEntry entry) {
    final colors = context.narrColors;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.extension_outlined,
                size: 18,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _ModBadge(status: entry.status),
            ],
          ),
          const SizedBox(height: 8),
          switch (entry.status) {
            ModMergeStatus.conflict => _buildModConflict(context, entry),
            ModMergeStatus.importOnly => Text(
                '仅导入有，将导入。',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ModMergeStatus.localOnly => Text(
                '仅本地有，保留本地。',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ModMergeStatus.identical => Text(
                '两者全一致，保留本地。',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
          },
        ],
      ),
    );
  }

  Widget _buildModConflict(BuildContext context, ModMergeEntry entry) {
    final colors = context.narrColors;
    final decision = _modDecisionOf(entry.name);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 与书籍冲突一致：并排展示「导入的备份」与「本地」两侧，均可预览对比。
        Row(
          children: [
            Expanded(
              child: _ModSideCard(
                label: '导入的备份',
                side: entry.imported!,
                selected: decision != ModMergeDecision.keepLocal,
                colors: colors,
                onPreview: () => _showModPreview(context, entry.imported!),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ModSideCard(
                label: '本地',
                side: entry.local!,
                selected: decision == ModMergeDecision.keepLocal,
                colors: colors,
                onPreview: () => _showModPreview(context, entry.local!),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SegmentedButton<ModMergeDecision>(
          segments: const [
            ButtonSegment(
              value: ModMergeDecision.import,
              label: Text('导入'),
            ),
            ButtonSegment(
              value: ModMergeDecision.rename,
              label: Text('重命名'),
            ),
            ButtonSegment(
              value: ModMergeDecision.keepLocal,
              label: Text('本地'),
            ),
          ],
          selected: {decision},
          onSelectionChanged: (s) => _setModDecision(entry.name, s.first),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 4),
        Text(
          '「导入」覆盖本地同名 Mod；「重命名」另存为「${entry.name} - 导入」；「本地」保留本地。',
          style: TextStyle(fontSize: 11, color: colors.textSecondary),
        ),
      ],
    );
  }

  void _showModPreview(BuildContext context, ModMergeSide side) {
    showDialog<void>(
      context: context,
      builder: (_) => _ModPreviewDialog(side: side),
    );
  }
}

/// 状态徽标。
class _StatusBadge extends StatelessWidget {
  final MergeBookStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final (text, color, bg) = switch (status) {
      MergeBookStatus.conflict => ('冲突', colors.warning, colors.bannerBackground),
      MergeBookStatus.importOnly => ('仅导入有', Colors.white, NarrChatTheme.primary),
      MergeBookStatus.localOnly => ('仅本地有', colors.textSecondary, colors.historyBackground),
      MergeBookStatus.identical => (
          '两者全一致',
          const Color(0xFF2E7D32),
          const Color(0xFFE8F5E9),
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 单侧书籍卡片：可选（冲突书）或纯展示（仅导入有 / 仅本地有）。
class _SideCard extends StatelessWidget {
  final String label;
  final BookMergeSide side;
  final bool selected;
  final NarrChatColors colors;
  final VoidCallback onPreview;
  final VoidCallback? onSelect;

  /// 是否「轮次更多」一侧：是则轮次数用绿色突出。
  final bool highlightRounds;

  /// 是否「更新时间较新」一侧：是则最后时间用绿色突出。
  final bool highlightTime;

  const _SideCard({
    required this.label,
    required this.side,
    required this.selected,
    required this.colors,
    required this.onPreview,
    this.onSelect,
    this.highlightRounds = false,
    this.highlightTime = false,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? Theme.of(context).colorScheme.primary
        : colors.divider;
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected ? colors.userBubble : colors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: selected ? 1.4 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (onSelect != null)
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 16,
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : colors.textSecondary,
                  ),
                if (onSelect != null) const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  tooltip: '预览',
                  visualDensity: VisualDensity.compact,
                  onPressed: onPreview,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '轮次 ${side.roundsCount}',
              style: TextStyle(
                fontSize: 12,
                color: highlightRounds ? colors.success : colors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '最后时间：${side.lastTime == null ? '—' : Formats.formatDateTime(side.lastTime!)}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: highlightTime ? colors.success : colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单侧 Mod 卡片：并排展示「导入的备份」与「本地」，供预览对比。
///
/// 与书籍的 [_SideCard] 仅展示一个字段摘要（Mod 无轮次/时间可对比），
/// 选中侧以主题主色描边，当前决策对应的来源侧高亮。
class _ModSideCard extends StatelessWidget {
  final String label;
  final ModMergeSide side;
  final bool selected;
  final NarrChatColors colors;
  final VoidCallback onPreview;

  const _ModSideCard({
    required this.label,
    required this.side,
    required this.selected,
    required this.colors,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? Theme.of(context).colorScheme.primary
        : colors.divider;
    final mod = side.mod;
    final fieldLabels = <String>[
      if ((mod['description'] as String? ?? '').trim().isNotEmpty) '描述',
      if ((mod['pre_prompt'] as String? ?? '').trim().isNotEmpty) '前置提示',
      if ((mod['post_prompt'] as String? ?? '').trim().isNotEmpty) '后置提示',
      if ((mod['system_prompt'] as String? ?? '').trim().isNotEmpty) '系统提示',
      if ((mod['world_book'] as String? ?? '').trim().isNotEmpty) '世界书',
    ];

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected ? colors.userBubble : colors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: selected ? 1.4 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  tooltip: '预览',
                  visualDensity: VisualDensity.compact,
                  onPressed: onPreview,
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (fieldLabels.isEmpty)
              Text(
                '（无内容）',
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: colors.textSecondary,
                ),
              )
            else
              Text(
                '包含：${fieldLabels.join('、')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.textPrimary),
              ),
          ],
        ),
      ),
    );
  }
}

/// Mod 状态徽标。
class _ModBadge extends StatelessWidget {
  final ModMergeStatus status;

  const _ModBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final (text, color, bg) = switch (status) {
      ModMergeStatus.conflict => ('冲突', colors.warning, colors.bannerBackground),
      ModMergeStatus.importOnly => ('仅导入有', Colors.white, NarrChatTheme.primary),
      ModMergeStatus.localOnly => ('仅本地有', colors.textSecondary, colors.historyBackground),
      ModMergeStatus.identical => (
          '两者全一致',
          const Color(0xFF2E7D32),
          const Color(0xFFE8F5E9),
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// Mod 预览对话框：查看某一侧 Mod 的内容字段。
class _ModPreviewDialog extends StatelessWidget {
  final ModMergeSide side;

  const _ModPreviewDialog({required this.side});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final mod = side.mod;
    final fields = <(String, String)>[
      ('名称', (mod['name'] as String? ?? '').trim()),
      ('描述', mod['description'] as String? ?? ''),
      ('前置提示', mod['pre_prompt'] as String? ?? ''),
      ('后置提示', mod['post_prompt'] as String? ?? ''),
      ('系统提示', mod['system_prompt'] as String? ?? ''),
      ('世界书', mod['world_book'] as String? ?? ''),
    ].where((s) => s.$2.trim().isNotEmpty).toList();

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
              child: Row(
                children: [
                  Text(
                    'Mod 预览',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (fields.isEmpty)
                      Text(
                        '（无内容）',
                        style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: colors.textSecondary,
                        ),
                      )
                    else
                      for (final (label, value) in fields)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: colors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              SelectableText(
                                value,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                  color: colors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 合并确认对话框：展示变更摘要。
class _MergeConfirmDialog extends StatelessWidget {
  final Map<String, int> summary;
  final Map<String, int>? modSummary;

  const _MergeConfirmDialog({required this.summary, this.modSummary});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final import = summary['import'] ?? 0;
    final replace = summary['replace'] ?? 0;
    final skip = summary['skip'] ?? 0;
    final mImport = modSummary?['import'] ?? 0;
    final mRename = modSummary?['rename'] ?? 0;
    final mReplace = modSummary?['replace'] ?? 0;
    final mKeep = modSummary?['keep'] ?? 0;
    final hasMods =
        modSummary != null && (mImport + mRename + mReplace + mKeep) > 0;
    return AlertDialog(
      title: const Text('确认合并'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '将按当前选择执行：',
            style: TextStyle(fontSize: 13, color: colors.textPrimary),
          ),
          const SizedBox(height: 10),
          _SummaryRow(label: '导入新书', value: import),
          const SizedBox(height: 4),
          _SummaryRow(label: '替换为导入（覆盖本地同名书）', value: replace),
          const SizedBox(height: 4),
          _SummaryRow(label: '跳过（保留本地 / 不导入）', value: skip),
          if (hasMods) ...[
            const SizedBox(height: 8),
            Text(
              'Mod：',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            _SummaryRow(label: '导入 Mod（新增）', value: mImport),
            _SummaryRow(label: '重命名 Mod（另存）', value: mRename),
            _SummaryRow(label: '覆盖本地 Mod', value: mReplace),
            _SummaryRow(label: '保留本地 Mod', value: mKeep),
          ],
          const SizedBox(height: 8),
          Text(
            '「仅本地有」与「两者全一致」的书籍 / Mod 保持不变。',
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('确认合并'),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final int value;

  const _SummaryRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: context.narrColors.textPrimary,
            ),
          ),
        ),
        Text(
          '$value 本',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: context.narrColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// 「自动勾选」快速统一选择的规则。
enum _BulkRule { allLocal, allImport, newest, mostRounds }
