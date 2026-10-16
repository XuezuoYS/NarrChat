import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph, RenderProxyBox;
import 'package:flutter/services.dart';

import '../models/raw_exchange.dart';
import '../services/request_frame_outline.dart';
import '../utils/focus_utils.dart';
import 'app_notice_overlay.dart';
import 'markdown_preview.dart';

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
/// [subsequentFrames] 仅预览模式下有意义：列出后续**可能**发出的帧
/// （每帧只展示相对上一帧的增量字段，见 [PlannedFrame]）。
///
/// 命名为 [showRawDataDialog] 以避开 Flutter 内置的 `showRawDialog`。
void showRawDataDialog(
  BuildContext context, {
  required List<RawExchange> exchanges,
  String? failedError,
  bool previewRequestOnly = false,
  List<PlannedFrame> subsequentFrames = const [],
}) {
  showDialog<void>(
    context: context,
    builder: (_) => RawDialog(
      exchanges: exchanges,
      failedError: failedError,
      previewRequestOnly: previewRequestOnly,
      subsequentFrames: subsequentFrames,
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

/// 把 [text] 按硬换行切成若干段，每段至多 [budget] 字符（末段与超长单行除外）。
///
/// 切点一律落在 `\n` **之后**，各段拼回原样逐字相同 —— 跨段选中复制才不出错。
/// 纯函数，便于测试。
List<String> splitAtNewlines(String text, int budget) {
  assert(budget > 0);
  final pieces = <String>[];
  var start = 0;
  while (start < text.length) {
    if (start + budget >= text.length) {
      pieces.add(text.substring(start));
      break;
    }
    // 优先在预算内收尾于换行；一行超长（无换行可用）就一路吃到下一个换行。
    final prev = text.lastIndexOf('\n', start + budget);
    int end;
    if (prev >= start) {
      end = prev + 1;
    } else {
      final next = text.indexOf('\n', start + budget);
      end = next < 0 ? text.length : next + 1;
    }
    if (end <= start) end = start + 1; // 兜底：绝不出空段
    pieces.add(text.substring(start, end));
    start = end;
  }
  return pieces;
}

/// 一个展示块的派生结果：处理完毕的展示文本 + 该块折叠掉的图片。
///
/// 展示文本要先折叠 base64 图片、再按开关转义，两步都是对整块的一次全量扫描，
/// 故只在 [_RawDialogState._blocks] 里算一次，之后渲染 / 检索只读结果。
class _RawBlock {
  const _RawBlock({
    required this.text,
    required this.mono,
    this.images = const [],
  });

  /// 展示文本（已折叠图片、已按「转译换行符」处理）。
  final String text;

  /// 是否用等宽字体（请求体与增量帧是 JSON）。
  final bool mono;

  /// 本块被折叠掉的 base64 图片（只有请求体块可能非空）。
  final List<RawImageData> images;
}

/// 派生快照所依赖的「AI 返回侧」字段值副本。
///
/// `RawExchange` 的这四个字段要等请求返回后才回填，而快照手里就是**同一个对象**，
/// 拿 `snap.exchanges[i].content` 去比 `widget.exchanges[i].content` 等于自己比
/// 自己、永远相等。所以派生时把值取出来存一份，之后比的是这份副本。
class _RawReturnFields {
  const _RawReturnFields({
    required this.thinking,
    required this.toolCalls,
    required this.content,
    required this.error,
  });

  final String thinking;
  final String toolCalls;
  final String content;
  final String error;

  /// 从交换当前值抄一份。
  factory _RawReturnFields.of(RawExchange ex) => _RawReturnFields(
    thinking: ex.thinking,
    toolCalls: ex.toolCalls,
    content: ex.content,
    error: ex.error,
  );

  /// 四个字段是否与 [ex] 的当前值完全一致。
  bool matches(RawExchange ex) =>
      thinking == ex.thinking &&
      toolCalls == ex.toolCalls &&
      content == ex.content &&
      error == ex.error;
}

/// 一次派生好的全部展示块快照，连同算它时用到的输入。
///
/// 输入任一项变化（换开关 / 某条交换的回填字段 / 预览模式 / 帧列表）都必须重建，
/// 否则会把旧文本当成新内容展示。
class _RawBlockSnapshot {
  const _RawBlockSnapshot({
    required this.escapeNewlines,
    required this.previewRequestOnly,
    required this.failedError,
    required this.exchanges,
    required this.returns,
    required this.frames,
    required this.blocks,
  });

  /// 派生时的「转译换行符」开关。
  final bool escapeNewlines;

  /// 派生时的预览请求体模式。
  final bool previewRequestOnly;

  /// 派生时的失败原因（决定无返回块写什么）。
  final String? failedError;

  /// 派生时的交换列表（只比对象身份：`requestBody` 构造后不再变）。
  final List<RawExchange> exchanges;

  /// 与 [exchanges] 一一对应的返回侧字段值副本。
  final List<_RawReturnFields> returns;

  /// 派生时的「后续可用帧」列表（非预览模式恒为空）。
  final List<PlannedFrame> frames;

  /// 按文档顺序排列的块，下标即全局块序号。
  final List<_RawBlock> blocks;
}

/// 检索命中（跨块全局匹配列表的一项）。
class _RawMatch {
  /// 所属块（全局块序号，见 [_RawDialogState._blocks]）。
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
///   `narrchat_webSearch` / `narrchat_edit*` 等全部工具）/ 正文块，
///   缺失显示「（无）」；
/// - 每个块（请求体与三块）均可折叠，**默认折叠**（长内容不撑满对话框）；
/// - 顶部提供关键词检索与「转译换行符」开关（默认开启，把 `\n` 等转义序列
///   展开为真实换行，便于阅读）。检索**手动触发**（点「搜索」或按回车）：
///   每块标题给出本块命中数「· N 处」，全部命中都可按「上一处 / 下一处」循环
///   定位，但一次只展开当前定位的那一块（命中很密时同时展开全部命中块会冻屏）；
/// - [previewRequestOnly] 为真时进入「预览请求体」模式：只展示请求体块，
///   不渲染【AI返回】区（标题相应改为「预览请求体」）；
/// - [subsequentFrames] 非空时，在请求体之后追加「后续可用帧」区（仅预览模式）：
///   每帧一个可折叠块，**只列出相对上一帧的增量字段**。
class RawDialog extends StatefulWidget {
  final List<RawExchange> exchanges;

  /// 失败条目的错误信息（展示于顶部；无返回的交换显示「请求失败」）。
  final String? failedError;

  /// 预览请求体模式（仅展示请求体块，隐藏 AI 返回区）。
  final bool previewRequestOnly;

  /// 后续可用帧（预览模式；首帧就是上方请求体，见 [PlannedFrame]）。
  final List<PlannedFrame> subsequentFrames;

  const RawDialog({
    super.key,
    required this.exchanges,
    this.failedError,
    this.previewRequestOnly = false,
    this.subsequentFrames = const [],
  });

  @override
  State<RawDialog> createState() => _RawDialogState();
}

class _RawDialogState extends State<RawDialog> {
  String _query = '';

  /// 「转译换行符」开关：默认开启（RAW / 预览请求体以可读性优先）。
  bool _escapeNewlines = true;
  final TextEditingController _searchController = TextEditingController();

  /// 全局匹配列表（按文档顺序跨块）。
  List<_RawMatch> _matches = const [];

  /// 当前定位的匹配在 [_matches] 中的下标（-1 = 无）。
  int _currentMatch = -1;

  /// 每块命中数（下标对齐 [_blocks] 的块序号；未检索时为空）。
  List<int> _blockCounts = const [];

  /// 是否有一次检索已排队、还没执行完（用于「搜索中」提示）。
  bool _searching = false;

  /// 展示块快照：把「折叠图片 + 转义」的全量扫描结果缓存下来复用。
  _RawBlockSnapshot? _snapshot;

  /// 手点标题展开的块（全局块序号）。
  final Set<int> _expandedBlocks = <int>{};

  /// 检索 / 定位当前展开的那一块（全局块序号；-1 = 无）。
  ///
  /// 与手点展开分开记：命中很多块时**一次全部展开**要在同一帧里排完所有命中块
  /// 的高亮文字，实测 20 万字符 / 1.25 万处就要 10 s 以上（爆点是普通段与高亮段
  /// 交替产生的样式切换数，不是字数也不是命中数），手机上就是点完搜索冻死。
  /// 所以检索只展开当前定位的一块，其余命中块靠标题上的「· N 处」提示，
  /// 点标题或按「上一处 / 下一处」走过去时才展开——每帧只排一块。
  int _searchBlock = -1;

  /// 块是否展开：手点点开的，或检索正定位到的。
  bool _isBlockExpanded(int blockIndex) =>
      _expandedBlocks.contains(blockIndex) || blockIndex == _searchBlock;

  /// 时间线滚动控制与视口锚点。
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewKey = GlobalKey();

  /// 每个块的「内容」GlobalKey（用于滚动定位到匹配行）。
  final Map<int, GlobalKey> _blockContentKeys = {};

  /// 按「转译换行符」开关转译后的展示文本（开启 = 展开转义序列）。
  String _display(String text) => _escapeNewlines ? expandEscapes(text) : text;

  /// 当前输入下的全部展示块：快照仍有效时零扫描，否则重建一次。
  ///
  /// 大 RAW 下单个请求体可达数 MB，「折叠图片」「转义」「检索」每遍都是对整块
  /// 的全量扫描；以前每次 build、每次按键、每个块都要重扫好几遍，这正是手机端
  /// 打开 RAW / 搜索时明显卡顿的来源。
  List<_RawBlock> _blocks() {
    final cached = _snapshot;
    if (cached != null && _isSnapshotUsable(cached)) return cached.blocks;
    final built = _buildSnapshot();
    _snapshot = built;
    return built.blocks;
  }

  /// 生效的「后续可用帧」列表（非预览模式恒为空）。
  List<PlannedFrame> get _plannedFrames => widget.previewRequestOnly
      ? widget.subsequentFrames
      : const <PlannedFrame>[];

  /// 快照的派生输入是否仍然有效。
  ///
  /// 交换的 `requestBody` 构造后不再变（比对象身份即可），但思考 / 工具调用 /
  /// 正文 / 错误是**请求返回后才回填**的，要比派生时抄下的值副本
  /// （见 [_RawReturnFields]）。
  bool _isSnapshotUsable(_RawBlockSnapshot snap) {
    if (snap.escapeNewlines != _escapeNewlines ||
        snap.previewRequestOnly != widget.previewRequestOnly ||
        snap.failedError != widget.failedError) {
      return false;
    }
    final exchanges = widget.exchanges;
    if (snap.exchanges.length != exchanges.length) return false;
    for (var i = 0; i < exchanges.length; i++) {
      if (!identical(snap.exchanges[i], exchanges[i])) return false;
      if (!snap.returns[i].matches(exchanges[i])) return false;
    }
    final frames = _plannedFrames;
    if (snap.frames.length != frames.length) return false;
    for (var i = 0; i < frames.length; i++) {
      if (!identical(snap.frames[i], frames[i])) return false;
    }
    return true;
  }

  /// 走一遍全部交换，算出每个块的展示文本（每块的折叠与转义各只做一次）。
  _RawBlockSnapshot _buildSnapshot() {
    final frames = _plannedFrames;
    final blocks = <_RawBlock>[];
    final returns = <_RawReturnFields>[];
    for (final ex in widget.exchanges) {
      // 先抄一份返回侧的值：这次派生认的是这份副本。
      returns.add(_RawReturnFields.of(ex));
      // 请求体：先在原文上定位并折叠 base64，再转义（顺序可互换：base64 区间
      // 与折叠占位符里都不含 `\n` 这类反斜杠转义，两遍结果逐字一致）。
      final images = extractRawImages(ex.requestBody);
      blocks.add(
        _RawBlock(
          text: _display(collapseRawImages(ex.requestBody, images)),
          mono: true,
          images: images,
        ),
      );
      // 预览请求体模式不渲染 AI 返回区，序号也不为它占位。
      if (widget.previewRequestOnly) continue;
      if (_hasReturn(ex)) {
        blocks.add(_RawBlock(text: _display(ex.thinking), mono: false));
        blocks.add(_RawBlock(text: _display(ex.toolCalls), mono: false));
        blocks.add(_RawBlock(text: _display(ex.content), mono: false));
      } else {
        // 无返回：把失败原因（若有）也纳入检索与定位。
        blocks.add(_RawBlock(text: _noReturnText(ex), mono: false));
      }
    }
    for (final frame in frames) {
      // diffJson 是每次取值都重新编码的 getter，这里只取一次。
      blocks.add(_RawBlock(text: frame.diffJson, mono: true));
    }
    return _RawBlockSnapshot(
      escapeNewlines: _escapeNewlines,
      previewRequestOnly: widget.previewRequestOnly,
      failedError: widget.failedError,
      exchanges: List.of(widget.exchanges),
      returns: returns,
      frames: List.of(frames),
      blocks: blocks,
    );
  }

  /// 块内命中数（未检索或越界时为 0）。
  int _countOf(int blockIndex) =>
      blockIndex < _blockCounts.length ? _blockCounts[blockIndex] : 0;

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 是否有返回内容（任一区块非空）。
  bool _hasReturn(RawExchange ex) =>
      ex.thinking.isNotEmpty ||
      ex.toolCalls.isNotEmpty ||
      ex.content.isNotEmpty;

  /// 第 [blockIndex] 个块（越界返回 null）。
  ///
  /// 块序号由 [_buildSnapshot] 的顺序定义，与 [_buildTimeline] 的渲染一一对应
  /// （检索定位按序号取 GlobalKey）。
  _RawBlock? _blockAt(int blockIndex) {
    final blocks = _blocks();
    return blockIndex >= 0 && blockIndex < blocks.length
        ? blocks[blockIndex]
        : null;
  }

  /// 无返回时的说明行：优先展示**本次请求的失败原因**（协议兼容降级前的探测
  /// 帧被服务商拒绝等），其次按整个对话框是否为失败尝试给出中性 / 失败提示。
  ///
  /// 注意：一条交换「没有返回内容」本身不代表发生错误——降级探测帧之外，
  /// 服务商也可能返回空响应。
  String _noReturnText(RawExchange ex) {
    if (ex.error.isNotEmpty) return '请求失败：${ex.error}';
    return widget.failedError == null ? '（无 AI 返回内容）' : '请求失败，无 AI 返回';
  }

  /// 计算全部匹配（按文档顺序、大小写不敏感），并记下每块命中数。
  ///
  /// 这是对全部块的一次全量扫描，只由「搜索」按钮 / 回车触发（见 [_runSearch]）。
  void _applySearch() {
    if (!mounted) return;
    final query = _searchController.text;
    final blocks = _blocks();
    final matches = <_RawMatch>[];
    final counts = List<int>.filled(blocks.length, 0);
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      for (var bi = 0; bi < blocks.length; bi++) {
        final text = blocks[bi].text;
        if (text.isEmpty) continue;
        final lower = text.toLowerCase();
        var start = 0;
        var localIndex = 0;
        while (true) {
          final idx = lower.indexOf(q, start);
          if (idx < 0) break;
          matches.add(
            _RawMatch(
              blockIndex: bi,
              localIndex: localIndex,
              start: idx,
              end: idx + q.length,
            ),
          );
          localIndex++;
          counts[bi] = localIndex;
          start = idx + q.length;
        }
      }
    }
    setState(() {
      _query = query;
      _matches = matches;
      _blockCounts = counts;
      _currentMatch = matches.isEmpty ? -1 : 0;
      _searching = false;
      if (query.isEmpty) {
        // 清空搜索 → 恢复默认全部折叠。
        _expandedBlocks.clear();
        _searchBlock = -1;
      } else {
        // 只展开第一处所在的块（其余命中块看标题上的「· N 处」）。
        _searchBlock = matches.isEmpty ? -1 : matches.first.blockIndex;
      }
    });
    if (matches.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBlockOffset(_matches.first);
      });
    }
  }

  /// 「搜索」按钮 / 回车：只对输入框里当前的词执行一次检索。
  ///
  /// 常见词要扫完全部块（大 RAW 下上百毫秒），所以先排一帧画出「搜索中」，
  /// 再在帧回调里扫描 —— 同步扫会让点下去像没反应。
  void _runSearch() {
    if (_searching) return;
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _applySearch());
  }

  /// 清空搜索词并复位（不触发检索）。
  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _query = '';
      _matches = const [];
      _blockCounts = const [];
      _currentMatch = -1;
      _searching = false;
      _expandedBlocks.clear();
      _searchBlock = -1;
    });
  }

  /// 转译换行符开关变化：展示文本变了，已算出的命中位置需重算。
  void _setEscapeNewlines(bool value) {
    if (value == _escapeNewlines) return;
    setState(() => _escapeNewlines = value);
    if (_query.isNotEmpty) _runSearch();
  }

  /// 块内「当前定位」命中的局部序号（-1 = 无）。
  int _localCurrentIndex(int blockIndex) {
    if (_currentMatch < 0 || _currentMatch >= _matches.length) return -1;
    final m = _matches[_currentMatch];
    return m.blockIndex == blockIndex ? m.localIndex : -1;
  }

  /// 定位到指定匹配（循环取模；把「检索展开的那一块」移到目标块并平滑滚动）。
  void _goToMatch(int newIndex) {
    if (_matches.isEmpty) return;
    final count = _matches.length;
    final idx = ((newIndex % count) + count) % count;
    setState(() {
      _currentMatch = idx;
      // 只跟着当前定位展开一块：上一块随着本槽位移走自动收回，
      // 手点点开的块（[_expandedBlocks]）不受影响。
      _searchBlock = _matches[idx].blockIndex;
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
        // 折叠正在定位的块：连检索那份展开一起收掉，否则点了折叠没反应。
        if (_searchBlock == blockIndex) _searchBlock = -1;
      }
    });
  }

  /// 收集块内容里所有真正排版文字的 [RenderParagraph]，顺序与 [_HighlightText] 的
  /// 分段一致。
  ///
  /// 块的 GlobalKey 挂在 `_HighlightText` 上，`findRenderObject()` 只停在链首的
  /// `RenderSemanticsAnnotations`，必须顺子节点往下走才能到达各段文字。
  List<RenderParagraph> _paragraphsOf(BuildContext? context) {
    final node = context?.findRenderObject();
    if (node == null) return const [];
    final found = <RenderParagraph>[];
    void visit(RenderObject child) {
      if (child is RenderParagraph) {
        found.add(child);
        return;
      }
      child.visitChildren(visit);
    }

    node.visitChildren(visit);
    return found;
  }

  /// 整段 span 树的字符总数（用来判断命中落在哪一段）。
  int _spanCharCount(InlineSpan span) {
    if (span is! TextSpan) return 0; // WidgetSpan 之类不占文字偏移
    var count = span.text?.length ?? 0;
    for (final child in span.children ?? const <InlineSpan>[]) {
      count += _spanCharCount(child);
    }
    return count;
  }

  /// 全文第 [offset] 个字符所在的那一段，以及它在该段内的偏移。
  ({RenderParagraph paragraph, int offset})? _segmentAt(
    List<RenderParagraph> paragraphs,
    int offset,
  ) {
    var consumed = 0;
    for (final paragraph in paragraphs) {
      final length = _spanCharCount(paragraph.text);
      if (offset < consumed + length) {
        return (paragraph: paragraph, offset: offset - consumed);
      }
      consumed += length;
    }
    if (paragraphs.isEmpty) return null;
    // 越界兜底（正常不会走到）：钉在末段末尾，至少滚到那块附近。
    final last = paragraphs.last;
    return (paragraph: last, offset: _spanCharCount(last.text));
  }

  /// 把 [match] 所在块（已展开）平滑滚动到匹配行。
  ///
  /// 直接用块内已经排好版的 [RenderParagraph] 取光标位置（内部只在文字变化时才
  /// 重排），不再为定位另起一个 TextPainter 把整块文字排一遍 —— 后者在数百 KB 的
  /// 请求体上单次就要 200 ms 以上。块是分段的，故先按字符数找到命中所在的那一段。
  void _scrollToBlockOffset(_RawMatch match) {
    final viewportBox =
        _scrollViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !_scrollController.hasClients) return;
    final block = _blockAt(match.blockIndex);
    if (block == null) return;
    final located = _segmentAt(
      _paragraphsOf(_blockContentKeys[match.blockIndex]?.currentContext),
      match.start.clamp(0, block.text.length),
    );
    if (located == null) return;
    final paragraph = located.paragraph;
    final caret = paragraph.getOffsetForCaret(
      TextPosition(offset: located.offset),
      const Rect.fromLTWH(0, 0, 1, 1),
    );
    final matchYInContent =
        _scrollController.offset +
        paragraph.localToGlobal(caret).dy -
        viewportBox.localToGlobal(Offset.zero).dy;
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
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
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
            //
            // **手动触发**：输入过程中不扫描（大 RAW 下每敲一个字扫一遍会让
            // 输入框明显卡），只有点「搜索」或按回车才执行一次检索。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('raw_search_field'),
                      controller: _searchController,
                      onSubmitted: (_) => _runSearch(),
                      onTapOutside: unfocusOnTapOutside,
                      decoration: InputDecoration(
                        hintText: '关键词检索…',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                tooltip: '清空',
                                onPressed: _clearSearch,
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
                  const SizedBox(width: 4),
                  TextButton(
                    key: const Key('raw_search_button'),
                    onPressed: _runSearch,
                    child: const Text('搜索'),
                  ),
                  // 常见词要扫完全部块，扫描期间先给出「搜索中」提示。
                  if (_searching)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        '搜索中…',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else if (_query.isNotEmpty) ...[
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
    children.addAll(_buildSubsequentFrames(context, blockIndex));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// 预览模式的「后续可用帧」区：每帧一个**可折叠增量块**（默认折叠，
  /// 参与关键词检索与定位——定位到该帧时展开这一块）。
  ///
  /// 这些帧是否真的发出取决于模型响应，故标题写清前提；块内只有相对上一帧的
  /// 追加 / 省略字段（[PlannedFrame.diffJson]，已在派生块里算好一次）。
  List<Widget> _buildSubsequentFrames(BuildContext context, int firstBlock) {
    final frames = _plannedFrames;
    if (frames.isEmpty) return const [];
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[
      const SizedBox(height: 18),
      Text(
        '【后续可用帧 ${frames.length}】',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        '首帧 = 上方请求体（与实发逐字一致，点发送即发出）。以下帧'
        '**是否发出取决于模型响应**，每帧只列出相对上一帧的增量字段。',
        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 6),
    ];
    var blockIndex = firstBlock;
    final blocks = _blocks();
    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      final index = blockIndex;
      children.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _CollapsibleBlock(
                label: '【${frame.label}】',
                text: blocks[index].text,
                query: _query,
                count: _countOf(index),
                mono: true,
                expanded: _isBlockExpanded(index),
                onToggle: (v) => _setBlockExpanded(index, v),
                currentMatchIndex: _localCurrentIndex(index),
                contentKey: _blockContentKeys.putIfAbsent(
                  index,
                  () => GlobalKey(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: Text(
                  frame.note,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      blockIndex++;
    }
    return children;
  }

  /// 构建一次交换（请求体 + AI 返回三块），返回构建结果与下一个全局块序号。
  ///
  /// 块内容一律取自 [_blocks]（一次派生的快照），这里只按下标取用；
  /// 下标越界说明渲染顺序与 [_buildSnapshot] 不一致，应当直接暴露。
  ({Widget widget, int nextBlockIndex}) _buildExchange(
    BuildContext context,
    RawExchange ex,
    int index,
    int blockIndex,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final blocks = _blocks();
    final requestBlockIndex = blockIndex;
    final requestExpanded = _isBlockExpanded(requestBlockIndex);
    final requestBlock = blocks[requestBlockIndex];
    final children = <Widget>[
      // 请求体：可折叠块（默认折叠，长图片 data URL 折叠为短占位符）。
      _CollapsibleBlock(
        label: '【请求体 ${index + 1}】',
        text: requestBlock.text,
        query: _query,
        count: _countOf(requestBlockIndex),
        mono: true,
        expanded: requestExpanded,
        onToggle: (v) => _setBlockExpanded(requestBlockIndex, v),
        currentMatchIndex: _localCurrentIndex(requestBlockIndex),
        contentKey: _blockContentKeys.putIfAbsent(
          requestBlockIndex,
          () => GlobalKey(),
        ),
      ),
      // 请求体展开且含图片时，追加「图像 N 个」二级扩展菜单展示 base64。
      // 折叠时不构建，省掉整棵图片列表子树。
      if (requestExpanded && requestBlock.images.isNotEmpty)
        _ImageListBlock(images: requestBlock.images),
    ];
    // 预览请求体模式：只展示请求体块，不渲染 AI 返回区（序号也要按「只占一个块」
    // 推进，与 [_buildSnapshot] 保持一致——后续可用帧接着编号）。
    if (widget.previewRequestOnly) {
      return (
        widget: Column(
          key: Key('raw_exchange_$index'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
        nextBlockIndex: blockIndex + 1,
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
      const partLabels = <String>['思考块', '工具调用块', '正文块'];
      for (final label in partLabels) {
        final partBlockIndex = blockIndex;
        children.add(
          _CollapsibleBlock(
            label: label,
            text: blocks[partBlockIndex].text,
            query: _query,
            count: _countOf(partBlockIndex),
            expanded: _isBlockExpanded(partBlockIndex),
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
      // 无返回：以与其它文本块**同款的可选中文本**展示说明（失败原因 / 中性提示），
      // 既能鼠标选中复制，也参与关键词检索与定位（块序号与 [_buildSnapshot]
      // 的派生顺序保持一一对应）。
      final partBlockIndex = blockIndex;
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _HighlightText(
            key: _blockContentKeys.putIfAbsent(
              partBlockIndex,
              () => GlobalKey(),
            ),
            text: blocks[partBlockIndex].text,
            query: _query,
            currentIndex: _localCurrentIndex(partBlockIndex),
          ),
        ),
      );
      blockIndex++;
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
/// 展开状态由父级控制（供检索定位联动：当前定位块展开）。
class _CollapsibleBlock extends StatelessWidget {
  final String label;

  /// 展示文本（已按「转译换行符」处理）。
  final String text;

  /// 关键词（用于高亮）。
  final String query;

  /// 本块命中数（由父级的检索结果按块记下，避免每次重建都扫一遍全文）。
  final int count;

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
    required this.count,
    this.mono = false,
    required this.expanded,
    required this.onToggle,
    required this.currentMatchIndex,
    required this.contentKey,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: header,
          )
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
    context.notices.success('已复制完整 data URL');
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
              child: SelectableTextArea(
                child: Text(_preview(img), style: mono, maxLines: 2),
              ),
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

/// 可选中文本：按关键词高亮（命中黄底，「当前定位」橙底），等宽字体用于 JSON 展示。
///
/// **高亮刻意只换底色、不动字重**（debug / Ahem 实测，见 `.agents/2026-10-12-raw-perf.md`）：
/// 一块 20 万字符 / 12500 处命中的文本里普通段与高亮段交替出现，加粗要另走一套字形，
/// 排版从 0.7 s 涨到 12 s。只给「当前定位」那一处加粗也不划算——它随定位来回挪动，
/// 每点一次上一处 / 下一处都要整块重排（实测 0.55 s 涨到 2.6 s）。
/// 底色与前景色不换字形，交替着来几乎不要钱。
///
/// **排版刻意不用 `SelectableText.rich`**：它内层是 `EditableText` / `RenderEditable`，
/// 同一块 20 万字符 / 25 001 个 span 冷排版要 2.2 s；换成 `SelectionArea` + [RichText]
/// （`RenderParagraph`）只要 1.1 s，再按下述分段摊薄到 0.56 s，挪动「当前定位」的重排
/// 从 545 ms 降到 86 ms。
///
/// 分段用 [splitAtNewlines] 按硬换行切（预算 [_segmentBudget] 字符），段尾的 `\n`
/// 照旧留在本段——各段拼回原样，跨段选中复制才逐字相同。代价是每段都多一个段尾空行
/// （引擎把「最后一个换行之后」也算一行），由 [_TrimLine] 从各段容器的 size 里裁掉，
/// 于是总高与逐字位置和整块完全一致（实测 3819.00 = 3819.00，偏移 0.00 px）。
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

  /// 一段的字符预算：够大以免段数失控（每段都要一层合成层），够小以摊薄重排。
  /// 实测同一块 20 万字符：整块 545 ms / 2 万一段 86 ms / 5 千一段 75 ms /
  /// 2 千一段 66 ms——再切细收益递减，故取 2 万。
  static const int _segmentBudget = 20000;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final base = TextStyle(
      fontSize: 12.5,
      height: 1.5,
      fontFamily: mono ? 'monospace' : null,
      color: scheme.onSurfaceVariant,
    );
    final highlight = base.copyWith(
      backgroundColor: const Color(0xFFFFF176).withValues(alpha: 0.5),
    );
    final current = base.copyWith(
      backgroundColor: const Color(0xFFFFB74D).withValues(alpha: 0.6),
    );
    final pieces = splitAtNewlines(text, _segmentBudget);
    final rowHeight = _rowHeightOf(base, textScaler);
    final selectionColor = scheme.primary.withValues(alpha: 0.4);
    // 与其他可选中区域共用同一容器：选中即弹「复制 / 全选」工具条
    // （见 [SelectableTextArea]；框架自带的选中工具栏在此同样被抑制）。
    return SelectableTextArea(
      child: Builder(
        builder: (BuildContext context) {
          // registrar 由 SelectionArea 下发的 SelectionContainer 提供，必须在它下面取。
          final registrar = SelectionContainer.maybeOf(context);
          final segments = <Widget>[];
          var hitsBefore = 0;
          for (var i = 0; i < pieces.length; i++) {
            // 检索框是单行输入，关键词不含 `\n`，故逐段扫描与整块扫描结果一致。
            final hitsHere = countMatches(pieces[i], query);
            final localIndex =
                currentIndex >= hitsBefore &&
                    currentIndex < hitsBefore + hitsHere
                ? currentIndex - hitsBefore
                : -1;
            hitsBefore += hitsHere;
            segments.add(
              _TrimLine(
                // 末段那个空行整块本来就有，只裁前面各段的。
                amount: i == pieces.length - 1 ? 0.0 : rowHeight,
                child: RichText(
                  textScaler: textScaler,
                  selectionRegistrar: registrar,
                  selectionColor: selectionColor,
                  text: TextSpan(
                    children: highlightSpans(
                      pieces[i],
                      query,
                      base,
                      highlight,
                      currentIndex: localIndex,
                      currentStyle: current,
                    ),
                  ),
                ),
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: segments,
          );
        },
      ),
    );
  }
}

/// 一行的真实高度：量一个字。
///
/// 行盒按物理像素吸附，名义值（fontSize × height = 12.5 × 1.5 = 18.75）在实测环境里
/// 是 19.00；拿名义值会让每个段间接缝差四分之一像素、越往后漂得越多。
double _rowHeightOf(TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: 'M', style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}

/// 把子节点末尾 `amount` 像素从**自己的 size** 里裁掉；绘制与命中坐标一律照旧
/// （子节点仍从 (0,0) 画满、不偏移）。
///
/// 用于 [_HighlightText] 的分段：段尾那个空行照样画得出来（它本来什么都不画），
/// 却不再占位；被裁掉的那条横带归下一段的容器，下一段首行也就正好落回整块里的
/// 原始位置。
///
/// 现成的负偏移容器全被框架断言拦住（`RenderPadding` 要求 inset 非负、`RenderFlex`
/// 要求 `spacing >= 0`、`CustomMultiChildLayout` 的 size 不许依赖子节点），
/// 故只能自己写这一层 render object。
class _TrimLine extends SingleChildRenderObjectWidget {
  const _TrimLine({required this.amount, super.child});

  final double amount;

  @override
  _RenderTrimLine createRenderObject(BuildContext context) =>
      _RenderTrimLine(amount: amount);

  @override
  void updateRenderObject(BuildContext context, _RenderTrimLine renderObject) {
    if (renderObject.amount == amount) return;
    renderObject.amount = amount;
    renderObject.markNeedsLayout();
  }
}

class _RenderTrimLine extends RenderProxyBox {
  _RenderTrimLine({required this.amount});

  /// 末尾要裁掉的像素数；改动后须由 [updateRenderObject] 标脏。
  double amount;

  double _trimmed(double height) => height <= amount ? 0.0 : height - amount;

  @override
  void performLayout() {
    final RenderBox boxedChild = child!;
    boxedChild.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(
      Size(boxedChild.size.width, _trimmed(boxedChild.size.height)),
    );
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final childSize = child!.getDryLayout(constraints);
    return constraints.constrain(
      Size(childSize.width, _trimmed(childSize.height)),
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _trimmed(child!.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _trimmed(child!.getMaxIntrinsicHeight(width));
}
