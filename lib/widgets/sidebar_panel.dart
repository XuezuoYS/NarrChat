import 'dart:async';

import 'package:flutter/material.dart';

import '../models/round.dart';
import 'markdown_collapsible_editor.dart';
import 'markdown_field.dart';

/// 侧边栏面板。
///
/// - 顶部 Top Bar：固定显示“当前轮次（第 N 轮）”或“历史轮次（第 X 轮）”；
///   历史轮次时背景变浅灰并带红色警告边框以作醒目区分。
/// - 内容区：将数据库存储的 `world_state`、`character_state`、`memory_summary`、
///   `current_time` 以可编辑文本形式显示；
///   `character_state` 使用 [MarkdownCollapsibleEditor] 折叠组件（含“一键展开”）。
///   （`recommended_action` 不在侧边栏编辑，展示于对话区 AI 气泡正文下方。）
/// - 实时保存：每个区块编辑时，内容变化后会经过短暂防抖自动写回数据库
///   （通过 [onAutoSaveField]），无需手动点击即可持久化；
///   底部显示自动保存状态提示条。
///   历史轮次的修改绝不自动影响后续轮次，仅作为快照存档。
///
/// 父级通过 `ValueKey(round.id)` 切换本组件状态，切换轮次时编辑器内容自动重置。
class SidebarPanel extends StatefulWidget {
  final Round? round;
  final bool isHistoryView;
  final Future<void> Function(Round round, String field, String value) onAutoSaveField;
  final VoidCallback onBackToCurrent;

  const SidebarPanel({
    super.key,
    required this.round,
    required this.isHistoryView,
    required this.onAutoSaveField,
    required this.onBackToCurrent,
  });

  @override
  State<SidebarPanel> createState() => _SidebarPanelState();
}

class _SidebarPanelState extends State<SidebarPanel> {
  late final TextEditingController _worldState =
      TextEditingController(text: widget.round?.worldState ?? '');
  late final TextEditingController _characterState =
      TextEditingController(text: widget.round?.characterState ?? '');
  late final TextEditingController _memorySummary =
      TextEditingController(text: widget.round?.memorySummary ?? '');
  late final TextEditingController _currentTime =
      TextEditingController(text: widget.round?.currentTime ?? '');

  // —— 实时自动保存（防抖） ——
  static const Duration _debounce = Duration(milliseconds: 700);
  final Map<String, Timer> _autoSaveTimers = {};
  DateTime? _lastAutoSaveAt;

  @override
  void didUpdateWidget(covariant SidebarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 保险起见：若轮次 id 变化（正常情况下因 ValueKey 不会走到这里）则重置内容。
    if (oldWidget.round?.id != widget.round?.id) {
      _worldState.text = widget.round?.worldState ?? '';
      _characterState.text = widget.round?.characterState ?? '';
      _memorySummary.text = widget.round?.memorySummary ?? '';
      _currentTime.text = widget.round?.currentTime ?? '';
    }
  }

  @override
  void dispose() {
    for (final t in _autoSaveTimers.values) {
      t.cancel();
    }
    _autoSaveTimers.clear();
    _worldState.dispose();
    _characterState.dispose();
    _memorySummary.dispose();
    _currentTime.dispose();
    super.dispose();
  }

  /// 编辑内容变化时调用：对单字段做防抖后自动保存。
  void _scheduleAutoSave(String field, String value) {
    final round = widget.round;
    if (round == null) return;
    _autoSaveTimers[field]?.cancel();
    _autoSaveTimers[field] = Timer(_debounce, () {
      _autoSaveTimers.remove(field);
      widget.onAutoSaveField(round, field, value).then((_) {
        if (mounted) {
          setState(() => _lastAutoSaveAt = DateTime.now());
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final round = widget.round;
    final history = widget.isHistoryView;

    return Container(
      decoration: BoxDecoration(
        color: history ? Colors.grey.shade100 : theme.colorScheme.surface,
        border: history
            ? Border.all(color: theme.colorScheme.error, width: 1.5)
            : Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTopBar(theme, history),
          const Divider(height: 1),
          Expanded(
            child: round == null
                ? _buildEmpty(theme)
                : ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      // 当前时间置顶
                      _sectionLabel(theme, '当前时间'),
                      TextField(
                        controller: _currentTime,
                        style: const TextStyle(fontSize: 14),
                        decoration: const InputDecoration(
                          hintText: '当前时间',
                          isDense: true,
                        ),
                        onChanged: (v) => _scheduleAutoSave('current_time', v),
                      ),
                      const SizedBox(height: 14),
                      _sectionLabel(theme, '世界状态'),
                      MarkdownField(
                        controller: _worldState,
                        hintText: '世界状态',
                        onChanged: (v) => _scheduleAutoSave('world_state', v),
                      ),
                      const SizedBox(height: 14),
                      _sectionLabel(theme, '角色状态'),
                      MarkdownCollapsibleEditor(
                        controller: _characterState,
                        hintText: '如：\n# 主角\n## 陆尘\n- 姓名：…',
                        onChanged: (v) => _scheduleAutoSave('character_state', v),
                      ),
                      const SizedBox(height: 14),
                      _sectionLabel(theme, '记忆总结'),
                      MarkdownField(
                        controller: _memorySummary,
                        hintText: '记忆总结',
                        onChanged: (v) => _scheduleAutoSave('memory_summary', v),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
          ),
          _buildAutoSaveStatusBar(theme),
        ],
      ),
    );
  }

  /// 底部状态条：显示自动保存状态提示（无保存记录时显示操作提示）。
  Widget _buildAutoSaveStatusBar(ThemeData theme) {
    final lastSaved = _lastAutoSaveAt;
    final hasSaved = lastSaved != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasSaved ? Icons.cloud_done_outlined : Icons.edit_outlined,
            size: 13,
            color: hasSaved
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          const SizedBox(width: 4),
          Text(
            hasSaved ? '已自动保存于 ${_formatTime(lastSaved)}' : '编辑各区块后自动保存',
            style: TextStyle(
              fontSize: 11,
              color: hasSaved
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Widget _buildTopBar(ThemeData theme, bool history) {
    final round = widget.round;
    return Container(
      decoration: BoxDecoration(
        gradient: history
            ? null
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF6C4DF6), Color(0xFF9A5CF2)],
              ),
        color: history
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.35)
            : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(
            history ? Icons.history : Icons.radio_button_checked,
            size: 18,
            color: history ? theme.colorScheme.error : Colors.white,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              history
                  ? '历史轮次（第 ${round?.roundIndex ?? '?'} 轮）'
                  : '当前轮次（第 ${round?.roundIndex ?? 0} 轮）',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: history ? theme.colorScheme.error : Colors.white,
              ),
            ),
          ),
          if (history)
            TextButton(
              onPressed: widget.onBackToCurrent,
              child: const Text('回到当前'),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 8),
          Text('暂无轮次数据', style: TextStyle(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
