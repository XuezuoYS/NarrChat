import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/round_provider.dart';
import '../services/branch_rules.dart';
import '../theme/app_theme.dart';
import 'app_notice_overlay.dart';
import 'round_action_dialogs.dart';

/// 面板订阅的变更信号：当前加载的是哪本书 / 数据版本 / 是否生成中。
///
/// 只把这三项交给 `select`，流式正文 chunk 不会触发本页重算。
typedef _CleanupSignals = ({
  String loadedBookUuid,
  int revision,
  bool generating,
});

/// 书籍设置页的「其它设置」面板：放不适合塞进其它子页的维护 / 清理操作。
///
/// 目前只有「删除未启用的代」：按组保留当前选中的代，清掉旧代与因此不可达的
/// 后续内容；属内容变更（刷新 `updated_at`）并触发云备份。
class BookOtherSettingsPanel extends StatefulWidget {
  /// 所属书籍 uuid（编辑态才有该面板）。
  final String bookUuid;

  const BookOtherSettingsPanel({super.key, required this.bookUuid});

  @override
  State<BookOtherSettingsPanel> createState() => _BookOtherSettingsPanelState();
}

class _BookOtherSettingsPanelState extends State<BookOtherSettingsPanel> {
  /// 删除请求进行中（按钮禁用 + 转圈，避免重复提交）。
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    // 编辑态入口只从对话页进入，正常已加载本书；直接打开时补一次加载。
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureRoundsLoaded());
  }

  Future<void> _ensureRoundsLoaded() async {
    if (!mounted || widget.bookUuid.isEmpty) return;
    final provider = context.read<RoundProvider>();
    if (provider.loadedBookUuid == widget.bookUuid) return;
    await provider.loadRounds(widget.bookUuid);
  }

  Future<void> _confirmAndDelete(DeleteUnusedGenerationsPlan plan) async {
    final confirmed = await showDeleteUnusedGenerationsConfirmDialog(
      context,
      unusedCount: plan.unusedCount,
      cascadedCount: plan.cascadedCount,
    );
    if (!confirmed || !mounted) return;

    final notices = context.notices;
    final provider = context.read<RoundProvider>();
    setState(() => _deleting = true);
    final result = await provider.deleteUnusedGenerations(widget.bookUuid);
    if (!mounted) return;
    setState(() => _deleting = false);

    if (result.isRefused) {
      final message = result.refusal ?? '删除失败';
      if (message.contains('正在生成中')) {
        notices.warning(message);
      } else {
        notices.error('删除失败：$message', copyable: true);
      }
      return;
    }
    if (result.deleted <= 0) {
      notices.info('没有可删除的未启用的代。');
      return;
    }
    notices.success('已删除 ${result.deleted} 个代。');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;

    final bookUuid = widget.bookUuid;
    // 只订阅会影响计划 / 按钮状态的信号：流式正文 chunk 不触发重算。
    final _CleanupSignals signals = context.select<RoundProvider, _CleanupSignals>(
      (provider) => (
        loadedBookUuid: provider.loadedBookUuid,
        revision: provider.versionsRevision,
        generating: provider.isGeneratingBook(bookUuid),
      ),
    );
    final ready = bookUuid.isNotEmpty && signals.loadedBookUuid == bookUuid;
    final plan = ready
        ? context.read<RoundProvider>().unusedGenerationsPlanFor(bookUuid)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '其它设置',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '书籍的维护与清理操作，不会改动设定与正文。',
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 20),
        _buildCleanupCard(
          context,
          plan: plan,
          ready: ready,
          generating: signals.generating,
        ),
      ],
    );
  }

  Widget _buildCleanupCard(
    BuildContext context, {
    required DeleteUnusedGenerationsPlan? plan,
    required bool ready,
    required bool generating,
  }) {
    final colors = context.narrColors;
    final error = Theme.of(context).colorScheme.error;
    final missingBook = widget.bookUuid.isEmpty;
    final canDelete =
        !missingBook &&
        plan != null &&
        plan.total > 0 &&
        !generating &&
        !_deleting;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.delete_sweep_outlined, size: 20, color: error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '删除未启用的代',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '每一轮可能有多个版本（代），只有当前启用的那一代会出现在活动链上。'
            '清理会立即写入本书，不需要点右上角「保存」。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          if (!ready && !missingBook)
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '正在读取本书的代…',
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                ),
              ],
            )
          else
            Text(
              _summaryText(
                plan: plan,
                generating: generating,
                missingBook: missingBook,
              ),
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: colors.textPrimary,
              ),
            ),
          if (ready && plan != null && plan.cascadedCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '另有 ${plan.cascadedCount} 个只能从这些代到达的后续代，会一并删除。',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: colors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '删除后无法恢复，也不会进入回收站。',
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: canDelete ? () => _confirmAndDelete(plan) : null,
              icon: _deleting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text(_deleting ? '正在删除…' : '删除未启用的代'),
              style: OutlinedButton.styleFrom(
                foregroundColor: error,
                side: BorderSide(color: error.withValues(alpha: 0.5)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _summaryText({
    required DeleteUnusedGenerationsPlan? plan,
    required bool generating,
    required bool missingBook,
  }) {
    if (missingBook) return '书籍信息缺失，暂不可清理。';
    if (generating) return '本书正在生成中，生成结束后才能清理。';
    if (plan == null) return '暂不可用。';
    if (plan.totalGenerations == 0) return '本书还没有任何代。';
    if (plan.total == 0) return '没有可删除的未启用的代。';
    return '全书共 ${plan.totalGenerations} 代，其中 ${plan.unusedCount} 个未启用。';
  }
}
