import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/utils/json_syntax_highlighter.dart';

/// [JsonSyntaxHighlighter] 的隔离测试：只验证「文本 → 词法区间」。
///
/// 配色与渲染分别在 `json_view_test` / `json_editing_controller_test` 覆盖，
/// 这里不涉及 Flutter UI 与颜色。
void main() {
  const highlighter = JsonSyntaxHighlighter();

  /// 文本内容**恰好等于** [fragment] 的区间（找不到即失败）。
  JsonHighlightSpan spanOf(
    String text,
    List<JsonHighlightSpan> spans,
    String fragment,
  ) {
    for (final span in spans) {
      if (text.substring(span.start, span.end) == fragment) return span;
    }
    fail(
      '未找到文本为「$fragment」的区间，'
      '实际区间：${spans.map((s) => text.substring(s.start, s.end)).toList()}',
    );
  }

  group('字符串', () {
    test('键名与字符串值按「闭合引号后是否紧跟冒号」区分', () {
      const text = '{"a": "b"}';
      final spans = highlighter.highlight(text);

      expect(spanOf(text, spans, '"a"').token, JsonSyntaxToken.key);
      expect(spanOf(text, spans, '"b"').token, JsonSyntaxToken.string);
    });

    test('键名与冒号之间允许空白', () {
      const text = '{"a"  : 1}';
      final spans = highlighter.highlight(text);

      expect(spanOf(text, spans, '"a"').token, JsonSyntaxToken.key);
      expect(spanOf(text, spans, '1').token, JsonSyntaxToken.number);
    });

    test('转义引号不会提前结束字符串', () {
      const text = r'"a\"b"';
      final spans = highlighter.highlight(text);

      expect(spans, hasLength(1));
      expect(text.substring(spans.single.start, spans.single.end), r'"a\"b"');
      expect(spans.single.token, JsonSyntaxToken.string);
    });

    test('未闭合字符串止于行尾，不把下一行染色', () {
      const text = '{"a": "open\n"b": 1}';
      final spans = highlighter.highlight(text);

      expect(spanOf(text, spans, '"open').token, JsonSyntaxToken.string);
      expect(spanOf(text, spans, '"b"').token, JsonSyntaxToken.key);
      expect(spanOf(text, spans, '1').token, JsonSyntaxToken.number);
    });

    test('中文键值同样正确切分', () {
      const text = '{"键": "值"}';
      final spans = highlighter.highlight(text);

      expect(spanOf(text, spans, '"键"').token, JsonSyntaxToken.key);
      expect(spanOf(text, spans, '"值"').token, JsonSyntaxToken.string);
    });
  });

  group('数字与字面量', () {
    test('整数 / 负数 / 小数 / 指数', () {
      const text = '[1, -2, 3.5, -4e10, 5E-2]';
      final spans = highlighter.highlight(text);

      for (final fragment in ['1', '-2', '3.5', '-4e10', '5E-2']) {
        expect(
          spanOf(text, spans, fragment).token,
          JsonSyntaxToken.number,
          reason: '「$fragment」应为数字',
        );
      }
    });

    test('true / false / null 识别为字面量', () {
      const text = '[true, false, null]';
      final spans = highlighter.highlight(text);

      for (final fragment in ['true', 'false', 'null']) {
        expect(
          spanOf(text, spans, fragment).token,
          JsonSyntaxToken.keyword,
          reason: '「$fragment」应为字面量',
        );
      }
    });

    test('词内不当成字面量（truex 不着色）', () {
      expect(highlighter.highlight('truex'), isEmpty);
      expect(highlighter.highlight('false_'), isEmpty);
    });

    test('「-」后没有数字时不算数字', () {
      const text = '[-]';
      final spans = highlighter.highlight(text);

      expect(spans, hasLength(2), reason: '只有两个方括号被着色');
      expect(
        spans.every((s) => s.token == JsonSyntaxToken.punctuation),
        isTrue,
      );
    });

    test('「1.」只把 1 当数字（点后没有数字不并入）', () {
      const text = '1.';
      final spans = highlighter.highlight(text);

      expect(spans, hasLength(1));
      expect(text.substring(spans.single.start, spans.single.end), '1');
      expect(spans.single.token, JsonSyntaxToken.number);
    });
  });

  group('标点与空隙', () {
    test('结构标点逐个着色', () {
      const text = '{}[],:';
      final spans = highlighter.highlight(text);

      expect(spans, hasLength(6));
      expect(
        spans.every((s) => s.token == JsonSyntaxToken.punctuation),
        isTrue,
      );
    });

    test('空白与无法识别的字符不着色', () {
      expect(highlighter.highlight(''), isEmpty);
      expect(highlighter.highlight('  \n\t '), isEmpty);
      expect(highlighter.highlight('hello world'), isEmpty);
    });
  });

  group('区间不变量', () {
    test('升序、不重叠、不越界，且空隙拼回后与原文逐字一致', () {
      const text = '{\n  "键": [1, -2.5e3, true, null],\n  "a": {"b": "值"}\n}';
      final spans = highlighter.highlight(text);

      var previousEnd = 0;
      final buffer = StringBuffer();
      for (final span in spans) {
        expect(span.start, greaterThanOrEqualTo(previousEnd), reason: '区间需升序且不重叠');
        expect(span.end, greaterThan(span.start), reason: '区间不能为空');
        expect(span.end, lessThanOrEqualTo(text.length), reason: '区间不能越界');
        buffer
          ..write(text.substring(previousEnd, span.start))
          ..write(text.substring(span.start, span.end));
        previousEnd = span.end;
      }
      buffer.write(text.substring(previousEnd));

      expect(buffer.toString(), text);
    });

    test('超长压缩 JSON 完整覆盖且不重叠', () {
      final text = List.generate(200, (i) => '{"k$i": [$i, "v$i"]}').join(',');

      final spans = highlighter.highlight(text);

      expect(spans, isNotEmpty);
      var previousEnd = 0;
      for (final span in spans) {
        expect(span.start, greaterThanOrEqualTo(previousEnd));
        previousEnd = span.end;
      }
      expect(previousEnd, lessThanOrEqualTo(text.length));
    });
  });
}
