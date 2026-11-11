import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_notice.dart';
import '../providers/cloud_sync_provider.dart';
import '../services/cloud_backup/backup_mods_conflict.dart';
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

/// 同步冲突决策页：把「PK 判不了」的冲突逐项摆出来让用户选择。
///
/// 书籍 / 书架整份二选一；Mod 库既支持整库二选一，也支持逐 Mod 选择后合并
/// （两侧较新的版本都保留，再推成云端新的一代）。
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

  /// 逐 Mod 合并的单元（unitKey）与逐项选择（unitKey → uuid → 选择）。
  final Set<String> _modsMerges = {};
  final Map<String, Map<String, BackupConflictChoice>> _modChoices = {};
  final Map<String, String> _errors = {};
  bool _busy = false;

  BackupConflictChoice? _choiceOf(SyncConflict conflict) =>
      _choices[conflict.unit.unitKey];

  bool _isMergeMode(SyncConflict conflict) =>
      _modsMerges.contains(conflict.unit.unitKey);

  Map<String, BackupConflictChoice> _modChoicesOf(SyncConflict conflict) =>
      _modChoices[conflict.unit.unitKey] ?? const {};

  /// 能逐项比较的 Mod 明细；非 Mod 单元 / 读不到明细时为 null。
  ModsPk? _modsPkOf(SyncConflict conflict) {
    final detail = conflict.pk.mods;
    return detail != null && detail.comparable ? detail : null;
  }

  /// 逐 Mod 合并模式下还差几个必须手动选的项。
  int _modsPending(SyncConflict conflict) {
    final detail = _modsPkOf(conflict);
    if (detail == null) return 0;
    final chosen = _modChoicesOf(conflict);
    return detail.entries
        .where((entry) => entry.needsChoice && !chosen.containsKey(entry.uuid))
        .length;
  }

  /// 某个冲突是否已「选好」：整库选择非 skip，或逐 Mod 合并且没有待选项。
  bool _isReady(SyncConflict conflict) {
    if (_isMergeMode(conflict)) {
      return _modsPkOf(conflict) != null && _modsPending(conflict) == 0;
    }
    final choice = _choiceOf(conflict);
    return choice != null && choice != BackupConflictChoice.skip;
  }

  /// 已选的有效决策（不含稍后处理 / 未选完的逐 Mod 合并）。
  List<SyncConflictDecision> _decisionsOf(List<SyncConflict> conflicts) => [
    for (final conflict in conflicts)
      if (_isMergeMode(conflict) && _isReady(conflict))
        SyncConflictDecision(
          conflict: conflict,
          modsMerge: true,
          modChoices: Map.unmodifiable(_modChoicesOf(conflict)),
        )
      else if (!_isMergeMode(conflict) && _isReady(conflict))
        SyncConflictDecision(conflict: conflict, choice: _choiceOf(conflict)),
  ];

  int _selectedCount(List<SyncConflict> conflicts) =>
      _decisionsOf(conflicts).length;

  void _setChoice(SyncConflict conflict, BackupConflictChoice choice) {
    setState(() {
      final key = conflict.unit.unitKey;
      _choices[key] = choice;
      _modsMerges.remove(key);
      _modChoices.remove(key);
      _errors.remove(key);
    });
  }

  /// 单条 Mod 的时间建议：内容不同的项按时间预先选好，未知项留空。
  static BackupConflictChoice? _suggestionOf(ModsPkEntry entry) =>
      switch (entry.status) {
        ModsPkStatus.local => BackupConflictChoice.local,
        ModsPkStatus.remote => BackupConflictChoice.remote,
        _ => null,
      };

  /// 在 merge 模式下填入可自动判定的选择；已手动选过的项保持不动。
  void _fillSuggestionsIn(SyncConflict conflict) {
    final detail = _modsPkOf(conflict);
    if (detail == null) return;
    final key = conflict.unit.unitKey;
    _choices.remove(key);
    _modsMerges.add(key);
    final choices = <String, BackupConflictChoice>{
      for (final entry in detail.entries)
        if (_suggestionOf(entry) != null) entry.uuid: _suggestionOf(entry)!,
      ...?_modChoices[key],
    };
    _modChoices[key] = choices;
  }

  /// 进入逐 Mod 合并（按时间建议填充）。
  void _enableModsMerge(SyncConflict conflict) {
    if (_modsPkOf(conflict) == null) return;
    setState(() {
      _fillSuggestionsIn(conflict);
      _errors.remove(conflict.unit.unitKey);
    });
  }

  /// 修改单个 Mod 的选择：自动进入逐 Mod 合并。
  void _setModChoice(
    SyncConflict conflict,
    String uuid,
    BackupConflictChoice choice,
  ) {
    if (_modsPkOf(conflict) == null) return;
    setState(() {
      _fillSuggestionsIn(conflict);
      final key = conflict.unit.unitKey;
      final choices = <String, BackupConflictChoice>{...?_modChoices[key]}
        ..[uuid] = choice;
      _modChoices[key] = choices;
      _errors.remove(key);
    });
  }

  void _applyBulk(List<SyncConflict> conflicts, _BulkRule rule) {
    setState(() {
      for (final conflict in conflicts) {
        final key = conflict.unit.unitKey;
        switch (rule) {
          case _BulkRule.allLocal:
            _choices[key] = BackupConflictChoice.local;
            _modsMerges.remove(key);
            _modChoices.remove(key);
          case _BulkRule.allRemote:
            _choices[key] = BackupConflictChoice.remote;
            _modsMerges.remove(key);
            _modChoices.remove(key);
          case _BulkRule.followPk:
            if (_modsPkOf(conflict) != null) {
              // Mod 库没有「整库胜者」可自动采用：按时间建议逐项填好，等用户应用。
              _fillSuggestionsIn(conflict);
            } else {
              final decision = conflict.pk.autoDecision;
              _choices[key] = decision == SyncPkOutcome.local
                  ? BackupConflictChoice.local
                  : decision == SyncPkOutcome.remote
                  ? BackupConflictChoice.remote
                  : BackupConflictChoice.skip;
              _modsMerges.remove(key);
              _modChoices.remove(key);
            }
          case _BulkRule.allLater:
            _choices[key] = BackupConflictChoice.skip;
            _modsMerges.remove(key);
            _modChoices.remove(key);
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
        _modsMerges.remove(key);
        _modChoices.remove(key);
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
    final merged = decisions.where((item) => item.isModsMerge).length;
    final remote = decisions
        .where(
          (item) =>
              !item.isModsMerge && item.choice == BackupConflictChoice.remote,
        )
        .length;
    final local = decisions.length - remote - merged;
    final counts = <String>[
      if (remote > 0) '采用云端 $remote 项',
      if (local > 0) '保留本地 $local 项',
      if (merged > 0) '逐 Mod 合并 $merged 项',
    ].join('，');
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
              Text('$counts。', style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Text(
                '采用云端会用云端快照整份覆盖本地这一项，本地未上传的改动会丢失；'
                '保留本地会把本地推成云端新的一代，其它设备下次同步时采用。'
                '逐 Mod 合并只按你的选择改写对应 Mod，其余本地 Mod 原样保留，'
                '结果会推成云端新的一代。',
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
                              modsMerge: _isMergeMode(conflict),
                              modChoices: _modChoicesOf(conflict),
                              onModsMergeEnabled: () =>
                                  _enableModsMerge(conflict),
                              onModChoiceChanged: (uuid, choice) =>
                                  _setModChoice(conflict, uuid, choice),
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
                  '更新时间（book_meta.updated_at）。三轴全部指向同一侧时自动采用；'
                  '如果轮次与代数都一致、只有更新时间不同，就按时间采用较新的一边；'
                  '其余情况（有轴相反 / 时间也持平 / 缺少数据）才交给你决定。\n'
                  'Mod 库按每个 Mod 逐项比较：内容一致算一致，不同时按修改时间取较新者；'
                  '如果本地有较新的 Mod、云端也有较新的 Mod（方向不一致），或时间相同 / '
                  '缺失，就交给你逐项选择。书架按行自动合并（保留两侧的书、'
                  '墓碑取较新者），合并不了才会出现在这里。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.55,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '书籍不做逐部件合并：整本二选一，选「保留本地」会把本地推成云端新一代。'
                  'Mod 库既可以整库二选一，也可以逐 Mod 合并——只改写你选中的 Mod，'
                  '两侧独有的 Mod 都会保留，再推成云端新的一代。',
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
                    _labelOf(decision),
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

  /// 决策一句话：整库选择 / 逐 Mod 合并（带两侧计数）。
  static String _labelOf(SyncConflictDecision decision) {
    if (decision.isModsMerge) {
      final local = decision.modChoices.values
          .where((choice) => choice == BackupConflictChoice.local)
          .length;
      final remote = decision.modChoices.values
          .where((choice) => choice == BackupConflictChoice.remote)
          .length;
      return '逐 Mod 合并（本地 $local · 云端 $remote）';
    }
    return decision.choice == BackupConflictChoice.local ? '保留本地' : '采用云端';
  }
}
