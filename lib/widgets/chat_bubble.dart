import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'brand_logo.dart';
import 'bubble_pointer_listener.dart';
import 'image_preview.dart';
import 'markdown_preview.dart';

/// 聊天气泡。
///
/// 布局约定：用户气泡靠右，AI 气泡靠左。
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
  final void Function(Offset globalPosition)? onContextMenu;

  const ChatBubble({
    super.key,
    required this.isUser,
    required this.text,
    this.images = const [],
    this.recommendedAction,
    this.footer,
    this.onContextMenu,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxWidth = MediaQuery.sizeOf(context).width * 0.8;
    final showAction = !isUser &&
        recommendedAction != null &&
        recommendedAction!.trim().isNotEmpty;

    return BubblePointerListener(
      onContextMenu: onContextMenu,
      child: Align(
        // 用户靠右，AI 靠左（模仿 DeepSeek：无气泡、纯文本消息流）。
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth.clamp(240, 680)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isUser) ...[
                const BrandLogo(size: 30),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: isUser
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    // 图片预览条：正文上方。
                    if (images.isNotEmpty) ...[
                      ImagePreviewStrip(
                        images: images,
                        size: 72,
                        onTapImage: (rel) => showImageViewer(context, rel),
                      ),
                      const SizedBox(height: 8),
                    ],
                    // 正文：AI 为无气泡纯文本；用户消息带浅色气泡。
                    // 两者均调用统一 Markdown 渲染模块实时渲染。
                    if (isUser)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 9),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
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
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

}

