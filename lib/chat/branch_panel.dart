import 'package:flutter/material.dart';

import '../models/branch.dart';

/// 分支面板：列出一条 IF 线里的所有分支，可切换 / 改名 / 删除。
///
/// 为什么单独一个 widget：分支是"整条链的上文"，切换它会换掉整屏内容，
/// 所以入口必须显眼但不能误触 —— 放独立面板里，点行切换、长菜单才动结构。
///
/// 默认分支（`branchUuid == ''`，显示为「主线」）不可改名、不可删除，
/// 它是这本书的地板：删掉它就没有"从哪来"的锚点了。
class BranchPanel extends StatelessWidget {
  const BranchPanel({
    super.key,
    required this.branches,
    required this.workingBranchUuid,
    required this.onSwitch,
    required this.onRename,
    required this.onDelete,
    this.onClose,
    this.width = 280,
  });

  /// 全部分支（默认分支应在其中，`isDefault` 为真）。
  final List<Branch> branches;

  /// 当前工作分支（`''` = 默认分支）。
  final String workingBranchUuid;

  final ValueChanged<String> onSwitch;

  /// 改名回调：返回 null 表示取消。
  final Future<String?> Function(Branch branch) onRename;

  /// 删除回调：已确认后才会被调用。
  final Future<void> Function(Branch branch) onDelete;

  final VoidCallback? onClose;

  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context, theme),
          const Divider(height: 1),
          Flexible(
            child: branches.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '还没有分支',
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: branches.length,
                    itemBuilder: (context, index) =>
                        _buildRow(context, theme, branches[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
      child: Row(
        children: [
          Icon(Icons.alt_route, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text('分支', style: theme.textTheme.titleSmall),
          const Spacer(),
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18),
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, ThemeData theme, Branch branch) {
    final isWorking = branch.branchUuid == workingBranchUuid;
    final subtitle = branch.isDefault
        ? '默认分支（不可删除）'
        : '从第 ${branch.fatherRowIndex} 轮分叉';
    return InkWell(
      onTap: isWorking ? null : () => onSwitch(branch.branchUuid),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Icon(
              isWorking ? Icons.check_circle : Icons.circle_outlined,
              size: 16,
              color: isWorking
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    branch.displayName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isWorking ? FontWeight.w600 : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            if (!branch.isDefault) _buildMenu(context, branch),
          ],
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context, Branch branch) {
    return PopupMenuButton<String>(
      tooltip: '分支操作',
      icon: const Icon(Icons.more_horiz, size: 18),
      onSelected: (value) async {
        if (value == 'rename') {
          // 改名对话框由调用方实现（它知道 Provider 的报错文案），这里只等结果。
          await onRename(branch);
        } else if (value == 'delete') {
          final ok = await _confirmDelete(context, branch);
          if (ok) await onDelete(branch);
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'rename', child: Text('重命名')),
        PopupMenuItem(value: 'delete', child: Text('删除分支')),
      ],
    );
  }

  Future<bool> _confirmDelete(BuildContext context, Branch branch) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除分支'),
        content: Text(
          '「${branch.displayName}」下的轮次会一起删除；由它分出来的子分支会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}
