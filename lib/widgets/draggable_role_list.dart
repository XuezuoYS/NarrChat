import 'package:flutter/material.dart';

import '../models/role_category.dart';

/// 可拖拽排序的角色类别列表。
///
/// - 每个角色类别包含「名称」与「详细描述格式」；
/// - 支持拖拽排序（长按拖动柄）、增删、编辑名称与格式；
/// - 通过 [onChanged] 将最新列表回传给父级，父级负责拼接层级字符串与 JSON 入库。
class DraggableRoleList extends StatefulWidget {
  final List<RoleCategory> initialCategories;
  final ValueChanged<List<RoleCategory>> onChanged;

  const DraggableRoleList({
    super.key,
    required this.initialCategories,
    required this.onChanged,
  });

  @override
  State<DraggableRoleList> createState() => _DraggableRoleListState();
}

class _DraggableRoleListState extends State<DraggableRoleList> {
  late final List<RoleCategory> _categories = List.of(widget.initialCategories);

  void _notify() {
    widget.onChanged(List.of(_categories));
  }

  Future<void> _openEditDialog({RoleCategory? category}) async {
    final isEdit = category != null;
    final result = await showDialog<RoleCategory>(
      context: context,
      builder: (ctx) => _RoleCategoryDialog(category: category),
    );
    if (result == null) return;
    setState(() {
      if (isEdit) {
        final index = _categories.indexWhere((c) => c.name == category.name);
        if (index >= 0) _categories[index] = result;
      } else {
        _categories.add(result);
      }
    });
    _notify();
  }

  void _remove(int index) {
    setState(() => _categories.removeAt(index));
    _notify();
  }

  void _onReorderItem(int oldIndex, int newIndex) {
    // 注意：onReorderItem 已自动修正 newIndex（向下移动时无需再减一）。
    setState(() {
      final item = _categories.removeAt(oldIndex);
      _categories.insert(newIndex, item);
    });
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '角色类别（拖动排序；编辑可为每类设定详细描述格式，AI 将按此组织角色状态）',
          style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _openEditDialog(),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('添加分类'),
          ),
        ),
        // 不设内部滚动：与所在对话框的总滚动条一致（shrinkWrap + 禁自身滚动）。
        _categories.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '暂无分类，请添加。',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
              )
            : ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorderItem: _onReorderItem,
                children: [
                    for (var i = 0; i < _categories.length; i++)
                      Container(
                        key: ValueKey('role_${i}_${_categories[i].name}'),
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: theme.colorScheme.outlineVariant),
                        ),
                        child: ListTile(
                          dense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          leading: ReorderableDragStartListener(
                            index: i,
                            child: const Icon(Icons.drag_handle),
                          ),
                          title: Text(
                            _categories[i].name,
                            style: const TextStyle(fontSize: 14),
                          ),
                          subtitle: Text(
                            _categories[i].format.isEmpty
                                ? '（未设置描述格式）'
                                : _categories[i].format,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                tooltip: '编辑名称与格式',
                                onPressed: () =>
                                    _openEditDialog(category: _categories[i]),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                tooltip: '删除',
                                onPressed: () => _remove(i),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
      ],
    );
  }
}

/// 角色类别编辑对话框（新增 / 编辑名称与描述格式）。
class _RoleCategoryDialog extends StatefulWidget {
  final RoleCategory? category;

  const _RoleCategoryDialog({this.category});

  @override
  State<_RoleCategoryDialog> createState() => _RoleCategoryDialogState();
}

class _RoleCategoryDialogState extends State<_RoleCategoryDialog> {
  late final TextEditingController _name;
  late final TextEditingController _format;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.category?.name ?? '');
    _format = TextEditingController(text: widget.category?.format ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _format.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('类别名称不能为空')),
      );
      return;
    }
    Navigator.of(context).pop(
      RoleCategory(name: name, format: _format.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.category == null ? '添加角色类别' : '编辑角色类别'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '类别名称',
                hintText: '如：女主角',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _format,
              minLines: 5,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: '详细描述格式（每行一个属性项）',
                hintText: '如：\n- 姓名：\n- 当前状态：',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '该格式将注入 System Prompt，AI 按此组织该类别角色的状态属性。',
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
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

