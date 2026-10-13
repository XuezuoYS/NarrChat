import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'brand_logo.dart';
import 'bubble_pointer_listener.dart';
import 'collapsible_content.dart';
import 'image_preview.dart';
import 'markdown_preview.dart';
import 'recommended_action_view.dart';
import 'responsive_builder.dart';

/// 用户气泡折叠时最多显示的正文行数（超过则收起，见 [UserBubbleBody]）。
const int kUserBubbleMaxCollapsedLines = 7;

/// 用户气泡正文样式（AI 侧同为 15px / 1.65 行高，但用户侧要带文字色）。
///
/// 字号与行高同时决定「7 行」的像素高度，故独立成常量：折叠阈值按它现算，
/// 不写死像素值。
const TextStyle kUserBubbleTextStyle =
    TextStyle(fontSize: 15, height: 1.65);

/// 消息正文列（气泡）的宽度上限：宽屏受阅读列宽约束。
const double kChatBubbleMaxWidth = 680;

/// 按消息区可用宽度计算气泡宽度上限。
///
/// 与主流 AI Chat APP（DeepSeek / ChatGPT / Kimi 等）一致：窄屏时正文
/// 列填满可用宽度，不做额外按比例收缩（避免「左侧头像 + 右侧留白」把
/// 消息夹成细长条）；仅宽屏受 [kChatBubbleMaxWidth] 阅读列宽上限约束。
double chatBubbleMaxWidth(double available) =>
    math.min(available, kChatBubbleMaxWidth);

/// 窄屏下用户气泡最多占内容列宽度的比例：左侧留出少量空白（约 10%），
/// 既表达「靠右」又不至于让正文列过窄。
const double kUserBubbleNarrowRatio = 0.9;

/// 聊天气泡。
///
/// 布局约定：用户气泡靠右，AI 气泡靠左。
/// - 窄屏（可用宽度 < [kResponsiveBreakpoint]）：AI 头像移至正文上方并左对齐，
///   右侧以「第 n 轮」小字标注（标题色、小于正文），正文左右对齐填满内容列；
///   用户气泡额外留出左侧空白（占内容列 `1 - [kUserBubbleNarrowRatio]`）。
/// - 宽屏：AI 头像内嵌正文左上，正文按内容收窄、受阅读列宽上限约束。
/// - 用户气泡正文超过 [kUserBubbleMaxCollapsedLines] 行时默认收起，气泡下方
///   出现展开箭头（见 [UserBubbleBody]）；AI 气泡不折叠。
/// - [roundIndex]：AI 气泡窄屏头部的「第 n 轮」标注；为空时不显示。
/// - [images]：本轮附带的图片（相对路径），展示于正文**上方**的预览条，
///   点击打开全屏查看；文件缺失以灰色占位图提示。
/// - [recommendedAction]：AI 气泡正文下方的「推荐下一步」，位于气泡内部且可复制；
///   其中的列表项（`- ` / `* ` / `1. `）是**可双击的选项**，双击把条目内容写入
///   输入框（不发送）——见 [onRecommendedActionInsert] / [onRecommendedActionCustomTap]。
/// - [footer]：气泡下方操作区（Token 用量、查看侧边栏、刷新、调试、删除等）。
/// - [onContextMenu]：右键（桌面）或长按（触屏）时回调，传入全局坐标用于弹出菜单。
class ChatBubble extends StatelessWidget {
  final bool isUser;
  final String text;
  final List<String> images;
  final String? recommendedAction;

  /// 双击「推荐下一步」的普通选项：把选项内容交给调用方写入输入框（不发送）。
  /// 为空时不绑定双击（选项仅按 Markdown 文本呈现）。
  final ValueChanged<String>? onRecommendedActionInsert;

  /// 双击「推荐下一步」末条「自定义行动」：仅聚焦输入框，不写入任何文本。
  final VoidCallback? onRecommendedActionCustomTap;

  final Widget? footer;
  final int? roundIndex;
  final void Function(Offset globalPosition)? onContextMenu;

  const ChatBubble({
    super.key,
    required this.isUser,
    required this.text,
    this.images = const [],
    this.recommendedAction,
    this.onRecommendedActionInsert,
    this.onRecommendedActionCustomTap,
    this.footer,
    this.roundIndex,
    this.onContextMenu,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showAction = !isUser &&
        recommendedAction != null &&
        recommendedAction!.trim().isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final narrow = isNarrowWidth(available);

        final Widget bubble;
        if (isUser) {
          // 用户消息：右对齐；窄屏下正文上限为内容列的 [kUserBubbleNarrowRatio]，
          // 左侧留出较宽的空白以表达「靠右」。
          bubble = Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: narrow
                    ? available * kUserBubbleNarrowRatio
                    : chatBubbleMaxWidth(available),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: _buildContent(context, theme, showAction,
                        CrossAxisAlignment.end),
                  ),
                ],
              ),
            ),
          );
        } else if (narrow) {
          // 窄屏 AI：头像移至正文上方并左对齐（Align 固定 30×30，避免被
          // stretch 拉宽后居中）；头像右侧以「第 n 轮」小字标注（markdown
          // 标题色、小于正文），弱化孤零感；正文列左右对齐填满内容列。
          bubble = Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: available,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const BrandLogo(size: 30),
                      if (roundIndex != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          // 气泡页眉：完成后仅剩「第 n 轮」。
                          '第 $roundIndex 轮',
                          style: TextStyle(
                            // 软件二级描述文本色（次要文本色），随主题切换。
                            color: context.narrColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildContent(context, theme, showAction,
                      CrossAxisAlignment.stretch),
                ],
              ),
            ),
          );
        } else {
          // 宽屏 AI：头像内嵌正文左上（模仿 DeepSeek：无气泡、纯文本消息流），
          // 「第 n 轮」标注置于正文**上方**、顶部与头像顶部对齐（Row 顶部
          // 对齐）；正文按内容收窄、受阅读列宽上限约束。
          bubble = Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: chatBubbleMaxWidth(available),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const BrandLogo(size: 30),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (roundIndex != null) ...[
                          Text(
                            // 气泡页眉：完成后仅剩「第 n 轮」。
                            '第 $roundIndex 轮',
                            style: TextStyle(
                              // 软件二级描述文本色（次要文本色），随主题切换。
                              color: context.narrColors.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        _buildContent(context, theme, showAction,
                            CrossAxisAlignment.start),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return BubblePointerListener(
          onContextMenu: onContextMenu,
          child: bubble,
        );
      },
    );
  }

  /// 正文列（图片预览条 + 正文 + 推荐下一步 + footer）。
  ///
  /// [crossAxisAlignment] 由各布局传入：用户消息右对齐收窄、窄屏 AI
  /// 左右对齐拉伸、宽屏 AI 左对齐按内容收窄。
  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    bool showAction,
    CrossAxisAlignment crossAxisAlignment,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxisAlignment,
      children: [
        // 图片预览条：正文上方。
        if (images.isNotEmpty) ...[
          ImagePreviewStrip(
            images: images,
            size: 72,
            onTapImage: (_, i) => showImageViewer(context, images, i),
          ),
          const SizedBox(height: 8),
        ],
        // 正文：AI 为无气泡纯文本；用户消息带浅色气泡（超长时可在气泡内收起）。
        // AI 侧始终走 Markdown；用户侧仅在文本具有 Markdown 结构特征（空行分段、
        // 行首块级标记、成对内联标记）时走 Markdown，否则按纯文本渲染，保证
        // 手打的换行不被软换行规则折叠成空格（判定在 [MarkdownPreview] 内）。
        if (isUser)
          DecoratedBox(
            decoration: BoxDecoration(
              color: context.narrColors.userBubble,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: UserBubbleBody(text: text),
            ),
          )
        else
          MarkdownPreview(
            data: text,
            base: TextStyle(
              fontSize: 15,
              height: 1.65,
              color: context.narrColors.textPrimary,
            ),
          ),
        // 推荐下一步：AI 正文下方，极简样式。
        if (showAction) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.flag_outlined,
                      size: 13,
                      color: NarrChatTheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '推荐下一步（双击选项插入输入框）',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: NarrChatTheme.primary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                RecommendedActionView(
                  data: recommendedAction!,
                  base: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: context.narrColors.textSecondary,
                  ),
                  onInsert: onRecommendedActionInsert,
                  onCustomAction: onRecommendedActionCustomTap,
                ),
              ],
            ),
          ),
        ],
        if (footer != null) ...[
          const SizedBox(height: 6),
          footer!,
        ],
      ],
    );
  }
}

/// 用户气泡正文（浅色气泡内，超长自动收起）。
///
/// 布局约定（对齐 Gemini APP 的观感）：
/// - 正文按**气泡完整可用宽**排版，任何控件都不挤占换行宽度；
/// - 正文超过 [maxCollapsedLines] 行时**默认收起**到该行数，正文下方多一行
///   「…」（独占一行，提示后面还有内容），该行右端是圆形箭头控件（收起点⌄、
///   展开点⌃）——展开控件只占这一行，正文一行都不受影响；
/// - 展开后控件单独占正文下方一行（右下角），正文铺开全文；
/// - 未超过时不显示尾行，气泡与从前完全一致；
/// - 收起只做高度裁切（正文仍在渲染树内）：长按框选、复制、右键菜单等既有
///   交互不受影响，展开后也无需重新排版；
/// - 阈值按正文样式实测 [maxCollapsedLines] 行的高度（随文字缩放一起变），
///   Markdown 正文（列表 / 标题 / 代码块）与纯文本共用同一条高度裁切路径；
/// - 展开 / 收起时**气泡顶部视觉位置不动**（消息列是底部锚定的，见
///   [_UserBubbleBodyState._toggleExpanded]）。
///
/// 由 [ChatBubble] 的用户分支使用；AI 气泡不折叠（正文由模型生成本就带分段）。
class UserBubbleBody extends StatefulWidget {
  const UserBubbleBody({
    super.key,
    required this.text,
    this.maxCollapsedLines = kUserBubbleMaxCollapsedLines,
  });

  /// 正文源文本。
  final String text;

  /// 收起时最多显示的行数。
  final int maxCollapsedLines;

  @override
  State<UserBubbleBody> createState() => _UserBubbleBodyState();
}

class _UserBubbleBodyState extends State<UserBubbleBody> {
  /// 是否已展开（仅影响展示高度，不改正文）。
  bool _expanded = false;

  /// 正文是否需要收起（由 [CollapsibleContent] 在布局阶段回报；首帧为 false）。
  bool _overflowing = false;

  /// 正文一行的自然高度（px）＝收起阈值的单位（阈值 = 它 × 行数）。
  ///
  /// 在 [didChangeDependencies] 里算：首次构建前必然执行一次，之后文字缩放 /
  /// 主题变化都会重算。
  late double _lineHeight;

  /// 正文渲染对象（用来读「展开后会有多高」，见 [_toggleExpanded]）。
  final GlobalKey _contentKey = GlobalKey();

  /// 消息列的滚动位置（在 [didChangeDependencies] 里取，展开 / 收起时用于锁定
  /// 气泡顶部；气泡不在可滚动列表里时为 null）。
  ScrollPosition? _scrollPosition;

  /// 小于该偏移（px）的补偿直接跳过（避免无意义的 `jumpTo`）。
  static const double _kScrollLockEpsilon = 0.5;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lineHeight = _measureLineHeight(context);
    _scrollPosition = Scrollable.maybeOf(context)?.position;
  }

  /// 实测一行正文的高度：用 [TextPainter] 而非 `fontSize × height` 手算，
  /// 字体回退 / 文字缩放都算得进来。
  double _measureLineHeight(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: '行', style: _textStyle(context)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// 用户气泡正文样式（正文与省略号共用同一份）。
  TextStyle _textStyle(BuildContext context) => kUserBubbleTextStyle.copyWith(
        color: context.narrColors.textPrimary,
      );

  /// 切换展开 / 收起：**切换前后气泡顶部的视觉位置不动**，且不用滚动动画。
  ///
  /// 消息列是 `reverse: true`（底部锚定）的：某一条变高，会让它**上方**的内容
  /// 整体上移——读者正看着的第一行会自己跑掉。两步把位置锁住：
  /// 1. **预补偿**：按「即将变化的高度 Δ」先把滚动偏移补回去（展开 = 变高 Δ
  ///    → 内容上移 Δ → 偏移 +Δ 抵消），与 `setState` 同一帧完成，`jumpTo` 瞬时
  ///    生效，所以既没有滚动动画、也不会先画一帧错位；
  /// 2. **帧末校正**：列表自身的锚定（末尾条目增长时的阅读锚定、内容不足一屏）
  ///    可能与预补偿叠加，以「顶部实际位置」为准再修一次（通常偏差为 0，
  ///    不触发）。
  ///
  /// 只在气泡与视口有交集时锁定：看不见就谈不上锁定视线，而气泡在视口**上方**
  /// 时它的高度变化本就不推动可视内容，补偿反而会推错。
  void _toggleExpanded() {
    final position = _scrollPosition;
    final box = context.findRenderObject() as RenderBox?;
    if (position == null || box == null || !position.hasContentDimensions) {
      setState(() => _expanded = !_expanded);
      return;
    }
    final top = box.localToGlobal(Offset.zero).dy;
    final visibleInViewport =
        top < position.viewportDimension && top + box.size.height > 0;
    if (!visibleInViewport) {
      setState(() => _expanded = !_expanded);
      return;
    }

    // 1. 预补偿：与切换同一帧生效（无动画、无中间帧）。
    _nudgeBy(position, _expansionDelta(_expanded ? -1 : 1));
    setState(() => _expanded = !_expanded);

    // 2. 帧末校正：列表锚定与预补偿叠加时以实际位置为准。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = (context.findRenderObject() as RenderBox?)
          ?.localToGlobal(Offset.zero)
          .dy;
      if (current == null) return;
      _nudgeBy(position, top - current);
    });
  }

  /// 展开（[sign] = 1）/ 收起（[sign] = -1）会让气泡高度变化多少（px）。
  ///
  /// 两种状态各有一条同高的尾行，所以气泡高度差 = 正文自然高度 − 裁切阈值；
  /// 收起态下这两个量都已量好（见 [RenderCollapsibleContent.naturalHeight]），
  /// 不用等展开帧。
  double _expansionDelta(int sign) {
    final render = _contentKey.currentContext?.findRenderObject();
    if (render is! RenderCollapsibleContent) return 0;
    return (render.naturalHeight - render.collapsedHeight) * sign;
  }

  /// 把滚动偏移挪 [delta]（px）：瞬时 `jumpTo`，不做滚动动画。
  void _nudgeBy(ScrollPosition position, double delta) {
    if (delta.abs() <= _kScrollLockEpsilon) return;
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() <= _kScrollLockEpsilon) return;
    position.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = _textStyle(context);
    // 正文按完整可用宽排版（不给任何控件让位）：收起时正文一行都不变窄，
    // 省略号与展开控件都放在正文**之外**的尾行里。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CollapsibleContent(
          key: _contentKey,
          collapsedLines: widget.maxCollapsedLines,
          lineHeight: _lineHeight,
          expanded: _expanded,
          onCollapsedChanged: (needed) {
            // 回调来自帧末（布局阶段不能 setState）；期间本组件可能已卸载。
            if (!mounted || needed == _overflowing) return;
            setState(() => _overflowing = needed);
          },
          child: MarkdownPreview(
            data: widget.text,
            plainTextWhenNotMarkdown: true,
            base: textStyle,
          ),
        ),
        // 正文没超过阈值 → 没有可折叠的内容，尾行不占位。
        if (_overflowing) _buildTailRow(textStyle),
      ],
    );
  }

  /// 正文下方的尾行：收起时「…」独占一行（右端是展开控件），展开时只有右下角
  /// 的收起控件。行高固定为控件热区高，因此两种状态下尾行一样高——展开 / 收起
  /// 的气泡高度差正好等于正文高度差（[_toggleExpanded] 按它补偿滚动）。
  Widget _buildTailRow(TextStyle textStyle) => SizedBox(
        height: _CollapseToggle.hitSize,
        child: Row(
          children: [
            if (!_expanded)
              Text(
                '…',
                style: textStyle,
                semanticsLabel: '已收起部分内容',
              ),
            const Spacer(),
            _CollapseToggle(
              expanded: _expanded,
              onToggle: _toggleExpanded,
            ),
          ],
        ),
      );
}

/// 气泡右下角的收起 / 展开箭头控件。
///
/// 独占正文下方尾行的右端（展开时整行只有它）：正文一行都不必为它让位。
class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({
    required this.expanded,
    required this.onToggle,
  });

  /// 是否处于展开态（箭头朝上）。
  final bool expanded;

  /// 点击切换收起 / 展开。
  final VoidCallback onToggle;

  /// 箭头热区边长（触屏友好，不小于 32）。
  static const double hitSize = 32;

  @override
  Widget build(BuildContext context) {
    final label = expanded ? '收起' : '展开全文';
    return Tooltip(
      message: label,
      child: SizedBox(
        height: hitSize,
        width: hitSize,
        child: Material(
          // 淡底衬托：压在正文边上时仍能看清箭头。
          color: context.narrColors.userBubble,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onToggle,
            child: Icon(
              expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: context.narrColors.textSecondary,
              semanticLabel: label,
            ),
          ),
        ),
      ),
    );
  }
}
