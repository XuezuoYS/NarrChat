import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/json_syntax_highlighter.dart';
import '../utils/json_text_format.dart';
import 'json_syntax_colors.dart';
import 'markdown_preview.dart' show SelectableTextArea;
import 'syntax_highlight.dart';

/// JSON 只读高亮展示组件。
///
/// 用途：把「一段 JSON 文本」原样、清晰地显示出来，例如调试用的 JSON 阅读器、
/// RAW 请求体、Mod 导出弹窗。
///
/// - **默认格式化**：[prettyPrint] 为 true 时按 2 空格缩进展开（与项目里
///   `JsonEncoder.withIndent('  ')` 同口径）；文本不是合法 JSON 时**不报错**，
///   直接展示原文（编辑中的半截 JSON、被折叠过占位符的调试文本都能看）。
/// - **主题着色**：键名 / 字符串 / 数字 / `true|false|null` / 标点分色，配色见
///   [JsonSyntaxColors]，随亮暗主题自动切换，与可编辑控制器
///   `JsonEditingController` 完全一致。
/// - **行不折行**：长行横向滚动，避免缩进被折断后读不出层级；纵向滚动交给调用方
///   （把本组件放进你自己的 `SingleChildScrollView` 即可）。
/// - **可选中**：[selectable] 为 true 时走全应用统一的 [SelectableTextArea]，
///   右键/长按复制行为与预览文本一致；行号不在选中区域内，复制不会带上。
///
/// 有明确宽度约束（行内 [Row] 用 [Expanded] 承载正文），不要放进横向无界约束里。
class JsonView extends StatefulWidget {
  const JsonView({
    super.key,
    required this.data,
    this.prettyPrint = true,
    this.selectable = true,
    this.showLineNumbers = false,
    this.base,
  });

  /// JSON 源文本（合法与否都能显示）。
  final String data;

  /// 是否先按 2 空格缩进格式化；解析失败时自动回退为原文。
  final bool prettyPrint;

  /// 是否允许文本选中（含统一的复制工具条）。
  final bool selectable;

  /// 是否显示左侧行号（逐行对齐、不参与选中）。
  ///
  /// 行号需要按行生成文本，超大 JSON 下请谨慎开启（默认关闭）。
  final bool showLineNumbers;

  /// 正文基样式（默认等宽 12 号、行高 1.5、主题主文字色）。
  final TextStyle? base;

  @override
  State<JsonView> createState() => _JsonViewState();
}

class _JsonViewState extends State<JsonView> {
  /// 实际展示的文本（格式化成功则为缩进后的版本，否则为归一化后的原文）。
  String _text = '';

  /// 与 [_text] 对应的词法区间（只在文本变化时重算一次）。
  List<JsonHighlightSpan> _spans = const [];

  /// 行数缓存（仅 [JsonView.showLineNumbers] 为 true 时需要）。
  int? _lineCountCache;

  @override
  void initState() {
    super.initState();
    _resolveText();
  }

  @override
  void didUpdateWidget(covariant JsonView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.prettyPrint != widget.prettyPrint) {
      _resolveText();
    }
  }

  /// 解析展示文本：先归一化换行，再按需格式化（失败回退原文），最后词法着色。
  void _resolveText() {
    final normalized = _normalizeNewlines(widget.data);
    final pretty = widget.prettyPrint ? tryPrettyPrintJson(normalized) : null;
    _text = pretty ?? normalized;
    _spans = const JsonSyntaxHighlighter().highlight(_text);
    _lineCountCache = null;
  }

  int get _lineCount => _lineCountCache ??= _text.split('\n').length;

  @override
  Widget build(BuildContext context) {
    final base = widget.base ?? _defaultBase(context);
    final colors = JsonSyntaxColors.of(context);
    final strut = _strutOf(base);

    final body = Text.rich(
      TextSpan(
        style: base,
        children: buildSyntaxHighlightSpans<JsonSyntaxToken>(
          text: _text,
          spans: _spans,
          base: base,
          styleOf: (token) => colors.styleFor(token, base),
        ),
      ),
      // 不折行：折行会把缩进层级折断，长行交给横向滚动。
      softWrap: false,
      strutStyle: strut,
    );

    final scrollable = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: body,
    );
    final content =
        widget.selectable ? SelectableTextArea(child: scrollable) : scrollable;
    if (!widget.showLineNumbers) return content;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _LineNumberGutter(
          lineCount: _lineCount,
          style: base,
          strutStyle: strut,
          color: context.narrColors.textSecondary,
        ),
        Expanded(child: content),
      ],
    );
  }

  /// 默认正文基样式：等宽、小字号、固定行高（固定行高让行号能逐行对齐）。
  TextStyle _defaultBase(BuildContext context) => TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.5,
        color: context.narrColors.textPrimary,
      );

  /// 强制统一行高的 strut：保证「没有降级字形的行」与「有降级字形的行」
  /// 高度一致（行号与正文要靠这个逐行对齐）。
  StrutStyle _strutOf(TextStyle base) => StrutStyle(
        fontFamily: base.fontFamily,
        fontSize: base.fontSize,
        height: base.height,
        forceStrutHeight: true,
      );
}

/// 归一化换行符：`\r\n` / `\r` → `\n`，避免不同来源的文本在展示上行高不一。
String _normalizeNewlines(String data) =>
    data.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// 行号栏：与正文**同字体 / 同字号 / 同行高**（因此逐行对齐），只是颜色更弱。
///
/// 用一个 Text 渲染全部行号（`1\n2\n…`），不为每行建 widget；行号不在选中区域
/// 内，复制正文不会带上它们。
class _LineNumberGutter extends StatelessWidget {
  const _LineNumberGutter({
    required this.lineCount,
    required this.style,
    required this.strutStyle,
    required this.color,
  });

  /// 正文行数（至少 1）。
  final int lineCount;

  /// 正文字体样式（用来对齐字号 / 行高）。
  final TextStyle style;

  /// 与正文相同的强制行高。
  final StrutStyle strutStyle;

  /// 行号颜色。
  final Color color;

  /// 行号与正文之间的间距。
  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    final gutterStyle = style.copyWith(color: color);
    final label = List<String>.generate(lineCount, (i) => '${i + 1}').join('\n');
    return Padding(
      padding: const EdgeInsets.only(right: _gap),
      child: SizedBox(
        // 量出最宽的行号（最大数字）再留 1 像素余量，避免字体取整后被裁。
        width: _measureWidth('$lineCount', gutterStyle) + 1,
        child: Text(
          label,
          style: gutterStyle,
          strutStyle: strutStyle,
          textAlign: TextAlign.right,
          softWrap: false,
        ),
      ),
    );
  }

  static double _measureWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}
