import 'package:flutter/material.dart';

import '../models/raw_exchange.dart';
import '../utils/focus_utils.dart';

/// 打开 RAW 对话框。
///
/// [exchanges] 为时间线数据（请求体 → AI返回 交错）；
/// [failedError] 非空时在顶部展示失败原因，且无返回的交换显示「请求失败」。
///
/// 命名为 [showRawDataDialog] 以避开 Flutter 内置的 `showRawDialog`。
void showRawDataDialog(
  BuildContext context, {
  required List<RawExchange> exchanges,
  String? failedError,
}) {
  showDialog<void>(
    context: context,
    builder: (_) => RawDialog(exchanges: exchanges, failedError: failedError),
  );
}

/// 把文本中的转义序列展开为真实换行 / 制表符（供「转译换行符」选项）。
///
/// 与「转义」相反：将 JSON 等原文里的 `\n` / `\r\n` / `\t` 字面量
/// 还原为实际换行 / 制表符，便于直接阅读内容（如请求体中 messages 的换行）。
/// 纯函数，便于测试。
String expandEscapes(String text) {
  return text
      .replaceAll(r'\r\n', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\n')
      .replaceAll(r'\t', '\t');
}

/// 计算 [query] 在 [text] 中的匹配次数（大小写不敏感；空查询返回 0）。
///
/// 纯函数，便于测试。
int countMatches(String text, String query) {
  if (query.isEmpty || text.isEmpty) return 0;
  final lower = text.toLowerCase();
  final q = query.toLowerCase();
  var count = 0;
  var start = 0;
  while (true) {
    final idx = lower.indexOf(q, start);
    if (idx < 0) break;
    count++;
    start = idx + q.length;
  }
  return count;
}

/// 把 [text] 按 [query] 分割为高亮片段（命中处使用 [highlightStyle]）。
///
/// 纯函数、大小写不敏感；空查询返回整段普通文本。
List<TextSpan> highlightSpans(
  String text,
  String query,
  TextStyle style,
  TextStyle highlightStyle,
) {
  if (query.isEmpty || text.isEmpty) {
    return [TextSpan(text: text, style: style)];
  }
  final lower = text.toLowerCase();
  final q = query.toLowerCase();
  final spans = <TextSpan>[];
  var start = 0;
  while (true) {
    final idx = lower.indexOf(q, start);
    if (idx < 0) {
      if (start < text.length) {
        spans.add(TextSpan(text: text.substring(start), style: style));
      }
      break;
    }
    if (idx > start) {
      spans.add(TextSpan(text: text.substring(start, idx), style: style));
    }
    spans.add(
      TextSpan(
        text: text.substring(idx, idx + q.length),
        style: highlightStyle,
      ),
    );
    start = idx + q.length;
  }
  return spans;
}

/// RAW 调试对话框：查看每轮实际发出的请求 JSON 与 AI 原始返回。
///
/// - 请求 / 返回按时间线交错展示：【请求体】→【AI返回】→…；
/// - AI 返回分三块：思考块 / 搜索块（原始 tool_calls JSON）/ 正文块，
///   缺失显示「（无）」；
/// - 每个块（请求体与三块）均可折叠，**默认折叠**（长内容不撑满对话框）；
/// - 顶部提供关键词检索（高亮 + 计数）与「转译换行符」开关
///   （开启时把 `\n` 等转义序列展开为真实换行，便于阅读）。
class RawDialog extends StatefulWidget {
  final List<RawExchange> exchanges;

  /// 失败条目的错误信息（展示于顶部；无返回的交换显示「请求失败」）。
  final String? failedError;

  const RawDialog({super.key, required this.exchanges, this.failedError});

  @override
  State<RawDialog> createState() => _RawDialogState();
}

class _RawDialogState extends State<RawDialog> {
  String _query = '';
  bool _escapeNewlines = false;
  final TextEditingController _searchController = TextEditingController();

  /// 按「转译换行符」开关转译后的展示文本（开启 = 展开转义序列）。
  String _display(String text) => _escapeNewlines ? expandEscapes(text) : text;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failedError = widget.failedError;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题 + 转译换行符开关 + 关闭。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
              child: Row(
                children: [
                  Text(
                    'RAW',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '转译换行符',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  Switch(
                    value: _escapeNewlines,
                    onChanged: (v) => setState(() => _escapeNewlines = v),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // 关键词检索。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: TextField(
                key: const Key('raw_search_field'),
                controller: _searchController,
                onChanged: (v) => setState(() => _query = v),
                onTapOutside: unfocusOnTapOutside,
                decoration: InputDecoration(
                  hintText: '关键词检索…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          tooltip: '清空',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            // 失败原因提示条。
            if (failedError != null && failedError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: scheme.error.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    '请求失败：$failedError',
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
              ),
            // 时间线主体。
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: _buildTimeline(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeline(BuildContext context) {
    if (widget.exchanges.isEmpty) {
      return Text(
        '（无 RAW 数据）',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < widget.exchanges.length; i++) ...[
          if (i > 0) const SizedBox(height: 18),
          _buildExchange(context, widget.exchanges[i], i),
        ],
      ],
    );
  }

  Widget _buildExchange(BuildContext context, RawExchange ex, int index) {
    final scheme = Theme.of(context).colorScheme;
    final hasReturn =
        ex.thinking.isNotEmpty || ex.search.isNotEmpty || ex.content.isNotEmpty;
    return Column(
      key: Key('raw_exchange_$index'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 请求体：可折叠块（默认折叠）。
        _CollapsibleBlock(
          label: '【请求体 ${index + 1}】',
          text: _display(ex.requestBody),
          query: _query,
          mono: true,
        ),
        const SizedBox(height: 10),
        // AI 返回：分组标签 + 三个可折叠块。
        Text(
          '【AI返回 ${index + 1}】',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: scheme.primary,
          ),
        ),
        const SizedBox(height: 2),
        if (hasReturn) ...[
          _CollapsibleBlock(
            label: '思考块',
            text: _display(ex.thinking),
            query: _query,
          ),
          _CollapsibleBlock(
            label: '搜索块',
            text: _display(ex.search),
            query: _query,
          ),
          _CollapsibleBlock(
            label: '正文块',
            text: _display(ex.content),
            query: _query,
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.failedError == null ? '请求已中断，无 AI 返回' : '请求失败，无 AI 返回',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// 可折叠内容块：标题行（标签 + 匹配计数 + 折叠箭头）默认**折叠**，
/// 点击标题展开内容；空内容直接显示「（无）」，不提供展开。
class _CollapsibleBlock extends StatefulWidget {
  final String label;

  /// 展示文本（已按「转译换行符」处理）。
  final String text;

  /// 关键词（用于高亮与计数）。
  final String query;

  /// 等宽字体（用于 JSON 展示）。
  final bool mono;

  const _CollapsibleBlock({
    required this.label,
    required this.text,
    required this.query,
    this.mono = false,
  });

  @override
  State<_CollapsibleBlock> createState() => _CollapsibleBlockState();
}

class _CollapsibleBlockState extends State<_CollapsibleBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = widget.text;
    final count = countMatches(text, widget.query);
    final isEmpty = text.isEmpty;

    final header = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isEmpty)
          Icon(
            _expanded ? Icons.expand_more : Icons.chevron_right,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
        const SizedBox(width: 2),
        Text(
          widget.label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        if (count > 0)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
              '· $count 处',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        if (isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
              '（无）',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: header)
        else ...[
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: header,
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 18),
              child: _HighlightText(
                text: text,
                query: widget.query,
                mono: widget.mono,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// 可选中文本：按关键词高亮（黄底加粗），等宽字体用于 JSON 展示。
class _HighlightText extends StatelessWidget {
  final String text;
  final String query;
  final bool mono;

  const _HighlightText({
    required this.text,
    required this.query,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = TextStyle(
      fontSize: 12.5,
      height: 1.5,
      fontFamily: mono ? 'monospace' : null,
      color: scheme.onSurfaceVariant,
    );
    final highlight = base.copyWith(
      backgroundColor: const Color(0xFFFFF176).withValues(alpha: 0.5),
      fontWeight: FontWeight.w700,
    );
    return SelectableText.rich(
      TextSpan(children: highlightSpans(text, query, base, highlight)),
    );
  }
}
