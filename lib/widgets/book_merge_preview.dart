import 'package:flutter/material.dart';

import '../models/round.dart';
import '../services/database_merge_service.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';
import 'markdown_preview.dart';

/// 合并决策页的书籍预览对话框：查看某一侧的书籍设置与轮次内容。
///
/// - [label] 标识来源侧（如「导入的备份」/「本地」）；
/// - 书籍设置（基础设定、文笔要求、文笔参考、全局提示等）以可折叠块展示；
/// - 轮次正文用 [MarkdownPreview] 渲染；图片只显示数量说明，不渲染图片。
/// - 轮次与设置块均**默认折叠**，仅在展开时排版，避免长书一次性渲染卡顿。
void showBookMergePreview(
  BuildContext context, {
  required String title,
  required String label,
  required BookMergeSide side,
}) {
  showDialog<void>(
    context: context,
    builder: (_) => BookMergePreview(title: title, label: label, side: side),
  );
}

class BookMergePreview extends StatelessWidget {
  final String title;
  final String label;
  final BookMergeSide side;

  const BookMergePreview({
    super.key,
    required this.title,
    required this.label,
    required this.side,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colors.userBubble,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildSettings(context),
                    const SizedBox(height: 16),
                    Text(
                      '轮次（${side.rounds.length}）',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (side.rounds.isEmpty)
                      Text(
                        '（无轮次）',
                        style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: colors.textSecondary,
                        ),
                      )
                    else
                      for (final round in side.rounds) _buildRound(context, round),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettings(BuildContext context) {
    final book = side.book;
    final settings = <(String, String)>[
      ('类别', book.category),
      ('基础设定', book.baseSetting),
      ('文笔要求', book.writingRequirements),
      ('文笔参考', book.writingStyle),
      ('全局前置提示', book.globalPrePrompt),
      ('全局后置提示', book.globalPostPrompt),
      ('角色层级', book.roleHierarchy),
      ('历史轮次数量', '${book.historyRounds}'),
    ].where((s) => s.$2.trim().isNotEmpty).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '书籍设置',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: context.narrColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        if (settings.isEmpty)
          Text(
            '（无设置内容）',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: context.narrColors.textSecondary,
            ),
          )
        else
          for (final (label, value) in settings)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                shape: const Border(),
                collapsedShape: const Border(),
                leading: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.narrColors.textSecondary,
                  ),
                ),
                title: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.narrColors.textPrimary,
                  ),
                ),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.only(left: 14, right: 8),
                    child: MarkdownPreview(
                      data: value,
                      base: const TextStyle(fontSize: 12.5, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _buildRound(BuildContext context, Round round) {
    final colors = context.narrColors;
    final header = [
      '第 ${round.roundIndex} 轮',
      if (round.createdAt != null)
        ' · ${Formats.formatDateTime(round.createdAt!)}',
    ].join();
    final imageNote = <String>[
      if (round.userImages.isNotEmpty) '用户图片 ${round.userImages.length} 张',
      if (round.aiImages.isNotEmpty) '生成图片 ${round.aiImages.length} 张',
    ].join('、');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.all(4),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(Icons.format_quote, size: 18, color: colors.textSecondary),
        title: Text(
          header,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        subtitle: imageNote.isEmpty
            ? null
            : Text(
                imageNote,
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildField(context, '用户输入', round.userInput),
          _buildField(context, 'AI 正文', round.aiNarrative),
        ],
      ),
    );
  }

  Widget _buildField(BuildContext context, String label, String content) {
    final colors = context.narrColors;
    final body = content.trim().isEmpty
        ? Text(
            '（无）',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: colors.textSecondary,
            ),
          )
        : MarkdownPreview(
            data: content,
            base: const TextStyle(fontSize: 12.5, height: 1.5),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 2),
          body,
        ],
      ),
    );
  }
}
