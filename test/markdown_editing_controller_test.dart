import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/markdown_editing_controller.dart';

/// MarkdownEditingController 语法高亮测试。
///
/// 收敛点：所有「输入文本 → 渲染 TextSpan → 断言某 token 样式」的用例
/// 共用 [renderSpans] / [firstWithText] helper，消除逐用例的 pump 样板。
void main() {
  /// 展平 TextSpan 树，返回所有非空文本叶子。
  List<TextSpan> flatten(TextSpan root) {
    final result = <TextSpan>[];
    void visit(TextSpan s) {
      if (s.text != null && s.text!.isNotEmpty) result.add(s);
      for (final child in s.children ?? const <InlineSpan>[]) {
        if (child is TextSpan) visit(child);
      }
    }

    visit(root);
    return result;
  }

  /// 所有叶子拼接文本（用于验证与原文一致）。
  String combined(TextSpan root) => flatten(root).map((s) => s.text).join();

  /// 在指定亮度主题下渲染控制器文本，返回展平后的全部叶子。
  Future<List<TextSpan>> renderSpans(
    WidgetTester tester,
    String text, {
    Brightness brightness = Brightness.light,
    bool withComposing = false,
    TextEditingValue? value,
  }) async {
    final c = MarkdownEditingController(text: text);
    if (value != null) {
      c.value = value;
    }
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(body: TextField(controller: c)),
      ),
    );
    final ctx = tester.element(find.byType(TextField));
    final span = c.buildTextSpan(
      context: ctx,
      style: TextStyle(
        fontSize: 15,
        color: brightness == Brightness.dark ? Colors.white : Colors.black,
      ),
      withComposing: withComposing,
    );
    return flatten(span);
  }

  /// 首个文本等于 [text] 的叶子。
  TextSpan firstWithText(List<TextSpan> spans, String text) =>
      spans.firstWhere((s) => s.text == text);

  testWidgets('加粗文本以专属颜色区分且不加粗字重', (tester) async {
    final spans = await renderSpans(tester, '**加粗**');
    final bold = spans.firstWhere((s) => s.text!.contains('加粗'));
    expect(bold.style?.color, MarkdownSyntaxColors.light.bold);
    expect(bold.style?.fontWeight, isNot(FontWeight.w700));
    expect(combined(TextSpan(children: spans)), '**加粗**');
  });

  test('深色主题配色与 VS Code One Dark Pro 一致', () {
    // 取值自 One Dark Pro themeData（classic 色板）。
    expect(MarkdownSyntaxColors.dark.heading, const Color(0xFFE06C75));
    expect(MarkdownSyntaxColors.dark.marker, const Color(0xFFE5C07B));
    expect(MarkdownSyntaxColors.dark.link, const Color(0xFF61AFEF));
    expect(MarkdownSyntaxColors.dark.linkUrl, const Color(0xFFC678DD));
    expect(MarkdownSyntaxColors.dark.code, const Color(0xFF98C379));
    expect(MarkdownSyntaxColors.dark.bold, const Color(0xFFD19A66));
    expect(MarkdownSyntaxColors.dark.blockquote, const Color(0xFF5C6370));
    expect(MarkdownSyntaxColors.dark.dim, const Color(0xFF5C6370));
  });

  testWidgets('标题使用主题标题色（浅色，不加粗）', (tester) async {
    final spans = await renderSpans(tester, '# 标题');
    final heading = spans.firstWhere((s) => s.text!.contains('标题'));
    expect(heading.style?.color, MarkdownSyntaxColors.light.heading);
    expect(heading.style?.fontWeight, isNot(FontWeight.w700));
    // 记号与正文同为标题红。
    expect(firstWithText(spans, '#').style?.color, MarkdownSyntaxColors.light.heading);
  });

  testWidgets('标题使用主题标题色（深色，不加粗）', (tester) async {
    final spans = await renderSpans(tester, '# 标题', brightness: Brightness.dark);
    final heading = spans.firstWhere((s) => s.text!.contains('标题'));
    expect(heading.style?.color, MarkdownSyntaxColors.dark.heading);
    expect(heading.style?.fontWeight, isNot(FontWeight.w700));
    // 记号与正文同为标题红。
    expect(firstWithText(spans, '#').style?.color, MarkdownSyntaxColors.dark.heading);
  });

  testWidgets('链接：括号红、文字蓝加下划线、URL 紫（浅色）', (tester) async {
    final spans = await renderSpans(tester, '[文字](https://a.b)');
    expect(
      firstWithText(spans, '[').style?.color,
      MarkdownSyntaxColors.light.heading,
      reason: '链接括号为标题红',
    );
    expect(
      firstWithText(spans, '文字').style?.color,
      MarkdownSyntaxColors.light.link,
      reason: '链接文字为链接色',
    );
    expect(
      firstWithText(spans, '文字').style?.decoration,
      TextDecoration.underline,
      reason: '链接文字加下划线',
    );
    expect(
      firstWithText(spans, 'https://a.b').style?.color,
      MarkdownSyntaxColors.light.linkUrl,
      reason: '链接 URL 为紫色',
    );
  });

  testWidgets('链接：括号红、文字蓝加下划线、URL 紫（深色）', (tester) async {
    final spans = await renderSpans(
      tester,
      '[文字](https://a.b)',
      brightness: Brightness.dark,
    );
    expect(
      firstWithText(spans, '[').style?.color,
      MarkdownSyntaxColors.dark.heading,
      reason: '链接括号为标题红',
    );
    expect(
      firstWithText(spans, '文字').style?.color,
      MarkdownSyntaxColors.dark.link,
      reason: '链接文字为链接色',
    );
    expect(
      firstWithText(spans, '文字').style?.decoration,
      TextDecoration.underline,
      reason: '链接文字加下划线',
    );
    expect(
      firstWithText(spans, 'https://a.b').style?.color,
      MarkdownSyntaxColors.dark.linkUrl,
      reason: '链接 URL 为紫色',
    );
  });

  testWidgets('斜体为紫色斜体（浅色）', (tester) async {
    final spans = await renderSpans(tester, '*斜体*');
    final italic = firstWithText(spans, '*斜体*');
    expect(italic.style?.color, MarkdownSyntaxColors.light.linkUrl);
    expect(italic.style?.fontStyle, FontStyle.italic);
  });

  testWidgets('斜体为紫色斜体（深色）', (tester) async {
    final spans = await renderSpans(tester, '*斜体*', brightness: Brightness.dark);
    final italic = firstWithText(spans, '*斜体*');
    expect(italic.style?.color, MarkdownSyntaxColors.dark.linkUrl);
    expect(italic.style?.fontStyle, FontStyle.italic);
  });

  testWidgets('行内代码使用等宽字体与代码色', (tester) async {
    final spans = await renderSpans(tester, '`code`');
    final code = firstWithText(spans, '`code`');
    expect(code.style?.fontFamily, 'monospace');
    expect(code.style?.color, MarkdownSyntaxColors.light.code);
  });

  testWidgets('组合区（IME 输入中）附加下划线', (tester) async {
    final spans = await renderSpans(
      tester,
      '',
      withComposing: true,
      value: const TextEditingValue(
        text: '**加粗**',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4), // 组合区 = “加粗”
      ),
    );
    final underlined = spans
        .where((s) => s.style?.decoration == TextDecoration.underline)
        .toList();
    expect(underlined, isNotEmpty);
    expect(underlined.map((s) => s.text).join(), '加粗');
    expect(combined(TextSpan(children: spans)), '**加粗**');
  });

  testWidgets('混合 Markdown 文本渲染后与原文完全一致', (tester) async {
    const t = '# 标题\n\n**加粗** 与 *斜体* 以及 `code`\n\n- 列表项\n> 引用\n\n---\n';
    final spans = await renderSpans(tester, t);
    expect(combined(TextSpan(children: spans)), t);
  });
}
