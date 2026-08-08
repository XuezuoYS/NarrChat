import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 本轮调试信息对话框。
///
/// 展示实际发给 AI 的**完整请求 JSON**（含 system / 历史 user/assistant / 当前 user
/// 的 messages 数组与全部参数）、AI 返回的原始文本（未经过 `##` 标题解析），
/// 以及思考内容（未开启思考时为「（无）」）。仅保留最新一轮的调试数据。
///
/// 顶部提供**按字符查询匹配定位**：输入任意片段后，各区块会高亮全部匹配位置、
/// 显示匹配数量，并支持「上一处/下一处」跳转定位，便于确认某段文本是否被提交
/// 到请求中（如 Prompt 片段）或由 AI 生成（如回复片段）。
class DebugPromptDialog extends StatefulWidget {
  final String requestBody;
  final String rawResponse;
  final String rawReasoning;

  const DebugPromptDialog({
    super.key,
    required this.requestBody,
    required this.rawResponse,
    this.rawReasoning = '',
  });

  static Future<void> show(
    BuildContext context, {
    required String requestBody,
    required String rawResponse,
    String rawReasoning = '',
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => DebugPromptDialog(
        requestBody: requestBody,
        rawResponse: rawResponse,
        rawReasoning: rawReasoning,
      ),
    );
  }

  /// 将请求体 JSON 格式化（缩进 2 空格）；解析失败时原样返回。
  static String _prettyJson(String raw) {
    if (raw.trim().isEmpty) return raw;
    try {
      final decoded = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return raw;
    }
  }

  @override
  State<DebugPromptDialog> createState() => _DebugPromptDialogState();
}

class _DebugPromptDialogState extends State<DebugPromptDialog> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.bug_report_outlined,
              size: 22, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          const Text('本轮调试信息'),
        ],
      ),
      content: SizedBox(
        width: 760,
        height: 560,
        child: DefaultTabController(
          length: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 按字符查询匹配定位
              TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '输入字符查询匹配并定位，如一段 Prompt 或 AI 输出片段',
                  hintStyle: const TextStyle(fontSize: 12),
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _searchController,
                    builder: (_, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            tooltip: '清空',
                            onPressed: () => _searchController.clear(),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const TabBar(
                tabs: [
                  Tab(text: '请求 JSON'),
                  Tab(text: 'AI 原始返回'),
                  Tab(text: '思考内容'),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  children: [
                    _DebugSection(
                      title: '实际发出的请求 JSON（含完整 messages 历史与参数）',
                      text: DebugPromptDialog._prettyJson(widget.requestBody),
                      hint: 'messages 数组：system → 历史 user/assistant → 当前 user。',
                      query: _searchController.text,
                    ),
                    _DebugSection(
                      title: 'AI 原始返回（未解析）',
                      text: widget.rawResponse,
                      hint: 'AI 返回的完整原文，未经 ## 标题解析。',
                      query: _searchController.text,
                    ),
                    _DebugSection(
                      title: '思考内容（reasoning_content）',
                      text: widget.rawReasoning.trim().isEmpty
                          ? '（无）'
                          : widget.rawReasoning,
                      hint: '未开启思考模式时，这里会显示（无）。',
                      query: _searchController.text,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 单个调试区块：标题 + 匹配计数 + 上一处/下一处定位 + 复制按钮 + 可滚动原文。
/// 当 [query] 非空时，高亮正文中全部匹配片段。
class _DebugSection extends StatefulWidget {
  final String title;
  final String text;
  final String? hint;
  final String query;

  const _DebugSection({
    required this.title,
    required this.text,
    this.hint,
    this.query = '',
  });

  @override
  State<_DebugSection> createState() => _DebugSectionState();
}

class _DebugSectionState extends State<_DebugSection> {
  static const TextStyle _textStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.6,
  );

  /// 匹配高亮背景色。
  static const Color _highlightColor = Color(0xFFFFE082);

  final ScrollController _scrollController = ScrollController();

  /// 匹配区间（[start, end)），大小写不敏感。
  late List<(int, int)> _matches;
  int _current = 0;
  double _contentWidth = 0;

  @override
  void initState() {
    super.initState();
    _matches = _computeMatches(widget.text, widget.query);
  }

  @override
  void didUpdateWidget(_DebugSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query || oldWidget.text != widget.text) {
      _matches = _computeMatches(widget.text, widget.query);
      _current = 0;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  static List<(int, int)> _computeMatches(String text, String query) {
    if (query.isEmpty || text.isEmpty) return [];
    final lower = text.toLowerCase();
    final q = query.toLowerCase();
    final result = <(int, int)>[];
    var i = 0;
    while (true) {
      final idx = lower.indexOf(q, i);
      if (idx < 0) break;
      result.add((idx, idx + q.length));
      i = idx + q.length;
    }
    return result;
  }

  /// 生成带高亮匹配的 TextSpan。
  TextSpan _buildHighlightedSpan() {
    if (_matches.isEmpty) return TextSpan(text: widget.text);
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final (start, end) in _matches) {
      if (start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, start)));
      }
      spans.add(TextSpan(
        text: widget.text.substring(start, end),
        style: const TextStyle(
          backgroundColor: _highlightColor,
          fontWeight: FontWeight.bold,
        ),
      ));
      cursor = end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }
    return TextSpan(children: spans);
  }

  /// 滚动定位到指定匹配项（按字符位置估算滚动偏移）。
  void _jumpToMatch(int index) {
    if (_matches.isEmpty) return;
    setState(() => _current = index);
    final start = _matches[index].$1;
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: _textStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: _contentWidth);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: start),
      Rect.zero,
    );
    final max = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      (caret.dy - 48).clamp(0.0, max).toDouble(),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 正文可用宽度 = 区块宽度 - 内边距（12 * 2）。
        _contentWidth = constraints.maxWidth - 24;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.code, size: 16, color: theme.colorScheme.outline),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Spacer(),
                // 匹配状态与定位
                if (widget.query.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      _matches.isEmpty
                          ? '无匹配'
                          : '${_current + 1}/${_matches.length}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _matches.isEmpty
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                    tooltip: '上一处',
                    visualDensity: VisualDensity.compact,
                    onPressed: _matches.isEmpty
                        ? null
                        : () {
                            _jumpToMatch(
                              (_current - 1 + _matches.length) %
                                  _matches.length,
                            );
                          },
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                    tooltip: '下一处',
                    visualDensity: VisualDensity.compact,
                    onPressed: _matches.isEmpty
                        ? null
                        : () {
                            _jumpToMatch((_current + 1) % _matches.length);
                          },
                  ),
                  const SizedBox(width: 4),
                ],
                TextButton.icon(
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.copy_outlined, size: 15),
                  label: const Text('复制'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            if (widget.hint != null) ...[
              const SizedBox(height: 2),
              Text(
                widget.hint!,
                style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
              ),
            ],
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  child: SelectableText.rich(
                    _buildHighlightedSpan(),
                    style: _textStyle,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
