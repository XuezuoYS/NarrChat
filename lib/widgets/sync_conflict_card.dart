import 'package:flutter/material.dart';

import '../services/cloud_backup/backup_mods_conflict.dart';
import '../services/cloud_backup/backup_runner.dart';
import '../services/cloud_backup/backup_pk.dart';
import '../services/cloud_backup/backup_unit.dart';
import '../services/sync/sync_conflict.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';
import 'backup_unit_badge.dart';
import 'settings/settings_kit.dart';

/// 冲突决策页里的一张冲突卡：PK 对比 + 两侧摘要 + 二选一。
///
/// 约定：左「本地」、右「云端（导入端）」；整张侧卡可点选，选中后主色描边 +
/// 淡底 + 单选圆点。`choice == null` 表示还没选。
///
/// Mod 库多一层「逐 Mod 对比」：内容不同且两侧都有的行可以逐项选本地 / 云端，
/// 选好后按并集合并（两侧独有的 Mod 也会保留），见 [modsMerge]。
class SyncConflictCard extends StatelessWidget {
  const SyncConflictCard({
    super.key,
    required this.conflict,
    required this.choice,
    required this.onChoiceChanged,
    required this.onPreview,
    this.error,
    this.enabled = true,
    this.cardKey,
    this.modsMerge = false,
    this.modChoices = const {},
    this.onModsMergeEnabled,
    this.onModChoiceChanged,
  });

  final SyncConflict conflict;

  /// 当前整库选择；null = 待选择（或逐 Mod 合并模式）。
  final BackupConflictChoice? choice;

  final ValueChanged<BackupConflictChoice> onChoiceChanged;

  /// 打开对比预览（本地 / 云端两路一起加载）。
  final VoidCallback onPreview;

  /// 单元级失败原因（内联展示，不弹窗）。
  final String? error;

  final bool enabled;

  /// 卡片根 key（测试定位）。
  final Key? cardKey;

  /// 是否处于「逐 Mod 合并」模式（只有 Mod 库且能逐项比较时有意义）。
  final bool modsMerge;

  /// 逐 Mod 选择：`mod_uuid → local / remote`。
  final Map<String, BackupConflictChoice> modChoices;

  /// 进入逐 Mod 合并并填入「按时间建议」（内容不同的项按时间预先选好）。
  final VoidCallback? onModsMergeEnabled;

  /// 修改单个 Mod 的选择。
  final void Function(String uuid, BackupConflictChoice choice)?
  onModChoiceChanged;

  bool get _isLocal => choice == BackupConflictChoice.local;
  bool get _isRemote => choice == BackupConflictChoice.remote;
  bool get _isLater => choice == BackupConflictChoice.skip;

  /// 能逐项比较的 Mod 明细；读不到时为 null（退回整库时间轴）。
  ModsPk? get _modsPk {
    final detail = conflict.pk.mods;
    return detail != null && detail.comparable ? detail : null;
  }

  bool get _showsModsCompare =>
      conflict.kind == BackupUnitKind.mods && _modsPk != null;

  /// 逐 Mod 合并模式下还差几个必须手动选的项。
  int get _modsPending {
    final detail = _modsPk;
    if (detail == null) return 0;
    return detail.entries
        .where(
          (entry) => entry.needsChoice && !modChoices.containsKey(entry.uuid),
        )
        .length;
  }

  bool get _modsReady => modsMerge && _modsPk != null && _modsPending == 0;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Padding(
      key: cardKey,
      padding: const EdgeInsets.only(bottom: 10),
      child: SettingsCard(
        radius: NarrChatTheme.controlRadius,
        color: colors.background,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            const SizedBox(height: 10),
            if (_showsModsCompare)
              _buildModsCompare(context, _modsPk!)
            else
              _buildPkTable(context),
            const SizedBox(height: 8),
            Text(
              conflict.pk.explanation,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final sideBySide = constraints.maxWidth >= 560;
                final local = _buildSide(context, SyncPreviewSide.local);
                final remote = _buildSide(context, SyncPreviewSide.remote);
                if (!sideBySide) {
                  return Column(
                    children: [local, const SizedBox(height: 8), remote],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: local),
                    const SizedBox(width: 10),
                    Expanded(child: remote),
                  ],
                );
              },
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _showsModsCompare
                        ? '整库二选一仍可用；也可以逐 Mod 合并，两侧较新的版本都会保留。'
                        : '重命名、改轮次之类的小差异不做逐部件合并：整本二选一。',
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ),
                TextButton(
                  onPressed: enabled
                      ? () => onChoiceChanged(BackupConflictChoice.skip)
                      : null,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: _isLater
                        ? colors.warning
                        : colors.textSecondary,
                  ),
                  child: Text(_isLater ? '已标记稍后处理' : '稍后处理'),
                ),
              ],
            ),
            if (error != null && error!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(
                    NarrChatTheme.controlRadius - 2,
                  ),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.error
                        .withValues(alpha: 0.35),
                  ),
                ),
                child: SelectableText(
                  error!,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final colors = context.narrColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BackupUnitBadge(kind: conflict.kind, size: 30),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                conflict.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                conflict.reasonLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _statusPill(context),
      ],
    );
  }

  Widget _statusPill(BuildContext context) {
    final colors = context.narrColors;
    final (label, color) = switch (choice) {
      BackupConflictChoice.local => ('已选本地', NarrChatTheme.primary),
      BackupConflictChoice.remote => ('已选云端', NarrChatTheme.primary),
      BackupConflictChoice.skip => ('稍后处理', colors.warning),
      null when _modsReady => ('逐 Mod 合并', NarrChatTheme.primary),
      null when modsMerge => ('逐 Mod 合并 · 还差 $_modsPending 项', colors.warning),
      null => ('待选择', colors.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  /// PK 对比表：三行，胜出的一侧打勾 + 绿色；未知显示「未知」。
  Widget _buildPkTable(BuildContext context) {
    final colors = context.narrColors;
    if (conflict.pk.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
          border: Border.all(color: colors.divider),
        ),
        child: Text(
          conflict.pk.explanation,
          style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
        border: Border.all(color: colors.divider),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 74),
              Expanded(
                child: Text(
                  '本地',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.textSecondary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  '云端（导入端）',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < conflict.pk.axes.length; i++) ...[
            if (i > 0) Divider(height: 10, color: colors.divider),
            _buildAxisRow(context, conflict.pk.axes[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildAxisRow(BuildContext context, SyncPkAxisResult axis) {
    final colors = context.narrColors;
    Widget cell(String text, bool highlight) {
      return Row(
        children: [
          if (highlight) ...[
            Icon(Icons.check_circle, size: 13, color: colors.success),
            const SizedBox(width: 3),
          ],
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
                color: highlight ? colors.success : colors.textPrimary,
              ),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Tooltip(
          message: axis.axis.hint,
          child: SizedBox(
            width: 74,
            child: Text(
              axis.axis.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
          ),
        ),
        Expanded(child: cell(axis.localText, axis.favorsLocal)),
        Expanded(child: cell(axis.remoteText, axis.favorsRemote)),
      ],
    );
  }

  /// 逐 Mod 对比：只列有差异的行，内容一致的折叠成计数。
  Widget _buildModsCompare(BuildContext context, ModsPk pk) {
    final colors = context.narrColors;
    final rows = [
      for (final entry in pk.entries)
        if (entry.status != ModsPkStatus.same) entry,
    ];
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
        border: Border.all(color: colors.divider),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.playlist_add_check_circle_outlined,
                size: 16,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '逐 Mod 对比（共 ${pk.entries.length} 个'
                  '${pk.sameCount > 0 ? '，${pk.sameCount} 个一致未列出' : ''}）',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (onModsMergeEnabled != null && !modsMerge)
                TextButton(
                  onPressed: enabled ? onModsMergeEnabled : null,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('按时间建议合并'),
                ),
            ],
          ),
          if (modsMerge)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _modsPending == 0
                    ? '已进入逐 Mod 合并：下面的选择会保留两侧较新的版本。'
                    : '已进入逐 Mod 合并：还有 $_modsPending 项需要你选。',
                style: TextStyle(
                  fontSize: 10.5,
                  color: _modsPending == 0 ? colors.success : colors.warning,
                ),
              ),
            ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '两侧 Mod 内容一致，没有需要逐项选择的内容。',
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  children: [
                    for (final entry in rows) _buildModsRow(context, entry),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildModsRow(BuildContext context, ModsPkEntry entry) {
    final colors = context.narrColors;
    final selected = modChoices[entry.uuid];
    final interactive =
        entry.needsChoice && enabled && onModChoiceChanged != null;
    return Padding(
      key: ValueKey('mods-compare-${entry.uuid}'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${entry.name} · ${entry.uuidShort}',
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
              _smallChip(
                context,
                entry.status.label,
                _statusColor(context, entry.status),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '本地：${_modTimeText(entry.localUpdatedAt, entry.presentLocal, entry.localDeleted)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '云端：${_modTimeText(entry.remoteUpdatedAt, entry.presentRemote, entry.remoteDeleted)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          if (interactive)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SettingsToggleChip(
                  key: ValueKey('mod-choice-${entry.uuid}-local'),
                  label: '本地',
                  selected: selected == BackupConflictChoice.local,
                  icon: Icons.folder_outlined,
                  onTap: () => onModChoiceChanged!(
                    entry.uuid,
                    BackupConflictChoice.local,
                  ),
                ),
                SettingsToggleChip(
                  key: ValueKey('mod-choice-${entry.uuid}-remote'),
                  label: '云端',
                  selected: selected == BackupConflictChoice.remote,
                  icon: Icons.cloud_outlined,
                  onTap: () => onModChoiceChanged!(
                    entry.uuid,
                    BackupConflictChoice.remote,
                  ),
                ),
                if (entry.status == ModsPkStatus.unknown)
                  Text(
                    '时间相同或缺失，请手动选',
                    style: TextStyle(fontSize: 10.5, color: colors.warning),
                  ),
              ],
            )
          else
            Text(
              _modAutoText(entry),
              style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
            ),
        ],
      ),
    );
  }

  Color _statusColor(BuildContext context, ModsPkStatus status) {
    final colors = context.narrColors;
    return switch (status) {
      ModsPkStatus.local => NarrChatTheme.primary,
      ModsPkStatus.onlyLocal => NarrChatTheme.primary,
      ModsPkStatus.remote => colors.warning,
      ModsPkStatus.onlyRemote => colors.warning,
      ModsPkStatus.unknown => colors.warning,
      ModsPkStatus.same => colors.success,
    };
  }

  Widget _smallChip(BuildContext context, String label, Color color) {
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

  static String _modAutoText(ModsPkEntry entry) => switch (entry.status) {
    ModsPkStatus.same => '两侧一致，保留本地',
    ModsPkStatus.onlyLocal => '仅本地有，合并时自动保留',
    ModsPkStatus.onlyRemote => '仅云端有，合并时自动带入',
    _ => '',
  };

  static String _modTimeText(DateTime? time, bool present, bool deleted) {
    if (!present) return '（无）';
    final text = time == null ? '时间未知' : Formats.formatDateTime(time);
    return deleted ? '$text · 已删除' : text;
  }

  /// 单侧摘要卡（点整卡即选中该侧）。
  Widget _buildSide(BuildContext context, SyncPreviewSide side) {
    final colors = context.narrColors;
    final isLocal = side == SyncPreviewSide.local;
    final selected = isLocal ? _isLocal : _isRemote;
    final accent = NarrChatTheme.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius - 2),
        onTap: enabled
            ? () => onChoiceChanged(
                isLocal
                    ? BackupConflictChoice.local
                    : BackupConflictChoice.remote,
              )
            : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: BoxDecoration(
            color: selected ? colors.userBubble : colors.background,
            borderRadius: BorderRadius.circular(
              NarrChatTheme.controlRadius - 2,
            ),
            border: Border.all(
              color: selected ? accent : colors.divider,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: selected ? accent : colors.placeholder,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isLocal ? '本地' : '云端（导入端）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '对比预览',
                    icon: const Icon(Icons.visibility_outlined, size: 16),
                    color: colors.textSecondary,
                    onPressed: enabled ? onPreview : null,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                isLocal
                    ? '本机已同步：${_generationText()}'
                    : '${conflict.remoteGenerationLabel} · '
                          '设备 ${conflict.remoteDeviceShort}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
              ),
              if (!isLocal) ...[
                const SizedBox(height: 2),
                Text(
                  '写入：${_timeText(conflict.remoteSavedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: colors.textSecondary),
                ),
              ],
              const SizedBox(height: 6),
              for (final axis in conflict.pk.axes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 62,
                        child: Text(
                          axis.axis.label,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          isLocal ? axis.localText : axis.remoteText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight:
                                (isLocal && axis.favorsLocal) ||
                                    (!isLocal && axis.favorsRemote)
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color:
                                (isLocal && axis.favorsLocal) ||
                                    (!isLocal && axis.favorsRemote)
                                ? colors.success
                                : colors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _generationText() {
    final known = conflict.plan.base.generation;
    return known > 0 ? '第 $known 代' : '还没同步过';
  }

  static String _timeText(DateTime? time) =>
      time == null ? '未知' : Formats.formatDateTime(time);
}
