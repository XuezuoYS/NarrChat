/// Markdown 语法词法单元（用于编辑器高亮，不含具体颜色 / 字形）。
///
/// 语义化标记由 `MarkdownSyntaxHighlighter` 产出，具体配色 / 字重等样式
/// 由上层（如 `MarkdownEditingController`）按亮暗主题映射，便于纯数据测试。
enum MarkdownSyntaxToken {
  /// 标题的 `#` 记号。
  headingMarker,

  /// 标题正文。
  headingText,

  /// 列表符号 / 引用 `>` 记号。
  marker,

  /// 链接文字 / 图片替代文字。
  linkText,

  /// 链接目标地址。
  linkUrl,

  /// 链接的 `[` `]` `(` `)` 括号。
  linkBracket,

  /// 行内代码 / 围栏代码块。
  code,

  /// 引用内容。
  blockquote,

  /// 水平分割线。
  hr,

  /// `**加粗**`。
  bold,

  /// `*斜体*`。
  italic,

  /// `***加粗斜体***`。
  boldItalic,

  /// `~~删除线~~`。
  strike,

  /// 弱化内容（转义反斜杠、链接括号等次要元素）。
  dim,

  /// `<自动链接>`。
  autolink,
}

/// 一段带语法类型标记的文本区间（`[start, end)`，含头不含尾）。
class MarkdownHighlightSpan {
  final int start;
  final int end;
  final MarkdownSyntaxToken token;

  const MarkdownHighlightSpan(this.start, this.end, this.token);
}

/// 极简 Markdown 语法高亮器（仿 VS Code / GitHub 风格）。
///
/// - 块级：逐行解析标题、水平分割线、引用、列表、围栏代码块；
/// - 行内：解析加粗 / 斜体 / 加粗斜体、删除线、行内代码、链接与图片、
///   自动链接、转义；
/// - 输出为按位置升序、互不重叠的区间列表，纯数据、不依赖 Flutter UI，
///   可独立单元测试。
///
/// 为编辑体验而设计的宽容策略（不追求 CommonMark 完全兼容）：
/// 标题允许 `#标题`（无空格）、强调以「前后不为 ASCII 单词字符」为界
/// （因此 `*强调*一下` 这类中文紧贴写法可正常识别，而 `a*b*c` /
/// `foo_bar` 不会被误伤）、引用 / 标题内容整体应用块级样式。
class MarkdownSyntaxHighlighter {
  const MarkdownSyntaxHighlighter();

  // —— 块级正则 ——
  // 标题：行首（≤3 空格）+ 1~6 个 #，后接非 # 或行尾（允许 `#标题` 无空格写法）。
  static final RegExp _headingPattern = RegExp(r'^ {0,3}(#{1,6})(?=[^#]|$)');
  // 水平分割线：行首（≤3 空格）+ 同一种符号连续 3 个以上（可带空格）。
  static final RegExp _hrPattern = RegExp(r'^ {0,3}([-_*])(?:\s*\1){2,}\s*$');
  // 引用：行首（≤3 空格）+ 一个以上 `>`（含 `>文本` 与 `>> 嵌套` 两种写法）。
  static final RegExp _blockquotePattern = RegExp(r'^ {0,3}(>+)(?=[^>]|$)');
  // 列表：行首（≤3 空格）+ `-` `*` `+` 或 `1.`/`1)`，后接空白。
  static final RegExp _listPattern = RegExp(r'^ {0,3}([-*+]|\d{1,9}[.)])(?=\s)');
  // 围栏代码块：``` 或 ~~~（≥3 个），可带语言标记。
  static final RegExp _fencePattern = RegExp(
    r'^ {0,3}(`{3,}|~{3,})[ \t]*[A-Za-z0-9_+.-]*[ \t]*$',
  );

  // —— 行内正则 ——
  // 自动链接：URL（含协议或 www.）或邮箱。
  static final RegExp _autolinkPattern = RegExp(
    r'(?:[a-zA-Z][a-zA-Z0-9+.-]*://|www\.)[^\s<>]+'
    r'|[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}',
  );
  // 强调边界：仅 ASCII 单词字符会阻止强调开启 / 闭合（中文可紧贴 `*`）。
  static final RegExp _asciiWordChar = RegExp(r'[A-Za-z0-9_]');

  /// 返回按位置升序、互不重叠的语法区间列表。
  List<MarkdownHighlightSpan> highlight(String text) {
    final raw = <MarkdownHighlightSpan>[];
    final lines = text.split('\n');
    var offset = 0;
    var inFence = false;
    var fence = '```';

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final start = offset;
      final end = offset + line.length;
      final hasNewline = i < lines.length - 1;
      // 代码块区间含换行符，便于跨行合并为整块。
      final codeEnd = end + (hasNewline ? 1 : 0);

      final fenceMatch = _fencePattern.firstMatch(line);
      if (fenceMatch != null) {
        if (inFence && fenceMatch.group(1) == fence) {
          inFence = false; // 闭合围栏：不含尾部换行
          _add(raw, start, end, MarkdownSyntaxToken.code);
        } else {
          if (!inFence) {
            inFence = true;
            fence = fenceMatch.group(1)!;
          }
          _add(raw, start, codeEnd, MarkdownSyntaxToken.code);
        }
      } else if (inFence) {
        _add(raw, start, codeEnd, MarkdownSyntaxToken.code);
      } else {
        _highlightLine(raw, line, start);
      }

      offset = end + (hasNewline ? 1 : 0);
    }
    return _resolve(raw);
  }

  /// 高亮一个普通行（块级元素优先，其余走行内解析）。
  void _highlightLine(List<MarkdownHighlightSpan> raw, String line, int lineStart) {
    // 标题。
    final heading = _headingPattern.firstMatch(line);
    if (heading != null) {
      // 正则匹配末尾即井号串末尾：marker 起点 = 匹配末尾 - 井号串长度。
      final markerStart = heading.end - heading.group(1)!.length;
      _add(
        raw,
        lineStart + markerStart,
        lineStart + heading.end,
        MarkdownSyntaxToken.headingMarker,
      );
      // 标题正文整体为块级样式，行内强调 / 链接由优先级解析叠加。
      _add(
        raw,
        lineStart + heading.end,
        lineStart + line.length,
        MarkdownSyntaxToken.headingText,
      );
      _parseInline(raw, line, lineStart, heading.end, line.length);
      return;
    }
    // 水平分割线。
    if (_hrPattern.hasMatch(line)) {
      _add(raw, lineStart, lineStart + line.length, MarkdownSyntaxToken.hr);
      return;
    }
    // 引用：`>` 记号 + 内容整体块级样式，行内元素由优先级解析叠加。
    final bq = _blockquotePattern.firstMatch(line);
    if (bq != null) {
      final markerStart = bq.end - bq.group(1)!.length;
      _add(
        raw,
        lineStart + markerStart,
        lineStart + bq.end,
        MarkdownSyntaxToken.marker,
      );
      _add(
        raw,
        lineStart + bq.end,
        lineStart + line.length,
        MarkdownSyntaxToken.blockquote,
      );
      _parseInline(raw, line, lineStart, bq.end, line.length);
      return;
    }
    // 列表。
    final list = _listPattern.firstMatch(line);
    if (list != null) {
      final markerStart = list.end - list.group(1)!.length;
      _add(
        raw,
        lineStart + markerStart,
        lineStart + list.end,
        MarkdownSyntaxToken.marker,
      );
      _parseInline(raw, line, lineStart, list.end, line.length);
      return;
    }
    _parseInline(raw, line, lineStart, 0, line.length);
  }

  /// 行内解析：链接 / 图片、行内代码、自动链接、强调、删除线、转义。
  void _parseInline(
    List<MarkdownHighlightSpan> spans,
    String line,
    int lineStart,
    int from,
    int to,
  ) {
    var i = from;
    while (i < to) {
      final ch = line[i];
      // 转义：`\` 弱化，被转义字符按普通文本处理。
      if (ch == r'\' && i + 1 < to) {
        _add(spans, lineStart + i, lineStart + i + 1, MarkdownSyntaxToken.dim);
        i += 2;
        continue;
      }
      // 行内代码。
      if (ch == '`') {
        final close = _findChar(line, '`', i + 1, to);
        if (close != -1) {
          _add(spans, lineStart + i, lineStart + close + 1, MarkdownSyntaxToken.code);
          i = close + 1;
          continue;
        }
      }
      // 自动链接 <...>。
      if (ch == '<') {
        final end = _tryAutolink(line, i, to);
        if (end != null) {
          _add(spans, lineStart + i, lineStart + end, MarkdownSyntaxToken.autolink);
          i = end;
          continue;
        }
      }
      // 图片 ![alt](url)。
      if (ch == '!' && i + 1 < to && line[i + 1] == '[') {
        final link = _tryLink(line, i, to);
        if (link != null) {
          _addLinkSpans(spans, lineStart, link);
          i = link.end;
          continue;
        }
      }
      // 链接 [text](url)。
      if (ch == '[') {
        final link = _tryLink(line, i, to);
        if (link != null) {
          _addLinkSpans(spans, lineStart, link);
          i = link.end;
          continue;
        }
      }
      // 强调（* / ** / *** 或 _ / __ / ___）。
      if (ch == '*' || ch == '_') {
        final next = _tryEmphasis(spans, line, lineStart, i, to);
        if (next != null) {
          i = next;
          continue;
        }
      }
      // 删除线 ~~text~~。
      if (ch == '~' && i + 1 < to && line[i + 1] == '~') {
        final close = line.indexOf('~~', i + 2);
        if (close != -1 && close < to && close > i + 2) {
          _add(spans, lineStart + i, lineStart + close + 2, MarkdownSyntaxToken.strike);
          i = close + 2;
          continue;
        }
      }
      i++;
    }
  }

  void _addLinkSpans(List<MarkdownHighlightSpan> spans, int lineStart, _LinkParts link) {
    _add(spans, lineStart + link.start, lineStart + link.textStart, MarkdownSyntaxToken.linkBracket);
    _add(spans, lineStart + link.textStart, lineStart + link.textEnd, MarkdownSyntaxToken.linkText);
    _add(spans, lineStart + link.textEnd, lineStart + link.urlStart, MarkdownSyntaxToken.linkBracket);
    _add(spans, lineStart + link.urlStart, lineStart + link.urlEnd, MarkdownSyntaxToken.linkUrl);
    _add(spans, lineStart + link.urlEnd, lineStart + link.end, MarkdownSyntaxToken.linkBracket);
  }

  /// 尝试解析强调，成功返回处理后的下一个索引，失败返回 null。
  int? _tryEmphasis(
    List<MarkdownHighlightSpan> spans,
    String line,
    int lineStart,
    int i,
    int to,
  ) {
    final ch = line[i];
    final run = _countRun(line, i, ch, to);
    if (run == 0) return null;
    final level = run >= 3 ? 3 : (run == 2 ? 2 : 1);
    final openLen = run >= 3 ? 3 : run;

    if (!_canOpen(line, i, to, ch, openLen)) return null;

    final contentStart = i + openLen;
    var j = contentStart;
    while (j < to) {
      if (line[j] == ch) {
        final closeRun = _countRun(line, j, ch, to);
        if (closeRun >= openLen && _canClose(line, j, to, ch, openLen)) {
          final content = line.substring(contentStart, j);
          // 内容需非空；单字符强调不允许首尾空白（避免 `* foo *`）。
          final hasContent = content.trim().isNotEmpty &&
              !(level == 1 && (content.startsWith(' ') || content.endsWith(' ')));
          if (hasContent) {
            final token = switch (level) {
              3 => MarkdownSyntaxToken.boldItalic,
              2 => MarkdownSyntaxToken.bold,
              _ => MarkdownSyntaxToken.italic,
            };
            _add(spans, lineStart + i, lineStart + j + closeRun, token);
            return j + closeRun;
          }
        }
      }
      j++;
    }
    return null;
  }

  /// 开启强调的合法性：行首或前一个字符不是 ASCII 单词字符
  /// （`a*b` 不识别，而 `中文*强调*` 可识别）。
  bool _canOpen(String line, int i, int to, String ch, int openLen) {
    if (i == 0) return true;
    return !_isAsciiWordChar(line[i - 1]);
  }

  /// 闭合强调的合法性：行尾或后一个字符不是 ASCII 单词字符
  /// （`*强调*一下` 可闭合，`*bold*text` 按 CommonMark 不闭合）。
  bool _canClose(String line, int j, int to, String ch, int openLen) {
    final nextIdx = j + openLen;
    if (nextIdx >= to) return true;
    return !_isAsciiWordChar(line[nextIdx]);
  }

  /// 解析 `[text](url)` 或 `![alt](url)`；[open] 指向 `[` 或 `!`。失败返回 null。
  _LinkParts? _tryLink(String line, int open, int to) {
    final bracket = line[open] == '!' ? open + 1 : open;
    final closeBracket = _findChar(line, ']', bracket + 1, to);
    if (closeBracket == -1) return null;
    if (closeBracket + 1 >= to || line[closeBracket + 1] != '(') return null;
    final closeParen = _findUnescaped(line, ')', closeBracket + 2, to);
    if (closeParen == -1) return null;
    final url = line.substring(closeBracket + 2, closeParen).trim();
    if (url.isEmpty) return null;
    return _LinkParts(
      start: open,
      textStart: bracket + 1,
      textEnd: closeBracket,
      urlStart: closeBracket + 2,
      urlEnd: closeParen,
      end: closeParen + 1,
    );
  }

  /// 尝试解析 `<url>` 自动链接，成功返回包含 `>` 的结束位置，失败返回 null。
  /// 注意：`matchAsPrefix` 返回的 `Match.start/end` 为字符串中的绝对位置。
  int? _tryAutolink(String line, int i, int to) {
    if (i + 1 >= to) return null;
    final m = _autolinkPattern.matchAsPrefix(line, i + 1);
    if (m == null) return null;
    if (m.end < to && line[m.end] == '>') return m.end + 1;
    return null;
  }

  int _countRun(String s, int i, String ch, int to) {
    var n = 0;
    while (i + n < to && s[i + n] == ch) {
      n++;
    }
    return n;
  }

  int _findChar(String s, String ch, int from, int to) {
    final idx = s.indexOf(ch, from);
    return (idx != -1 && idx < to) ? idx : -1;
  }

  int _findUnescaped(String s, String ch, int from, int to) {
    for (var i = from; i < to; i++) {
      if (s[i] == r'\') {
        i++;
        continue;
      }
      if (s[i] == ch) return i;
    }
    return -1;
  }

  bool _isAsciiWordChar(String ch) => _asciiWordChar.hasMatch(ch);

  /// 追加区间；与末尾相邻且同类型的区间合并，减少 span 数量。
  void _add(List<MarkdownHighlightSpan> spans, int start, int end, MarkdownSyntaxToken token) {
    if (end <= start) return;
    if (spans.isNotEmpty) {
      final last = spans.last;
      if (last.end == start && last.token == token) {
        spans[spans.length - 1] = MarkdownHighlightSpan(last.start, end, token);
        return;
      }
    }
    spans.add(MarkdownHighlightSpan(start, end, token));
  }

  /// 将可能重叠的原始区间解析为互不重叠的区间。
  ///
  /// 按所有边界点切分后，每段取「优先级最高且区间最短」的覆盖区间：
  /// - 行内元素（代码 / 链接 / 自动链接 / 转义）优先级最高，完全覆盖；
  /// - 块级内容（引用 / 标题正文）次之，整体应用其样式；
  /// - 强调（加粗 / 斜体）在普通段落中生效，但在引用 / 标题内被块级样式吸收
  ///   （整块统一风格，符合主流编辑器观感）。
  List<MarkdownHighlightSpan> _resolve(List<MarkdownHighlightSpan> raw) {
    if (raw.isEmpty) return const [];
    final points = <int>{};
    for (final s in raw) {
      points.add(s.start);
      points.add(s.end);
    }
    final sorted = points.toList()..sort();
    final resolved = <MarkdownHighlightSpan>[];
    for (var i = 0; i < sorted.length - 1; i++) {
      final a = sorted[i];
      final b = sorted[i + 1];
      if (a >= b) continue;
      MarkdownHighlightSpan? best;
      var bestPriority = -1;
      var bestLen = 1 << 30;
      for (final s in raw) {
        if (s.start <= a && s.end >= b) {
          final p = _priority(s.token);
          final len = s.end - s.start;
          if (p > bestPriority || (p == bestPriority && len < bestLen)) {
            best = s;
            bestPriority = p;
            bestLen = len;
          }
        }
      }
      if (best != null) {
        _add(resolved, a, b, best.token);
      }
    }
    return resolved;
  }

  /// 区间类型优先级（数值越大越具体）。
  int _priority(MarkdownSyntaxToken token) {
    switch (token) {
      case MarkdownSyntaxToken.code:
      case MarkdownSyntaxToken.linkText:
      case MarkdownSyntaxToken.linkUrl:
      case MarkdownSyntaxToken.linkBracket:
      case MarkdownSyntaxToken.autolink:
      case MarkdownSyntaxToken.dim:
        return 3;
      case MarkdownSyntaxToken.blockquote:
      case MarkdownSyntaxToken.headingText:
        return 2;
      case MarkdownSyntaxToken.bold:
      case MarkdownSyntaxToken.italic:
      case MarkdownSyntaxToken.boldItalic:
      case MarkdownSyntaxToken.strike:
        return 1;
      case MarkdownSyntaxToken.headingMarker:
      case MarkdownSyntaxToken.marker:
      case MarkdownSyntaxToken.hr:
        return 0;
    }
  }
}

/// 链接各段区间（相对所在行）。
class _LinkParts {
  /// 起始位置（`[` 或 `!`）。
  final int start;

  /// 链接文字起点。
  final int textStart;

  /// `]` 位置。
  final int textEnd;

  /// URL 起点（`(` 之后）。
  final int urlStart;

  /// URL 终点（`)` 之前）。
  final int urlEnd;

  /// `)` 之后的结束位置。
  final int end;

  const _LinkParts({
    required this.start,
    required this.textStart,
    required this.textEnd,
    required this.urlStart,
    required this.urlEnd,
    required this.end,
  });
}
