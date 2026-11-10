import 'package:flutter/material.dart';

import '../services/cloud_backup/backup_runner.dart';
import '../services/cloud_backup/backup_pk.dart';
import '../services/sync/sync_conflict.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';
import 'backup_unit_badge.dart';
import 'settings/settings_kit.dart';

/// 冲突决策页里的一张冲突卡：PK 三轴对比 + 两侧摘要 + 整本二选一。
///
/// 约定：左「本地」、右「云端（导入端）」；整张侧卡可点选，选中后主色描边 +
/// 淡底 + 单选圆点。`choice == null` 表示还没选。
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
  });

  final SyncConflict conflict;

  /// 当前选择；null = 待选择。
  final BackupConflictChoice? choice;

  final ValueChanged<BackupConflictChoice> onChoiceChanged;

  /// 打开对比预览（本地 / 云端两路一起加载）。
  final VoidCallback onPreview;

  /// 单元级失败原因（内联展示，不弹窗）。
  final String? error;

  final bool enabled;

  /// 卡片根 key（测试定位）。
  final Key? cardKey;

  bool get _isLocal => choice == BackupConflictChoice.local;
  bool get _isRemote => choice == BackupConflictChoice.remote;
  bool get _isLater => choice == BackupConflictChoice.skip;

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
                    '重命名、改轮次之类的小差异不做逐部件合并：整本二选一。',
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
