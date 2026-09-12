import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../services/recommended_action_parser.dart';
import 'markdown_preview.dart';

/// 「推荐下一步」正文：Markdown 基础解析 + 列表项「双击插入输入框」。
///
/// 渲染约定：
/// - 列表项（`- ` / `* ` / `1. `）沿用整块列表的外观——符号用
///   [MarkdownPreview.buildListBullet]、符号列宽按
///   [GitHubMarkdownStyle.listBulletWidth] 对齐，条目内容仍走 [MarkdownPreview]
///   （行内 Markdown 照常解析），只是额外绑定**双击**手势；
/// - 非列表文本原样交给 [MarkdownPreview]，不做任何手势绑定；
/// - 整个区块共用一个 [SelectableTextArea]（与气泡内其它 Markdown 同一约定：
///   抑制默认右键 / 长按菜单，避免与气泡菜单冲突）。因此「长按选择 / 拖动框选
///   + 复制」与改造前一致（触屏同样生效），选项行不会因双击手势失去选中能力：
///   双击由行内 `DoubleTapGestureRecognizer` 抢先判定，单击 / 长按 / 拖动仍归
///   [SelectionArea]。
class RecommendedActionView extends StatelessWidget {
  const RecommendedActionView({
    super.key,
    required this.data,
    this.onInsert,
    this.onCustomAction,
    this.base,
  });

  /// `## 推荐行动` 正文原文。
  final String data;

  /// 双击普通选项：把条目内容交给调用方写入输入框（**不发送**）。为空则不绑定
  /// 双击（选项退化为普通 Markdown 文本）。
  final ValueChanged<String>? onInsert;

  /// 双击末条「自定义行动」：语义是「由用户自行输入」，只聚焦输入框、不写入
  /// 文本。为空则不绑定双击。
  final VoidCallback? onCustomAction;

  /// 正文字体样式（与气泡内其它 Markdown 保持一致）。
  final TextStyle? base;

  @override
  Widget build(BuildContext context) {
    final segments = splitRecommendedAction(data);
    return SelectableTextArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final segment in segments)
            switch (segment) {
              RecommendedActionOption() => _OptionRow(
                  option: segment,
                  base: base,
                  onDoubleTap: segment.isCustomAction
                      ? onCustomAction
                      : (onInsert == null
                          ? null
                          : () => onInsert!(segment.content)),
                ),
              RecommendedActionMarkdown() => MarkdownPreview(
                  data: segment.text,
                  base: base,
                  selectable: false,
                ),
            },
        ],
      ),
    );
  }
}

/// 单个可双击选项行：列表符号（与整块列表同一外观）+ Markdown 条目内容。
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.onDoubleTap,
    this.base,
  });

  final RecommendedActionOption option;

  /// 双击回调；为空时该行不参与手势（保持纯 Markdown 文本）。
  final VoidCallback? onDoubleTap;

  final TextStyle? base;

  @override
  Widget build(BuildContext context) {
    final bullet = MarkdownPreview.buildListBullet(
      context,
      MarkdownBulletParameters(
        // 符号构建器按 `index + 1` 渲染有序序号，这里回填显示序号。
        index: option.ordered ? option.number - 1 : 0,
        style: option.ordered
            ? BulletStyle.orderedList
            : BulletStyle.unorderedList,
        nestLevel: 0,
      ),
    );

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      textBaseline: TextBaseline.alphabetic,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      children: [
        SizedBox(
          width: GitHubMarkdownStyle.listBulletWidth,
          child: Padding(
            padding: GitHubMarkdownStyle.listBulletPadding,
            child: bullet,
          ),
        ),
        Flexible(
          child: MarkdownPreview(
            data: option.content,
            base: base,
            selectable: false,
          ),
        ),
      ],
    );

    if (onDoubleTap == null) return row;
    return GestureDetector(
      // 整行（含符号列与行尾空白）都可双击，避免只有文字上才生效。
      behavior: HitTestBehavior.opaque,
      onDoubleTap: onDoubleTap,
      child: row,
    );
  }
}
