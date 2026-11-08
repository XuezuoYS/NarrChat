import 'package:flutter/material.dart';

import '../../services/book_creation/book_creation_step.dart';
import '../../theme/app_theme.dart';
import '../../utils/formats.dart';
import '../markdown_preview.dart';
import '../settings/settings_kit.dart';
import '../streaming_markdown.dart';

/// 创建流程里的单个步骤卡片。
///
/// 状态：等待 / 生成中（流式文本）/ 完成 / 完成但有提醒 / 失败。
/// 完成后可展开查看该步解析出的内容；每步右上角显示分步 Token。
class BookCreationStepCard extends StatefulWidget {
  const BookCreationStepCard({
    super.key,
    required this.badge,
    required this.title,
    required this.status,
    this.visibleText = '',
    this.summary,
    this.detailMarkdown,
    this.problems = const [],
    this.usage = BookCreationUsage.empty,
  });

  /// 左侧圆形徽标内容（固定阶段是序号，补充轮是「补1」这类）。
  final String badge;

  /// 步骤标题（如「基础设定与世界书」）。
  final String title;

  final BookCreationStepStatus status;

  /// 生成中实时展示的可见文本（已去标签）。
  final String visibleText;

  /// 完成后的单行摘要。
  final String? summary;

  /// 展开后展示的 Markdown 内容。
  final String? detailMarkdown;

  /// 提醒 / 失败原因。
  final List<String> problems;

  /// 本步 Token 用量。
  final BookCreationUsage usage;

  @override
  State<BookCreationStepCard> createState() => _BookCreationStepCardState();
}

class _BookCreationStepCardState extends State<BookCreationStepCard> {
  bool _expanded = false;

  Color _statusColor(BuildContext context) {
    final colors = context.narrColors;
    switch (widget.status) {
      case BookCreationStepStatus.waiting:
        return colors.textSecondary;
      case BookCreationStepStatus.running:
        return Theme.of(context).colorScheme.primary;
      case BookCreationStepStatus.done:
        return colors.success;
      case BookCreationStepStatus.warning:
        return colors.warning;
      case BookCreationStepStatus.failed:
        return Theme.of(context).colorScheme.error;
    }
  }

  String _statusLabel() {
    switch (widget.status) {
      case BookCreationStepStatus.waiting:
        return '等待中';
      case BookCreationStepStatus.running:
        return '生成中…';
      case BookCreationStepStatus.done:
        return '已完成';
      case BookCreationStepStatus.warning:
        return '已完成（有提醒）';
      case BookCreationStepStatus.failed:
        return '失败';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final color = _statusColor(context);
    final detail = widget.detailMarkdown?.trim() ?? '';
    return SettingsCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildBadge(color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statusLabel(),
                      style: TextStyle(fontSize: 11.5, color: color),
                    ),
                  ],
                ),
              ),
              if (widget.usage.hasData) ...[
                const SizedBox(width: 8),
                Text(
                  '输入 ${Formats.formatTokenCount(widget.usage.promptTokens)}'
                  ' · 输出 ${Formats.formatTokenCount(widget.usage.completionTokens)}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
          if (widget.status == BookCreationStepStatus.running) ...[
            const SizedBox(height: 10),
            _buildRunning(context),
          ],
          if (widget.status != BookCreationStepStatus.running &&
              widget.status != BookCreationStepStatus.waiting) ...[
            if ((widget.summary ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                widget.summary!.trim(),
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: colors.textSecondary,
                ),
              ),
            ],
            if (widget.problems.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final problem in widget.problems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        widget.status == BookCreationStepStatus.failed
                            ? Icons.error_outline
                            : Icons.info_outline,
                        size: 14,
                        color: color,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          problem,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (detail.isNotEmpty &&
                widget.status != BookCreationStepStatus.failed) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: ValueKey('book_creation_step_expand_${widget.title}'),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                  ),
                  label: Text(_expanded ? '收起生成内容' : '查看生成内容'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              if (_expanded)
                Container(
                  constraints: const BoxConstraints(maxHeight: 360),
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  decoration: BoxDecoration(
                    color: colors.background,
                    borderRadius:
                        BorderRadius.circular(NarrChatTheme.controlRadius),
                    border: Border.all(color: colors.divider),
                  ),
                  child: SingleChildScrollView(
                    child: MarkdownPreview(
                      data: detail,
                      base: const TextStyle(fontSize: 12.5, height: 1.6),
                    ),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildBadge(Color color) {
    switch (widget.status) {
      case BookCreationStepStatus.waiting:
      case BookCreationStepStatus.done:
      case BookCreationStepStatus.warning:
      case BookCreationStepStatus.failed:
        return Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: widget.status == BookCreationStepStatus.waiting
                ? Text(
                    widget.badge,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  )
                : Icon(
                    widget.status == BookCreationStepStatus.failed
                        ? Icons.close
                        : Icons.check,
                    size: 16,
                    color: color,
                  ),
          ),
        );
      case BookCreationStepStatus.running:
        return Container(
          width: 26,
          height: 26,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        );
    }
  }

  Widget _buildRunning(BuildContext context) {
    final colors = context.narrColors;
    if (widget.visibleText.trim().isEmpty) {
      return Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '模型正在生成…',
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ],
      );
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
        border: Border.all(color: colors.divider),
      ),
      child: SingleChildScrollView(
        child: StreamingMarkdown(
          data: widget.visibleText,
          base: const TextStyle(fontSize: 12.5, height: 1.6),
        ),
      ),
    );
  }
}
