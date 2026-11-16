/// 测试公用：把 `TextSpan` 树展平成可断言的叶子列表。
///
/// 高亮相关的两组用例都要「按文本找 span、再断样式」：
/// - `json_editing_controller_test`（编辑控制器直接产出 TextSpan 树）；
/// - `json_view_test`（展示组件渲染成 RichText 后取 `text`）。
/// 因此收在 helpers 里，避免每个文件各写一份。
library;

import 'package:flutter/painting.dart';

/// 按文档顺序展平 [root]，返回所有**非空文本**叶子。
List<TextSpan> flattenSpans(InlineSpan root) {
  final result = <TextSpan>[];
  void visit(InlineSpan span) {
    if (span is! TextSpan) return;
    if (span.text != null && span.text!.isNotEmpty) result.add(span);
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child);
    }
  }

  visit(root);
  return result;
}

/// 全部叶子拼接后的文本（用于验证「渲染结果与原文逐字一致」）。
String combinedSpansText(InlineSpan root) =>
    flattenSpans(root).map((span) => span.text).join();

/// 文本**恰好等于** [text] 的首个叶子。
TextSpan spanWithText(InlineSpan root, String text) =>
    flattenSpans(root).firstWhere(
      (span) => span.text == text,
      orElse: () => throw StateError(
        '未找到文本为「$text」的 span，'
        '实际叶子：${flattenSpans(root).map((s) => s.text).toList()}',
      ),
    );
