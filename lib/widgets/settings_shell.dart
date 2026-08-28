import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 设置页导航项。
class SettingsNavItem {
  final IconData icon;
  final String label;

  const SettingsNavItem({required this.icon, required this.label});
}

/// 全窗口设置页通用外壳：
/// - 顶栏：品牌图标 + 标题 + 自定义操作（如统一「保存」）+ 关闭按钮；
/// - 宽屏（≥760）：左侧竖向导航 + 右侧内容区；
/// - 窄屏：顶部横向标签 + 内容区 PageView（左右滑动切换子页面）。
class SettingsShell extends StatefulWidget {
  final String title;
  final IconData icon;
  final List<SettingsNavItem> navItems;
  final Widget Function(BuildContext context, int index) contentBuilder;
  final List<Widget>? actions;

  /// 初始选中的面板序号（默认 0；越界时钳制到合法范围）。
  final int initialIndex;

  const SettingsShell({
    super.key,
    required this.title,
    required this.icon,
    required this.navItems,
    required this.contentBuilder,
    this.actions,
    this.initialIndex = 0,
  });

  @override
  State<SettingsShell> createState() => _SettingsShellState();
}

class _SettingsShellState extends State<SettingsShell> {
  late int _index =
      widget.initialIndex.clamp(0, widget.navItems.length - 1);

  /// 窄屏内容区 PageView 控制器。
  ///
  /// 仅在窄屏布局期间挂载；首次进入窄屏或从宽屏切回时以当前 [_index] 重建，
  /// 避免 PageView 恢复到离开前的旧页，导致标签高亮与内容不一致。
  PageController? _pageController;

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  /// 窄屏：点击顶部标签 → 滑动到对应页（高亮立即切换，内容随动画过渡）。
  void _onNarrowNavTap(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _pageController?.animateToPage(
      i,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  /// 窄屏：内容区左右滑动（或动画）停靠后，标签高亮跟随最新页。
  void _onNarrowPageChanged(int i) {
    if (i == _index) return;
    setState(() => _index = i);
  }

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
                Expanded(child: _buildContent(context, _index)),
              ],
            );
          }
          // 窄屏：顶部横向标签 + 内容区 PageView（左右滑动切换子页面）。
          // 首次进入窄屏 / 从宽屏切回时重建控制器，保证起始页与当前选中一致。
          if (_pageController == null || !_pageController!.hasClients) {
            _pageController?.dispose();
            _pageController = PageController(initialPage: _index);
          }
          return Column(
            children: [
              Container(
                color: colors.surface,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
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
                          onSelected: (_) => _onNarrowNavTap(i),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: _onNarrowPageChanged,
                  scrollBehavior: const _NarrowPageSwipeBehavior(),
                  children: [
                    for (var i = 0; i < widget.navItems.length; i++)
                      _buildContent(context, i),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, int index) {
    // 用 Material（不透明 surface 色）承载内容区，而非 Container 的 ColoredBox，
    // 避免区内 SwitchListTile/ListTile 的墨迹与选中背景被 ColoredBox 遮挡而触发
    // 「ListTile background color or ink splashes may be invisible」断言。
    return Material(
      color: context.narrColors.surface,
      child: Align(
        alignment: Alignment.topCenter,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: widget.contentBuilder(context, index),
          ),
        ),
      ),
    );
  }
}

/// 窄屏 PageView 的滚动行为：
/// - 鼠标也可拖拽翻页（Windows 桌面上同样支持左右滑动切换子页面）；
/// - 不显示滚动条（分页切换控件，滚动条无意义）。
class _NarrowPageSwipeBehavior extends MaterialScrollBehavior {
  const _NarrowPageSwipeBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
      };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
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
      // 外层 Container 带背景色（ColoredBox）会遮挡 ListTile 的墨迹与选中高亮，
      // 需用 Material 包裹，使选中背景 / 水波纹绘制在本层之上。
      // Material 需为不透明背景色（与导航栏一致）；透明 Material 会触发
      // 「ListTile background color or ink splashes may be invisible」断言。
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(10),
        child: ListTile(
          dense: true,
          selected: selected,
          selectedTileColor: NarrChatTheme.primary.withValues(alpha: 0.12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
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
      ),
    );
  }
}
