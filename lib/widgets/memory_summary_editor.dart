import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../utils/focus_utils.dart';
import '../utils/memory_entry_format.dart';
import 'app_menu.dart';
import 'app_notice_overlay.dart';
import 'bubble_pointer_listener.dart';
import 'editable_field_state.dart';
import 'markdown_editing_controller.dart';

/// 一条记忆条目的长按 / 右键菜单动作。
enum MemoryEntryAction {
  copyTime,
  copyContent,
  jumpToEntry,
}

/// 「记忆总结」专用编辑组件。
///
/// 与 [MarkdownField] 接口一致（外部传入 [controller]、保存/退出编辑触发
/// [onSave]），但视图模式按「轮次 / 时间 / 内容」绑定为一条的条目卡片渲染
/// （而非通用 Markdown 预览）：
///
/// - 每条记忆 = 一个卡片：左侧「第N轮」徽标，下方时间 + 内容；
/// - **长按（触屏）/ 右键（桌面）条目卡片**弹出扩展菜单：
///   [kMemoryEntryCopyTimeLabel] / [kMemoryEntryCopyContentLabel] /
///   [kMemoryEntryJumpLabel]（详见 [_showEntryMenu]）；
/// - 新格式（`- 34 | {时间} | {内容}`）与旧格式
///   （`- 第N轮｜日期：xxx｜概括内容`）共用 [memoryEntryLineRegex] 解析，
///   旧数据无需迁移即可继续渲染；
/// - **合并条目**（轮次写成 `11~15` / `11-15`，半角/全角 `-` / `~` 均可）徽标显示
///   原文区间（如 `第11~15轮`），底纹与文字改用**灰阶**主题色（去强调；亮/暗
///   主题各取 `ColorScheme` 对应色，无需另行硬编码），且卡片改为两行——
///   首行「轮次 + 时间」、次行「记忆内容」整宽（与徽标左对齐）；
///   常规单轮条目保持原布局与品牌蓝徽标（左侧徽标 + 右侧「时间 / 内容」）；
/// - 时间段的标签允许省略或使用「时间：」（兼容历史数据），同样按条目卡片渲染；
/// - 未命中条目格式的杂散行会以普通文本追加在条目列表之后（不丢数据，
///   判定与 [parseMemoryEntries] 同源，见 [unmatchedMemoryLines]）；
/// - 点击标题栏「编辑」按钮进入原始文本编辑模式；
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

  /// 条目菜单「跳转至对应条目」：把该条目对应的轮次交给上层定位
  /// （合并条目一律取**起始轮**，见 `memory_entry_format.dart` 的区间归一）。
  ///
  /// [entryAt] = 触发菜单的**指针全局坐标**（右键 = 鼠标位置，长按 = 手指位置），
  /// 供上层按「同屏对齐」细化落点（菜单本身也按该坐标弹出）。
  ///
  /// 为 null 时条目卡片**不挂载长按 / 右键菜单**（三项都不显示）：没有跳转
  /// 落点的一方不必伪装可跳转。本组件当前只有侧栏一个使用方
  /// （见 `SidebarPanel.onJumpToRound`），已接线。
  final void Function(int roundIndex, Offset entryAt)? onJumpToRound;

  const MemorySummaryEditor({
    super.key,
    required this.controller,
    this.hintText,
    this.readOnly = false,
    this.showToolbar = true,
    this.onSave,
    this.onEditingChanged,
    this.onJumpToRound,
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
            _buildEntry(theme, entries[i]),
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

  /// 记忆条目卡片外框（底色 + 细边框；单轮与合并条目共用）。
  ///
  /// 交互（长按 / 右键）由 [_entryCardShell] 单独包裹，本方法只管外观。
  Widget _card(ThemeData theme, Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: child,
    );
  }

  /// 记忆条目卡片的交互外壳：长按（触屏）/ 右键（桌面）都走
  /// [BubblePointerListener]（与气泡同一套手势口径：右键立即触发、触屏长按
  /// 500ms、滑动超过 18px（`kTouchSlop` 同量级）取消），并包一层 [InkWell]
  /// 提供悬停 / 按压反馈。
  ///
  /// 菜单锚点用 [BubblePointerListener] 回调给的**指针全局坐标**：桌面右键因此
  /// 在鼠标处弹出（符合右键菜单的一贯预期），触屏在手指处弹出。
  /// 长按与右键**不走** `InkWell.onLongPress`——那样只能拿到卡片原点，
  /// 无法跟随指针，且会与 [BubblePointerListener] 的长按判定重复触发。
  Widget _entryCardShell(
    Widget card, {
    required void Function(Offset globalPosition) onContextMenu,
  }) {
    const radius = BorderRadius.all(Radius.circular(8));
    return BubblePointerListener(
      onContextMenu: onContextMenu,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: () {}, // 空实现：仅借 InkWell 提供悬停 / 按压反馈。
          borderRadius: radius,
          child: card,
        ),
      ),
    );
  }

  /// 条目卡片：卡片内容 + 外框；[MemorySummaryEditor.onJumpToRound] 非空
  /// （即本卡片确有跳转目标）时再包一层「长按 / 右键菜单」。
  Widget _buildEntry(ThemeData theme, MemoryEntry e) {
    final content = _entryContent(theme, e);
    if (widget.onJumpToRound == null) return _card(theme, content);
    return _entryCardShell(
      _card(theme, content),
      onContextMenu: (globalPosition) => _showEntryMenu(e, globalPosition),
    );
  }

  /// 条目扩展菜单：复制时间 / 复制内容 / 跳转至对应条目。
  ///
  /// 合并条目的时间与轮次口径（与卡片展示一致）：
  /// - 「复制时间」复制条目时间段的原文（合并条目的时间本就是区间文本）；
  /// - 「跳转至对应条目」传 [MemoryEntry.round]（区间**小端** = 起始轮）；
  /// - [menuAt] 既作菜单弹出位置，也原样交给上层作跳转锚点。
  Future<void> _showEntryMenu(MemoryEntry e, Offset menuAt) async {
    if (!mounted) return;
    final action = await showAppMenu<MemoryEntryAction>(
      context: context,
      position: menuAt,
      items: const [
        PopupMenuItem(
          value: MemoryEntryAction.copyTime,
          child: AppMenuAction(
            icon: Icons.schedule,
            label: kMemoryEntryCopyTimeLabel,
          ),
        ),
        PopupMenuItem(
          value: MemoryEntryAction.copyContent,
          child: AppMenuAction(
            icon: Icons.copy_outlined,
            label: kMemoryEntryCopyContentLabel,
          ),
        ),
        PopupMenuItem(
          value: MemoryEntryAction.jumpToEntry,
          child: AppMenuAction(
            icon: Icons.my_location,
            label: kMemoryEntryJumpLabel,
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case MemoryEntryAction.copyTime:
        await _copy(memoryEntryTimeText(e));
      case MemoryEntryAction.copyContent:
        await _copy(e.content);
      case MemoryEntryAction.jumpToEntry:
        widget.onJumpToRound?.call(e.round, menuAt);
    }
  }

  /// 复制文本到系统剪贴板，并给出应用内提示（与气泡「复制」同一口径）。
  ///
  /// 通知中心在 `await` **之前**取出（见 `app_notice_overlay.dart` 的约定）：
  /// 剪贴板写入期间组件可能被卸载，届时不再触碰 context。
  Future<void> _copy(String text) async {
    final notices = context.notices;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    notices.success('已复制', dwell: const Duration(seconds: 1));
  }

  /// 轮次徽标（合并区间保留原文分隔符，如 `第11~15轮`）。
  ///
  /// 合并条目（`11~15`）用灰阶去强调：底纹 / 文字都取当前主题的 ColorScheme 灰阶
  /// （亮色 surfaceContainerHighest + onSurfaceVariant，深色自动随之切换），
  /// 与常规单轮条目的品牌蓝徽标形成区分。
  Widget _roundBadge(ThemeData theme, MemoryEntry e) {
    final merged = e.isMerged;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: merged
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        '第${e.roundLabel}轮',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: merged
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.primary,
        ),
      ),
    );
  }

  /// 时间行（时钟图标 + 时间文本）；缺失时显示「（未标注时间）」。
  Widget _timeRow(MemoryEntry e) {
    return Row(
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
    );
  }

  Widget _contentText(ThemeData theme, MemoryEntry e) {
    return Text(
      e.content,
      style: TextStyle(
        fontSize: 13,
        height: 1.5,
        color: theme.colorScheme.onSurface,
      ),
    );
  }

  /// 条目卡片：**卡片内容**（不含外框）——外观与交互由 [_card] / [_entryCardShell]
  /// 在 [_buildEntry] 里包上。
  Widget _entryContent(ThemeData theme, MemoryEntry e) {
    final badge = _roundBadge(theme, e);
    final time = _timeRow(e);
    final content = _contentText(theme, e);

    // 合并条目（覆盖多轮、内容通常更长）改两行：首行「轮次 + 时间」（时间紧接
    // 徽标同一行），次行「记忆内容」整宽（与徽标左对齐）；
    if (e.isMerged) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              badge,
              const SizedBox(width: 8),
              Expanded(child: time),
            ],
          ),
          const SizedBox(height: 6),
          content,
        ],
      );
    }

    // 单轮条目保持原布局：左侧徽标，右侧「时间 + 内容」。
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        badge,
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              time,
              const SizedBox(height: 4),
              content,
            ],
          ),
        ),
      ],
    );
  }
}
