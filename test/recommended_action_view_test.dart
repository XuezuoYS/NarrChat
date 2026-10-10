import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/chat_bubble.dart';
import 'package:narrchat/widgets/recommended_action_view.dart';

/// 「推荐下一步」一次解析（P0-②）：选项行改为**内联 span**，不再每项一个
/// `MarkdownBody`。
///
/// 为什么值得钉死：每个选项各建一个 `MarkdownBody` = 每条选项各付一次块级解析
/// + 一整棵 Markdown 子树构建。实测一个 AI 气泡 6 次构树（正文 1 + 选项 5，
/// `.agents/2026-10-11-chat-ui-perf-plan.md`「P0-②」）。改造后构树次数 = 正文 1 + 非列表文本
/// 段数，选项为 0。
///
/// 与既有用例的分工：`chat_bubble_test.dart` 覆盖双击 / 单击 / 选中 / 复制等
/// 交互（集成层），`recommended_action_parser_test.dart` 覆盖切分规则；本文件
/// 只覆盖「渲染路径与构树次数」这一新增行为。
const String _action = '1. 上前行礼\n2. 询问掌门\n3. 自定义行动';

Widget _wrap(Widget child) => MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(body: Center(child: child)),
    );

/// 页面上所有 `Text.rich` 的内联 span 拍平成「文本 → 生效样式」（含继承）。
///
/// 从 `Text.style`（即 `Text.rich` 的 style）作为根开始，才能覆盖调用点传入的
/// 基样式（`base`），与渲染时的继承关系一致。
List<({String text, TextStyle? style})> _flattenedSpans(WidgetTester tester) {
  final out = <({String text, TextStyle? style})>[];

  void walk(InlineSpan span, TextStyle? inherited) {
    if (span is! TextSpan) return;
    var style = inherited;
    if (span.style != null) style = style?.merge(span.style!) ?? span.style;
    if (span.text != null) out.add((text: span.text!, style: style));
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final span = text.textSpan;
    if (span != null) walk(span, text.style);
  }
  return out;
}

/// 指定文本在页面上的**生效**样式（含继承）。
TextStyle? _styleOf(WidgetTester tester, String text) {
  for (final span in _flattenedSpans(tester)) {
    if (span.text == text) return span.style;
  }
  return null;
}

void main() {
  testWidgets('选项行不再各建一个 MarkdownBody（构树次数 = 非列表文本段数）', (tester) async {
    await tester.pumpWidget(
      _wrap(RecommendedActionView(data: _action, onInsert: (_) {})),
    );

    expect(
      find.descendant(
        of: find.byType(RecommendedActionView),
        matching: find.byType(MarkdownBody),
      ),
      findsNothing,
      reason: '选项走内联 span，整块不得再有块级构树',
    );
    // 选项文本仍完整上屏（每条一个 RichText），标记字符不残留。
    expect(find.text('上前行礼', findRichText: true), findsOneWidget);
    expect(find.text('询问掌门', findRichText: true), findsOneWidget);
    expect(find.text('自定义行动', findRichText: true), findsOneWidget);
    expect(find.textContaining('1. ', findRichText: true), findsNothing);
    // 列表符号列仍在（有序序号由符号构建器渲染）。
    expect(find.text('1.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非列表文本仍走块级解析（块级结构不能丢）', (tester) async {
    await tester.pumpWidget(
      _wrap(const RecommendedActionView(data: '前言说明。\n\n1. 甲\n2. 乙')),
    );

    expect(
      find.byType(MarkdownBody),
      findsOneWidget,
      reason: '只有非列表文本需要 MarkdownBody',
    );
    expect(find.text('前言说明。', findRichText: true), findsOneWidget);
    expect(find.text('甲', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选项内的行内 Markdown 仍生效（粗体 / 行内代码 / 链接）并继承 base', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const RecommendedActionView(
          data: '1. **加粗**与`代码`与[链接](https://example.com)',
          base: TextStyle(fontSize: 13),
        ),
      ),
    );

    final bold = _styleOf(tester, '加粗');
    expect(bold?.fontWeight, FontWeight.w600, reason: 'strong 仍加粗');
    expect(bold?.fontSize, 13, reason: '继承调用点传入的 base 字号');
    final code = _styleOf(tester, '代码');
    expect(code?.fontFamily, 'monospace', reason: '行内代码用等宽字体');
    expect(code?.fontSize, closeTo(13 * 0.85, 0.01));
    final link = _styleOf(tester, '链接');
    expect(link?.decoration, TextDecoration.underline, reason: '链接仍带下划线');
    // Markdown 标记字符不得出现在渲染文本里。
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('](', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单个 AI 气泡的 Markdown 构树次数 ≤ 2（P0-② 验收；改造前 6）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const ChatBubble(
          isUser: false,
          text: '## 剧情演绎\n\n山门巍峨。',
          recommendedAction: _action,
        ),
      ),
    );

    final bodies = find.descendant(
      of: find.byType(ChatBubble),
      matching: find.byType(MarkdownBody),
    );
    expect(bodies, findsOneWidget, reason: '正文 1 次 + 选项 0 次');
    expect(
      bodies.evaluate().length,
      lessThanOrEqualTo(2),
      reason: 'P0-② 验收：单气泡构树次数 ≤ 2（改造前 6）',
    );
    // 正文与选项都在屏上（避免「少构树 = 少内容」的假通过）。
    expect(find.text('山门巍峨。', findRichText: true), findsOneWidget);
    expect(find.text('上前行礼', findRichText: true), findsOneWidget);
  });
}
