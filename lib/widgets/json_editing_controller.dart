import 'package:flutter/material.dart';

import '../utils/json_syntax_highlighter.dart';
import '../utils/syntax_highlight_span.dart';
import 'json_syntax_colors.dart';
import 'syntax_highlight.dart';

/// 支持 JSON 语法高亮的输入控制器。
///
/// 用法：把多行 `TextField` 的 `controller` 换成 [JsonEditingController]，
/// 其余行为（多行、光标、选择、IME、键盘类型等）与普通控制器完全一致。
///
/// - 高亮由 [JsonSyntaxHighlighter] 提供（宽容词法：`{"a":` 这类半截内容、
///   甚至不是 JSON 的文本都能安全着色，输入过程绝不抛异常）；
/// - 配色与只读展示组件 `JsonView` 共用 [JsonSyntaxColors]，看到的就是编辑的；
/// - 输入法组合区的下划线由 [SyntaxHighlightingController] 统一处理。
class JsonEditingController
    extends SyntaxHighlightingController<JsonSyntaxToken> {
  JsonEditingController({super.text});

  static const JsonSyntaxHighlighter _highlighter = JsonSyntaxHighlighter();

  @override
  List<SyntaxHighlightSpan<JsonSyntaxToken>> highlightSpans(String text) =>
      _highlighter.highlight(text);

  @override
  SyntaxStyleResolver<JsonSyntaxToken> stylesFor(
    BuildContext context,
    TextStyle base,
  ) {
    final colors = JsonSyntaxColors.of(context);
    return (token) => colors.styleFor(token, base);
  }
}
