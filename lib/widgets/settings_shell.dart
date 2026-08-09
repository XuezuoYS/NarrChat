import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 设置页导航项。
class SettingsNavItem {
  final IconData icon;
  final String label;

  const SettingsNavItem({required this.icon, required this.label});
}

/// 全窗口设置页通用外壳：
/// - 顶栏：品牌图标 + 标题 + 自定义操作 + 关闭按钮；
/// - 宽屏（≥760）：左侧竖向导航 + 右侧内容区；
/// - 窄屏：顶部横向标签 + 下方内容区。
class SettingsShell extends StatefulWidget {
  final String title;
  final IconData icon;
  final List<SettingsNavItem> navItems;
  final Widget Function(BuildContext context, int index) contentBuilder;
  final List<Widget>? actions;

  const SettingsShell({
    super.key,
    required this.title,
    required this.icon,
    required this.navItems,
    required this.contentBuilder,
    this.actions,
  });

  @override
  State<SettingsShell> createState() => _SettingsShellState();
}

class _SettingsShellState extends State<SettingsShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient: NarrChatTheme.brandGradient,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(widget.icon, size: 16, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Text(widget.title),
          ],
        ),
        actions: [
          ...?widget.actions,
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 220,
                  color: colors.surface,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      for (var i = 0; i < widget.navItems.length; i++)
                        _NavTile(
                          item: widget.navItems[i],
                          selected: i == _index,
                          onTap: () => setState(() => _index = i),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _buildContent(context)),
              ],
            );
          }
          // 窄屏：顶部横向标签。
          return Column(
            children: [
              Container(
                color: colors.surface,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.navItems.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        ChoiceChip(
                          selected: i == _index,
                          showCheckmark: false,
                          avatar: Icon(
                            widget.navItems[i].icon,
                            size: 16,
                            color: i == _index
                                ? NarrChatTheme.primary
                                : colors.textSecondary,
                          ),
                          label: Text(widget.navItems[i].label),
                          onSelected: (_) => setState(() => _index = i),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _buildContent(context)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return Container(
      color: context.narrColors.surface,
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: widget.contentBuilder(context, _index),
        ),
      ),
    );
  }
}

/// 左侧导航项。
class _NavTile extends StatelessWidget {
  final SettingsNavItem item;
  final bool selected;
  final VoidCallback onTap;

  const _NavTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: NarrChatTheme.primary.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        leading: Icon(
          item.icon,
          size: 20,
          color: selected ? NarrChatTheme.primary : colors.textSecondary,
        ),
        title: Text(
          item.label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? NarrChatTheme.primary : colors.textPrimary,
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}
