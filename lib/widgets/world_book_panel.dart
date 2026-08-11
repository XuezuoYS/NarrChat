import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/world_book_entry.dart';
import '../providers/world_book_provider.dart';
import '../theme/app_theme.dart';
import '../utils/focus_utils.dart';
import 'app_empty_hint.dart';
import 'markdown_editing_controller.dart';

/// 世界书管理面板（作为书籍设置的一个子模块）。
///
/// 世界书条目由「关键词 + 注入内容」组成：发送剧情指令时，
/// App 会扫描本轮输入与最近历史轮次，命中关键词的条目内容将注入 System Prompt。
/// 支持新增、编辑、启用/停用与删除。
class WorldBookPanel extends StatefulWidget {
  /// 所属书籍 ID；为 null 表示新建书籍草稿模式（条目保存在内存，
  /// 保存书籍后由外层统一落库）。
  final int? bookId;

  /// 草稿模式（bookId 为 null）下当前的世界书条目；改动后通过
  /// [onPendingChanged] 回传，供外层在保存书籍时统一落库。
  final List<WorldBookEntry>? pendingEntries;
  final ValueChanged<List<WorldBookEntry>>? onPendingChanged;

  const WorldBookPanel({
    super.key,
    this.bookId,
    this.pendingEntries,
    this.onPendingChanged,
  });

  @override
  State<WorldBookPanel> createState() => _WorldBookPanelState();
}

class _WorldBookPanelState extends State<WorldBookPanel> {
  final TextEditingController _keywordController = TextEditingController();
  final MarkdownEditingController _contentController = MarkdownEditingController();

  /// 草稿模式下的本地条目（仅 bookId 为 null 时使用）。
  late List<WorldBookEntry> _pending;

  bool get _isDraft => widget.bookId == null;

  @override
  void initState() {
    super.initState();
    _pending = List.of(widget.pendingEntries ?? const []);
    final bookId = widget.bookId;
    if (bookId != null) {
      // 进入时加载该书籍的世界书条目。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<WorldBookProvider>().loadEntries(bookId);
      });
    }
  }

  @override
  void didUpdateWidget(covariant WorldBookPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 草稿模式下外层状态可能在切换标签后重建本面板，同步最新条目。
    if (_isDraft && oldWidget.pendingEntries != widget.pendingEntries) {
      _pending = List.of(widget.pendingEntries ?? const []);
    }
  }

  @override
  void dispose() {
    _keywordController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _addEntry() async {
    final keyword = _keywordController.text.trim();
    final content = _contentController.text.trim();
    if (keyword.isEmpty || content.isEmpty) {
      _showMessage('关键词与内容不能为空');
      return;
    }
    if (_isDraft) {
      setState(() {
        _pending.add(
          WorldBookEntry(
            bookId: 0,
            keyword: keyword,
            content: content,
            isActive: true,
            createdAt: DateTime.now(),
          ),
        );
      });
      _keywordController.clear();
      _contentController.clear();
      _notifyPendingChanged();
      return;
    }
    final ok = await context.read<WorldBookProvider>().addEntry(
          keyword: keyword,
          content: content,
        );
    if (ok && mounted) {
      _keywordController.clear();
      _contentController.clear();
    } else if (mounted) {
      _showMessage('添加失败：${context.read<WorldBookProvider>().error}');
    }
  }

  Future<void> _editEntry(WorldBookEntry entry) async {
    final result = await showDialog<_WorldBookEntryEdit>(
      context: context,
      builder: (_) => _WorldBookEntryDialog(entry: entry),
    );
    if (result == null || !mounted) return;
    if (_isDraft) {
      final index = _pending.indexWhere((e) => identical(e, entry));
      if (index == -1) return;
      setState(() {
        _pending[index] = _pending[index].copyWith(
          keyword: result.keyword,
          content: result.content,
          isActive: result.isActive,
        );
      });
      _notifyPendingChanged();
      return;
    }
    final ok = await context.read<WorldBookProvider>().updateEntry(
          entry.copyWith(
            keyword: result.keyword,
            content: result.content,
            isActive: result.isActive,
          ),
        );
    if (!ok && mounted) {
      _showMessage('保存失败：${context.read<WorldBookProvider>().error}');
    }
  }

  /// 草稿模式下将最新条目回传外层。
  void _notifyPendingChanged() {
    widget.onPendingChanged?.call(List.of(_pending));
  }

  /// 切换条目启用状态。
  Future<void> _toggleEntry(WorldBookEntry entry, bool active) async {
    if (_isDraft) {
      final index = _pending.indexWhere((e) => identical(e, entry));
      if (index == -1) return;
      setState(() {
        _pending[index] = _pending[index].copyWith(isActive: active);
      });
      _notifyPendingChanged();
      return;
    }
    await context.read<WorldBookProvider>().updateEntry(
          entry.copyWith(isActive: active),
        );
  }

  /// 删除条目。
  Future<void> _deleteEntry(WorldBookEntry entry) async {
    if (_isDraft) {
      setState(() {
        _pending.removeWhere((e) => identical(e, entry));
      });
      _notifyPendingChanged();
      return;
    }
    await context.read<WorldBookProvider>().removeEntry(entry.id!);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 草稿模式使用面板本地内存条目；编辑模式使用全局 Provider 的条目。
    final entries = _isDraft
        ? List.unmodifiable(_pending)
        : context.watch<WorldBookProvider>().entries;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '世界书',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: context.narrColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '关键词命中后自动注入 System Prompt。',
          style: TextStyle(
            fontSize: 12,
            color: context.narrColors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        // 新增条目表单
        TextField(
          controller: _keywordController,
          onTapOutside: unfocusOnTapOutside,
          decoration: const InputDecoration(
            labelText: '触发关键词',
            hintText: '多个关键词用逗号/顿号分隔，如：青云宗, 苏清月',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _contentController,
          onTapOutside: unfocusOnTapOutside,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '注入内容（命中后写入 System Prompt）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _addEntry,
            icon: const Icon(Icons.add),
            label: const Text('添加条目'),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              '条目（${entries.length}）',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Divider(height: 1),
        const SizedBox(height: 4),
        if (entries.isEmpty)
          const AppEmptyHint(
            icon: Icons.menu_book_outlined,
            text: '暂无世界书条目\n添加关键词与内容，剧情输入命中关键词时将自动注入',
          )
        else
          // 面板内嵌于外层滚动区，列表自身不滚动。
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _EntryTile(
                entry: entry,
                onToggle: (v) => _toggleEntry(entry, v),
                onEdit: () => _editEntry(entry),
                onDelete: () => _deleteEntry(entry),
              );
            },
          ),
      ],
    );
  }
}

/// 单条世界书条目（含启用开关、编辑与删除）。
class _EntryTile extends StatelessWidget {
  final WorldBookEntry entry;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _EntryTile({
    required this.entry,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inactive = !entry.isActive;
    return Opacity(
      opacity: inactive ? 0.55 : 1,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Switch(
          value: entry.isActive,
          onChanged: onToggle,
        ),
        title: Text(
          entry.keyword,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          entry.content,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: '编辑',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: '删除',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑结果。
class _WorldBookEntryEdit {
  final String keyword;
  final String content;
  final bool isActive;

  const _WorldBookEntryEdit({
    required this.keyword,
    required this.content,
    required this.isActive,
  });
}

/// 编辑世界书条目对话框。
class _WorldBookEntryDialog extends StatefulWidget {
  final WorldBookEntry entry;

  const _WorldBookEntryDialog({required this.entry});

  @override
  State<_WorldBookEntryDialog> createState() => _WorldBookEntryDialogState();
}

class _WorldBookEntryDialogState extends State<_WorldBookEntryDialog> {
  late final TextEditingController _keyword;
  late final MarkdownEditingController _content;
  late bool _isActive;

  @override
  void initState() {
    super.initState();
    _keyword = TextEditingController(text: widget.entry.keyword);
    _content = MarkdownEditingController(text: widget.entry.content);
    _isActive = widget.entry.isActive;
  }

  @override
  void dispose() {
    _keyword.dispose();
    _content.dispose();
    super.dispose();
  }

  void _save() {
    final keyword = _keyword.text.trim();
    final content = _content.text.trim();
    if (keyword.isEmpty || content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('关键词与内容不能为空')),
      );
      return;
    }
    Navigator.of(context).pop(
      _WorldBookEntryEdit(
        keyword: keyword,
        content: content,
        isActive: _isActive,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑世界书条目'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _keyword,
              onTapOutside: unfocusOnTapOutside,
              decoration: const InputDecoration(
                labelText: '触发关键词',
                hintText: '多个关键词用逗号/顿号分隔',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _content,
              onTapOutside: unfocusOnTapOutside,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '注入内容',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用该条目'),
              value: _isActive,
              onChanged: (v) => setState(() => _isActive = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
