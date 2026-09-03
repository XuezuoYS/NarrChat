import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'brand_logo.dart';
import 'bubble_pointer_listener.dart';
import 'image_preview.dart';
import 'markdown_preview.dart';
import 'responsive_builder.dart';

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
/// - [roundIndex]：AI 气泡窄屏头部的「第 n 轮」标注；为空时不显示。
/// - [images]：本轮附带的图片（相对路径），展示于正文**上方**的预览条，
///   点击打开全屏查看；文件缺失以灰色占位图提示。
/// - [recommendedAction]：AI 气泡正文下方的「推荐下一步」，位于气泡内部且可复制。
/// - [footer]：气泡下方操作区（Token 用量、查看侧边栏、刷新、调试、删除等）。
/// - [onContextMenu]：右键（桌面）或长按（触屏）时回调，传入全局坐标用于弹出菜单。
class ChatBubble extends StatelessWidget {
  final bool isUser;
  final String text;
  final List<String> images;
  final String? recommendedAction;
  final Widget? footer;
  final int? roundIndex;
  final void Function(Offset globalPosition)? onContextMenu;

  const ChatBubble({
    super.key,
    required this.isUser,
    required this.text,
    this.images = const [],
    this.recommendedAction,
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
        // 正文：AI 为无气泡纯文本；用户消息带浅色气泡。
        // 两者均调用统一 Markdown 渲染模块实时渲染。
        if (isUser)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: context.narrColors.userBubble,
              borderRadius: BorderRadius.circular(14),
            ),
            child: MarkdownPreview(
              data: text,
              base: TextStyle(
                fontSize: 15,
                height: 1.65,
                color: context.narrColors.textPrimary,
              ),
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
                    Text(
                      '推荐下一步',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: NarrChatTheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                MarkdownPreview(
                  data: recommendedAction!,
                  base: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: context.narrColors.textSecondary,
                  ),
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
