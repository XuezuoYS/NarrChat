import 'package:flutter/material.dart';

import '../models/mod.dart';
import '../theme/app_theme.dart';
import '../utils/focus_utils.dart';
import 'markdown_editing_controller.dart';
import 'uuid_display.dart';

/// 打开 Mod 详情对话框（新建 / 编辑 / 只读查看共用）。
///
/// - 只读（[readOnly] 为 true）：仅「关闭」，不可修改；
/// - 可编辑：返回 [ModFormData]，取消时返回 null。
Future<ModFormData?> showModDetailDialog(
  BuildContext context, {
  Mod? mod,
  bool readOnly = false,
}) {
  return showDialog<ModFormData>(
    context: context,
    builder: (_) => ModDetailDialog(mod: mod, readOnly: readOnly),
  );
}

/// 【预览 mod】只读查看对话框：展示名称、简介与前置词/后置词/系统提示词/
/// 世界书全部内容（5 个标签页），不可修改。
Future<void> showModPreview(BuildContext context, Mod mod) {
  return showModDetailDialog(context, mod: mod, readOnly: true);
}

/// 新建/编辑/查看 Mod 对话框返回的数据。
class ModFormData {
  final String name;
  final String description;
  final String prePrompt;
  final String postPrompt;
  final String systemPrompt;
  final List<ModWorldBookEntry> worldBookEntries;

  const ModFormData({
    required this.name,
    required this.description,
    required this.prePrompt,
    required this.postPrompt,
    required this.systemPrompt,
    required this.worldBookEntries,
  });
}

/// Mod 详情对话框（新建 / 编辑 / 只读查看共用）。
///
/// 使用 5 个标签页：基本信息、前置词、后置词、系统提示词、世界书。
class ModDetailDialog extends StatefulWidget {
  final Mod? mod;
  final bool readOnly;

  const ModDetailDialog({super.key, this.mod, required this.readOnly});

  @override
  State<ModDetailDialog> createState() => _ModDetailDialogState();
}

class _ModDetailDialogState extends State<ModDetailDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final MarkdownEditingController _prePrompt;
  late final MarkdownEditingController _postPrompt;
  late final MarkdownEditingController _systemPrompt;
  late List<ModWorldBookEntry> _worldBookEntries;

  bool get _readOnly => widget.readOnly;
  bool get _isEdit => widget.mod != null;

  @override
  void initState() {
    super.initState();
    final mod = widget.mod;
    _name = TextEditingController(text: mod?.name ?? '');
    _description = TextEditingController(text: mod?.description ?? '');
    _prePrompt = MarkdownEditingController(text: mod?.prePrompt ?? '');
    _postPrompt = MarkdownEditingController(text: mod?.postPrompt ?? '');
    _systemPrompt = MarkdownEditingController(text: mod?.systemPrompt ?? '');
    _worldBookEntries = List.of(mod?.worldBookEntries ?? const []);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _prePrompt.dispose();
    _postPrompt.dispose();
    _systemPrompt.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称不能为空')),
      );
      return;
    }
    Navigator.of(context).pop(
      ModFormData(
        name: _name.text.trim(),
        description: _description.text,
        prePrompt: _prePrompt.text,
        postPrompt: _postPrompt.text,
        systemPrompt: _systemPrompt.text,
        worldBookEntries: List.of(_worldBookEntries),
      ),
    );
  }

  Widget _multiline(TextEditingController controller, String hint) {
    return TextField(
      controller: controller,
      onTapOutside: unfocusOnTapOutside,
      readOnly: _readOnly,
      maxLines: null,
      minLines: 6,
      keyboardType: TextInputType.multiline,
      style: const TextStyle(fontSize: 13, height: 1.5),
      decoration: InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _readOnly
        ? '查看 Mod'
        : (_isEdit ? '编辑 Mod' : '新建 Mod');
    return Dialog(
      child: Container(
        width: 600,
        height: 520,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.extension_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: context.narrColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DefaultTabController(
              length: 5,
              child: Expanded(
                child: Column(
                  children: [
                    const TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        Tab(text: '基本信息'),
                        Tab(text: '前置词'),
                        Tab(text: '后置词'),
                        Tab(text: '系统提示词'),
                        Tab(text: '世界书'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: TabBarView(
                        children: [
                          // 基本信息
                          SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextField(
                                  controller: _name,
                                  onTapOutside: unfocusOnTapOutside,
                                  readOnly: _readOnly,
                                  decoration: const InputDecoration(
                                    labelText: '名称 *（仅用于辨识，不发送给 AI）',
                                    hintText: '如：文笔润色',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _description,
                                  onTapOutside: unfocusOnTapOutside,
                                  readOnly: _readOnly,
                                  maxLines: 3,
                                  minLines: 2,
                                  decoration: const InputDecoration(
                                    labelText: '简介（仅用于辨识，不发送给 AI）',
                                    hintText: '简要说明这个 Mod 的作用',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                UuidDisplay(
                                  label: 'Mod UUID',
                                  uuid: widget.mod?.uuid ?? '',
                                ),
                              ],
                            ),
                          ),
                          _multiline(_prePrompt, '发送请求时自动置入「前置词」区'),
                          _multiline(_postPrompt, '发送请求时自动置入「后置词」区'),
                          _multiline(_systemPrompt, '自动追加到 System Prompt'),
                          // 世界书条目可能较多，需可滚动（与「基本信息」Tab 一致）。
                          SingleChildScrollView(
                            child: _ModWorldBookEditor(
                              initialEntries: _worldBookEntries,
                              readOnly: _readOnly,
                              onChanged: (entries) => _worldBookEntries = entries,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(_readOnly ? '关闭' : '取消'),
                ),
                if (!_readOnly)
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('保存'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Mod 世界书条目编辑器（关键词 + 内容，与书籍世界书一致）。
///
/// - 关键词非空的条目：扫描本轮输入与最近历史轮次，命中才注入；
/// - 关键词留空的条目：恒定生效（无需命中）。
class _ModWorldBookEditor extends StatefulWidget {
  final List<ModWorldBookEntry> initialEntries;
  final bool readOnly;
  final ValueChanged<List<ModWorldBookEntry>> onChanged;

  const _ModWorldBookEditor({
    required this.initialEntries,
    required this.readOnly,
    required this.onChanged,
  });

  @override
  State<_ModWorldBookEditor> createState() => _ModWorldBookEditorState();
}

class _ModWorldBookEditorState extends State<_ModWorldBookEditor> {
  late final List<ModWorldBookEntry> _entries = List.of(widget.initialEntries);

  void _notify() {
    widget.onChanged(List.of(_entries));
  }

  Future<void> _addOrEdit({ModWorldBookEntry? entry}) async {
    final isEdit = entry != null;
    final result = await showDialog<ModWorldBookEntry>(
      context: context,
      builder: (_) => _WorldBookEntryDialog(entry: entry, readOnly: widget.readOnly),
    );
    if (result == null) return;
    setState(() {
      if (isEdit) {
        final index = _entries.indexOf(entry);
        if (index >= 0) _entries[index] = result;
      } else {
        _entries.add(result);
      }
    });
    _notify();
  }

  void _remove(ModWorldBookEntry entry) {
    setState(() => _entries.remove(entry));
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '关键词命中后自动注入（与书籍世界书一致）；关键词留空则恒定生效。',
          style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 8),
        if (!widget.readOnly)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _addOrEdit(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加条目'),
            ),
          ),
        const SizedBox(height: 4),
        if (_entries.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
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
                  color: theme.colorScheme.outlineVariant,
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
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = _entries[index];
              final isConstant = entry.keywords.isEmpty;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  isConstant ? Icons.public : Icons.manage_search,
                  size: 20,
                  color: isConstant
                      ? NarrChatTheme.primary
                      : context.narrColors.textSecondary,
                ),
                title: Text(
                  isConstant ? '（恒定生效）' : entry.keyword,
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
                      tooltip: '查看/编辑',
                      onPressed: () => _addOrEdit(entry: entry),
                    ),
                    if (!widget.readOnly)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: '删除',
                        onPressed: () => _remove(entry),
                      ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

/// 世界书条目（关键词 + 内容）编辑对话框。
class _WorldBookEntryDialog extends StatefulWidget {
  final ModWorldBookEntry? entry;
  final bool readOnly;

  const _WorldBookEntryDialog({this.entry, required this.readOnly});

  @override
  State<_WorldBookEntryDialog> createState() => _WorldBookEntryDialogState();
}

class _WorldBookEntryDialogState extends State<_WorldBookEntryDialog> {
  late final TextEditingController _keyword;
  late final MarkdownEditingController _content;

  @override
  void initState() {
    super.initState();
    _keyword = TextEditingController(text: widget.entry?.keyword ?? '');
    _content = MarkdownEditingController(text: widget.entry?.content ?? '');
  }

  @override
  void dispose() {
    _keyword.dispose();
    _content.dispose();
    super.dispose();
  }

  void _save() {
    if (_content.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('内容不能为空')),
      );
      return;
    }
    Navigator.of(context).pop(
      ModWorldBookEntry(
        keyword: _keyword.text.trim(),
        content: _content.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.entry != null;
    return AlertDialog(
      title: Text(
        widget.readOnly
            ? '查看世界书条目'
            : (isEdit ? '编辑世界书条目' : '添加世界书条目'),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _keyword,
              onTapOutside: unfocusOnTapOutside,
              readOnly: widget.readOnly,
              decoration: const InputDecoration(
                labelText: '触发关键词',
                hintText: '多个关键词用逗号/顿号分隔；留空则恒定生效',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _content,
              onTapOutside: unfocusOnTapOutside,
              readOnly: widget.readOnly,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '注入内容',
                hintText: '命中关键词后写入 System Prompt',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.readOnly ? '关闭' : '取消'),
        ),
        if (!widget.readOnly)
          FilledButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
      ],
    );
  }
}
