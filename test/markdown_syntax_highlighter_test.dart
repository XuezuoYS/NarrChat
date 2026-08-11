import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/utils/markdown_syntax_highlighter.dart';

/// 取出指定 token 的所有区间文本，用 `|` 连接（便于断言）。
String _textOf(String text, MarkdownSyntaxToken token) {
  final spans = const MarkdownSyntaxHighlighter()
      .highlight(text)
      .where((s) => s.token == token)
      .toList();
  return spans.map((s) => text.substring(s.start, s.end)).join('|');
}

/// 断言区间互不重叠、按位置升序且不越界（纯文本片段允许无区间覆盖，
/// 由上层渲染时以基础样式补齐）。
void _expectCoverage(String text) {
  final spans = const MarkdownSyntaxHighlighter().highlight(text);
  var pos = 0;
  for (final s in spans) {
    expect(s.start, greaterThanOrEqualTo(pos), reason: '区间不应重叠');
    expect(s.end, greaterThan(s.start), reason: '区间应非空');
    expect(s.end, lessThanOrEqualTo(text.length), reason: '区间不应越界');
    pos = s.end;
  }
}

void main() {
  group('标题', () {
    test('`# 标题` 识别记号与正文', () {
      const t = '# 标题';
      expect(_textOf(t, MarkdownSyntaxToken.headingMarker), '#');
      expect(_textOf(t, MarkdownSyntaxToken.headingText), ' 标题');
    });

    test('无空格写法 `#标题` 也识别', () {
      const t = '#标题';
      expect(_textOf(t, MarkdownSyntaxToken.headingMarker), '#');
      expect(_textOf(t, MarkdownSyntaxToken.headingText), '标题');
    });

    test('多级标题 `### 三级`', () {
      const t = '### 三级';
      expect(_textOf(t, MarkdownSyntaxToken.headingMarker), '###');
    });

    test('6 个井号合法，7 个不识别为标题', () {
      expect(_textOf('###### 六', MarkdownSyntaxToken.headingMarker), '######');
      expect(_textOf('####### 七', MarkdownSyntaxToken.headingMarker), isEmpty);
    });

    test('非行首井号不识别', () {
      expect(_textOf('正文 # 不是标题', MarkdownSyntaxToken.headingMarker), isEmpty);
    });
  });

  group('分割线 / 引用 / 列表', () {
    test('`---` 识别为分割线', () {
      const t = '---';
      expect(_textOf(t, MarkdownSyntaxToken.hr), '---');
    });

    test('`* * *` 带空格也识别为分割线', () {
      const t = '* * *';
      expect(_textOf(t, MarkdownSyntaxToken.hr), '* * *');
    });

    test('`> 引用` 整行（含记号）为引用样式', () {
      const t = '> 引用内容';
      expect(_textOf(t, MarkdownSyntaxToken.marker), isEmpty);
      expect(_textOf(t, MarkdownSyntaxToken.blockquote), '> 引用内容');
    });

    test('`>text` 无空格也识别为引用', () {
      const t = '>text';
      expect(_textOf(t, MarkdownSyntaxToken.marker), isEmpty);
      expect(_textOf(t, MarkdownSyntaxToken.blockquote), '>text');
    });

    test('`>> 嵌套` 整体为引用样式', () {
      const t = '>> 嵌套';
      expect(_textOf(t, MarkdownSyntaxToken.marker), isEmpty);
      expect(_textOf(t, MarkdownSyntaxToken.blockquote), '>> 嵌套');
    });

    test('无序列表 `- 项目`', () {
      const t = '- 项目';
      expect(_textOf(t, MarkdownSyntaxToken.marker), '-');
      expect(_textOf(t, MarkdownSyntaxToken.headingText), isEmpty);
    });

    test('有序列表 `1. 项目` 与 `1) 项目`', () {
      expect(_textOf('1. 项目', MarkdownSyntaxToken.marker), '1.');
      expect(_textOf('1) 项目', MarkdownSyntaxToken.marker), '1)');
    });

    test('缩进列表 `  - 子项`', () {
      const t = '  - 子项';
      expect(_textOf(t, MarkdownSyntaxToken.marker), '-');
    });

    test('`-项目`（无空格）不识别为列表', () {
      expect(_textOf('-项目', MarkdownSyntaxToken.marker), isEmpty);
    });
  });

  group('行内代码 / 围栏代码', () {
    test('`` `code` `` 行内代码', () {
      const t = '使用 `code` 强调';
      expect(_textOf(t, MarkdownSyntaxToken.code), '`code`');
    });

    test('围栏代码块整块高亮（含语言标记行）', () {
      const t = '```dart\nvoid main() {}\n```\n后续';
      expect(_textOf(t, MarkdownSyntaxToken.code), '```dart\nvoid main() {}\n```');
      expect(_textOf(t, MarkdownSyntaxToken.headingText), isEmpty);
    });

    test('未闭合围栏按代码块处理', () {
      const t = '```\n未闭合';
      expect(_textOf(t, MarkdownSyntaxToken.code), '```\n未闭合');
    });

    test('围栏内 markdown 语法不参与行内高亮', () {
      const t = '```\n**加粗**\n```';
      expect(_textOf(t, MarkdownSyntaxToken.bold), isEmpty);
      expect(_textOf(t, MarkdownSyntaxToken.code), isNotEmpty);
    });
  });

  group('强调', () {
    test('`**加粗**`', () {
      const t = '**加粗**';
      expect(_textOf(t, MarkdownSyntaxToken.bold), '**加粗**');
    });

    test('`*斜体*`', () {
      const t = '*斜体*';
      expect(_textOf(t, MarkdownSyntaxToken.italic), '*斜体*');
    });

    test('`***粗斜***` 优先于加粗/斜体', () {
      const t = '***粗斜***';
      expect(_textOf(t, MarkdownSyntaxToken.boldItalic), '***粗斜***');
      expect(_textOf(t, MarkdownSyntaxToken.bold), isEmpty);
      expect(_textOf(t, MarkdownSyntaxToken.italic), isEmpty);
    });

    test('`__下划线加粗__` 与 `_下划线斜体_`', () {
      expect(_textOf('__加粗__', MarkdownSyntaxToken.bold), '__加粗__');
      expect(_textOf('_斜体_', MarkdownSyntaxToken.italic), '_斜体_');
    });

    test('单词中间的 `_` 不误伤（foo_bar）', () {
      expect(_textOf('foo_bar_baz', MarkdownSyntaxToken.italic), isEmpty);
    });

    test('单词中间 `*` 不识别（a*b*c）', () {
      expect(_textOf('a*b*c', MarkdownSyntaxToken.italic), isEmpty);
    });

    test('未闭合强调按普通文本', () {
      expect(_textOf('**未闭合', MarkdownSyntaxToken.bold), isEmpty);
    });

    test('`* 空格 *` 不识别为斜体', () {
      expect(_textOf('* 空格 *', MarkdownSyntaxToken.italic), isEmpty);
    });

    test('中文前后强调正常识别', () {
      expect(_textOf('他说：*强调*一下', MarkdownSyntaxToken.italic), '*强调*');
    });
  });

  group('删除线 / 转义 / 自动链接', () {
    test('`~~删除~~`', () {
      expect(_textOf('~~删除~~', MarkdownSyntaxToken.strike), '~~删除~~');
    });

    test('`\\*不斜体\\*` 反斜杠弱化、星号不触发强调', () {
      const t = r'\*不斜体\*';
      // 两个反斜杠各成一个 dim 区间，用 `|` 连接。
      expect(_textOf(t, MarkdownSyntaxToken.dim), '\\|\\');
      expect(_textOf(t, MarkdownSyntaxToken.italic), isEmpty);
    });

    test('`<https://example.com>` 自动链接', () {
      const t = '见 <https://example.com> 文档';
      expect(_textOf(t, MarkdownSyntaxToken.autolink), '<https://example.com>');
    });

    test('`<a@b.com>` 邮箱自动链接', () {
      const t = '<a@b.com>';
      expect(_textOf(t, MarkdownSyntaxToken.autolink), '<a@b.com>');
    });

    test('`<不是链接>` 不识别', () {
      expect(_textOf('<不是链接>', MarkdownSyntaxToken.autolink), isEmpty);
    });
  });

  group('链接 / 图片', () {
    test('`[文字](url)` 分段', () {
      const t = '[文字](https://a.b)';
      expect(_textOf(t, MarkdownSyntaxToken.linkText), '文字');
      expect(_textOf(t, MarkdownSyntaxToken.linkUrl), 'https://a.b');
      expect(_textOf(t, MarkdownSyntaxToken.linkBracket), '[|](|)');
    });

    test('`![图片](url)` 替代文字', () {
      const t = '![图片](img.png)';
      expect(_textOf(t, MarkdownSyntaxToken.linkText), '图片');
      expect(_textOf(t, MarkdownSyntaxToken.linkUrl), 'img.png');
    });

    test('链接文字内可含加粗（`[**粗**](u)`，整体为链接样式）', () {
      const t = '[**粗**](u)';
      expect(_textOf(t, MarkdownSyntaxToken.linkText), '**粗**');
      // 链接样式优先级高于强调，链接内不再单独识别加粗。
      expect(_textOf(t, MarkdownSyntaxToken.bold), isEmpty);
    });

    test('无括号目标不识别为链接', () {
      expect(_textOf('[只是方括号]', MarkdownSyntaxToken.linkText), isEmpty);
    });
  });

  group('区间完整性', () {
    test('多元素混合文本区间覆盖全文且不重叠', () {
      const t = '# 标题\n\n**加粗** 与 *斜体* 以及 `code`\n\n- 列表项\n> 引用\n\n---\n';
      _expectCoverage(t);
    });

    test('纯中文普通文本区间覆盖', () {
      _expectCoverage('这是一段没有任何标记的普通中文文本，用于验证覆盖完整性。');
    });
  });
}
