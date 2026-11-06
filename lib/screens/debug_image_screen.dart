import 'dart:io';

import 'package:flutter/material.dart';

import '../services/debug_file_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_empty_hint.dart';
import '../widgets/island_bar.dart';
import '../widgets/narr_chat_app_bar.dart';

/// 「图片」阅读器：全屏黑底，支持缩放与拖动。
///
/// 不接入应用里带云同步删除语义的图片查看器：调试页只看，不删、不同步。
class DebugImageScreen extends StatelessWidget {
  const DebugImageScreen({
    super.key,
    required this.fileService,
    required this.entry,
  });

  final DebugFileService fileService;
  final DebugFileEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return IslandAwareScaffold(
      backgroundColor: colors.background,
      appBarBuilder: (context, extraRow) =>
          NarrChatAppBar(extraRowHeight: extraRow, title: entry.name),
      body: Container(
        color: Colors.black,
        child: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 8,
            child: Image.file(
              File(fileService.absolutePathOf(entry.relativePath)),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Padding(
                padding: const EdgeInsets.all(24),
                child: AppEmptyHint(
                  icon: Icons.broken_image_outlined,
                  text: '图片加载失败：$error',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
