/// 折叠态思考框的「末尾窗口」工具。
///
/// 折叠态思考框只有 4~5 行可见高度，内容却放在 `SingleChildScrollView` 中
/// （子级高度无界）——纯文本是**单个段落**，内容一变就要整段重新整形与换行。
/// 若渲染全文，每个流式增量都要付出 O(全文) 的排版成本，思考链越长越卡
/// （见 `screens/chat_screen.dart` 的 `_ThinkingBox`）。只渲染末尾窗口后，
/// 单次成本与思考链总长解耦。
///
/// 这是与 Markdown 无关的纯字符串工具（思考框按纯文本渲染），因此不涉及
/// 空行 / 围栏 / 表格等 Markdown 边界问题。
library;

/// 折叠态思考框保留的末尾字符数上限（约 25 行正文，远大于 4~5 行可见区，
/// 足以在折叠框内上翻回顾最近的推理）。
const int kThinkingTailMaxChars = 1400;

/// 为对齐行首允许向前回看的最大字符数（避免为找行首而吞掉一个超长行）。
const int _kMaxLineLookback = 200;

/// 取 [text] 的末尾窗口；内容未超过 [maxChars] 时返回 `null`（无需截断）。
///
/// 切点选取（窗口长度有界：`maxChars - 1 ≤ 长度 ≤ maxChars + 回看上限`）：
/// 1. 距末尾约 [maxChars] 处向前回看（不超过 [_kMaxLineLookback]）找到的**行首**，
///    避免窗口以半行开头；
/// 2. 回看不到行首（超长单行）时直接硬切，并跳过 UTF-16 低代理位
///    （emoji 等补充平面字符不会被切成半个码点）。
String? thinkingTailWindow(String text, {int maxChars = kThinkingTailMaxChars}) {
  if (maxChars <= 0 || text.length <= maxChars) return null;
  // maxChars ≥ 2 时 `approximate ≤ text.length - 2`，故回看命中行首也不会越界；
  // 更小的取值属退化用法，直接按「无需截断」返回。
  final approximate = text.length - maxChars;
  final lineStart = text.lastIndexOf('\n', approximate);
  final snapped = lineStart >= 0 && approximate - lineStart <= _kMaxLineLookback;
  var start = snapped ? lineStart + 1 : approximate;
  if (start >= text.length) return null;
  // 硬切可能落在代理对中间：前移一位，保证窗口以完整码点开头。
  if (_isLowSurrogate(text.codeUnitAt(start))) start++;
  return text.substring(start);
}

/// 是否为 UTF-16 低代理位（`0xDC00`~`0xDFFF`）。
bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
