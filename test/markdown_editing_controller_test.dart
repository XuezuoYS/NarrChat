import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/markdown_editing_controller.dart';

/// 展平 TextSpan 树，返回所有非空文本叶子。
List<TextSpan> _flatten(TextSpan root) {
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
String _combined(TextSpan root) =>
    _flatten(root).map((s) => s.text).join();

/// 在指定亮度主题下渲染一个含控制器的 TextField，返回其 BuildContext。
Future<BuildContext> _pumpField(
  WidgetTester tester,
  MarkdownEditingController c, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: TextField(controller: c)),
    ),
  );
  return tester.element(find.byType(TextField));
}

void main() {
  testWidgets('加粗文本以专属颜色区分且不加粗字重', (tester) async {
    final c = MarkdownEditingController(text: '**加粗**');
    final ctx = await _pumpField(tester, c);
    final span = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(fontSize: 15, color: Colors.black),
      withComposing: false,
    );
    final bold = _flatten(span).firstWhere((s) => s.text!.contains('加粗'));
    expect(bold.style?.color, MarkdownSyntaxColors.light.bold);
    expect(bold.style?.fontWeight, isNot(FontWeight.w700));
    expect(_combined(span), '**加粗**');
    c.dispose();
  });

  testWidgets('标题使用主题标题色（浅色，不加粗）', (tester) async {
    final c = MarkdownEditingController(text: '# 标题');
    final ctx = await _pumpField(tester, c);
    final span = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(color: Colors.black),
      withComposing: false,
    );
    final heading = _flatten(span).firstWhere((s) => s.text!.contains('标题'));
    expect(heading.style?.color, MarkdownSyntaxColors.light.heading);
    expect(heading.style?.fontWeight, isNot(FontWeight.w700));
    c.dispose();
  });

  testWidgets('深色主题使用深色标题色（不加粗）', (tester) async {
    final c = MarkdownEditingController(text: '# 标题');
    final ctx = await _pumpField(tester, c, brightness: Brightness.dark);
    final span = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(color: Colors.white),
      withComposing: false,
    );
    final heading = _flatten(span).firstWhere((s) => s.text!.contains('标题'));
    expect(heading.style?.color, MarkdownSyntaxColors.dark.heading);
    expect(heading.style?.fontWeight, isNot(FontWeight.w700));
    c.dispose();
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

  testWidgets('深色标题记号与正文同为标题红', (tester) async {
    final c = MarkdownEditingController(text: '# 标题');
    final ctx = await _pumpField(tester, c, brightness: Brightness.dark);
    final span = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(color: Colors.white),
      withComposing: false,
    );
    final parts = _flatten(span);
    expect(parts.firstWhere((s) => s.text == '#').style?.color,
        MarkdownSyntaxColors.dark.heading);
    expect(parts.firstWhere((s) => s.text == ' 标题').style?.color,
        MarkdownSyntaxColors.dark.heading);
    c.dispose();
  });

  testWidgets('深色链接括号红、文字蓝、URL 紫', (tester) async {
    final c = MarkdownEditingController(text: '[文字](https://a.b)');
    final ctx = await _pumpField(tester, c, brightness: Brightness.dark);
    final span = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(color: Colors.white),
      withComposing: false,
    );
    final parts = _flatten(span);
    expect(parts.firstWhere((s) => s.text == '[').style?.color,
        MarkdownSyntaxColors.dark.heading);
    expect(parts.firstWhere((s) => s.text == '文字').style?.color,
        MarkdownSyntaxColors.dark.link);
    expect(parts.firstWhere((s) => s.text == 'https://a.b').style?.color,
        MarkdownSyntaxColors.dark.linkUrl);
    c.dispose();
  });

  testWidgets('深色斜体为紫色斜体', (tester) async {
    final c = MarkdownEditingController(text: '*斜体*');
    final ctx = await _pumpField(tester, c, brightness: Brightness.dark);
    final span = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(color: Colors.white),
      withComposing: false,
    );
    final italic = _flatten(span).firstWhere((s) => s.text == '*斜体*');
    expect(italic.style?.color, MarkdownSyntaxColors.dark.linkUrl);
    expect(italic.style?.fontStyle, FontStyle.italic);
    c.dispose();
  });

  testWidgets('行内代码使用等宽字体与代码色', (tester) async {
    final c = MarkdownEditingController(text: '`code`');
    final ctx = await _pumpField(tester, c);
    final span = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(color: Colors.black),
      withComposing: false,
    );
    final code = _flatten(span).firstWhere((s) => s.text == '`code`');
    expect(code.style?.fontFamily, 'monospace');
    expect(code.style?.color, MarkdownSyntaxColors.light.code);
    c.dispose();
  });

  testWidgets('链接文字加下划线且 URL 紫色', (tester) async {
    final c = MarkdownEditingController(text: '[文字](https://a.b)');
    final ctx = await _pumpField(tester, c);
    final span = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(color: Colors.black),
      withComposing: false,
    );
    final parts = _flatten(span);
    final link = parts.firstWhere((s) => s.text == '文字');
    expect(link.style?.decoration, TextDecoration.underline);
    final url = parts.firstWhere((s) => s.text == 'https://a.b');
    expect(url.style?.color, MarkdownSyntaxColors.light.linkUrl);
    c.dispose();
  });

  testWidgets('组合区（IME 输入中）附加下划线', (tester) async {
    final c = MarkdownEditingController();
    c.value = const TextEditingValue(
      text: '**加粗**',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 2, end: 4), // 组合区 = “加粗”
    );
    final ctx = await _pumpField(tester, c);
    final span = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(color: Colors.black),
      withComposing: true,
    );
    final underlined = _flatten(span)
        .where((s) => s.style?.decoration == TextDecoration.underline)
        .toList();
    expect(underlined, isNotEmpty);
    expect(underlined.map((s) => s.text).join(), '加粗');
    expect(_combined(span), '**加粗**');
    c.dispose();
  });

  testWidgets('混合 Markdown 文本渲染后与原文完全一致', (tester) async {
    const t = '# 标题\n\n**加粗** 与 *斜体* 以及 `code`\n\n- 列表项\n> 引用\n\n---\n';
    final c = MarkdownEditingController(text: t);
    final ctx = await _pumpField(tester, c);
    final span = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(color: Colors.black),
      withComposing: false,
    );
    expect(_combined(span), t);
    c.dispose();
  });
}
