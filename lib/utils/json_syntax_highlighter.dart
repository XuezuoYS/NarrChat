import 'syntax_highlight_span.dart';

/// JSON 词法单元（用于高亮，不含具体颜色 / 字形）。
///
/// 语义化标记由 [JsonSyntaxHighlighter] 产出，具体配色由上层
/// （`JsonSyntaxColors`）按亮暗主题映射，便于纯数据测试。
enum JsonSyntaxToken {
  /// 对象键名（`{"key": …}` 里引号内的部分）。
  key,

  /// 字符串值。
  string,

  /// 数字（含负号、小数、指数）。
  number,

  /// 字面量 `true` / `false` / `null`。
  keyword,

  /// 结构标点 `{ } [ ] , :`。
  punctuation,
}

/// 一段带词法类型标记的 JSON 文本区间（`[start, end)`，含头不含尾）。
class JsonHighlightSpan implements SyntaxHighlightSpan<JsonSyntaxToken> {
  @override
  final int start;

  @override
  final int end;

  @override
  final JsonSyntaxToken token;

  const JsonHighlightSpan(this.start, this.end, this.token);
}

/// 宽容的 JSON 语法高亮器。
///
/// 与「严格 JSON 解析」不同，它**不要求文本是合法 JSON**，也从不抛异常：
/// 编辑中的半截内容（`{"a":`）、含折叠占位符的调试文本（`"…"`）、甚至完全
/// 不是 JSON 的文本都能安全着色。规则：
///
/// - 键名与字符串值按「闭合引号后是否紧跟 `:`」区分；
/// - 字符串支持 `\"` 等转义；未闭合的字符串止于行尾，不会吞掉下一行；
/// - 数字识别 `-`、小数、指数，`-` 后没有数字时不算数字；
/// - `true` / `false` / `null` 只在词边界处识别（`truex` 不算）；
/// - 输出按位置升序、互不重叠；空白与无法识别的字符不着色（由上层用正文
///   基样式渲染），因此调用方按区间取子串再拼接即可还原全文。
class JsonSyntaxHighlighter {
  const JsonSyntaxHighlighter();

  // —— 字符码点（避免逐字符分配单字符字符串）——
  static const int _quote = 0x22; // "
  static const int _backslash = 0x5C; // \
  static const int _colon = 0x3A; // :
  static const int _comma = 0x2C; // ,
  static const int _dot = 0x2E; // .
  static const int _minus = 0x2D; // -
  static const int _plus = 0x2B; // +
  static const int _newline = 0x0A;
  static const int _carriageReturn = 0x0D;
  static const int _space = 0x20;
  static const int _tab = 0x09;
  static const int _lowerE = 0x65; // e
  static const int _upperE = 0x45; // E
  static const int _underscore = 0x5F;
  static const int _zero = 0x30;
  static const int _nine = 0x39;
  static const int _upperA = 0x41;
  static const int _upperZ = 0x5A;
  static const int _lowerA = 0x61;
  static const int _lowerZ = 0x7A;

  /// 字面量关键字（均为小写，判定区分大小写）。
  static const List<String> _keywords = ['false', 'null', 'true'];

  /// 返回按位置升序、互不重叠的语法区间列表。
  List<JsonHighlightSpan> highlight(String text) {
    final spans = <JsonHighlightSpan>[];
    final length = text.length;
    var i = 0;
    while (i < length) {
      final code = text.codeUnitAt(i);

      // 字符串 / 键名。
      if (code == _quote) {
        final end = _scanString(text, i);
        spans.add(
          JsonHighlightSpan(
            i,
            end,
            _hasColonAhead(text, end)
                ? JsonSyntaxToken.key
                : JsonSyntaxToken.string,
          ),
        );
        i = end;
        continue;
      }

      // 数字。
      if (code == _minus || _isDigit(code)) {
        final end = _scanNumber(text, i);
        if (end > i) {
          spans.add(JsonHighlightSpan(i, end, JsonSyntaxToken.number));
          i = end;
          continue;
        }
      }

      // true / false / null。
      final keywordEnd = _scanKeyword(text, i);
      if (keywordEnd != null) {
        spans.add(JsonHighlightSpan(i, keywordEnd, JsonSyntaxToken.keyword));
        i = keywordEnd;
        continue;
      }

      // 结构标点。
      if (_isPunctuation(code)) {
        spans.add(JsonHighlightSpan(i, i + 1, JsonSyntaxToken.punctuation));
        i++;
        continue;
      }

      // 空白与其余字符：不着色，继续扫描。
      i++;
    }
    return spans;
  }

  /// 扫描一个字符串，返回**闭合引号之后**的位置。
  ///
  /// 未闭合时止于行尾（含行尾本身，即返回换行符位置）：JSON 字符串不允许裸换行，
  /// 这样「打了一半的字符串」不会把后续整篇内容都染成字符串色。
  int _scanString(String text, int open) {
    final length = text.length;
    var i = open + 1;
    while (i < length) {
      final code = text.codeUnitAt(i);
      if (code == _backslash) {
        // 行尾反斜杠视为未闭合（否则会把下一行一起染进字符串）。
        if (i + 1 >= length ||
            text.codeUnitAt(i + 1) == _newline ||
            text.codeUnitAt(i + 1) == _carriageReturn) {
          return i;
        }
        i += 2;
        continue;
      }
      if (code == _quote) return i + 1;
      if (code == _newline || code == _carriageReturn) return i;
      i++;
    }
    return length;
  }

  /// [from] 之后（跳过空白）是否紧接着 `:`——是则为对象键名。
  bool _hasColonAhead(String text, int from) {
    final length = text.length;
    var i = from;
    while (i < length) {
      final code = text.codeUnitAt(i);
      if (code == _space ||
          code == _tab ||
          code == _newline ||
          code == _carriageReturn) {
        i++;
        continue;
      }
      return code == _colon;
    }
    return false;
  }

  /// 扫描一个数字，返回结束位置；不是数字时返回 [start]。
  int _scanNumber(String text, int start) {
    final length = text.length;
    var i = start;
    if (text.codeUnitAt(i) == _minus) i++;

    final digitStart = i;
    while (i < length && _isDigit(text.codeUnitAt(i))) {
      i++;
    }
    if (i == digitStart) return start;

    // 小数部分：点后必须还有数字才算数（`1.` 的句点留给后续字符处理）。
    if (i + 1 < length &&
        text.codeUnitAt(i) == _dot &&
        _isDigit(text.codeUnitAt(i + 1))) {
      i += 2;
      while (i < length && _isDigit(text.codeUnitAt(i))) {
        i++;
      }
    }

    // 指数部分：`e` / `E` 后可带正负号，符号后必须还有数字。
    if (i < length) {
      final code = text.codeUnitAt(i);
      if (code == _lowerE || code == _upperE) {
        var j = i + 1;
        if (j < length) {
          final sign = text.codeUnitAt(j);
          if (sign == _plus || sign == _minus) j++;
        }
        final expDigitStart = j;
        while (j < length && _isDigit(text.codeUnitAt(j))) {
          j++;
        }
        if (j > expDigitStart) i = j;
      }
    }
    return i;
  }

  /// 尝试匹配一个关键字，返回结束位置；不匹配或不在词边界时返回 null。
  int? _scanKeyword(String text, int start) {
    for (final keyword in _keywords) {
      final end = start + keyword.length;
      if (end > text.length) continue;
      if (text.startsWith(keyword, start) && !_isWordChar(text, end)) {
        return end;
      }
    }
    return null;
  }

  bool _isWordChar(String text, int index) {
    if (index >= text.length) return false;
    final code = text.codeUnitAt(index);
    return _isDigit(code) ||
        (code >= _upperA && code <= _upperZ) ||
        (code >= _lowerA && code <= _lowerZ) ||
        code == _underscore;
  }

  bool _isDigit(int code) => code >= _zero && code <= _nine;

  bool _isPunctuation(int code) {
    switch (code) {
      case 0x7B: // {
      case 0x7D: // }
      case 0x5B: // [
      case 0x5D: // ]
      case _comma:
      case _colon:
        return true;
      default:
        return false;
    }
  }
}
