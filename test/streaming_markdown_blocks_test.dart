import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/utils/streaming_markdown_blocks.dart';

/// 断言切分无损：块与尾部拼接必须逐字节等于源文本。
void _expectLossless(String source) {
  final split = splitStreamingMarkdownBlocks(source);
  expect(
    '${split.blocks.join()}${split.tail}',
    source,
    reason: '切分只做分块，不得增删字符',
  );
}

void main() {
  test('空文本 / 无空行：不切分', () {
    expect(splitStreamingMarkdownBlocks('').blocks, isEmpty);
    expect(splitStreamingMarkdownBlocks('').tail, '');

    // 一段话持续增长（没有空行）时不切分：内容等价于现状。
    const growing = '雨停了，林昭把斗笠往下压了压，朝南门走去。';
    final split = splitStreamingMarkdownBlocks(growing);
    expect(split.blocks, isEmpty);
    expect(split.tail, growing);
  });

  test('空行分段：完整段落冻结，最后一块留在尾部', () {
    final split = splitStreamingMarkdownBlocks('第一段。\n\n第二段还没写完');
    expect(split.blocks, ['第一段。\n\n']);
    expect(split.tail, '第二段还没写完');
    _expectLossless('第一段。\n\n第二段还没写完');
  });

  test('段内单个换行不切分（软换行不能变成段间空行）', () {
    final split = splitStreamingMarkdownBlocks('第一行\n第二行\n\n第三段');
    expect(
      split.blocks,
      ['第一行\n第二行\n\n'],
      reason: '段内换行是软换行，切开会造成可见的排版跳变',
    );
    expect(split.tail, '第三段');
  });

  test('以空行结尾时整块冻结（下一增量不会改前文）', () {
    final split = splitStreamingMarkdownBlocks('第一段。\n\n第二段。\n\n');
    expect(split.blocks, ['第一段。\n\n', '第二段。\n\n']);
    expect(split.tail, '');
    _expectLossless('第一段。\n\n第二段。\n\n');
  });

  test('列表 / 引用 / 表格之后的空行不切分（可能与后续内容合并成同一块）', () {
    for (final source in <String>[
      '- 甲\n\n- 乙', // 松散列表
      '- 甲\n- 乙\n\n正文', // 列表续接
      '1. 甲\n\n2. 乙', // 有序列表
      '  - 缩进列表项\n\n- 乙', // 前导空白续行
      '> 引用\n\n正文', // 引用
      '| 甲 | 乙 |\n\n正文', // 表格
      '标题\n===\n\n正文', // setext 下划线
      '---\n\n正文', // 分割线（其上一行可能是段落，故分割线本身不作切分点前一行）
    ]) {
      expect(
        splitStreamingMarkdownBlocks(source).blocks,
        isEmpty,
        reason: '不应在「$source」处切分',
      );
      _expectLossless(source);
    }
  });

  test('代码围栏：内部空行不切分，闭合后可切分', () {
    // 未闭合围栏：其后一律不切分。
    const unclosed = '```dart\nif (a) {\n\n  b();\n';
    expect(splitStreamingMarkdownBlocks(unclosed).blocks, isEmpty);
    _expectLossless(unclosed);

    // 已闭合围栏：结束行之后的空行是合法切分点（前缀含围栏结束行）。
    const closed = '```dart\nfinal a = 1;\n\nfinal b = 2;\n```\n\n正文';
    final split = splitStreamingMarkdownBlocks(closed);
    expect(split.blocks, ['```dart\nfinal a = 1;\n\nfinal b = 2;\n```\n\n']);
    expect(split.tail, '正文');
    _expectLossless(closed);

    // 围栏**之前**的空行照常可切分（围栏整体留在尾部）。
    const beforeFence = '正文段。\n\n```dart\n还没写完';
    final split2 = splitStreamingMarkdownBlocks(beforeFence);
    expect(split2.blocks, ['正文段。\n\n']);
    expect(split2.tail, '```dart\n还没写完');
  });

  test('可跨空行的原始 HTML 块内部不切分', () {
    const source = '<!--\n注释里的空行\n\n仍然在注释里\n-->\n\n正文';
    final split = splitStreamingMarkdownBlocks(source);
    expect(
      split.blocks,
      ['<!--\n注释里的空行\n\n仍然在注释里\n-->\n\n'],
      reason: '注释块结束行之后的空行才是切分点',
    );
    expect(split.tail, '正文');
    _expectLossless(source);

    // 未闭合的 script 块：内部空行不切分。
    const script = '<script>\nvar a = 1;\n\nvar b = 2;\n';
    expect(splitStreamingMarkdownBlocks(script).blocks, isEmpty);
  });

  test('引用定义是文档级语义：出现后停止切分', () {
    const source = '正文一。\n\n[参考]: https://example.com\n\n正文二。';
    final split = splitStreamingMarkdownBlocks(source);
    expect(split.blocks, ['正文一。\n\n']);
    expect(
      split.tail,
      '[参考]: https://example.com\n\n正文二。',
      reason: '定义必须留在尾部，与后续引用同块解析',
    );
    _expectLossless(source);

    // 定义恰在开头：任何内容都不冻结（定义后续可能被引用）。
    expect(
      splitStreamingMarkdownBlocks('[参考]: https://example.com\n\n正文。').blocks,
      isEmpty,
    );
  });

  test('CRLF：切分点保留原始换行符', () {
    const source = '第一段。\r\n\r\n第二段。';
    final split = splitStreamingMarkdownBlocks(source);
    expect(split.blocks, ['第一段。\r\n\r\n']);
    expect(split.tail, '第二段。');
    _expectLossless(source);
  });

  test('标题 / 行首内联标记可作切分点前半行', () {
    final split = splitStreamingMarkdownBlocks('## 剧情演绎\n\n**加粗**开头的一段\n\n下一段');
    expect(split.blocks, ['## 剧情演绎\n\n', '**加粗**开头的一段\n\n']);
    expect(split.tail, '下一段');
    _expectLossless('## 剧情演绎\n\n**加粗**开头的一段\n\n下一段');
  });

  test('逐字增长：切分结果单调且始终无损', () {
    const full = '第一段。\n\n第二段。\n\n- 甲\n\n收尾段落。\n\n```\n代码\n';
    var previous = <String>[];
    for (var length = 0; length <= full.length; length++) {
      final prefix = full.substring(0, length);
      final split = splitStreamingMarkdownBlocks(prefix);

      expect(
        '${split.blocks.join()}${split.tail}',
        prefix,
        reason: '长度 $length 的切分必须无损',
      );
      expect(
        split.blocks.length,
        greaterThanOrEqualTo(previous.length),
        reason: '已冻结的块不得被回收（长度 $length）',
      );
      for (var i = 0; i < previous.length; i++) {
        expect(split.blocks[i], previous[i], reason: '旧块内容不得变化');
      }
      previous = split.blocks;
    }
    // 该文本最终应冻结到围栏开始之前（列表项之后的空行不切分）。
    expect(previous.last, '- 甲\n\n收尾段落。\n\n');
  });
}
