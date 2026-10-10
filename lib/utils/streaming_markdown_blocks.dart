/// 流式 Markdown 的**块级切分**（纯函数，不依赖 Flutter / 渲染层）。
///
/// 目的：让「每帧都在增长的流式正文」在渲染时只重排**未完成的尾部残块**，
/// 已写完的块只解析一次即可冻结复用（调用方见
/// `lib/widgets/streaming_markdown.dart`）。
///
/// ## 为什么只在空行处切分
/// 空行是 Markdown 里唯一「终止前一块、且后文无法再改写其含义」的边界。
/// 本函数因此：
/// - 只把**空行**当作候选切分点；
/// - 仅当空行**上一行是封闭块的行**（普通段落行 / ATX 标题行，或已闭合围栏
///   代码块的结束行）时才真正切分——列表项、引用、表格行、缩进（前导空白）
///   行之后的空行一律不切，因为它们可能与后续内容合并成同一个块（最典型的
///   是「`- a` / 空行 / `- b`」会被解析成同一个松散列表）；
/// - 段内**单个换行绝不切分**：Markdown 把段内换行当软换行（默认渲染为空格），
///   切开会把它变成段间空行，造成可见的排版跳变；
/// - 围栏代码块（``` / ~~~）与**可跨空行的原始 HTML 块**（`<script>` / `<pre>` /
///   `<!--` 等）内部的空行不切分；未闭合的围栏之后一律不切分；
/// - 链接 / 脚注引用定义（`[x]: url`）是**文档级**语义：一经出现即停止切分，
///   让定义始终留在尾部、与后续引用同块解析，避免把引用渲染成字面量。
///
/// ## 不变量
/// - `blocks.join('') + tail == source`：切分只做分块，不增删字符；
/// - 对同一文本的**前缀序列**（流式逐字增长），结果单调：`blocks` 只增不减，
///   已给出的块永不被回收。
library;

/// 块切分结果。
///
/// - [blocks]：可冻结的完整块，按顺序拼接即 `source` 的前缀；
/// - [tail]：仍需每帧重建的未完成尾部（可能为空串）。
typedef StreamingMarkdownSplit = ({List<String> blocks, String tail});

/// 把一个（可能只写了一半的）Markdown 源文本切成「可冻结块 + 未完成尾部」。
StreamingMarkdownSplit splitStreamingMarkdownBlocks(String source) {
  if (source.isEmpty) return (blocks: const <String>[], tail: '');

  final lines = _splitSourceLines(source);
  _resolveLineStates(lines);

  final blocks = <String>[];
  var cursor = 0; // 已归入 blocks 的字符数（= 冻结前缀长度）
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    // 引用定义是文档级语义：此后不再切分（定义留在尾部与引用同块解析）。
    if (line.isReferenceDefinition) break;
    if (!line.isBlank || line.inVerbatimBlock) {
      i++;
      continue;
    }
    // 连续空行区间 [i, j)：切分点取区间末尾（空行也归入前缀）。
    var j = i;
    while (j < lines.length && lines[j].isBlank && !lines[j].inVerbatimBlock) {
      j++;
    }
    if (i > 0) {
      final prev = lines[i - 1];
      if (prev.isFenceClose || _isSelfContainedLine(prev.text)) {
        final boundary = lines[j - 1].end;
        if (boundary > cursor) {
          blocks.add(source.substring(cursor, boundary));
          cursor = boundary;
        }
      }
    }
    i = j;
  }

  return (blocks: blocks, tail: source.substring(cursor));
}

/// 源文本的一行（保留行尾偏移，供无损切分用）。
class _SourceLine {
  _SourceLine({required this.text, required this.end});

  /// 行内容（不含行尾换行）。
  final String text;

  /// 行尾换行之后的偏移（末行无换行时 = 该行末尾）。
  final int end;

  /// 是否空行（只含空白字符）。
  late final bool isBlank = text.trim().isEmpty;

  /// 是否处在围栏代码块 / 原始 HTML 块内部（含开始行与结束行）。
  bool inVerbatimBlock = false;

  /// 是否围栏代码块的**结束行**。
  bool isFenceClose = false;

  /// 是否文档级引用定义行（冻结屏障，见文件头）。
  bool isReferenceDefinition = false;
}

/// 按 `\n` / `\r\n` / `\r` 切行，并记录每行行尾之后的偏移。
List<_SourceLine> _splitSourceLines(String source) {
  final lines = <_SourceLine>[];
  var start = 0;
  var i = 0;
  while (i < source.length) {
    final unit = source.codeUnitAt(i);
    if (unit == 0x0A) {
      lines.add(_SourceLine(
        text: source.substring(start, i),
        end: i + 1,
      ));
      i++;
      start = i;
    } else if (unit == 0x0D) {
      final next =
          (i + 1 < source.length && source.codeUnitAt(i + 1) == 0x0A) ? i + 2 : i + 1;
      lines.add(_SourceLine(
        text: source.substring(start, i),
        end: next,
      ));
      i = next;
      start = i;
    } else {
      i++;
    }
  }
  if (start < source.length) {
    lines.add(_SourceLine(
      text: source.substring(start),
      end: source.length,
    ));
  }
  return lines;
}

/// 围栏开始 / 结束行的形态：` ``` ` 或 `~~~`（允许最多 3 个前导空格）。
final RegExp _fencePattern = RegExp(r'^(`{3,}|~{3,})(.*)$');

/// 引用定义行：`[标签]: 目标`（脚注 `[^1]: …` 同样命中）。
final RegExp _referenceDefinitionPattern = RegExp(r'^\[[^\]\n]+\]:[ \t]*\S');

/// 无序列表项：`- ` / `* ` / `+ `（后随空白或行尾）。
final RegExp _unorderedListItemPattern = RegExp(r'^[-*+](?:[ \t]|$)');

/// 有序列表项：`1. ` / `1) `。
final RegExp _orderedListItemPattern = RegExp(r'^\d{1,9}[.)](?:[ \t]|$)');

/// 分割线：`---` / `***` / `___`（允许空格或 Tab 分隔）。
final RegExp _thematicBreakPattern = RegExp(r'^([-*_])(?:[ \t]*\1){2,}[ \t]*$');

/// setext 标题下划线：整行只有 `=`。
final RegExp _setextUnderlinePattern = RegExp(r'^=+[ \t]*$');

/// 可为空行切分点的「上一行」判定。
///
/// 允许：普通段落行（含行首内联标记，如 `**粗体**`）、ATX 标题行。
/// 拒绝：前导空白行（可能是列表项续行）、列表项、引用、表格行、围栏行、
/// 原始 HTML 行、分割线 / setext 下划线（可能与上一行合并成标题）。
bool _isSelfContainedLine(String text) {
  if (text.isEmpty) return false;
  final first = text.codeUnitAt(0);
  // 前导空白：可能是列表项续行，空行之后仍可能与后续列表项合并。
  if (first == 0x20 || first == 0x09) return false;
  // 引用 / 表格行 / 围栏行 / 原始 HTML 行：都不是「段落式封闭块」。
  if (first == 0x3E || first == 0x7C || first == 0x60 || first == 0x7E || first == 0x3C) {
    return false;
  }
  // 列表项：其后空行可能把紧凑列表变成松散列表（跨块耦合）。
  if (_unorderedListItemPattern.hasMatch(text) ||
      _orderedListItemPattern.hasMatch(text)) {
    return false;
  }
  // 分割线 / setext 下划线：可能与上一行合并成标题或分割线。
  if (_thematicBreakPattern.hasMatch(text) ||
      _setextUnderlinePattern.hasMatch(text)) {
    return false;
  }
  // 其余（普通段落行 / ATX 标题行）自成一块：空行之后的内容改不动它。
  return true;
}

/// 标注每行是否处于围栏代码块 / 可跨空行的原始 HTML 块内部，
/// 以及是否为围栏结束行、引用定义行。
void _resolveLineStates(List<_SourceLine> lines) {
  String? fenceChar;
  var fenceLength = 0;
  String? rawHtmlCloser;

  for (final line in lines) {
    final inFence = fenceChar != null;
    final inRawHtml = rawHtmlCloser != null;
    line.inVerbatimBlock = inFence || inRawHtml;

    final content = _stripUpToThreeSpaces(line.text);

    if (inFence) {
      final match = _fencePattern.firstMatch(content);
      if (match != null &&
          match.group(1)![0] == fenceChar &&
          match.group(1)!.length >= fenceLength &&
          match.group(2)!.trim().isEmpty) {
        fenceChar = null;
        fenceLength = 0;
        line.isFenceClose = true;
      }
      continue;
    }
    if (inRawHtml) {
      if (line.text.toLowerCase().contains(rawHtmlCloser)) rawHtmlCloser = null;
      continue;
    }

    final fence = _fencePattern.firstMatch(content);
    if (fence != null) {
      fenceChar = fence.group(1)![0];
      fenceLength = fence.group(1)!.length;
      line.inVerbatimBlock = true;
      continue;
    }

    final closer = _rawHtmlCloser(content);
    if (closer != null) {
      line.inVerbatimBlock = true;
      // 开始与结束在同行（如 `<!-- 注释 -->`）：块已闭合，不必继续吞行。
      rawHtmlCloser =
          line.text.toLowerCase().contains(closer) ? null : closer;
      continue;
    }

    line.isReferenceDefinition = _referenceDefinitionPattern.hasMatch(content);
  }
}

/// 去掉最多 3 个前导空格（CommonMark 允许块标记缩进 3 格）。
String _stripUpToThreeSpaces(String text) {
  var i = 0;
  while (i < 3 && i < text.length && text.codeUnitAt(i) == 0x20) {
    i++;
  }
  return text.substring(i);
}

/// 原始 HTML 块的开始标记 → 结束标记；非原始 HTML 块返回 null。
///
/// 只涵盖可以**跨空行**的类型（CommonMark 类型 1~5）；其余 HTML 行
/// （`<div>`、`<br>` 等）由空行终止，无需特判。
String? _rawHtmlCloser(String content) {
  if (content.startsWith('<!--')) return '-->';
  if (content.startsWith('<?')) return '?>';
  if (content.startsWith('<![CDATA[')) return ']]>';
  if (RegExp(r'^<![A-Za-z]').hasMatch(content)) return '>';
  final match = RegExp(
    r'^<(script|pre|style|textarea)(?:[ \t>]|$)',
    caseSensitive: false,
  ).firstMatch(content);
  if (match != null) return '</${match.group(1)!.toLowerCase()}>';
  return null;
}
