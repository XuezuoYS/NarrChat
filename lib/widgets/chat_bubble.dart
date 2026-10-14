import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'brand_logo.dart';
import 'bubble_pointer_listener.dart';
import 'collapsible_content.dart';
import 'image_preview.dart';
import 'markdown_preview.dart';
import 'reading_anchor.dart';
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
/// - 展开时以**气泡顶部**为锚点固定不动、收起时以**气泡底部**为锚点固定不动
///   （消息列是底部锚定的，见 [_UserBubbleBodyState._toggleExpanded]）。
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lineHeight = _measureLineHeight(context);
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

  /// 切换展开 / 收起：**展开锁气泡顶部、收起锁气泡底部**（各让点击的那一端不动）。
  ///
  /// 消息列是 `reverse: true`（底部锚定）的：条目变高 / 变矮时它的**底边**天然不动，
  /// 顶边往上跑 / 往下滑。于是两条方向刚好各取所需：
  ///
  /// - **展开**：以**顶部**为锚点固定不动 —— 补 Δ（= 正文自然高度 − 裁切阈值）让
  ///   内容朝下方铺开，读者从消息开头往下读，观感与产品预期一致。补偿交给
  ///   [ScrollLockAnchor]，在**下一帧布局阶段**（新范围已知）落地，本帧即按补偿后的
  ///   位置重排重绘；不能自己按旧范围夹紧（那会把补偿吃掉，是「一展开就跳」的旧病根）。
  /// - **收起**：以**底部**为锚点固定不动 —— 底边锚定本来就是列表的天然行为，
  ///   **一个偏移都不用补**：控件就停在指尖 / 光标下，正文朝下收拢。这里曾经无条件
  ///   锁顶边，而点收起时读者通常在气泡尾部（顶边早在视口上方几千 px），锁住一个
  ///   看不见的顶边等于把整屏内容平移 Δ（实测 Δ 近万 px）—— 这就是「一收起就跳到
  ///   全页顶部」的真身；改成锁底边后这条链整体消失。
  ///
  /// 唯一要额外处理的：本条若是列表末尾那条（阅读锚定的对象），锚定会把这次高度
  /// 变化当成「视口下方内容长高」再补一次 —— 展开时会叠成双倍、收起时会破坏
  /// 「底边不动」，所以按需声明压掉（见 [ScrollLockRequest]）。
  void _toggleExpanded() {
    final position = Scrollable.maybeOf(context)?.position;
    if (position != null) _requestScrollCompensation(position);
    setState(() => _expanded = !_expanded);
  }

  /// 按展开 / 收起分别登记滚动补偿（见 [_toggleExpanded]）。
  void _requestScrollCompensation(ScrollPosition position) {
    if (!position.hasContentDimensions) return;
    final physics = position.physics;
    if (physics is! ReadingAnchorScrollPhysics) return;
    final lock = physics.lock;
    if (lock == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    // 本条是不是列表末尾那条（阅读锚定的对象）：锚定会替它补同一个高度变化。
    final isAnchorItem =
        context.findAncestorWidgetOfExactType<ReadingAnchorItem>()?.active ??
            false;
    if (!_expanded) {
      // 展开：锁顶部。气泡得与视口有交集 —— 看不见就谈不上锁视线。
      final top = box.localToGlobal(Offset.zero).dy;
      if (top >= position.viewportDimension || top + box.size.height <= 0) {
        return;
      }
      final delta = _expansionDelta();
      if (delta == 0) return;
      lock.request(shift: delta, suppressAnchorGrowth: isAnchorItem);
      return;
    }
    // 收起：锁底部 —— 不补任何偏移，只压掉阅读锚定可能补的那一次。
    final atBottom = position.pixels <=
        position.minScrollExtent + ReadingAnchorScrollPhysics.atBottomEpsilon;
    if (isAnchorItem && !atBottom) lock.request(suppressAnchorGrowth: true);
  }

  /// 展开会让气泡高度变化多少（px）= 正文自然高度 − 裁切阈值。
  ///
  /// 两种状态各有一条同高的尾行，所以气泡高度差正好是它；收起态下这两个量都已
  /// 量好（见 [RenderCollapsibleContent.naturalHeight]），不用等展开帧。
  double _expansionDelta() {
    final render = _contentKey.currentContext?.findRenderObject();
    if (render is! RenderCollapsibleContent) return 0;
    return render.naturalHeight - render.collapsedHeight;
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
  /// 的收起控件。行高固定为控件热区高，因此两种状态下尾行一样高——正文顶边
  /// 的位置只由正文高度决定，控件本身在两种状态下都待在气泡最底行。
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
///
/// 点击判定**不依赖手势竞技场**（[Listener] 自己认「按下 → 抬起」）：
/// 消息列是可滚动列表，而鼠标指针的拖动判定阈值只有 1px
/// （`kPrecisePointerHitSlop`）—— 按住鼠标时手抖两三像素就会被判成「拖动滚动」，
/// [InkWell.onTap] 随之被取消，用户看到的是「点一下没反应，点几下才行」。
/// 自己判定后：位移在 [tapSlop] 内即视为点击，超过就交回列表滚动（不误伤拖动）。
class _CollapseToggle extends StatefulWidget {
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

  /// 「按下 → 抬起」允许的最大位移（px）：超过即认为是滚动拖动。
  static const double tapSlop = 18;

  @override
  State<_CollapseToggle> createState() => _CollapseToggleState();
}

class _CollapseToggleState extends State<_CollapseToggle> {
  /// 正在跟踪的指针（多指时只认第一根）。
  int? _pointer;

  /// 该指针按下时的全局位置。
  Offset? _downPosition;

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _downPosition = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final down = _downPosition;
    if (down == null) return;
    if ((event.position - down).distance > _CollapseToggle.tapSlop) {
      // 位移超出点击范围：这是一次滚动拖动，交给列表，不触发切换。
      _forget();
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final down = _downPosition;
    _forget();
    if (down == null) return;
    if ((event.position - down).distance > _CollapseToggle.tapSlop) return;
    widget.onToggle();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _forget();
  }

  void _forget() {
    _pointer = null;
    _downPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.expanded ? '收起' : '展开全文';
    return Tooltip(
      message: label,
      child: SizedBox(
        height: _CollapseToggle.hitSize,
        width: _CollapseToggle.hitSize,
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: Material(
            // 淡底衬托：压在正文边上时仍能看清箭头。
            color: context.narrColors.userBubble,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            // 只借它画水波纹：切换由上面的 [Listener] 负责，避免同一次点击触发两次。
            child: InkWell(
              onTap: () {},
              child: Icon(
                widget.expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: context.narrColors.textSecondary,
                semanticLabel: label,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
