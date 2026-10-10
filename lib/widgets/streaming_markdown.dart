import 'package:flutter/material.dart';

import '../utils/streaming_markdown_blocks.dart';
import 'markdown_preview.dart';

/// 流式 Markdown 预览：**按块增量渲染**。
///
/// 呈现的内容与 [MarkdownPreview] 一致，区别只在「内容持续增长时的重建成本」：
/// - 经 [splitStreamingMarkdownBlocks] 判定为**完整块**的部分只解析一次，其
///   widget 实例被冻结保存；父级重建时同一实例被复用，Flutter 会跳过该子树的
///   rebuild（`Element.updateChild` 命中同一实例短路）→ 既不重新解析、也不重新
///   排版。于是**解析 + 构树 + 排版**的成本只与尾部残块长度相关，不再随正文全长
///   增长（实测 8000 字时末段便宜 7.4x，见 `.agents/chat-ui-perf-plan.md` §8.2）；
/// - 只有尾部残块（尚未出现空行的最后一块）随每个增量重建。
///
/// ⚠️ 屏幕上已渲染的块仍会被框架逐帧遍历（layout/paint 早退 + 选中容器注册），
/// 那部分成本与「有多少块」相关、与解析无关，本组件不负责消除。
///
/// 代价与约定：
/// - 冻结块与尾部残块各自走一次 [MarkdownPreview]，块间隔按
///   [GitHubMarkdownStyle.blockSpacing] 手工补出（与 `MarkdownBody` 内部一致）；
/// - 选中语义不变：整段正文仍只有**一个** [SelectionArea]（本组件外层），
///   各块自身不建选区，故可跨块连续选中；
/// - [data] 不是上一次的前缀延伸时（换轮 / 重试 / 内容改写，或基样式随主题
///   变化），缓存整体重建。
class StreamingMarkdown extends StatefulWidget {
  /// 流式正文源文本（**不含**光标等装饰字符）。
  final String data;

  /// 正文基样式（默认主题 `bodyMedium`，可覆盖字号/行高）。
  final TextStyle? base;

  /// 是否允许文本选中。默认 true（外层建一个 [SelectionArea]）。
  final bool selectable;

  /// 尾随装饰文本（如流式光标 `▍`）：只拼在**尾部残块**末尾，
  /// 不参与块切分（否则会被当成正文内容参与分块判定）。
  final String trailing;

  const StreamingMarkdown({
    super.key,
    required this.data,
    this.base,
    this.selectable = true,
    this.trailing = '',
  });

  @override
  State<StreamingMarkdown> createState() => _StreamingMarkdownState();
}

class _StreamingMarkdownState extends State<StreamingMarkdown> {
  /// 已冻结块（widget 实例复用 → 子元素被跳过 rebuild）。
  final List<Widget> _frozenBlocks = <Widget>[];

  /// 已冻结的源文本前缀（[_frozenBlocks] 对应的精确子串）。
  String _frozenSource = '';

  /// 当前尾部残块文本。
  String _tail = '';

  @override
  void initState() {
    super.initState();
    _advanceCache();
  }

  @override
  void didUpdateWidget(StreamingMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 基样式（调用点按当前主题现算）变化：冻结块捕获的是旧样式，整体重建。
    if (oldWidget.base != widget.base) _resetCache();
    _advanceCache();
  }

  /// 按最新的 [StreamingMarkdown.data] 推进「冻结前缀 + 尾部残块」。
  void _advanceCache() {
    final data = widget.data;
    // 前缀关系不成立（换轮 / 重试 / 文本改写）→ 缓存失效。
    if (!data.startsWith(_frozenSource)) _resetCache();

    final split =
        splitStreamingMarkdownBlocks(data.substring(_frozenSource.length));
    for (final block in split.blocks) {
      final index = _frozenBlocks.length;
      _frozenBlocks.add(
        MarkdownPreview(
          key: ValueKey('streamingBlock$index'),
          data: block,
          base: widget.base,
          selectable: false,
        ),
      );
      _frozenSource += block;
    }
    _tail = split.tail;
  }

  void _resetCache() {
    _frozenBlocks.clear();
    _frozenSource = '';
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    void addChild(Widget child) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: GitHubMarkdownStyle.blockSpacing));
      }
      children.add(child);
    }

    for (final block in _frozenBlocks) {
      addChild(block);
    }
    final tail = _tail + widget.trailing;
    if (tail.isNotEmpty) {
      addChild(
        MarkdownPreview(
          key: const ValueKey('streamingTail'),
          data: tail,
          base: widget.base,
          selectable: false,
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    return widget.selectable ? SelectableTextArea(child: content) : content;
  }
}
