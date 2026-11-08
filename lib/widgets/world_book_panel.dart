import 'package:flutter/material.dart';

import '../models/app_notice.dart';
import '../models/world_book_entry.dart';
import 'app_empty_hint.dart';
import 'app_notice_overlay.dart';
import 'markdown_editing_controller.dart';
import 'settings/settings_kit.dart';

/// 世界书管理面板（作为书籍设置的一个子模块）。
///
/// 世界书条目由「关键词 + 注入内容」组成：发送剧情指令时，
/// App 会扫描本轮输入与最近历史轮次，命中关键词的条目内容将注入 System Prompt。
/// 支持新增、编辑、启用/停用与删除。
///
/// 本面板是**纯草稿组件**：所有增删改只改本地列表并通过 [onChanged] 回传，
/// 不直接读写数据库；真正落库由书籍设置页在点「保存」时统一整体提交。
class WorldBookPanel extends StatefulWidget {
  /// 当前草稿条目（父级持有；外部刷新时传新的列表进来）。
  final List<WorldBookEntry> entries;

  /// 草稿变化回调（每次变化回传完整的条目快照）。
  final ValueChanged<List<WorldBookEntry>>? onChanged;

  const WorldBookPanel({super.key, this.entries = const [], this.onChanged});

  @override
  State<WorldBookPanel> createState() => _WorldBookPanelState();
}

class _WorldBookPanelState extends State<WorldBookPanel> {
  final TextEditingController _keywordController = TextEditingController();
  final MarkdownEditingController _contentController =
      MarkdownEditingController();

  /// 面板本地草稿（父级列表是它的初始值 / 外部刷新来源）。
  late List<WorldBookEntry> _pending;

  @override
  void initState() {
    super.initState();
    _pending = List.of(widget.entries);
  }

  @override
  void didUpdateWidget(covariant WorldBookPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父级外部刷新（云同步落地等）提供的新列表与内部草稿内容不同 → 采纳；
    // 内容一致时保留内部状态（父级回传自己的回声不重置用户操作）。
    if (!WorldBookEntry.sameList(widget.entries, _pending)) {
      setState(() => _pending = List.of(widget.entries));
    }
  }

  @override
  void dispose() {
    _keywordController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _addEntry() {
    final keyword = _keywordController.text.trim();
    final content = _contentController.text.trim();
    if (keyword.isEmpty || content.isEmpty) {
      _showMessage('关键词与内容不能为空', kind: NoticeKind.warning);
      return;
    }
    setState(() {
      _pending.add(
        WorldBookEntry(
          bookUuid: '',
          keyword: keyword,
          content: content,
          isActive: true,
          createdAt: DateTime.now(),
        ),
      );
    });
    _keywordController.clear();
    _contentController.clear();
    _notifyChanged();
  }

  Future<void> _editEntry(WorldBookEntry entry) async {
    final result = await showDialog<_WorldBookEntryEdit>(
      context: context,
      builder: (_) => _WorldBookEntryDialog(entry: entry),
    );
    if (result == null || !mounted) return;
    final index = _pending.indexWhere((e) => identical(e, entry));
    if (index == -1) return;
    setState(() {
      _pending[index] = _pending[index].copyWith(
        keyword: result.keyword,
        content: result.content,
        isActive: result.isActive,
      );
    });
    _notifyChanged();
  }

  /// 草稿变化后回传外层快照。
  void _notifyChanged() {
    widget.onChanged?.call(List.of(_pending));
  }

  /// 切换条目启用状态。
  void _toggleEntry(WorldBookEntry entry, bool active) {
    final index = _pending.indexWhere((e) => identical(e, entry));
    if (index == -1) return;
    setState(() {
      _pending[index] = _pending[index].copyWith(isActive: active);
    });
    _notifyChanged();
  }

  /// 删除条目（草稿态；保存后才写库）。
  void _deleteEntry(WorldBookEntry entry) {
    setState(() {
      _pending.removeWhere((e) => identical(e, entry));
    });
    _notifyChanged();
  }

  void _showMessage(String message, {NoticeKind kind = NoticeKind.info}) {
    context.notices.show(message, kind: kind);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = List<WorldBookEntry>.unmodifiable(_pending);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsPageHeader(
          title: '世界书',
          description: '关键词命中后自动注入 System Prompt；改动在点击顶栏「保存」后生效。',
        ),
        // 新增条目表单
        SettingsTextField(
          controller: _keywordController,
          label: '触发关键词',
          hint: '多个关键词用逗号/顿号分隔，如：青云宗, 苏清月',
        ),
        const SizedBox(height: 8),
        SettingsTextField(
          controller: _contentController,
          label: '注入内容（命中后写入 System Prompt）',
          minLines: 2,
          maxLines: 4,
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
            padding: EdgeInsets.zero,
            itemCount: entries.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              indent: 14,
              endIndent: 14,
              color: theme.colorScheme.outlineVariant,
            ),
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
    final inactive = !entry.isActive;
    return Opacity(
      opacity: inactive ? 0.55 : 1,
      // 整行点击 = 切换启用；开关本体、编辑/删除按钮各自处理手势，不误触。
      child: SettingsRow(
        leading: Switch(value: entry.isActive, onChanged: onToggle),
        title: entry.keyword,
        subtitle: entry.content,
        onTap: () => onToggle(!entry.isActive),
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
      context.notices.warning('关键词与内容不能为空');
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
            SettingsTextField(
              controller: _keyword,
              label: '触发关键词',
              hint: '多个关键词用逗号/顿号分隔',
            ),
            const SizedBox(height: 12),
            SettingsTextField(
              controller: _content,
              label: '注入内容',
              minLines: 4,
              maxLines: 8,
            ),
            const SizedBox(height: 8),
            SettingsSwitchRow(
              title: '启用该条目',
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
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
