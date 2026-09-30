import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/focus_utils.dart';
import '../utils/memory_entry_format.dart';
import 'editable_field_state.dart';
import 'markdown_editing_controller.dart';

/// 「记忆总结」专用编辑组件。
///
/// 与 [MarkdownField] 接口一致（外部传入 [controller]、保存/退出编辑触发
/// [onSave]），但视图模式按「轮次 / 时间 / 内容」绑定为一条的条目卡片渲染
/// （而非通用 Markdown 预览）：
///
/// - 每条记忆 = 一个卡片：左侧「第N轮」徽标，下方时间 + 内容；
/// - 新格式（`- 34 | {时间} | {内容}`）与旧格式
///   （`- 第N轮｜日期：xxx｜概括内容`）共用 [memoryEntryLineRegex] 解析，
///   旧数据无需迁移即可继续渲染；
/// - **合并条目**（轮次写成 `11~15` / `11-15`，半角/全角 `-` / `~` 均可）徽标显示
///   原文区间（如 `第11~15轮`），底纹与文字改用**灰阶**主题色（去强调；亮/暗
///   主题各取 `ColorScheme` 对应色，无需另行硬编码）；常规单轮条目仍是品牌蓝徽标；
/// - 时间段的标签允许省略或使用「时间：」（兼容历史数据），同样按条目卡片渲染；
/// - 未命中条目格式的杂散行会以普通文本追加在条目列表之后（不丢数据，
///   判定与 [parseMemoryEntries] 同源，见 [unmatchedMemoryLines]）；
/// - 点击标题栏「编辑」或双击进入原始文本编辑模式；
/// - 不自动保存：仅保存/退出编辑触发 [onSave]，取消编辑丢弃修改。
class MemorySummaryEditor extends StatefulWidget {
  final TextEditingController controller;
  final String? hintText;
  final bool readOnly;

  /// 是否显示内部工具栏（含「编辑/完成」按钮）。
  final bool showToolbar;

  /// 保存 / 退出编辑时回调（持久化）。
  final ValueChanged<String>? onSave;

  /// 进入 / 退出编辑模式时回调（供外部标题栏切换【保存】/【取消】按钮）。
  final ValueChanged<bool>? onEditingChanged;

  const MemorySummaryEditor({
    super.key,
    required this.controller,
    this.hintText,
    this.readOnly = false,
    this.showToolbar = true,
    this.onSave,
    this.onEditingChanged,
  });

  @override
  State<MemorySummaryEditor> createState() => MemorySummaryEditorState();
}

class MemorySummaryEditorState extends State<MemorySummaryEditor>
    implements EditableFieldState {
  bool _editMode = false;
  late final MarkdownEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = MarkdownEditingController(text: widget.controller.text);
    widget.controller.addListener(_syncFromExternal);
  }

  void _syncFromExternal() {
    if (!_editMode && _editController.text != widget.controller.text) {
      _editController.text = widget.controller.text;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromExternal);
    _editController.dispose();
    super.dispose();
  }

  void _enterEdit() {
    if (widget.readOnly) return;
    // 先同步文本（此时 _editMode 仍为 false，编辑控制器仅跟随外部控制器），
    // 再进入编辑模式，保证编辑框打开即为当前已保存内容。
    _editController.text = widget.controller.text;
    setState(() {
      _editMode = true;
    });
    widget.onEditingChanged?.call(true);
  }

  void _exitEdit({required bool save}) {
    _editMode = false;
    if (save) {
      widget.controller.text = _editController.text;
      widget.onSave?.call(_editController.text);
    } else {
      _editController.text = widget.controller.text;
    }
    widget.onEditingChanged?.call(false);
    setState(() {});
  }

  // —— EditableFieldState（供侧边栏模块标题栏驱动） ——
  @override
  bool get isEditing => _editMode;

  @override
  void enterEdit() => _enterEdit();

  @override
  void save() => _exitEdit(save: true);

  @override
  void cancel() => _exitEdit(save: false);

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
          if (widget.showToolbar) ...[_buildHeader(theme), const Divider(height: 1)],
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
              _editMode ? '原始文本编辑' : '记忆列表 · 每条绑定轮次/时间/内容',
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
        onTapOutside: unfocusOnTapOutside,
        maxLines: null,
        minLines: 5,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.4,
        ),
        decoration: InputDecoration(
          hintText: widget.hintText ?? '格式：$kMemoryEntryFormat（一行一条）',
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

    // 逐行解析：命中条目格式的进入卡片（含 `11~15` 这类合并区间），未命中的
    // 非空行追加为兜底文本（解析与兜底判定 = 共享真源，口径完全一致）。
    final entries = parseMemoryEntries(text);
    final unmatched = unmatchedMemoryLines(text);

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
    // 合并条目（`11~15`）用灰阶徽标去强调：底纹 / 文字都取当前主题的 ColorScheme
    // 灰阶（亮色 surfaceContainerHighest + onSurfaceVariant，深色自动随之切换），
    // 与常规单轮条目的品牌蓝徽标形成区分；卡片底色与边框两态一致。
    final merged = e.isMerged;
    final badgeBackground = merged
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.primary.withValues(alpha: 0.1);
    final badgeForeground =
        merged ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.primary;
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
          // 轮次徽标（合并区间保留原文分隔符，如 `第11~15轮`）
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: badgeBackground,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              '第${e.roundLabel}轮',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: badgeForeground,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 时间 + 内容
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.schedule,
                      size: 12,
                      color: context.narrColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        e.time.isEmpty ? '（未标注时间）' : e.time,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: context.narrColors.textSecondary,
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
