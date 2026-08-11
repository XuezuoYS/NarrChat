import 'package:flutter/material.dart';

import '../utils/markdown_syntax_highlighter.dart';

/// Markdown 编辑框语法高亮配色（仿 VS Code / GitHub，随亮暗主题自适应）。
class MarkdownSyntaxColors {
  /// 标题。
  final Color heading;

  /// 列表符号 / 引用记号。
  final Color marker;

  /// 链接文字 / 自动链接。
  final Color link;

  /// 行内代码 / 围栏代码。
  final Color code;

  /// 加粗内容（`**加粗**`，以颜色区分而非加粗字重）。
  final Color bold;

  /// 引用内容。
  final Color blockquote;

  /// 弱化内容（URL、括号、分割线等）。
  final Color dim;

  const MarkdownSyntaxColors({
    required this.heading,
    required this.marker,
    required this.link,
    required this.code,
    required this.bold,
    required this.blockquote,
    required this.dim,
  });

  /// 浅色主题（VS Code 浅色风格：蓝标题、红代码、蓝链接、灰引用）。
  static const MarkdownSyntaxColors light = MarkdownSyntaxColors(
    heading: Color(0xFF005CC5),
    marker: Color(0xFF6E5BEF),
    link: Color(0xFF0000EE),
    code: Color(0xFFA31515),
    bold: Color(0xFF188038),
    blockquote: Color(0xFF6A737D),
    dim: Color(0xFF6A737D),
  );

  /// 深色主题（GitHub Dark 风格：亮蓝标题、橙代码、亮蓝链接、灰引用）。
  static const MarkdownSyntaxColors dark = MarkdownSyntaxColors(
    heading: Color(0xFF58A6FF),
    marker: Color(0xFFB0A6FF),
    link: Color(0xFF4DA3FF),
    code: Color(0xFFCE9178),
    bold: Color(0xFF7EE0B5),
    blockquote: Color(0xFF8B949E),
    dim: Color(0xFF8B949E),
  );

  /// 按当前主题亮度选取配色。
  static MarkdownSyntaxColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// 支持 Markdown 语法高亮的输入控制器。
///
/// 用法：将普通 `TextField` 的 `controller` 换成 [MarkdownEditingController]，
/// 其余行为（多行、光标、选择、IME、键盘类型等）与普通控制器完全一致。
///
/// - 高亮逻辑由 [MarkdownSyntaxHighlighter] 提供，配色随亮暗主题自动切换；
/// - 输入法组合区（composition）文本会附加下划线，与系统输入法候选窗
///   的视觉反馈保持一致，且不影响 `ImeCaretSync` 的光标定位。
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    assert(!value.composing.isValid || !withComposing || value.isComposingRangeValid);

    final base = style ?? const TextStyle();
    final colors = MarkdownSyntaxColors.of(context);
    final spans = const MarkdownSyntaxHighlighter().highlight(text);

    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : null;
    final children = _buildChildren(spans, base, colors, composing);
    return TextSpan(style: base, children: children);
  }

  /// 将语法区间组装为 TextSpan 列表；[composing] 非空时对组合区附加下划线。
  List<TextSpan> _buildChildren(
    List<MarkdownHighlightSpan> spans,
    TextStyle base,
    MarkdownSyntaxColors colors,
    TextRange? composing,
  ) {
    final children = <TextSpan>[];

    void push(int absStart, int absEnd, TextStyle st) {
      if (absEnd <= absStart) return;
      final piece = text.substring(absStart, absEnd);
      if (composing == null ||
          composing.isCollapsed ||
          absEnd <= composing.start ||
          absStart >= composing.end) {
        children.add(TextSpan(text: piece, style: st));
        return;
      }
      // 与组合区相交：切分为 前 / 组合区（加下划线）/ 后 三段。
      final beforeEnd = composing.start > absStart ? composing.start : absStart;
      final afterStart = composing.end < absEnd ? composing.end : absEnd;
      if (beforeEnd > absStart) {
        children.add(TextSpan(text: text.substring(absStart, beforeEnd), style: st));
      }
      children.add(
        TextSpan(
          text: text.substring(beforeEnd, afterStart),
          style: st.copyWith(
            decoration: TextDecoration.underline,
            decorationColor: base.color,
          ),
        ),
      );
      if (afterStart < absEnd) {
        children.add(TextSpan(text: text.substring(afterStart, absEnd), style: st));
      }
    }

    var pos = 0;
    for (final s in spans) {
      if (s.start > pos) {
        push(pos, s.start, base);
      }
      push(s.start, s.end, _styleFor(s.token, base, colors));
      pos = s.end;
    }
    if (pos < text.length) {
      push(pos, text.length, base);
    }
    return children;
  }

  /// 词法单元 → 字形样式（仅颜色 / 斜体 / 删除线 / 等宽字体，**不使用加粗字重**，
  /// 加粗内容以专属颜色区分）。
  TextStyle _styleFor(
    MarkdownSyntaxToken token,
    TextStyle base,
    MarkdownSyntaxColors colors,
  ) {
    switch (token) {
      case MarkdownSyntaxToken.headingMarker:
      case MarkdownSyntaxToken.headingText:
        return base.copyWith(color: colors.heading);
      case MarkdownSyntaxToken.marker:
        return base.copyWith(color: colors.marker);
      case MarkdownSyntaxToken.linkText:
        return base.copyWith(
          color: colors.link,
          decoration: TextDecoration.underline,
          decorationColor: colors.link,
        );
      case MarkdownSyntaxToken.linkUrl:
      case MarkdownSyntaxToken.linkBracket:
      case MarkdownSyntaxToken.hr:
      case MarkdownSyntaxToken.dim:
        return base.copyWith(color: colors.dim);
      case MarkdownSyntaxToken.code:
        return base.copyWith(color: colors.code, fontFamily: 'monospace');
      case MarkdownSyntaxToken.blockquote:
        return base.copyWith(color: colors.blockquote, fontStyle: FontStyle.italic);
      case MarkdownSyntaxToken.bold:
        return base.copyWith(color: colors.bold);
      case MarkdownSyntaxToken.italic:
        return base.copyWith(fontStyle: FontStyle.italic);
      case MarkdownSyntaxToken.boldItalic:
        return base.copyWith(color: colors.bold, fontStyle: FontStyle.italic);
      case MarkdownSyntaxToken.strike:
        return base.copyWith(
          color: colors.dim,
          decoration: TextDecoration.lineThrough,
          decorationColor: colors.dim,
        );
      case MarkdownSyntaxToken.autolink:
        return base.copyWith(
          color: colors.link,
          decoration: TextDecoration.underline,
          decorationColor: colors.link,
        );
    }
  }
}
