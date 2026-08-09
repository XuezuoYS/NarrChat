import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/world_book_entry.dart';
import '../providers/world_book_provider.dart';
import '../theme/app_theme.dart';

/// 世界书管理面板（作为书籍设置的一个子模块）。
///
/// 世界书条目由「关键词 + 注入内容」组成：发送剧情指令时，
/// App 会扫描本轮输入与最近历史轮次，命中关键词的条目内容将注入 System Prompt。
/// 支持新增、编辑、启用/停用与删除。
class WorldBookPanel extends StatefulWidget {
  /// 所属书籍 ID；为 null 表示新建书籍尚未保存（此时仅显示提示）。
  final int? bookId;

  const WorldBookPanel({super.key, this.bookId});

  @override
  State<WorldBookPanel> createState() => _WorldBookPanelState();
}

class _WorldBookPanelState extends State<WorldBookPanel> {
  final TextEditingController _keywordController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final bookId = widget.bookId;
    if (bookId != null) {
      // 进入时加载该书籍的世界书条目。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<WorldBookProvider>().loadEntries(bookId);
      });
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bookId = widget.bookId;
    if (bookId == null) {
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            decoration: BoxDecoration(
              color: context.narrColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.narrColors.divider),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: 28,
                  color: context.narrColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '保存新建书籍后，即可在此管理本书的世界书条目。',
                    style: TextStyle(
                      fontSize: 13,
                      color: context.narrColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final theme = Theme.of(context);
    final worldBookProvider = context.watch<WorldBookProvider>();
    final entries = worldBookProvider.entries;

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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
            decoration: BoxDecoration(
              color: context.narrColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.narrColors.divider),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                const SizedBox(height: 8),
                Text(
                  '暂无世界书条目\n添加关键词与内容，剧情输入命中关键词时将自动注入',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.narrColors.textSecondary,
                    height: 1.5,
                  ),
                ),
              ],
            ),
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
                onToggle: (v) async {
                  await worldBookProvider.updateEntry(
                    entry.copyWith(isActive: v),
                  );
                },
                onEdit: () => _editEntry(entry),
                onDelete: () async {
                  await worldBookProvider.removeEntry(entry.id!);
                },
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
  late final TextEditingController _content;
  late bool _isActive;

  @override
  void initState() {
    super.initState();
    _keyword = TextEditingController(text: widget.entry.keyword);
    _content = TextEditingController(text: widget.entry.content);
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
