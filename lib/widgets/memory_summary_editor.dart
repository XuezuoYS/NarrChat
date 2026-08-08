import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 一条记忆条目：轮数 + 日期 + 概括内容（三者绑定在一条内）。
class MemoryEntry {
  final int round;
  final String date;
  final String content;

  const MemoryEntry({
    required this.round,
    required this.date,
    required this.content,
  });
}

/// 记忆条目行的正则：`- 第N轮｜日期：xxx｜概括内容`。
///
/// 容忍：
/// - 列表符 `-` 或 `*`；
/// - 分隔符全角 `｜` 或半角 `|`；
/// - 冒号全角 `：` 或半角 `:`；
/// - 概括内容中再次出现 `｜`/`|`（末尾 `.*` 贪婪匹配）。
final RegExp _memoryEntryRegex = RegExp(
  r'^[-*]\s*第\s*(\d+)\s*轮\s*[｜|]\s*日期\s*[:：]\s*([^｜|]*)\s*[｜|]\s*(.*)$',
);

/// 解析「- 第N轮｜日期：xxx｜概括内容」格式的记忆总结文本。
///
/// 按行解析，能匹配的行转换为 [MemoryEntry]，无法匹配的行直接忽略
/// （需要兜底展示原始文本时，请由调用方自行保留原文本）。
List<MemoryEntry> parseMemoryEntries(String text) {
  final result = <MemoryEntry>[];
  for (final line in text.split('\n')) {
    final m = _memoryEntryRegex.firstMatch(line.trim());
    if (m == null) continue;
    result.add(
      MemoryEntry(
        round: int.tryParse(m.group(1) ?? '') ?? 0,
        date: (m.group(2) ?? '').trim(),
        content: (m.group(3) ?? '').trim(),
      ),
    );
  }
  return result;
}

/// 「记忆总结」专用编辑组件。
///
/// 与 [MarkdownField] 接口一致（同一个 [TextEditingController]、防抖自动保存
/// 回调 [onChanged]、点击「完成」立即保存 [onSave]），但视图模式按「轮数 / 日期 /
/// 概括内容」绑定为一条的条目卡片渲染（而非通用 Markdown 预览）：
///
/// - 每条记忆 = 一个卡片：左侧「第N轮」徽标，下方日期 + 概括内容；
/// - 未命中条目格式的杂散行会以普通文本追加在条目列表之后（不丢数据）；
/// - 点击标题栏「编辑」或双击进入原始文本编辑模式。
class MemorySummaryEditor extends StatefulWidget {
  final TextEditingController controller;
  final String? hintText;
  final bool readOnly;

  /// 编辑模式下文本变化时实时回调（用于侧边栏自动保存）。
  final ValueChanged<String>? onChanged;

  /// 点击「完成」时回调（立即保存，不经过防抖）。
  final ValueChanged<String>? onSave;

  const MemorySummaryEditor({
    super.key,
    required this.controller,
    this.hintText,
    this.readOnly = false,
    this.onChanged,
    this.onSave,
  });

  @override
  State<MemorySummaryEditor> createState() => _MemorySummaryEditorState();
}

class _MemorySummaryEditorState extends State<MemorySummaryEditor> {
  bool _editMode = false;
  late final TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.controller.text);
    widget.controller.addListener(_syncFromExternal);
    _editController.addListener(_onEditChanged);
  }

  void _syncFromExternal() {
    if (!_editMode && _editController.text != widget.controller.text) {
      _editController.text = widget.controller.text;
    }
  }

  void _onEditChanged() {
    if (_editMode) {
      widget.onChanged?.call(_editController.text);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromExternal);
    _editController.removeListener(_onEditChanged);
    _editController.dispose();
    super.dispose();
  }

  void _enterEdit() {
    if (widget.readOnly) return;
    setState(() {
      _editMode = true;
      _editController.text = widget.controller.text;
    });
  }

  void _exitEdit({required bool save}) {
    // 先退出编辑模式，再同步文本：避免回写/还原时触发 onChanged 造成多余的自动保存。
    _editMode = false;
    if (save) {
      widget.controller.text = _editController.text;
      widget.onSave?.call(_editController.text);
    } else {
      _editController.text = widget.controller.text;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(theme),
          const Divider(height: 1),
          if (_editMode) _buildEdit(theme) else _buildView(theme),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 0),
      child: Row(
        children: [
          Icon(
            _editMode ? Icons.edit_note : Icons.history,
            size: 14,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _editMode ? '原始文本编辑' : '记忆列表 · 每条绑定轮数/日期/概括',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
            ),
          ),
          if (!widget.readOnly)
            TextButton.icon(
              onPressed: _editMode ? () => _exitEdit(save: true) : _enterEdit,
              icon: Icon(
                _editMode ? Icons.check : Icons.edit_outlined,
                size: 14,
              ),
              label: Text(_editMode ? '完成' : '编辑'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEdit(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: TextField(
        controller: _editController,
        maxLines: null,
        minLines: 5,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.4,
        ),
        decoration: InputDecoration(
          hintText:
              widget.hintText ?? '格式：- 第N轮｜日期：xxx｜概括内容（一行一条）',
          isDense: true,
          border: InputBorder.none,
        ),
      ),
    );
  }

  Widget _buildView(ThemeData theme) {
    final text = widget.controller.text;
    if (text.trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Text(
          '（空）',
          style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
        ),
      );
    }

    // 逐行解析：命中条目格式的进入卡片，未命中的非空行追加为兜底文本。
    final entries = <MemoryEntry>[];
    final unmatched = <String>[];
    for (final line in text.split('\n')) {
      final m = _memoryEntryRegex.firstMatch(line.trim());
      if (m != null) {
        entries.add(
          MemoryEntry(
            round: int.tryParse(m.group(1) ?? '') ?? 0,
            date: (m.group(2) ?? '').trim(),
            content: (m.group(3) ?? '').trim(),
          ),
        );
      } else if (line.trim().isNotEmpty) {
        unmatched.add(line);
      }
    }

    // 完全非结构化文本：原样展示，保证内容不丢。
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Text(
          text,
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            _entryCard(theme, entries[i]),
            if (i < entries.length - 1) const SizedBox(height: 8),
          ],
          if (unmatched.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              unmatched.join('\n'),
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _entryCard(ThemeData theme, MemoryEntry e) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 轮数徽标
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              '第${e.round}轮',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 日期 + 概括内容
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.schedule,
                      size: 12,
                      color: NarrChatTheme.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        e.date.isEmpty ? '（未标注日期）' : e.date,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: NarrChatTheme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  e.content,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: theme.colorScheme.onSurface,
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
