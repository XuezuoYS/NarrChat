import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'editable_field_state.dart';

/// Markdown 文档树节点。
class MarkdownNode {
  final int level;
  final String heading;
  final List<String> contentLines;
  final List<MarkdownNode> children;

  MarkdownNode({
    required this.level,
    required this.heading,
    List<String>? contentLines,
    List<MarkdownNode>? children,
  })  : contentLines = contentLines ?? [],
        children = children ?? [];
}

/// Markdown 层级折叠组件（用于 `character_state` 等含多级标题的纯文本）。
///
/// 特性：
/// - 自动解析 `#` / `##` / `###` 等多级标题并构建树；
/// - 默认只展示顶层分组（如“女主角”），点击标题前的箭头展开子级（如“苏清月”及其属性）；
/// - 保持纯文本编辑能力：双击进入原始文本编辑模式，编辑结果写回传入的 [controller]。
///
/// 组件与外部通过同一个 [TextEditingController] 通信，父级“保存快照”时直接读取
/// `controller.text` 即可拿到最新（含折叠树中不可直接修改但可编辑的）内容。
class MarkdownCollapsibleEditor extends StatefulWidget {
  final TextEditingController controller;
  final String? hintText;
  final bool readOnly;

  /// 是否显示视图模式工具栏中的说明文字与「编辑」按钮。
  /// 为 false 时仅保留「一键展开/全部折叠」控件，
  /// 「编辑/保存」由外部（如侧边栏模块标题栏）通过 [EditableFieldState] 驱动。
  final bool showToolbar;

  /// 编辑模式下文本变化时实时回调（用于侧边栏自动保存）。
  final ValueChanged<String>? onChanged;

  /// 点击「完成」时回调（立即保存，不经过防抖）。
  final ValueChanged<String>? onSave;

  const MarkdownCollapsibleEditor({
    super.key,
    required this.controller,
    this.hintText,
    this.readOnly = false,
    this.showToolbar = true,
    this.onChanged,
    this.onSave,
  });

  @override
  State<MarkdownCollapsibleEditor> createState() =>
      MarkdownCollapsibleEditorState();
}

class MarkdownCollapsibleEditorState extends State<MarkdownCollapsibleEditor>
    implements EditableFieldState {
  bool _editMode = false;
  late final TextEditingController _editController;

  // 一键展开 / 全部折叠控制。
  bool _allExpanded = true;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.controller.text);
    // 外部（父级）修改 controller 时同步到编辑框（仅非编辑模式下）。
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
    // 先同步文本（此时 _editMode 仍为 false，不会触发多余的 onChanged），
    // 再进入编辑模式，避免进入编辑时触发一次无意义的防抖自动保存。
    _editController.text = widget.controller.text;
    setState(() {
      _editMode = true;
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

  /// 一键展开 / 全部折叠所有人物卡片。
  ///
  /// 卡片 State 保持不变（不强制重建），由各卡片的 didUpdateWidget
  /// 根据新的 [MarkdownCollapsibleEditor] 初始展开状态平滑动画过渡，
  /// 避免内容高度骤变导致侧栏滚动位置被瞬间钳制而“瞬移”。
  void _setAllExpanded(bool expand) {
    setState(() => _allExpanded = expand);
  }

  // —— EditableFieldState（供侧边栏模块标题栏驱动） ——
  @override
  bool get isEditing => _editMode;

  @override
  void enterEdit() => _enterEdit();

  @override
  void save() => _exitEdit(save: true);

  /// 是否处于「一键展开 / 全部折叠」中的展开态。
  bool get allExpanded => _allExpanded;

  /// 一键展开 / 全部折叠所有人物卡片（供外部驱动）。
  void setAllExpanded(bool expand) => _setAllExpanded(expand);

  @override
  Widget build(BuildContext context) {
    return _editMode ? _buildEditMode(context) : _buildViewMode(context);
  }

  // ---------------------------------------------------------------------------
  // 编辑模式
  // ---------------------------------------------------------------------------
  Widget _buildEditMode(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.primary),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.edit_note,
                  size: 16,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '原始文本编辑',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _exitEdit(save: false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => _exitEdit(save: true),
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: TextField(
              controller: _editController,
              maxLines: null,
              minLines: 6,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.4,
              ),
              decoration: InputDecoration(
                hintText: widget.hintText ?? '输入 Markdown 文本…',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 视图模式（按人物折叠）
  // ---------------------------------------------------------------------------
  Widget _buildViewMode(BuildContext context) {
    final raw = widget.controller.text;
    final roots = _buildTree(raw);
    final displayRoots = _pickDisplayRoots(roots);
    // 人物层级 = 最深的标题层级（每个人物是一个折叠卡片）。
    final personLevel = _maxLevel(displayRoots);

    return GestureDetector(
      onDoubleTap: widget.readOnly ? null : _enterEdit,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  if (widget.showToolbar) ...[
                    Icon(
                      Icons.account_tree_outlined,
                      size: 14,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '按人物折叠 · 双击进入原始文本编辑',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                    if (!widget.readOnly)
                      TextButton.icon(
                        onPressed: _enterEdit,
                        icon: const Icon(Icons.edit_outlined, size: 14),
                        label: const Text('编辑'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                  if (!widget.showToolbar) const Spacer(),
                  // 一键展开 / 全部折叠
                  TextButton.icon(
                    onPressed: widget.readOnly
                        ? null
                        : () => _setAllExpanded(!_allExpanded),
                    icon: Icon(
                      _allExpanded ? Icons.unfold_less : Icons.unfold_more,
                      size: 14,
                    ),
                    label: Text(_allExpanded ? '全部折叠' : '一键展开'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            if (displayRoots.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '（暂无内容）',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                    fontSize: 12,
                  ),
                ),
              )
            else
              ...displayRoots.asMap().entries.map(
                    (e) => _buildPersonNode(
                      context,
                      e.value,
                      personLevel,
                      'root${e.key}',
                    ),
                  ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  /// 计算树中最大的标题层级（即“人物层级”）。
  int _maxLevel(List<MarkdownNode> nodes) {
    var max = 1;
    void walk(MarkdownNode n) {
      if (n.level > max) max = n.level;
      for (final c in n.children) {
        walk(c);
      }
    }

    for (final n in nodes) {
      walk(n);
    }
    return max;
  }

  /// 递归渲染：
  /// - 层级达到“人物层级”的节点 → 可折叠的人物卡片（默认展开显示内容）；
  /// - 层级更浅的节点 → 分组标题（始终展开）+ 其子级。
  ///
  /// [path] 为卡片在树中的稳定路径（如 `root0.c1`），用于生成唯一 key，
  /// 保证同一张卡片跨重建保持 State（展开状态与动画不丢失）。
  Widget _buildPersonNode(
    BuildContext context,
    MarkdownNode node,
    int personLevel,
    String path,
  ) {
    if (node.level >= personLevel) {
      return _PersonCard(
        key: ValueKey('person_$path'),
        node: node,
        initiallyExpanded: _allExpanded,
      );
    }
    // 分组标题（如“女主角”），始终显示。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _GroupHeader(heading: node.heading),
        ..._groupParagraphs(node.contentLines).map(
          (paragraph) => Padding(
            padding: const EdgeInsets.only(left: 12, right: 8, bottom: 4),
            child: MarkdownBody(
              data: paragraph.join('\n'),
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                p: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
          ),
        ),
        ...node.children.asMap().entries.map(
          (e) => Padding(
            padding: const EdgeInsets.only(left: 4),
            child: _buildPersonNode(
              context,
              e.value,
              personLevel,
              '$path.c${e.key}',
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 树构建与展示根级选择
  // ---------------------------------------------------------------------------

  /// 解析原始文本为标题树；标题前的杂散内容被忽略。
  List<MarkdownNode> _buildTree(String raw) {
    final roots = <MarkdownNode>[];
    final stack = <MarkdownNode>[];

    for (final line in raw.split('\n')) {
      final heading = _parseHeading(line);
      if (heading != null) {
        final node = MarkdownNode(level: heading.$1, heading: heading.$2);
        while (stack.isNotEmpty && stack.last.level >= node.level) {
          stack.removeLast();
        }
        if (stack.isEmpty) {
          roots.add(node);
        } else {
          stack.last.children.add(node);
        }
        stack.add(node);
      } else {
        if (stack.isNotEmpty) {
          stack.last.contentLines.add(line);
        }
      }
    }
    return roots;
  }

  /// 选择用于折叠展示的根级节点。
  ///
  /// 规则：
  /// - 若文本最外层只有一个一级标题（如 `# 角色状态`）且其下还有更深层级，
  ///   则视其为包装层，将其子级（如 `## 女主角`）作为展示根级；
  /// - 否则使用最小层级作为展示根级。
  List<MarkdownNode> _pickDisplayRoots(List<MarkdownNode> roots) {
    if (roots.length != 1) return roots;
    final only = roots.first;
    if (only.level == 1 && _hasDeeper(only)) {
      return only.children.isNotEmpty ? only.children : roots;
    }
    return roots;
  }

  bool _hasDeeper(MarkdownNode node) {
    if (node.children.isNotEmpty) return true;
    for (final c in node.children) {
      if (_hasDeeper(c)) return true;
    }
    return false;
  }

  /// 解析一行是否为标题，返回 (层级, 标题文本)；非标题返回 null。
  static (int, String)? _parseHeading(String line) {
    final trimmed = line.trimLeft();
    final match = RegExp(r'^(#{1,6})\s*(.+)$').firstMatch(trimmed);
    if (match == null) return null;
    final hashes = match.group(1)!;
    final text = match.group(2)!.trim();
    if (text.isEmpty) return null;
    return (hashes.length, text);
  }
}

/// 分组标题（如“女主角”），始终展开显示。
class _GroupHeader extends StatelessWidget {
  final String heading;

  const _GroupHeader({required this.heading});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
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
          Expanded(
            child: Text(
              heading,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 人物卡片：每个人物是一个可折叠卡片，默认收起，点击展开属性内容。
///
/// 展开/收起通过 [SizeTransition] 平滑过渡：内容高度渐变，侧栏 ListView 的
/// 滚动位置随之逐帧平滑跟随，避免“一键展开/全部折叠”时内容高度骤变导致
/// 滚动偏移被瞬间钳制而“瞬移”。
class _PersonCard extends StatefulWidget {
  final MarkdownNode node;
  final bool initiallyExpanded;

  const _PersonCard({
    super.key,
    required this.node,
    this.initiallyExpanded = false,
  });

  @override
  State<_PersonCard> createState() => _PersonCardState();
}

class _PersonCardState extends State<_PersonCard>
    with SingleTickerProviderStateMixin {
  late bool _expanded = widget.initiallyExpanded;

  /// 展开/收起动画控制器（0=收起，1=展开）。
  late final AnimationController _expandController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.initiallyExpanded ? 1.0 : 0.0,
  );
  late final Animation<double> _sizeFactor = CurvedAnimation(
    parent: _expandController,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    // 动画结束时触发重建：完全收起后把展开内容从树中卸载，
    // 避免高度已为 0 的内容仍残留在树中（占用布局、干扰查询）。
    _expandController.addStatusListener(_onExpandStatusChanged);
  }

  void _onExpandStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed ||
        status == AnimationStatus.completed) {
      if (mounted) setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _PersonCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅当“一键展开/全部折叠”改变初始状态时，将本卡片动画过渡到新状态；
    // 普通重建（如流式更新导致 node 实例变化）不重置用户手动展开/收起状态。
    if (oldWidget.initiallyExpanded != widget.initiallyExpanded &&
        _expanded != widget.initiallyExpanded) {
      _expanded = widget.initiallyExpanded;
      if (widget.initiallyExpanded) {
        _expandController.forward();
      } else {
        _expandController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _expandController.removeStatusListener(_onExpandStatusChanged);
    _expandController.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _expandController.forward();
      } else {
        _expandController.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = widget.node;
    final hasContent =
        node.contentLines.any((l) => l.trim().isNotEmpty) || node.children.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _expanded
                ? theme.colorScheme.primary.withValues(alpha: 0.5)
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: hasContent ? _toggle : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      !hasContent
                          ? Icons.person_outline
                          : (_expanded ? Icons.expand_more : Icons.chevron_right),
                      size: 18,
                      color: hasContent
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        node.heading,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // SizeTransition 平滑过渡展开内容高度；完全收起后卸载内容以节省布局。
            SizeTransition(
              sizeFactor: _sizeFactor,
              alignment: Alignment.topCenter, // 从顶部向下展开
              child: (_expanded || _expandController.isAnimating)
                  ? _buildExpandedContent(theme, node)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  /// 展开后的内容区（分隔线 + 属性/子级）。
  Widget _buildExpandedContent(ThemeData theme, MarkdownNode node) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._groupParagraphs(node.contentLines).map(
                (paragraph) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: MarkdownBody(
                    data: paragraph.join('\n'),
                    styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                      p: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                ),
              ),
              ...node.children.map(
                (child) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${'#' * child.level} ${child.heading}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

}

/// 将内容行按空行分组为段落（保持列表、段落等 Markdown 结构）。
///
/// [MarkdownCollapsibleEditorState] 与 [_PersonCardState] 共用，避免重复定义。
List<List<String>> _groupParagraphs(List<String> lines) {
  final result = <List<String>>[];
  var current = <String>[];
  for (final line in lines) {
    if (line.trim().isEmpty) {
      if (current.isNotEmpty) {
        result.add(current);
        current = [];
      }
    } else {
      current.add(line);
    }
  }
  if (current.isNotEmpty) result.add(current);
  return result;
}
