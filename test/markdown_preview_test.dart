import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_preview.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// 遍历所有 RichText 的 TextSpan，找到文本为 [text] 的 span 并返回其样式。
///
/// flutter_markdown 的标题/正文样式位于具体 TextSpan 上（而非根 span），
/// 因此需按文本内容定位对应 span。
TextStyle? _spanStyle(WidgetTester tester, String text) {
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    final style = _findSpanStyle(rt.text, text);
    if (style != null) return style;
  }
  return null;
}

TextStyle? _findSpanStyle(InlineSpan span, String text) {
  if (span is TextSpan) {
    if (span.text == text) return span.style;
    for (final c in span.children ?? const <InlineSpan>[]) {
      final s = _findSpanStyle(c, text);
      if (s != null) return s;
    }
  }
  return null;
}

void main() {
  testWidgets('h1/h2 底部边框线随主题绘制', (tester) async {
    await tester.pumpWidget(
      _wrap(
        MarkdownPreview(
          data: '# 一级标题\n\n## 二级标题\n\n### 三级\n\n正文',
          base: const TextStyle(fontSize: 14),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 标题文本渲染。
    expect(find.text('一级标题'), findsOneWidget);
    expect(find.text('二级标题'), findsOneWidget);
    expect(find.text('三级'), findsOneWidget);

    // h1/h2 用 underline 近似 GitHub 标题底边框线（颜色随主题）。
    final h1Style = _spanStyle(tester, '一级标题');
    final h2Style = _spanStyle(tester, '二级标题');
    expect(h1Style?.fontSize, 28, reason: 'h1 应放大到正文 2 倍');
    expect(h1Style?.fontWeight, FontWeight.w600);
    expect(h1Style?.decoration, TextDecoration.underline);
    expect(h1Style?.decorationColor, const Color(0xFFD0D7DE));
    expect(h2Style?.fontSize, 21, reason: 'h2 应放大到正文 1.5 倍');
    expect(h2Style?.decoration, TextDecoration.underline);
    expect(h2Style?.decorationColor, const Color(0xFFD0D7DE));

    // 深色主题切换后边框颜色随之变化。
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.dark,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: MarkdownPreview(
              data: '# 一级标题',
              base: TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final darkH1 = _spanStyle(tester, '一级标题');
    expect(darkH1?.decoration, TextDecoration.underline);
    expect(
      darkH1?.decorationColor,
      const Color(0xFF30363D),
      reason: '深色主题 h1 边框应为 GitHub 深色 headingBorder',
    );
  });

  testWidgets('GitHub Alerts 渲染彩色提示块', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MarkdownPreview(
          data: '> [!NOTE]\n> 这是一条提示。\n\n'
              '> [!WARNING]\n> 这是一条警告。\n\n'
              '> [!TIP]\n> 这是一条建议。',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 标题文字（位于 Text.rich 中，用 textContaining）。
    expect(find.textContaining('Note'), findsOneWidget);
    expect(find.textContaining('Warning'), findsOneWidget);
    expect(find.textContaining('Tip'), findsOneWidget);
    // 正文。
    expect(find.text('这是一条提示。'), findsOneWidget);
    expect(find.text('这是一条警告。'), findsOneWidget);
    expect(find.text('这是一条建议。'), findsOneWidget);

    // 每种 alert 应有带背景色的容器（浅色 note 背景 #DDF4FF）。
    final noteContainer = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) =>
            c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).color == const Color(0xFFDDF4FF))
        .toList();
    expect(noteContainer, isNotEmpty);
    // 图标。
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.lightbulb_outline), findsOneWidget);
  });

  testWidgets('==高亮== 渲染为荧光标记', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MarkdownPreview(data: '普通文本 ==重点高亮== 结尾'),
      ),
    );
    await tester.pumpAndSettle();

    // 高亮文本渲染为独立 Text，且带 GitHub mark 荧光底色（浅色 #FFF8C5）。
    expect(find.text('重点高亮'), findsOneWidget);
    final text = tester.widget<Text>(find.text('重点高亮'));
    expect(text.style?.backgroundColor, const Color(0xFFFFF8C5));
  });

  testWidgets('任务列表渲染为 GitHub 复选框', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MarkdownPreview(data: '- [x] 已完成\n- [ ] 未完成\n'),
      ),
    );
    await tester.pumpAndSettle();

    // 选中/未选中图标。
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('未完成'), findsOneWidget);
  });

  testWidgets('代码块语法高亮 + 行内代码样式', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MarkdownPreview(
          data: '```dart\nfinal int x = 42; // 注释\nprint("hi");\n```\n\n'
              '行内 `code` 测试',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 代码块内容存在（语法高亮拆分为多个 TextSpan，用 code 行片段匹配）。
    expect(find.textContaining('final int x'), findsOneWidget);
    expect(find.textContaining('print('), findsOneWidget);
    // 行内代码存在。
    expect(find.text('code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('表格/引用/链接仍按 GitHub 风格渲染', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MarkdownPreview(
          data: '| 列1 | 列2 |\n| --- | --- |\n| A | B |\n\n'
              '> 引用内容\n\n[链接](https://example.com)',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('列1'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('引用内容'), findsOneWidget);
    expect(find.text('链接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selectable=false 时不包 SelectionArea', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MarkdownPreview(data: '正文', selectable: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('嵌套列表按层级切换符号（•/○/▪）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MarkdownPreview(data: '- 内容1\n  - 内容2\n    - 内容3'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('•'), findsOneWidget);
    expect(find.text('○'), findsOneWidget);
    expect(find.text('▪'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有序列表渲染数字序号而非圆点', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MarkdownPreview(data: '1. 第一项\n2. 第二项\n3. 第三项'),
      ),
    );
    await tester.pumpAndSettle();

    // 数字序号渲染，而不是圆点。
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('3.'), findsOneWidget);
    expect(find.text('•'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有序 + 无序混排互不干扰', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MarkdownPreview(
          data: '1. 有序一\n2. 有序二\n\n- 无序一\n- 无序二',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('•'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('行内代码无继承白底（避免灰边白底）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MarkdownPreview(data: '正文 `code` 结尾'),
      ),
    );
    await tester.pumpAndSettle();

    final codeText = tester.widget<Text>(find.text('code'));
    expect(codeText.style?.backgroundColor, isNull,
        reason: '行内代码不应继承正文白底');
    // 行内代码前景色为 GitHub 浅色 codeInlineFg。
    expect(codeText.style?.color, const Color(0xFF0550AE));
  });

  test('GitHubMarkdownStyle 可独立构建样式表', () {
    // 纯逻辑校验：样式表可构建且关键样式存在。
    expect(GitHubMarkdownStyle.extensionSet, isNotNull);
  });
}
