import 'package:flutter/material.dart';

import '../models/round.dart';
import '../theme/app_theme.dart';
import 'editable_field_state.dart';
import 'markdown_collapsible_editor.dart';
import 'markdown_field.dart';
import 'memory_summary_editor.dart';
import 'plain_text_field_editor.dart';

/// 侧边栏面板。
///
/// - 顶部 Top Bar：固定显示“当前轮次（第 N 轮）”或“历史轮次（第 X 轮）”；
///   历史轮次时背景变浅灰并带红色警告边框以作醒目区分。
/// - 内容区：将数据库存储的 `world_state`、`character_state`、`memory_summary`、
///   `current_time` 以可编辑文本形式显示；
///   `character_state` 使用 [MarkdownCollapsibleEditor] 折叠组件（含“一键展开”）。
///   （`recommended_action` 不在侧边栏编辑，展示于对话区 AI 气泡正文下方。）
/// - 可折叠子模块：每个大区块（当前时间/世界状态/角色状态/记忆总结）都有吸顶标题栏，
///   滚动到下方时标题栏固定在视口顶部；点击标题栏可折叠/展开该区块内容。
/// - 手动保存：编辑时**不自动写库**；每个子模块通过标题栏【编辑】进入编辑、
///   【保存】（或编辑模式内「完成」）退出编辑并调用 [onSaveField] 持久化，
///   【取消】放弃本次修改（还原为已保存内容）。
///   保存结果通过 ScaffoldMessenger 的 SnackBar（Flutter 默认通知渠道）提示。
///   历史轮次的修改绝不自动影响后续轮次，仅作为快照存档。
///
/// 父级通过 `ValueKey(round.id)` 切换本组件状态，切换轮次时编辑器内容自动重置。
class SidebarPanel extends StatefulWidget {
  final Round? round;
  final bool isHistoryView;
  /// 显式保存回调；返回是否保存成功（成功提示「已保存」，失败提示「保存失败」）。
  final Future<bool> Function(Round round, String field, String value) onSaveField;
  final VoidCallback onBackToCurrent;

  /// 顶栏“收起”按钮回调（为空则不显示该按钮）。
  final VoidCallback? onClose;

  const SidebarPanel({
    super.key,
    required this.round,
    required this.isHistoryView,
    required this.onSaveField,
    required this.onBackToCurrent,
    this.onClose,
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

  /// 各子模块的折叠状态（key = 字段名；默认展开）。
  final Map<String, bool> _collapsed = {};

  /// 各子模块的编辑状态（key = 字段名；标题栏据此切换【保存】/【取消】按钮）。
  final Map<String, bool> _editing = {};

  /// 各编辑器的 GlobalKey，供吸顶标题栏的【编辑】/【保存】/【取消】按钮驱动
  /// （见 [EditableFieldState]）。
  final GlobalKey _worldStateKey = GlobalKey();
  final GlobalKey _characterStateKey = GlobalKey();
  final GlobalKey _memorySummaryKey = GlobalKey();
  final GlobalKey _currentTimeKey = GlobalKey();

  @override
  void didUpdateWidget(covariant SidebarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 保险起见：若轮次 id 变化（正常情况下因 ValueKey 不会走到这里）则重置内容，
    // 并清空编辑/折叠状态，避免把旧轮次的值写回旧轮次。
    if (oldWidget.round?.id != widget.round?.id) {
      _editing.clear();
      _worldState.text = widget.round?.worldState ?? '';
      _characterState.text = widget.round?.characterState ?? '';
      _memorySummary.text = widget.round?.memorySummary ?? '';
      _currentTime.text = widget.round?.currentTime ?? '';
    }
  }

  @override
  void dispose() {
    _worldState.dispose();
    _characterState.dispose();
    _memorySummary.dispose();
    _currentTime.dispose();
    super.dispose();
  }

  /// 记录子模块编辑状态（供标题栏显示【保存】/【取消】）。
  void _onEditingChanged(String field, bool editing) {
    if (_editing[field] == editing) return;
    setState(() => _editing[field] = editing);
  }

  /// 保存并写回数据库；保存结果通过 SnackBar（Flutter 默认通知渠道）提示。
  Future<void> _saveFieldNow(String field, String value) async {
    final round = widget.round;
    if (round == null) return;
    final ok = await widget.onSaveField(round, field, value);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(ok ? '已保存' : '保存失败'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 标题栏【编辑】：若模块已折叠则先展开，再让对应编辑器进入编辑模式。
  void _enterEditModule(String collapseKey, GlobalKey editorKey) {
    setState(() => _collapsed[collapseKey] = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      (editorKey.currentState as EditableFieldState?)?.enterEdit();
    });
  }

  /// 标题栏【保存】：让对应编辑器立即保存（退出编辑模式并触发 onSave）。
  void _saveModule(GlobalKey editorKey) {
    (editorKey.currentState as EditableFieldState?)?.save();
  }

  /// 标题栏【取消】：让对应编辑器放弃本次修改（退出编辑模式，不触发 onSave）。
  void _cancelModule(GlobalKey editorKey) {
    (editorKey.currentState as EditableFieldState?)?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final round = widget.round;
    final history = widget.isHistoryView;

    return Container(
      decoration: BoxDecoration(
        color: history
            ? context.narrColors.historyBackground
            : context.narrColors.surface,
        border: history
            ? Border.all(color: theme.colorScheme.error.withValues(alpha: 0.5))
            : Border.all(color: context.narrColors.divider),
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
                // 原生滚动条（主题已统一为常显细圆角拇指），内容长度/滚动自动跟随。
                // 每个大子模块用 _buildSection 包裹（SliverMainAxisGroup 分组）：
                // 组内标题栏吸顶，但会被钳制在本组范围，滚动时前一个标题栏
                // 随组滚出视口、不叠层，一次只有一个标题栏固定在顶部。
                : CustomScrollView(
                    slivers: [
                      _buildSection(
                        key: RoundField.currentTime,
                        label: '当前时间',
                        onEdit: () =>
                            _enterEditModule(RoundField.currentTime, _currentTimeKey),
                        onSave: () => _saveModule(_currentTimeKey),
                        onCancel: () => _cancelModule(_currentTimeKey),
                        body: PlainTextFieldEditor(
                          key: _currentTimeKey,
                          controller: _currentTime,
                          hintText: '当前时间',
                          onSave: (v) => _saveFieldNow(RoundField.currentTime, v),
                          onEditingChanged: (e) =>
                              _onEditingChanged(RoundField.currentTime, e),
                        ),
                      ),
                      _buildSection(
                        key: RoundField.worldState,
                        label: '世界状态',
                        onEdit: () => _enterEditModule(RoundField.worldState, _worldStateKey),
                        onSave: () => _saveModule(_worldStateKey),
                        onCancel: () => _cancelModule(_worldStateKey),
                        body: MarkdownField(
                          key: _worldStateKey,
                          controller: _worldState,
                          hintText: '世界状态',
                          showToolbar: false,
                          onSave: (v) => _saveFieldNow(RoundField.worldState, v),
                          onEditingChanged: (e) =>
                              _onEditingChanged(RoundField.worldState, e),
                        ),
                      ),
                      _buildSection(
                        key: RoundField.characterState,
                        label: '角色状态',
                        onEdit: () => _enterEditModule(RoundField.characterState, _characterStateKey),
                        onSave: () => _saveModule(_characterStateKey),
                        onCancel: () => _cancelModule(_characterStateKey),
                        body: MarkdownCollapsibleEditor(
                          key: _characterStateKey,
                          controller: _characterState,
                          hintText: '如：\n# 主角\n## 陆尘\n- 姓名：…',
                          showToolbar: false,
                          onSave: (v) => _saveFieldNow(RoundField.characterState, v),
                          onEditingChanged: (e) =>
                              _onEditingChanged(RoundField.characterState, e),
                        ),
                      ),
                      _buildSection(
                        key: RoundField.memorySummary,
                        label: '记忆总结',
                        subtitle: '每条一行：- 第N轮｜日期：xxx｜概括内容',
                        onEdit: () => _enterEditModule(RoundField.memorySummary, _memorySummaryKey),
                        onSave: () => _saveModule(_memorySummaryKey),
                        onCancel: () => _cancelModule(_memorySummaryKey),
                        body: MemorySummaryEditor(
                          key: _memorySummaryKey,
                          controller: _memorySummary,
                          hintText: '记忆总结',
                          showToolbar: false,
                          onSave: (v) => _saveFieldNow(RoundField.memorySummary, v),
                          onEditingChanged: (e) =>
                              _onEditingChanged(RoundField.memorySummary, e),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 12)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(ThemeData theme, bool history) {
    final round = widget.round;
    return Container(
      decoration: BoxDecoration(
        color: history
            ? context.narrColors.historyHeader
            : context.narrColors.surface,
        border: Border(
          bottom: BorderSide(color: context.narrColors.divider),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(
            history ? Icons.history : Icons.radio_button_checked,
            size: 17,
            color: history
                ? theme.colorScheme.error
                : NarrChatTheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              history
                  ? '历史轮次（第 ${round?.roundIndex ?? '?'} 轮）'
                  : '当前轮次（第 ${round?.roundIndex ?? 0} 轮）',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: history
                    ? theme.colorScheme.error
                    : context.narrColors.textPrimary,
              ),
            ),
          ),
          if (history)
            TextButton(
              onPressed: widget.onBackToCurrent,
              child: const Text('回到当前'),
            ),
          if (widget.onClose != null)
            IconButton(
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, size: 18),
              tooltip: '收起侧边栏',
              visualDensity: VisualDensity.compact,
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

  /// 构建一个「可折叠 + 吸顶标题栏」的子模块。
  ///
  /// 每个子模块用 [SliverMainAxisGroup] 分组：组内的吸顶标题栏会被钳制在
  /// 本组范围内，滚动到下一个模块时，前一个标题栏随本组滚出视口（不会
  /// 叠层堆积），一次只有当前模块的标题栏固定在顶部。
  /// [onEdit]/[onSave]/[onCancel] 提供给标题栏右侧的【编辑】/【保存】/【取消】按钮，
  /// 作用于当前模块；未编辑时仅显示【编辑】，编辑中显示【保存】/【取消】。
  Widget _buildSection({
    required String key,
    required String label,
    required Widget body,
    String? subtitle,
    VoidCallback? onEdit,
    VoidCallback? onSave,
    VoidCallback? onCancel,
  }) {
    final collapsed = _collapsed[key] ?? false;
    final editing = _editing[key] ?? false;
    return SliverMainAxisGroup(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _SidebarSectionHeaderDelegate(
            label: label,
            subtitle: subtitle,
            collapsed: collapsed,
            editing: editing,
            backgroundColor: widget.isHistoryView
                ? context.narrColors.historyBackground
                : context.narrColors.surface,
            onToggle: () => setState(() => _collapsed[key] = !collapsed),
            onEdit: onEdit,
            onSave: onSave,
            onCancel: onCancel,
          ),
        ),
        if (!collapsed)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: body,
            ),
          ),
      ],
    );
  }
}

/// 侧边栏子模块的吸顶标题栏（[SliverPersistentHeader] 的 delegate）。
///
/// - 固定高度，滚动时吸顶（pinned: true），内容从标题栏下方滚过；
/// - 整个标题栏可点击：切换该子模块的折叠/展开，箭头随状态旋转；
/// - 右侧提供当前模块的【编辑】/【保存】/【取消】按钮
///   （[onEdit]/[onSave]/[onCancel] 非空时显示；未编辑时仅显示【编辑】，
///   编辑中显示【保存】/【取消】，折叠时隐藏【保存】/【取消】）；
/// - 吸顶时显示底部分割线与轻微阴影，与下方内容区分。
class _SidebarSectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  final String? subtitle;
  final bool collapsed;
  final bool editing;
  final Color backgroundColor;
  final VoidCallback onToggle;
  final VoidCallback? onEdit;
  final VoidCallback? onSave;
  final VoidCallback? onCancel;

  _SidebarSectionHeaderDelegate({
    required this.label,
    required this.collapsed,
    required this.editing,
    required this.backgroundColor,
    required this.onToggle,
    this.subtitle,
    this.onEdit,
    this.onSave,
    this.onCancel,
  });

  static const double _height = 42;

  /// 标题栏紧凑操作按钮的统一样式（【编辑】/【保存】/【取消】共用）。
  ///
  /// 三个按钮的几何尺寸完全一致（仅「保存」额外保留 FilledButton 的填充底纹），
  /// 避免出现「保存底纹比取消悬停底纹小」的视觉不一致。
  static final ButtonStyle _compactActionStyle = TextButton.styleFrom(
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
  );

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final pinned = overlapsContent || shrinkOffset > 0;
    // 局部变量以获得类型提升（公开字段无法提升为 String）。
    final sub = subtitle;
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border(
          bottom: BorderSide(
            color: pinned ? context.narrColors.divider : Colors.transparent,
          ),
        ),
        boxShadow: pinned
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              // 折叠/展开箭头（随状态旋转）
              AnimatedRotation(
                turns: collapsed ? 0 : 0.25,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: const Icon(Icons.chevron_right, size: 18),
              ),
              const SizedBox(width: 6),
              // 彩色竖条
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              // 标题 + 副标题
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    if (sub != null)
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                  ],
                ),
              ),
              // 折叠状态提示
              if (collapsed)
                Text(
                  '已折叠',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.outline,
                  ),
                ),
              // 当前模块的【编辑】/【保存】/【取消】按钮：
              // 未编辑时仅显示【编辑】；编辑中显示【取消】/【保存】（折叠时隐藏）。
              // 三者均为同款紧凑 TextButton，尺寸与悬停底纹一致。
              if (onEdit != null && !editing)
                TextButton(
                  onPressed: onEdit,
                  style: _compactActionStyle,
                  child: const Text('编辑'),
                ),
              if (editing && !collapsed) ...[
                if (onCancel != null)
                  TextButton(
                    onPressed: onCancel,
                    style: _compactActionStyle,
                    child: const Text('取消'),
                  ),
                // 主操作「保存」：与「编辑/取消」同尺寸，但带填充底纹以便区分。
                if (onSave != null)
                  FilledButton(
                    onPressed: onSave,
                    style: _compactActionStyle,
                    child: const Text('保存'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SidebarSectionHeaderDelegate oldDelegate) {
    return oldDelegate.label != label ||
        oldDelegate.subtitle != subtitle ||
        oldDelegate.collapsed != collapsed ||
        oldDelegate.editing != editing ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.onToggle != onToggle ||
        oldDelegate.onEdit != onEdit ||
        oldDelegate.onSave != onSave ||
        oldDelegate.onCancel != onCancel;
  }
}
