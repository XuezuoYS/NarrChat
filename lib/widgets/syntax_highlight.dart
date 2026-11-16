import 'package:flutter/material.dart';

import '../utils/syntax_highlight_span.dart';

/// 「词法单元 → 字形样式」的解析器。
///
/// 同一次构建里只算一次（如先取主题配色），再按 token 复用，避免每个区间都做
/// 一次主题查找。见 [SyntaxHighlightingController.stylesFor]。
typedef SyntaxStyleResolver<T> = TextStyle Function(T token);

/// 把词法区间铺满 [text]，返回可直接放进 `Text.rich` / [TextSpan.children] 的
/// 子级列表。
///
/// 约定 [spans] 按位置升序、互不重叠（各语言的词法分析器负责保证）：
/// - 区间之间的空隙（空白、未识别字符）用 [base] 渲染；
/// - 区间内的文本用 [styleOf] 的返回值渲染；
/// - [composing] 非空时，与该区间相交的文本附加下划线（输入法组合区），
///   并切成「前 / 组合区 / 后」三段，保证不会漏字或重复。
///
/// 编辑器控制器（[SyntaxHighlightingController]）与只读展示组件共用本函数，
/// 两边的换行、组合区与样式边界行为因此完全一致。
List<TextSpan> buildSyntaxHighlightSpans<T>({
  required String text,
  required List<SyntaxHighlightSpan<T>> spans,
  required TextStyle base,
  required SyntaxStyleResolver<T> styleOf,
  TextRange? composing,
}) {
  final children = <TextSpan>[];

  void push(int start, int end, TextStyle style) {
    if (end <= start) return;
    final piece = text.substring(start, end);
    if (composing == null ||
        composing.isCollapsed ||
        end <= composing.start ||
        start >= composing.end) {
      children.add(TextSpan(text: piece, style: style));
      return;
    }
    // 与组合区相交：切分为 前 / 组合区（加下划线）/ 后 三段。
    final beforeEnd = composing.start > start ? composing.start : start;
    final afterStart = composing.end < end ? composing.end : end;
    if (beforeEnd > start) {
      children.add(TextSpan(text: text.substring(start, beforeEnd), style: style));
    }
    children.add(
      TextSpan(
        text: text.substring(beforeEnd, afterStart),
        style: style.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: base.color,
        ),
      ),
    );
    if (afterStart < end) {
      children.add(TextSpan(text: text.substring(afterStart, end), style: style));
    }
  }

  var position = 0;
  for (final span in spans) {
    if (span.start > position) {
      push(position, span.start, base);
    }
    push(span.start, span.end, styleOf(span.token));
    position = span.end;
  }
  if (position < text.length) {
    push(position, text.length, base);
  }
  return children;
}

/// 语法高亮输入控制器的公共骨架。
///
/// 子类只需给出两件事：
/// - [highlightSpans]：文本 → 词法区间；
/// - [stylesFor]：词法单元 → 字形样式。
///
/// 其余（按位置铺满全文、输入法组合区下划线）由本类统一处理，各语言编辑器的
/// 边界行为因此保持一致。用法与普通 [TextEditingController] 完全一致：
/// 把 `TextField` 的 `controller` 换成本类的子类即可，多行、光标、选择、IME、
/// 键盘类型等行为都不变。
abstract class SyntaxHighlightingController<T> extends TextEditingController {
  SyntaxHighlightingController({super.text});

  /// 计算 [text] 的词法区间（按位置升序、互不重叠）。
  List<SyntaxHighlightSpan<T>> highlightSpans(String text);

  /// 构造「词法单元 → 字形样式」解析器；[base] 为正文基样式。
  ///
  /// 每次 [buildTextSpan] 调用一次（而不是每个区间一次），主题查找、配色
  /// 缓存等只需在解析器构造时做一遍。
  SyntaxStyleResolver<T> stylesFor(BuildContext context, TextStyle base);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    assert(
      !value.composing.isValid || !withComposing || value.isComposingRangeValid,
    );

    final base = style ?? const TextStyle();
    final composing =
        withComposing && value.isComposingRangeValid ? value.composing : null;
    return TextSpan(
      style: base,
      children: buildSyntaxHighlightSpans<T>(
        text: text,
        spans: highlightSpans(text),
        base: base,
        styleOf: stylesFor(context, base),
        composing: composing,
      ),
    );
  }
}
