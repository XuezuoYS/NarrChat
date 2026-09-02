import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/raw_exchange.dart';
import '../utils/focus_utils.dart';

/// 从文本中提取一个 base64 图片 data URL（用于 RAW 请求体中折叠长图）。
class RawImageData {
  /// 在文本中出现的顺序（1 起）。
  final int index;

  /// 图片扩展名（如 `png`）。
  final String ext;

  /// 完整 data URL（`data:image/<ext>;base64,<…>`）。
  final String data;

  /// 估计的原始字节数。
  final int byteLength;

  /// 在源文本中的起始偏移。
  final int start;

  /// 在源文本中的结束偏移（不含）。
  final int end;

  const RawImageData({
    required this.index,
    required this.ext,
    required this.data,
    required this.byteLength,
    required this.start,
    required this.end,
  });
}

/// 判断代码单元是否为 base64 字符（A-Z a-z 0-9 + / =）。
bool _isBase64CodeUnit(int cu) =>
    (cu >= 0x41 && cu <= 0x5A) ||
    (cu >= 0x61 && cu <= 0x7A) ||
    (cu >= 0x30 && cu <= 0x39) ||
    cu == 0x2B || // '+'
    cu == 0x2F || // '/'
    cu == 0x3D; // '='

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

/// 提取文本中的全部 `data:image/<ext>;base64,<…>` data URL（按出现顺序）。
///
/// 纯函数，便于测试。
///
/// 说明：这里刻意不使用 `RegExp`，因为 Dart 的正则引擎在贪婪量词（`+`）
/// 扫描超长 base64（可达数 MB）时会在内部递归匹配而导致 `StackOverflowError`；
/// 用 `indexOf` 线性扫描可安全处理任意长度。
List<RawImageData> extractRawImages(String text) {
  const prefix = 'data:image/';
  const sep = ';base64,';
  final n = text.length;
  final result = <RawImageData>[];
  var index = 0;
  var searchStart = 0;
  while (true) {
    final p = text.indexOf(prefix, searchStart);
    if (p < 0) break;
    final sepIdx = text.indexOf(sep, p + prefix.length);
    if (sepIdx < 0) break;
    final ext = text.substring(p + prefix.length, sepIdx).toLowerCase();
    final b64Start = sepIdx + sep.length;
    var end = b64Start;
    while (end < n && _isBase64CodeUnit(text.codeUnitAt(end))) {
      end++;
    }
    if (end > b64Start) {
      final b64 = text.substring(b64Start, end);
      final padding = b64.endsWith('==') ? 2 : (b64.endsWith('=') ? 1 : 0);
      result.add(
        RawImageData(
          index: ++index,
          ext: ext,
          data: text.substring(p, end),
          byteLength: (b64.length * 3) ~/ 4 - padding,
          start: p,
          end: end,
        ),
      );
    }
    // 推进搜索起点：正常在 base64 结尾之后继续；否则跳到分隔符之后，避免死循环。
    searchStart = end > b64Start ? end : sepIdx + 1;
  }
  return result;
}

/// 把文本中的每个图片 data URL 替换为短占位符（`「图像 N · ext · base64 已折叠」`）。
///
/// 仅替换匹配区间本身，JSON 的引号/结构保持不变；无图片时原样返回。
/// [images] 假定来自对同一 [text] 调用 [extractRawImages] 的结果。纯函数。
String collapseRawImages(String text, List<RawImageData> images) {
  if (images.isEmpty) return text;
  var result = text;
  // 从后往前替换，避免前面的替换位移后续匹配区间。
  for (var i = images.length - 1; i >= 0; i--) {
    final img = images[i];
    if (img.start < 0 || img.end > result.length || img.start >= img.end) {
      continue;
    }
    result = result.replaceRange(
      img.start,
      img.end,
      '「图像 ${img.index} · ${img.ext} · base64 已折叠」',
    );
  }
  return result;
}

/// 打开 RAW 对话框。
///
/// [exchanges] 为时间线数据（请求体 → AI返回 交错）；
/// [failedError] 非空时在顶部展示失败原因，且无返回的交换显示「请求失败」。
/// [previewRequestOnly] 为真时进入「预览请求体」模式：标题改为「预览请求体」，
/// 且只展示请求体块（不渲染 AI 返回区），图片折叠 / 检索等能力照常复用。
///
/// 命名为 [showRawDataDialog] 以避开 Flutter 内置的 `showRawDialog`。
void showRawDataDialog(
  BuildContext context, {
  required List<RawExchange> exchanges,
  String? failedError,
  bool previewRequestOnly = false,
}) {
  showDialog<void>(
    context: context,
    builder: (_) => RawDialog(
      exchanges: exchanges,
      failedError: failedError,
      previewRequestOnly: previewRequestOnly,
    ),
  );
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
/// 纯函数、大小写不敏感；空查询返回整段普通文本。[currentIndex] 指定
/// 「当前定位」命中的局部序号，命中处改用 [currentStyle]（浏览器 Ctrl+F
/// 式当前项高亮）。
List<TextSpan> highlightSpans(
  String text,
  String query,
  TextStyle style,
  TextStyle highlightStyle, {
  int currentIndex = -1,
  TextStyle? currentStyle,
}) {
  if (query.isEmpty || text.isEmpty) {
    return [TextSpan(text: text, style: style)];
  }
  final lower = text.toLowerCase();
  final q = query.toLowerCase();
  final spans = <TextSpan>[];
  var start = 0;
  var matchIndex = 0;
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
    final isCurrent = currentStyle != null && matchIndex == currentIndex;
    spans.add(
      TextSpan(
        text: text.substring(idx, idx + q.length),
        style: isCurrent ? currentStyle : highlightStyle,
      ),
    );
    start = idx + q.length;
    matchIndex++;
  }
  return spans;
}

/// 检索命中（跨块全局匹配列表的一项）。
class _RawMatch {
  /// 所属块（全局块序号，见 [_RawDialogState._forEachBlock]）。
  final int blockIndex;

  /// 块内局部命中序号。
  final int localIndex;

  /// 命中区间（半开区间）。
  final int start;
  final int end;

  const _RawMatch({
    required this.blockIndex,
    required this.localIndex,
    required this.start,
    required this.end,
  });
}

/// 定位滚动时，匹配行距视口顶部的留白。
const double _kScrollTopPadding = 40;

/// RAW 调试对话框：查看每轮实际发出的请求 JSON 与 AI 原始返回。
///
/// - 请求 / 返回按时间线交错展示：【请求体】→【AI返回】→…；
/// - AI 返回分三块：思考块 / 工具调用块（原始 tool_calls JSON，含
///   `narrchat_webSearch` / `narrchat_setLine` 等全部工具）/ 正文块，
///   缺失显示「（无）」；
/// - 每个块（请求体与三块）均可折叠，**默认折叠**（长内容不撑满对话框）；
/// - 顶部提供关键词检索（高亮 + 计数）与「转译换行符」开关
///   （开启时把 `\n` 等转义序列展开为真实换行，便于阅读）；
/// - [previewRequestOnly] 为真时进入「预览请求体」模式：只展示请求体块，
///   不渲染【AI返回】区（标题相应改为「预览请求体」）。
class RawDialog extends StatefulWidget {
  final List<RawExchange> exchanges;

  /// 失败条目的错误信息（展示于顶部；无返回的交换显示「请求失败」）。
  final String? failedError;

  /// 预览请求体模式（仅展示请求体块，隐藏 AI 返回区）。
  final bool previewRequestOnly;

  const RawDialog({
    super.key,
    required this.exchanges,
    this.failedError,
    this.previewRequestOnly = false,
  });

  @override
  State<RawDialog> createState() => _RawDialogState();
}

class _RawDialogState extends State<RawDialog> {
  String _query = '';
  bool _escapeNewlines = false;
  final TextEditingController _searchController = TextEditingController();

  /// 全局匹配列表（按文档顺序跨块）。
  List<_RawMatch> _matches = const [];

  /// 当前定位的匹配在 [_matches] 中的下标（-1 = 无）。
  int _currentMatch = -1;

  /// 已展开的块（全局块序号）。
  final Set<int> _expandedBlocks = <int>{};

  /// 时间线滚动控制与视口锚点。
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewKey = GlobalKey();

  /// 每个块的「内容」GlobalKey（用于滚动定位到匹配行）。
  final Map<int, GlobalKey> _blockContentKeys = {};

  /// 按「转译换行符」开关转译后的展示文本（开启 = 展开转义序列）。
  String _display(String text) => _escapeNewlines ? expandEscapes(text) : text;

  /// 请求体展示文本：先按开关转译，再把长图片 data URL 折叠为短占位符，
  /// 避免 base64 撑满对话框（图片详情收进二级扩展菜单）。
  String _requestDisplay(RawExchange ex) {
    final text = _display(ex.requestBody);
    return collapseRawImages(text, extractRawImages(text));
  }

  /// 请求体文本中引用的图片 data URL 列表（用于二级扩展菜单）。
  List<RawImageData> _requestImages(RawExchange ex) =>
      extractRawImages(_display(ex.requestBody));

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 是否有返回内容（任一区块非空）。
  bool _hasReturn(RawExchange ex) =>
      ex.thinking.isNotEmpty || ex.toolCalls.isNotEmpty || ex.content.isNotEmpty;

  /// 按文档顺序遍历全部块（请求体 + 思考/搜索/正文），回调传入
  /// 全局块序号、展示文本与是否等宽。
  void _forEachBlock(void Function(int blockIndex, String text, bool mono) fn) {
    var blockIndex = 0;
    for (final ex in widget.exchanges) {
      fn(blockIndex++, _requestDisplay(ex), true);
      if (_hasReturn(ex)) {
        fn(blockIndex++, _display(ex.thinking), false);
        fn(blockIndex++, _display(ex.toolCalls), false);
        fn(blockIndex++, _display(ex.content), false);
      }
    }
  }

  /// 计算全部匹配（按文档顺序、大小写不敏感）。
  List<_RawMatch> _computeMatches() {
    if (_query.isEmpty) return const [];
    final q = _query.toLowerCase();
    final matches = <_RawMatch>[];
    _forEachBlock((blockIndex, text, _) {
      if (text.isEmpty) return;
      final lower = text.toLowerCase();
      var start = 0;
      var localIndex = 0;
      while (true) {
        final idx = lower.indexOf(q, start);
        if (idx < 0) break;
        matches.add(
          _RawMatch(
            blockIndex: blockIndex,
            localIndex: localIndex,
            start: idx,
            end: idx + q.length,
          ),
        );
        localIndex++;
        start = idx + q.length;
      }
    });
    return matches;
  }

  /// 块内「当前定位」命中的局部序号（-1 = 无）。
  int _localCurrentIndex(int blockIndex) {
    if (_currentMatch < 0 || _currentMatch >= _matches.length) return -1;
    final m = _matches[_currentMatch];
    return m.blockIndex == blockIndex ? m.localIndex : -1;
  }

  /// 搜索词变化：重算匹配、自动展开含匹配的块、定位到第一处。
  void _onQueryChanged(String value) {
    setState(() {
      _query = value;
      _matches = _computeMatches();
      _currentMatch = _matches.isEmpty ? -1 : 0;
      if (_query.isEmpty) {
        // 清空搜索 → 恢复默认全部折叠。
        _expandedBlocks.clear();
      } else {
        // 浏览器 Ctrl+F 式：自动展开含匹配的块，便于浏览全部命中。
        for (final m in _matches) {
          _expandedBlocks.add(m.blockIndex);
        }
      }
    });
    if (_matches.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBlockOffset(_matches.first);
      });
    }
  }

  /// 转译换行符开关变化：转译后文本变化，需重算匹配与定位。
  void _setEscapeNewlines(bool value) {
    setState(() {
      _escapeNewlines = value;
      _matches = _computeMatches();
      _currentMatch = _matches.isEmpty ? -1 : 0;
    });
    if (_matches.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBlockOffset(_matches.first);
      });
    }
  }

  /// 定位到指定匹配（循环取模；自动展开所属块并平滑滚动）。
  void _goToMatch(int newIndex) {
    if (_matches.isEmpty) return;
    final count = _matches.length;
    final idx = ((newIndex % count) + count) % count;
    setState(() {
      _currentMatch = idx;
      _expandedBlocks.add(_matches[idx].blockIndex);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBlockOffset(_matches[idx]);
    });
  }

  /// 展开 / 折叠指定块。
  void _setBlockExpanded(int blockIndex, bool value) {
    setState(() {
      if (value) {
        _expandedBlocks.add(blockIndex);
      } else {
        _expandedBlocks.remove(blockIndex);
      }
    });
  }

  /// 把 [match] 所在块（已展开）平滑滚动到匹配行：
  /// 用同款样式的 TextPainter 按字符偏移估算行位置，再换算滚动目标。
  void _scrollToBlockOffset(_RawMatch match) {
    final contentCtx = _blockContentKeys[match.blockIndex]?.currentContext;
    final contentBox = contentCtx?.findRenderObject() as RenderBox?;
    final viewportBox =
        _scrollViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox == null ||
        viewportBox == null ||
        !_scrollController.hasClients) {
      return;
    }
    String? blockText;
    bool? blockMono;
    _forEachBlock((bi, text, mono) {
      if (bi == match.blockIndex) {
        blockText = text;
        blockMono = mono;
      }
    });
    if (blockText == null) return;
    final painter = TextPainter(
      text: TextSpan(
        text: blockText,
        style: _blockStyle(blockMono ?? false),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: contentBox.size.width);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: match.start),
      Rect.zero,
    );

    final contentTopGlobal = contentBox.localToGlobal(Offset.zero).dy;
    final viewportTopGlobal = viewportBox.localToGlobal(Offset.zero).dy;
    final contentTopInViewport = contentTopGlobal - viewportTopGlobal;
    final matchYInContent =
        _scrollController.offset + contentTopInViewport + caret.dy;
    final target = (matchYInContent - _kScrollTopPadding).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// 与内容一致的块文本样式（TextPainter 估算布局用）。
  static TextStyle _blockStyle(bool mono) => TextStyle(
    fontSize: 12.5,
    height: 1.5,
    fontFamily: mono ? 'monospace' : null,
  );

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
                    widget.previewRequestOnly ? '预览请求体' : 'RAW',
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
                    onChanged: _setEscapeNewlines,
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
            // 关键词检索 + 上一处 / 下一处定位（浏览器 Ctrl+F 式）。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('raw_search_field'),
                      controller: _searchController,
                      onChanged: _onQueryChanged,
                      onSubmitted: (_) => _goToMatch(_currentMatch + 1),
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
                                  _onQueryChanged('');
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
                  if (_query.isNotEmpty) ...[const SizedBox(width: 4),
                    IconButton(
                      key: const Key('raw_match_prev'),
                      icon: const Icon(Icons.arrow_upward, size: 16),
                      tooltip: '上一处',
                      onPressed: _matches.isEmpty
                          ? null
                          : () => _goToMatch(_currentMatch - 1),
                    ),
                    IconButton(
                      key: const Key('raw_match_next'),
                      icon: const Icon(Icons.arrow_downward, size: 16),
                      tooltip: '下一处',
                      onPressed: _matches.isEmpty
                          ? null
                          : () => _goToMatch(_currentMatch + 1),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        _matches.isEmpty
                            ? '0/0'
                            : '${_currentMatch + 1}/${_matches.length}',
                        style: TextStyle(
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
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
                key: _scrollViewKey,
                controller: _scrollController,
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
    final children = <Widget>[];
    var blockIndex = 0;
    for (var i = 0; i < widget.exchanges.length; i++) {
      if (i > 0) children.add(const SizedBox(height: 18));
      final built = _buildExchange(context, widget.exchanges[i], i, blockIndex);
      children.add(built.widget);
      blockIndex = built.nextBlockIndex;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// 构建一次交换（请求体 + AI 返回三块），返回构建结果与下一个全局块序号。
  ({Widget widget, int nextBlockIndex}) _buildExchange(
    BuildContext context,
    RawExchange ex,
    int index,
    int blockIndex,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final requestBlockIndex = blockIndex;
    final requestImages = _requestImages(ex);
    final children = <Widget>[
      // 请求体：可折叠块（默认折叠，长图片 data URL 折叠为短占位符）。
      _CollapsibleBlock(
        label: '【请求体 ${index + 1}】',
        text: _requestDisplay(ex),
        query: _query,
        mono: true,
        expanded: _expandedBlocks.contains(requestBlockIndex),
        onToggle: (v) => _setBlockExpanded(requestBlockIndex, v),
        currentMatchIndex: _localCurrentIndex(requestBlockIndex),
        contentKey: _blockContentKeys.putIfAbsent(
          requestBlockIndex,
          () => GlobalKey(),
        ),
      ),
      // 请求体展开且含图片时，追加「图像 N 个」二级扩展菜单展示 base64。
      if (requestImages.isNotEmpty && _expandedBlocks.contains(requestBlockIndex))
        _ImageListBlock(images: requestImages),
    ];
    // 预览请求体模式：只展示请求体块，不渲染 AI 返回区。
    if (widget.previewRequestOnly) {
      return (
        widget: Column(
          key: Key('raw_exchange_$index'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
        nextBlockIndex: blockIndex,
      );
    }
    children.add(const SizedBox(height: 10));
    // AI 返回：分组标签 + 三个可折叠块。
    children.add(
      Text(
        '【AI返回 ${index + 1}】',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
    children.add(const SizedBox(height: 2));
    blockIndex++;
    if (_hasReturn(ex)) {
      final parts = <(String, String)>[
        ('思考块', _display(ex.thinking)),
        ('工具调用块', _display(ex.toolCalls)),
        ('正文块', _display(ex.content)),
      ];
      for (final (label, text) in parts) {
        final partBlockIndex = blockIndex;
        children.add(
          _CollapsibleBlock(
            label: label,
            text: text,
            query: _query,
            expanded: _expandedBlocks.contains(partBlockIndex),
            onToggle: (v) => _setBlockExpanded(partBlockIndex, v),
            currentMatchIndex: _localCurrentIndex(partBlockIndex),
            contentKey: _blockContentKeys.putIfAbsent(
              partBlockIndex,
              () => GlobalKey(),
            ),
          ),
        );
        blockIndex++;
      }
    } else {
      children.add(
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
      );
    }
    return (
      widget: Column(
        key: Key('raw_exchange_$index'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
      nextBlockIndex: blockIndex,
    );
  }
}

/// 可折叠内容块：标题行（标签 + 匹配计数 + 折叠箭头），默认**折叠**，
/// 点击标题展开内容；空内容直接显示「（无）」，不提供展开。
/// 展开状态由父级控制（供检索定位联动：命中块自动展开）。
class _CollapsibleBlock extends StatelessWidget {
  final String label;

  /// 展示文本（已按「转译换行符」处理）。
  final String text;

  /// 关键词（用于高亮与计数）。
  final String query;

  /// 等宽字体（用于 JSON 展示）。
  final bool mono;

  /// 是否展开（由父级控制）。
  final bool expanded;

  /// 展开状态变更回调。
  final ValueChanged<bool> onToggle;

  /// 本块内「当前定位」命中的局部序号（-1 = 无）。
  final int currentMatchIndex;

  /// 内容区 GlobalKey（用于滚动定位）。
  final GlobalKey contentKey;

  const _CollapsibleBlock({
    required this.label,
    required this.text,
    required this.query,
    this.mono = false,
    required this.expanded,
    required this.onToggle,
    required this.currentMatchIndex,
    required this.contentKey,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = countMatches(text, query);
    final isEmpty = text.isEmpty;

    final header = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isEmpty)
          Icon(
            expanded ? Icons.expand_more : Icons.chevron_right,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
        const SizedBox(width: 2),
        Text(
          label,
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
            onTap: () => onToggle(!expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: header,
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 18),
              child: _HighlightText(
                key: contentKey,
                text: text,
                query: query,
                mono: mono,
                currentIndex: currentMatchIndex,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// 图片 data URL 二级扩展菜单：展示请求体中引用的每张图片元数据与截断预览。
///
/// 默认折叠；展开后显示 `图 n · ext · 字节数`、一段截断预览与
/// 「复制完整 data URL」按钮。**不直接渲染完整 base64** —— 单张图片 base64
/// 可达数 MB，直接交给文本排版会卡死界面。
class _ImageListBlock extends StatefulWidget {
  final List<RawImageData> images;

  const _ImageListBlock({required this.images});

  @override
  State<_ImageListBlock> createState() => _ImageListBlockState();
}

class _ImageListBlockState extends State<_ImageListBlock> {
  bool _expanded = false;

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 截断预览：超长 base64 只显示前 120 个字符，避免大文本排版卡死。
  String _preview(RawImageData img) {
    const maxLen = 120;
    if (img.data.length <= maxLen) return img.data;
    return '${img.data.substring(0, maxLen)}…（共 ${img.data.length} 字符）';
  }

  Future<void> _copy(BuildContext context, String data) async {
    await Clipboard.setData(ClipboardData(text: data));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制完整 data URL')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mono = TextStyle(
      fontSize: 11,
      height: 1.5,
      fontFamily: 'monospace',
      color: scheme.onSurfaceVariant,
    );
    final header = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _expanded ? Icons.expand_more : Icons.chevron_right,
          size: 16,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 2),
        Text(
          '图像 ${widget.images.length} 个（base64 已折叠）',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
    final entries = [
      for (final img in widget.images) ...[
        Text(
          '图 ${img.index} · ${img.ext} · ${_fmtBytes(img.byteLength)}',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(_preview(img), style: mono, maxLines: 2),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 16),
              tooltip: '复制完整 data URL',
              visualDensity: VisualDensity.compact,
              onPressed: () => _copy(context, img.data),
            ),
          ],
        ),
        if (img != widget.images.last) const SizedBox(height: 10),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 34, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: header,
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: entries,
            ),
          ],
        ],
      ),
    );
  }
}

/// 可选中文本：按关键词高亮（命中黄底加粗，「当前定位」橙底），
/// 等宽字体用于 JSON 展示。
class _HighlightText extends StatelessWidget {
  final String text;
  final String query;
  final bool mono;

  /// 本段内「当前定位」命中的局部序号（-1 = 无）。
  final int currentIndex;

  const _HighlightText({
    super.key,
    required this.text,
    required this.query,
    this.mono = false,
    this.currentIndex = -1,
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
    final current = base.copyWith(
      backgroundColor: const Color(0xFFFFB74D).withValues(alpha: 0.6),
      fontWeight: FontWeight.w700,
    );
    return SelectableText.rich(
      TextSpan(
        children: highlightSpans(
          text,
          query,
          base,
          highlight,
          currentIndex: currentIndex,
          currentStyle: current,
        ),
      ),
    );
  }
}
