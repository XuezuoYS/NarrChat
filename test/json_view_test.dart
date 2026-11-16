import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/json_syntax_colors.dart';
import 'package:narrchat/widgets/json_view.dart';

import 'helpers/span_helpers.dart';

/// [JsonView] 展示组件的隔离测试：格式化、着色、行号、选中与布局约定。
void main() {
  Widget wrap(Widget child, {Brightness brightness = Brightness.light}) =>
      MaterialApp(
        theme: brightness == Brightness.dark
            ? NarrChatTheme.dark
            : NarrChatTheme.light,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  /// 行号栏的文本只由数字行组成（用于把它和正文 RichText 区分开）。
  bool looksLikeLineNumbers(String text) =>
      text.split('\n').every((line) => int.tryParse(line) != null);

  /// 正文 RichText（排除行号栏）。
  RichText contentOf(WidgetTester tester) {
    final candidates = tester
        .widgetList<RichText>(find.byType(RichText))
        .where((rt) => !looksLikeLineNumbers(rt.text.toPlainText()))
        .toList();
    expect(candidates, hasLength(1), reason: '应恰好有一个正文 RichText');
    return candidates.single;
  }

  group('格式化', () {
    testWidgets('默认把压缩 JSON 展开为 2 空格缩进', (tester) async {
      await tester.pumpWidget(wrap(const JsonView(data: '{"a":1,"b":[2]}')));

      expect(
        contentOf(tester).text.toPlainText(),
        '{\n  "a": 1,\n  "b": [\n    2\n  ]\n}',
      );
    });

    testWidgets('prettyPrint 为 false 时保留原文（仅归一化换行）', (tester) async {
      await tester.pumpWidget(
        wrap(const JsonView(data: '{"a":1}\r\n', prettyPrint: false)),
      );

      expect(contentOf(tester).text.toPlainText(), '{"a":1}\n');
    });

    testWidgets('非法 JSON 回退原文，不报错也不清空内容', (tester) async {
      await tester.pumpWidget(wrap(const JsonView(data: '{"a": ')));

      expect(contentOf(tester).text.toPlainText(), '{"a": ');
    });
  });

  group('着色', () {
    testWidgets('键名 / 字符串 / 数字 / 字面量 / 标点各用专属颜色（浅色）', (tester) async {
      await tester.pumpWidget(
        wrap(const JsonView(data: '{"a": "b", "n": 1.5, "t": true}')),
      );
      final root = contentOf(tester).text;

      expect(spanWithText(root, '"a"').style?.color, JsonSyntaxColors.light.key);
      expect(
        spanWithText(root, '"b"').style?.color,
        JsonSyntaxColors.light.string,
      );
      expect(
        spanWithText(root, '1.5').style?.color,
        JsonSyntaxColors.light.number,
      );
      expect(
        spanWithText(root, 'true').style?.color,
        JsonSyntaxColors.light.keyword,
      );
      expect(
        spanWithText(root, '{').style?.color,
        JsonSyntaxColors.light.punctuation,
      );
    });

    testWidgets('深色主题换用深色调色板', (tester) async {
      await tester.pumpWidget(
        wrap(
          const JsonView(data: '{"a": 1}'),
          brightness: Brightness.dark,
        ),
      );
      final root = contentOf(tester).text;

      expect(spanWithText(root, '"a"').style?.color, JsonSyntaxColors.dark.key);
      expect(
        spanWithText(root, '1').style?.color,
        JsonSyntaxColors.dark.number,
      );
    });

    testWidgets('解析失败时原文依旧着色', (tester) async {
      await tester.pumpWidget(wrap(const JsonView(data: '{"a": ')));
      final root = contentOf(tester).text;

      expect(spanWithText(root, '"a"').style?.color, JsonSyntaxColors.light.key);
    });
  });

  group('行号', () {
    testWidgets('showLineNumbers 打开时逐行显示行号', (tester) async {
      await tester.pumpWidget(
        wrap(
          const JsonView(data: '{\n"a": 1\n}', prettyPrint: false, showLineNumbers: true),
        ),
      );

      expect(find.text('1\n2\n3'), findsOneWidget);
    });

    testWidgets('行号不参与选中（复制正文不会带上行号）', (tester) async {
      await tester.pumpWidget(
        wrap(
          const JsonView(data: '{\n"a": 1\n}', prettyPrint: false, showLineNumbers: true),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(SelectionArea),
          matching: find.text('1\n2\n3'),
        ),
        findsNothing,
      );
    });

    testWidgets('默认不显示行号', (tester) async {
      await tester.pumpWidget(wrap(const JsonView(data: '{}')));

      expect(find.text('1'), findsNothing);
    });

    testWidgets('行号栏与正文逐行对齐（同字号同行高）', (tester) async {
      await tester.pumpWidget(
        wrap(
          const JsonView(
            data: '{\n"a": 1\n}',
            prettyPrint: false,
            showLineNumbers: true,
          ),
        ),
      );
      final content = contentOf(tester);

      final gutterHeight = tester.getSize(find.text('1\n2\n3')).height;
      final contentHeight = tester.getSize(find.byWidget(content)).height;
      expect(gutterHeight, contentHeight, reason: '行号与正文必须同高，否则逐行错位');
    });

    testWidgets('数据变化后行号随行数刷新', (tester) async {
      await tester.pumpWidget(
        wrap(const JsonView(data: '{"a":1}', showLineNumbers: true)),
      );
      expect(find.text('1\n2\n3'), findsOneWidget);

      await tester.pumpWidget(
        wrap(const JsonView(data: '{"a":1,"b":2}', showLineNumbers: true)),
      );
      expect(find.text('1\n2\n3\n4'), findsOneWidget);
    });
  });

  group('选中与布局', () {
    testWidgets('默认可选中，selectable 为 false 时不建选中区域', (tester) async {
      await tester.pumpWidget(wrap(const JsonView(data: '{"a":1}')));
      expect(find.byType(SelectionArea), findsOneWidget);

      await tester.pumpWidget(
        wrap(const JsonView(data: '{"a":1}', selectable: false)),
      );
      expect(find.byType(SelectionArea), findsNothing);
    });

    testWidgets('长行不折行，改由横向滚动承载', (tester) async {
      final longValue = 'x' * 300;
      await tester.pumpWidget(
        wrap(JsonView(data: '{"a":"$longValue"}', prettyPrint: false)),
      );

      expect(contentOf(tester).softWrap, isFalse);
      expect(
        find.byWidgetPredicate(
          (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
        ),
        findsOneWidget,
      );
    });
  });

  group('数据更新', () {
    testWidgets('data 变化后重新解析并重新着色', (tester) async {
      await tester.pumpWidget(wrap(const JsonView(data: '{"a":1}')));
      expect(contentOf(tester).text.toPlainText(), '{\n  "a": 1\n}');

      await tester.pumpWidget(wrap(const JsonView(data: '{"b":2}')));
      final root = contentOf(tester).text;
      expect(root.toPlainText(), '{\n  "b": 2\n}');
      expect(spanWithText(root, '"b"').style?.color, JsonSyntaxColors.light.key);
    });

    testWidgets('空文本不抛异常', (tester) async {
      await tester.pumpWidget(wrap(const JsonView(data: '')));

      expect(contentOf(tester).text.toPlainText(), '');
    });
  });
}
