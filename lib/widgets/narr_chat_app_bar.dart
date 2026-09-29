import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'island_bar.dart';

/// 右侧按键宽度的保守估计（未测量前使用）：按 3 个图标按钮计。
const double _kActionsReserveFallback = 160;

/// 全应用统一顶栏（单一可复用组件）。
///
/// 结构固定为：**左侧按键（返回 / 自定义）— 标题图标 + 标题 — 右侧按键**，
/// 并在中间承接驻场岛槽位：
/// - 宽屏且宽度预算充足：岛**居中嵌在工具栏一行内**（不可见槽位居中占位，岛由
///   应用级 overlay 画在同一矩形），标题被挤压但保底 [kIslandTitleMinWidth]
///   （随全局字号缩放）的可见字数；
/// - 窄屏（< [kIslandEmbedBreakpoint]）或预算不足（< [kIslandMinWidth]）：
///   顶栏向下多出 [kIslandRowHeight] 的一行放岛，标题恢复完整宽度；
/// - 岛展开脱离后：槽位收缩为 [kIslandMarkerSize] 的小标记（标题回收空间），
///   点击标记可把岛收回顶栏。
///
/// 高度随附加行动画变化：页面用 [IslandAwareScaffold] 包裹即可逐帧生效。
class NarrChatAppBar extends StatefulWidget implements PreferredSizeWidget {
  const NarrChatAppBar({
    super.key,
    this.title,
    this.titleWidget,
    this.icon,
    this.leading,
    this.actions = const [],
    this.titleSpacing = 0,
    this.leadingWidth,
    this.showBorder = true,
    this.backgroundColor,
    this.foregroundColor,
    this.onTitleTap,
    this.islandEnabled = true,
    this.extraRowHeight = 0,
  }) : assert(
         title != null || titleWidget != null,
         '标题与自定义标题至少提供一个',
       );

  /// 文本标题（单行、自动省略号）。
  final String? title;

  /// 自定义标题（如首页品牌 Logo）；与 [title] 二选一。
  final Widget? titleWidget;

  /// 标题左侧图标（如设置页的渐变方块）。
  final Widget? icon;

  /// 左侧按键；为 null 时按导航栈自动决定返回按钮。
  final Widget? leading;

  /// 右侧按键。
  final List<Widget> actions;

  /// 标题与左侧按键的间距（0 收紧）。
  final double titleSpacing;

  /// 左侧按键槽位宽度（默认与 [kToolbarHeight] 一致，即 56）。
  final double? leadingWidth;

  /// 是否画底部 1px 分隔线。
  final bool showBorder;

  final Color? backgroundColor;
  final Color? foregroundColor;

  /// 点击标题回调（对话页点击书名进入书籍设置）。
  final VoidCallback? onTitleTap;

  /// 本页是否承接驻场岛槽位（沉浸式页面可关闭）。
  final bool islandEnabled;

  /// 顶栏附加行当前高度（由 [IslandAwareScaffold] 注入，0 表示单行形态）。
  final double extraRowHeight;

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + extraRowHeight);

  @override
  State<NarrChatAppBar> createState() => _NarrChatAppBarState();
}

class _NarrChatAppBarState extends State<NarrChatAppBar> {
  final GlobalKey _actionsKey = GlobalKey();

  /// 顶栏自身矩形（汇报给控制器：岛展开时据此贴住顶栏下缘）。
  final GlobalKey _barKey = GlobalKey();

  /// 右侧按键实测宽度（首帧用保守估计，测量后收敛；仅在变化时 setState）。
  double? _actionsWidth;

  @override
  void initState() {
    super.initState();
    _scheduleMeasureActions();
  }

  @override
  void didUpdateWidget(covariant NarrChatAppBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasureActions();
  }

  /// 帧后测量右侧按键总宽（避免首帧估算过窄导致岛与按钮重叠）与顶栏矩形。
  void _scheduleMeasureActions() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = IslandBarScope.maybeOf(context);
      final barBox = _barKey.currentContext?.findRenderObject() as RenderBox?;
      if (controller != null && barBox != null && barBox.hasSize) {
        controller.publishBarRect(
          barBox.localToGlobal(Offset.zero) & barBox.size,
        );
      }
      final box = _actionsKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final measured = box.size.width;
      final current = _actionsWidth;
      if (current != null && (current - measured).abs() < 0.5) return;
      setState(() => _actionsWidth = measured);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = IslandBarScope.maybeOf(context);
    if (!widget.islandEnabled || controller == null) {
      return _buildBar(context, null, expanded: false);
    }
    // 岛的有内容 / 已展开状态变化时重建顶栏（决定占不占槽位、槽位收缩为小标记）。
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.islandActive,
        controller.islandExpanded,
      ]),
      builder: (context, _) => _buildBar(
        context,
        controller,
        expanded: controller.islandExpanded.value,
      ),
    );
  }

  Widget _buildBar(
    BuildContext context,
    IslandBarController? controller, {
    required bool expanded,
  }) {
    final colors = context.narrColors;
    final islandOn = widget.islandEnabled && controller != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final barWidth = constraints.maxWidth;
        // 左侧是否有按键：由「显式 leading」或「路由可返回（含抽屉）」决定，
        // 与 `AppBar.automaticallyImplyLeading` 同源（`ModalRoute` 依赖，可随
        // 路由栈变化自动重建），避免自己判 `canPop()` 时把状态判死在某一帧。
        final route = ModalRoute.of(context);
        final autoLeading =
            widget.leading == null && (route?.impliesAppBarDismissal ?? false);
        final hasLeading = widget.leading != null || autoLeading;
        final leadingWidth =
            widget.leadingWidth ?? (hasLeading ? kToolbarHeight : 0);
        // 没有左侧按键时不收紧标题间距（否则首页标题会贴到窗口左缘）。
        final titleSpacing = hasLeading ? widget.titleSpacing : 16.0;
        final actionsWidth = _actionsWidth ?? _kActionsReserveFallback;
        final titleMinWidth =
            kIslandTitleMinWidth * MediaQuery.textScalerOf(context).scale(1);

        // 岛可用宽度：顶栏去掉左右占位后，两侧各留出标题保底字数。
        final available = barWidth -
            leadingWidth -
            actionsWidth -
            2 * titleMinWidth -
            2 * kIslandTitleGap;
        final slotBudget =
            available.clamp(0.0, barWidth * kIslandMaxBarFraction);
        final twoRow = barWidth < kIslandEmbedBreakpoint ||
            slotBudget < kIslandMinWidth;
        if (islandOn) controller.setTwoRow(twoRow);

        // 槽位宽：展开时收缩为小标记（标题回收空间）。
        final slotWidth = expanded ? kIslandMarkerSize : slotBudget;
        final slotVisible = islandOn &&
            (controller.islandActive.value || expanded) &&
            slotBudget >= kIslandMinWidth;
        // 单行形态下标题只能用「岛左缘 - 间距」，且必须落在左侧按键之后。
        final titleMaxWidth = twoRow
            ? barWidth
            : (barWidth / 2 -
                    slotWidth / 2 -
                    kIslandTitleGap -
                    leadingWidth -
                    titleSpacing)
                .clamp(titleMinWidth, barWidth);

        final slot = slotVisible
            ? IslandSlot(width: slotWidth, height: kIslandPillHeight)
            : null;
        final islandRow = islandOn
            ? PreferredSize(
                preferredSize: Size.fromHeight(widget.extraRowHeight),
                child: widget.extraRowHeight <= 0.5
                    ? const SizedBox.shrink()
                    : Center(
                        child: IslandSlot(
                          width: expanded
                              ? kIslandMarkerSize
                              : (barWidth - 2 * kIslandTitleGap).clamp(
                                  kIslandMinWidth,
                                  barWidth,
                                ),
                          height: kIslandPillHeight,
                        ),
                      ),
              )
            : null;

        return PreferredSize(
          key: _barKey,
          preferredSize: Size.fromHeight(
            kToolbarHeight + widget.extraRowHeight,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: widget.backgroundColor ?? colors.surface,
              border: widget.showBorder
                  ? Border(bottom: BorderSide(color: colors.divider))
                  : null,
            ),
            child: AppBar(
              backgroundColor: widget.backgroundColor ?? colors.surface,
              foregroundColor: widget.foregroundColor,
              elevation: 0,
              scrolledUnderElevation: 0,
              titleSpacing: titleSpacing,
              leadingWidth: widget.leadingWidth,
              // 自动返回按钮交给 `AppBar` 自己决定（`impliesAppBarDismissal`）：
              // 该判断挂在 `ModalRoute` 上，路由栈变化时会自动重建；自己判
              // `canPop()` 会在「返回动画途中恰好重建」时留下一个永不消失的返回键。
              leading: widget.leading,
              title: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: titleMaxWidth),
                child: _buildTitleContent(context),
              ),
              actions: [
                if (widget.actions.isNotEmpty)
                  Row(
                    key: _actionsKey,
                    mainAxisSize: MainAxisSize.min,
                    children: widget.actions,
                  ),
              ],
              // 单行形态：不可见槽位居中占位（岛由 overlay 画在同一矩形）。
              flexibleSpace: twoRow ? null : Center(child: slot),
              // 附加行形态：向下多出一行放岛（高度随动画逐帧变化）。
              bottom: twoRow ? islandRow : null,
            ),
          ),
        );
      },
    );
  }

  /// 标题内容：可选图标 + 标题（文本或自定义）。
  Widget _buildTitleContent(BuildContext context) {
    final title = widget.titleWidget ??
        Text(
          widget.title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.icon != null) ...[widget.icon!, const SizedBox(width: 10)],
        Flexible(child: title),
      ],
    );
    if (widget.onTitleTap == null) return row;
    return GestureDetector(
      onTap: widget.onTitleTap,
      behavior: HitTestBehavior.opaque,
      child: row,
    );
  }
}
