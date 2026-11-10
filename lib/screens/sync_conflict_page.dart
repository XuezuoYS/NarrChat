import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_notice.dart';
import '../providers/cloud_sync_provider.dart';
import '../services/cloud_backup/backup_pk.dart';
import '../services/cloud_backup/backup_runner.dart';
import '../services/cloud_backup/backup_unit.dart';
import '../services/sync/sync_conflict.dart';
import '../theme/app_theme.dart';
import '../widgets/app_empty_hint.dart';
import '../widgets/app_notice_overlay.dart';
import '../widgets/island_bar.dart';
import '../widgets/narr_chat_app_bar.dart';
import '../widgets/sync_conflict_card.dart';
import '../widgets/sync_conflict_preview.dart';
import '../widgets/settings/settings_kit.dart';

/// 同步冲突决策页：把「PK 判不了」的冲突逐项摆出来让用户整本二选一。
///
/// 入口有三处：同步中三选一选「冲突决策」后自动打开、云同步面板的待处理卡、
/// 首页同步状态章。页面只读 provider 的 `conflicts` 快照，决策通过
/// `applyConflictDecisions` 落库。
class SyncConflictPage extends StatefulWidget {
  const SyncConflictPage({super.key});

  /// 打开冲突决策页（同一时间只保留一个页面实例）。
  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SyncConflictPage()));
  }

  @override
  State<SyncConflictPage> createState() => _SyncConflictPageState();
}

class _SyncConflictPageState extends State<SyncConflictPage> {
  final Map<String, BackupConflictChoice> _choices = {};
  final Map<String, String> _errors = {};
  bool _busy = false;

  BackupConflictChoice? _choiceOf(SyncConflict conflict) =>
      _choices[conflict.unit.unitKey];

  /// 已选的有效决策（不含稍后处理 / 未选择）。
  List<SyncConflictDecision> _decisionsOf(List<SyncConflict> conflicts) => [
    for (final conflict in conflicts)
      if ((_choiceOf(conflict) ?? BackupConflictChoice.skip) !=
          BackupConflictChoice.skip)
        SyncConflictDecision(conflict: conflict, choice: _choiceOf(conflict)!),
  ];

  int _selectedCount(List<SyncConflict> conflicts) =>
      _decisionsOf(conflicts).length;

  void _setChoice(SyncConflict conflict, BackupConflictChoice choice) {
    setState(() {
      _choices[conflict.unit.unitKey] = choice;
      _errors.remove(conflict.unit.unitKey);
    });
  }

  void _applyBulk(List<SyncConflict> conflicts, _BulkRule rule) {
    setState(() {
      for (final conflict in conflicts) {
        final key = conflict.unit.unitKey;
        switch (rule) {
          case _BulkRule.allLocal:
            _choices[key] = BackupConflictChoice.local;
          case _BulkRule.allRemote:
            _choices[key] = BackupConflictChoice.remote;
          case _BulkRule.followPk:
            final winner = conflict.pk.winner;
            _choices[key] = winner == SyncPkOutcome.local
                ? BackupConflictChoice.local
                : winner == SyncPkOutcome.remote
                ? BackupConflictChoice.remote
                : BackupConflictChoice.skip;
          case _BulkRule.allLater:
            _choices[key] = BackupConflictChoice.skip;
        }
      }
    });
  }

  Future<void> _apply(
    CloudSyncProvider provider,
    List<SyncConflict> conflicts,
  ) async {
    final decisions = _decisionsOf(conflicts);
    if (decisions.isEmpty || _busy) return;
    final confirmed = await _confirmApply(decisions);
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _errors.clear();
    });
    final report = await provider.applyConflictDecisions(decisions);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _errors.addAll(report.errors);
      for (final decision in decisions) {
        final key = decision.conflict.unit.unitKey;
        if (report.errors.containsKey(key)) continue;
        _choices.remove(key);
      }
    });
    final notices = context.notices;
    // 整批被拒（例如同步正在进行）时没有具体单元可挂错误，单独提示。
    final blocked = report.errors[''];
    notices.show(
      blocked ?? report.summary,
      kind: report.hasErrors ? NoticeKind.error : NoticeKind.success,
    );
    if (provider.conflicts.isEmpty && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<bool?> _confirmApply(List<SyncConflictDecision> decisions) {
    final remote = decisions
        .where((item) => item.choice == BackupConflictChoice.remote)
        .length;
    final local = decisions.length - remote;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('应用这些决策？'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '采用云端 $remote 项，保留本地 $local 项。',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                '采用云端会用云端快照整份覆盖本地这一项，本地未上传的改动会丢失；'
                '保留本地会把本地推成云端新的一代，其它设备下次同步时采用。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: context.narrColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              _DecisionSummaryList(decisions: decisions),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('应用'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final provider = context.watch<CloudSyncProvider>();
    final conflicts = provider.conflicts;
    final selected = _selectedCount(conflicts);
    return IslandAwareScaffold(
      backgroundColor: colors.surface,
      appBarBuilder: (context, extraRow) =>
          NarrChatAppBar(extraRowHeight: extraRow, title: '同步冲突决策'),
      body: conflicts.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: AppEmptyHint(
                  icon: Icons.check_circle_outline,
                  text: '没有待处理的冲突',
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 880),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                        children: [
                          _buildOverview(context, conflicts),
                          const SizedBox(height: 12),
                          for (final conflict in conflicts)
                            SyncConflictCard(
                              key: ValueKey(conflict.unit.unitKey),
                              cardKey: ValueKey(
                                'conflict-card-${conflict.unit.unitKey}',
                              ),
                              conflict: conflict,
                              choice: _choiceOf(conflict),
                              enabled: !_busy,
                              error: _errors[conflict.unit.unitKey],
                              onChoiceChanged: (choice) =>
                                  _setChoice(conflict, choice),
                              onPreview: () => showSyncConflictPreview(
                                context,
                                conflict,
                                provider,
                              ),
                            ),
                          const SizedBox(height: 8),
                          Text(
                            '冲突不处理也不会丢数据：本地与云端各自保持原样，'
                            '下次同步会重新检出。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                _buildBottomBar(context, provider, conflicts, selected),
              ],
            ),
    );
  }

  Widget _buildOverview(BuildContext context, List<SyncConflict> conflicts) {
    final colors = context.narrColors;
    final books = conflicts.where((item) => item.isBook).length;
    final mods = conflicts
        .where((item) => item.kind == BackupUnitKind.mods)
        .length;
    final library = conflicts
        .where((item) => item.kind == BackupUnitKind.library)
        .length;
    return SettingsCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsCardHeader(
            icon: Icons.sync_problem_outlined,
            title: '需要你决定 ${conflicts.length} 项',
            subtitle: '本地与导入的云端快照都改过这些数据，PK 无法判定哪边更新。',
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
              border: Border.all(color: colors.divider),
            ),
            child: Row(
              children: [
                _stat(context, '书籍', books),
                _divider(context),
                _stat(context, 'Mod 库', mods),
                _divider(context),
                _stat(context, '书架', library),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SettingsExpandableCard(
            title: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: colors.textSecondary),
                const SizedBox(width: 6),
                Text(
                  'PK 规则与自动裁决',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '书籍按三条轴比较：代数（round_stack 行数）、最新轮次（最大轮号）、'
                  '更新时间（book_meta.updated_at）。三轴全部指向同一侧时自动采用，'
                  '有一轴持平、未知或相反才交给你决定。\n'
                  'Mod 库按较新的修改时间自动采用；书架按行自动合并（保留两侧的书、'
                  '墓碑取较新者），合并不了才会出现在这里。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.55,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '整本二选一：不做逐部件合并，选「保留本地」会把本地推成云端新一代。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.55,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _bulkChip(context, conflicts, _BulkRule.allLocal, '全部保留本地'),
              _bulkChip(context, conflicts, _BulkRule.allRemote, '全部采用云端'),
              _bulkChip(context, conflicts, _BulkRule.followPk, '按 PK 建议'),
              _bulkChip(context, conflicts, _BulkRule.allLater, '全部稍后处理'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String label, int value) {
    final colors = context.narrColors;
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) =>
      Container(width: 1, height: 26, color: context.narrColors.divider);

  Widget _bulkChip(
    BuildContext context,
    List<SyncConflict> conflicts,
    _BulkRule rule,
    String label,
  ) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
      onPressed: _busy ? null : () => _applyBulk(conflicts, rule),
    );
  }

  Widget _buildBottomBar(
    BuildContext context,
    CloudSyncProvider provider,
    List<SyncConflict> conflicts,
    int selected,
  ) {
    final colors = context.narrColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '已选 $selected / ${conflicts.length}',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('稍后处理'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: selected == 0 || _busy
                    ? null
                    : () => _apply(provider, conflicts),
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check, size: 18),
                label: Text(selected == 0 ? '应用决策' : '应用决策（$selected）'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「自动勾选」规则。
enum _BulkRule { allLocal, allRemote, followPk, allLater }

/// 应用前的决策清单（可折叠，避免长列表把对话框撑爆）。
class _DecisionSummaryList extends StatelessWidget {
  const _DecisionSummaryList({required this.decisions});

  final List<SyncConflictDecision> decisions;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return SettingsExpandableCard(
      title: Text(
        '逐项清单（${decisions.length}）',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final decision in decisions)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      decision.conflict.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    decision.choice == BackupConflictChoice.local
                        ? '保留本地'
                        : '采用云端',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: NarrChatTheme.primary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
