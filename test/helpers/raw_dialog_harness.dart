import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

/// RAW 对话框用例的公共脚手架。
///
/// RAW 内容块的渲染形状是「一块一个 `SelectionArea`，块内按 2 万字符分段渲染多个
/// `RichText`」（见 `lib/widgets/raw_dialog.dart` 的 `_HighlightText`），于是两个
/// 惯用读法都失效：
/// - `find.byType(SelectableText)` 数不到内容块（如今只剩图片详情行还是它）；
/// - `find.text(...)` 读不到块内文字（默认不看裸 `RichText`）。
/// 统一走这里的 finder / 读取函数，`[dialog]` 一律传 `find.byType(RawDialog)`，
/// 免得命中对话框之外（底层对话气泡）的选中区域。

/// 对话框内展开着的 RAW 内容块（折叠的不计）。
Finder rawBlocks(Finder dialog) =>
    find.descendant(of: dialog, matching: find.byType(SelectionArea));

/// 第 [block] 个展开块里各段的 render paragraph（顺序与分段一致）。
List<RenderParagraph> rawParagraphs(
  Finder dialog,
  WidgetTester tester, {
  int block = 0,
}) {
  return tester
      .widgetList<RichText>(
        find.descendant(
          of: rawBlocks(dialog).at(block),
          matching: find.byType(RichText),
        ),
      )
      .map(
        (RichText w) => tester.renderObject<RenderParagraph>(find.byWidget(w)),
      )
      .toList();
}

/// 第 [block] 个展开块的上屏文字（分段渲染，拼回整块）。
String rawBlockText(Finder dialog, WidgetTester tester, {int block = 0}) =>
    rawParagraphs(
      dialog,
      tester,
      block: block,
    ).map((p) => p.text.toPlainText()).join();

/// 对话框内全部展开块的上屏文字（按上屏顺序）。
List<String> rawBlockTexts(Finder dialog, WidgetTester tester) => [
  for (var i = 0; i < rawBlocks(dialog).evaluate().length; i++)
    rawBlockText(dialog, tester, block: i),
];

/// 第 [block] 个展开块里全部 span（各段的子 span 平铺）。
List<InlineSpan> rawBlockSpans(
  Finder dialog,
  WidgetTester tester, {
  int block = 0,
}) {
  return rawParagraphs(
    dialog,
    tester,
    block: block,
  ).expand((p) => (p.text as TextSpan).children!).toList();
}

/// 第 [block] 个展开块内第 [flat] 个字符所在处的全局坐标。
///
/// 用 `RenderParagraph.getOffsetForCaret` 换算，避免手算字体度量；并向右下各偏移
/// 一点：返回矩形的**上边界**恰好落在行顶（实测 y ≈ -0.02px），该点在命中区外，
/// 指针事件根本到不了选中区域（拖动会「什么都不选中」）。
Offset rawOffsetAt(
  Finder dialog,
  WidgetTester tester,
  int flat, {
  int block = 0,
}) {
  const caret = Rect.fromLTWH(0.0, 0.0, 2.0, 20.0);
  var consumed = 0;
  for (final paragraph in rawParagraphs(dialog, tester, block: block)) {
    final length = paragraph.text.toPlainText().length;
    if (flat < consumed + length) {
      return paragraph.localToGlobal(
        paragraph.getOffsetForCaret(
              TextPosition(offset: flat - consumed),
              caret,
            ) +
            Offset(1, caret.height / 2),
      );
    }
    consumed += length;
  }
  throw StateError('偏移 $flat 超出块 $block 的长度 $consumed');
}

/// 第 [block] 个展开块各段的起始字符偏移（与全文偏移同轴，用于挑跨段样本）。
List<int> rawSegmentStarts(
  Finder dialog,
  WidgetTester tester, {
  int block = 0,
}) {
  final starts = <int>[];
  var consumed = 0;
  for (final paragraph in rawParagraphs(dialog, tester, block: block)) {
    starts.add(consumed);
    consumed += paragraph.text.toPlainText().length;
  }
  return starts;
}
