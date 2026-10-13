import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// 折叠时末行收尾的安全缝（px）：宁可少露一丝丝空白，也不让下一行露头。
const double _kLastLineSlack = 0.5;

/// 高度可收起的正文容器（通用件，不针对具体业务）。
///
/// 用法：`CollapsibleContent(collapsedLines: 7, lineHeight: …, expanded: …, child: 长正文)`。
/// 正文行数超过 [collapsedLines] 且未 [expanded] 时**在布局阶段**裁切到「第
/// [collapsedLines] 行的下沿」——因此首帧即生效（没有「先全展开、下一帧再收起」
/// 的跳动），也不需要「先渲染再读 `context.size`」的两帧测量（框架禁止在 build
/// 里读 size）。
///
/// 行数按**实际排版**统计（见 `_countLines`），阈值 = 第 [collapsedLines] 行的
/// 下沿（实测，见 `collapsedHeight`）：既不能按源码换行符数行（软换行会多折
/// 行），也不能拿「整段排版高度」当阈值（Markdown 段落之间的块间距会把阈值推
/// 到某一行中间，那半截行照样被画出来——「多溢出了一点」就是这么来的）。
///
/// 裁切只是一层绘制裁剪 + 命中测试裁剪：正文**仍全部在渲染树内**，展开时
/// 无需重新排版，长按框选 / 复制等交互也不受影响。
///
/// 正文按**完整可用宽**排版（宽度不给任何控件让位）：收起时的省略号、展开 /
/// 收起控件都由调用方放在正文**之外**（如正文下方的尾行），本组件只管裁切。
///
/// [onCollapsedChanged] 在「是否需要收起」变化时回调（供调用方决定要不要显示
/// 展开控件）；回调发生在布局阶段，调用方只能在回调里登记状态，
/// 重新构建发生在下一帧（框架禁止布局中 setState）。
class CollapsibleContent extends SingleChildRenderObjectWidget {
  const CollapsibleContent({
    super.key,
    required this.collapsedLines,
    required this.lineHeight,
    required this.expanded,
    this.onCollapsedChanged,
    super.child,
  });

  /// 收起时可显示的正文行数（超过则收起）。
  final int collapsedLines;

  /// 正文一行的自然高度（px）：调用方按正文样式给出（随文字缩放变化）。
  /// 收起阈值按「实际排版的第 N 行下沿」实测，这里只作数不出段落时的兜底。
  final double lineHeight;

  /// 是否已展开（展开时不裁切）。
  final bool expanded;

  /// 「是否需要收起（正文行数多于 [collapsedLines]）」变化时回调。
  final ValueChanged<bool>? onCollapsedChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderCollapsibleContent(
        collapsedLines: collapsedLines,
        lineHeight: lineHeight,
        expanded: expanded,
        onCollapsedChanged: onCollapsedChanged,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderCollapsibleContent renderObject,
  ) {
    renderObject
      ..collapsedLines = collapsedLines
      ..lineHeight = lineHeight
      ..expanded = expanded
      ..onCollapsedChanged = onCollapsedChanged;
  }
}

/// [CollapsibleContent] 的渲染对象：未展开时按 [collapsedHeight] 裁切子级。
class RenderCollapsibleContent extends RenderProxyBox {
  RenderCollapsibleContent({
    required int collapsedLines,
    required double lineHeight,
    required bool expanded,
    ValueChanged<bool>? onCollapsedChanged,
  })  :
        // ignore: prefer_initializing_formals
        _collapsedLines = collapsedLines,
        // ignore: prefer_initializing_formals
        _lineHeight = lineHeight,
        // ignore: prefer_initializing_formals
        _expanded = expanded,
        // ignore: prefer_initializing_formals
        _onCollapsedChanged = onCollapsedChanged;

  int _collapsedLines;

  /// 收起时可显示的正文行数。
  int get collapsedLines => _collapsedLines;

  set collapsedLines(int value) {
    if (_collapsedLines == value) return;
    _collapsedLines = value;
    markNeedsLayout();
  }

  bool _expanded;

  /// 是否展开（展开态不裁切）。
  bool get expanded => _expanded;

  set expanded(bool value) {
    if (_expanded == value) return;
    _expanded = value;
    markNeedsLayout();
  }

  ValueChanged<bool>? _onCollapsedChanged;

  set onCollapsedChanged(ValueChanged<bool>? value) =>
      _onCollapsedChanged = value;

  /// 正文自然（未裁切）高度。
  double _fullHeight = 0;

  /// 正文自然（未裁切）高度：展开后本节点会有多高（收起态下也能量到）。
  /// 供调用方算「展开会让上方内容上移多少」（见 `UserBubbleBody` 的滚动锁定）。
  double get naturalHeight => _fullHeight;

  /// 正文总行数（由各段落排版结果统计）。
  int _lineCount = 0;

  /// 实测的第 [collapsedLines] 行的下沿（px）；量不出段落时为 null。
  double? _measuredCollapseHeight;

  /// 折叠生效时的阈值（px）：正文里第 [collapsedLines] 行的下沿。
  ///
  /// 由**实际排版**逐段量出来（见 [_measureCollapseHeight]），不是「行高 × 行数」
  /// 的估算：多段 Markdown 的各行分散在不同 [RenderParagraph] 里，每段的行高、
  /// 末尾 leading 都不一样，估算会偏，偏一点就会让下一行露头。
  /// [lineHeight] 只作为「数不出段落」时的兜底。
  ///
  /// 公开只读：供调用方 / 测试核对「正好 N 行」。
  double get collapsedHeight =>
      _measuredCollapseHeight ?? _lineHeight * _collapsedLines - _kLastLineSlack;

  double _lineHeight;

  /// 正文一行的自然高度（px）；由调用方按正文样式给出。
  double get lineHeight => _lineHeight;

  set lineHeight(double value) {
    if (_lineHeight == value) return;
    _lineHeight = value;
    markNeedsLayout();
  }

  /// 正文是否多于 [CollapsibleContent.collapsedLines] 行。
  bool get needsCollapse => _lineCount > _collapsedLines;

  /// 当前是否已裁切（供绘制 / 命中测试判断）。
  bool get _clipped => !_expanded && needsCollapse;

  /// 上一帧对外报告的状态（回调只在翻转时触发）。
  bool? _reportedNeedsCollapse;

  @override
  void performLayout() {
    // 只放开高度上限：宽度约束原样传下去（正文高度只由宽度决定），
    // 因此「量到的高度」一定是未裁切的自然高度。
    // 宽度不缩水：正文按**完整可用宽**排版，展开控件放在正文之外（尾行），
    // 不挤占任何一行的换行宽度。
    // parentUsesSize：本节点要读子级 size 来决定自己的裁切高度。
    child?.layout(
      constraints.copyWith(maxHeight: double.infinity),
      parentUsesSize: true,
    );
    _fullHeight = child?.size.height ?? 0;
    _lineCount = child == null ? 0 : _countLines(child!);
    _measuredCollapseHeight =
        child == null ? null : _measureCollapseHeight(child!);
    // 宽度取可用宽（有界时）：调用方（如气泡正文列）按本节点铺满。无界宽
    // （如放进 Row 里自测）时退回按正文收窄。
    final width = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : (child?.size.width ?? 0);
    // 需要收起 → 硬裁切到阈值（且不超过父级高度上限）；否则原样铺开。
    size = constraints.constrain(
      Size(width, _clipped ? collapsedHeight : _fullHeight),
    );
    _reportNeedsCollapse();
  }

  /// 统计已排版正文的总行数（段落逐段累加；非文本子级不计）。
  ///
  /// 段落的行数取「整段选区命中的行框数」——它反映的是**实际排版**结果，
  /// 自动换行、软换行折叠都算在内，与用户看到的行数一致。
  int _countLines(RenderObject node) {
    var lines = 0;
    void visit(RenderObject child) {
      if (child is RenderParagraph) {
        lines += _lineBoxes(child).length;
        return;
      }
      child.visitChildren(visit);
    }

    node.visitChildren(visit);
    return lines;
  }

  /// 量出「第 [collapsedLines] 行的下沿」在正文里的纵向位置（px）。
  ///
  /// 逐段扫过，只用**行框**（`getBoxesForSelection`，布局期可安全读取）与段落相对
  /// 正文的位置：
  /// - 边界落在某段之内 → 该段第 need 行的下沿 = 行字框底 + 半份行间空隙；
  /// - 边界正好落在段末 → 取该段最后一个行框的底 + 半份行间空隙（行与行之间的
  ///   空档，切在这里既不切上一行的字，也够不到下一段的首行）。
  ///
  /// 行间空隙的推算：段内行距（相邻行框底之差）− 行字框高；段内只有一个行框时
  /// 退回「调用方给的行高 − 行字框高」。段落位置取 [RenderObject.localToGlobal]
  /// （它读的是自身 size，布局期合法），段落之间的块间距因此不用手算。
  double? _measureCollapseHeight(RenderObject node) {
    final body = node is RenderBox ? node : null;
    if (body == null) return null;
    var consumed = 0;
    double? boundary;

    void walk(RenderObject object) {
      if (boundary != null) return;
      if (object is RenderParagraph) {
        final lines = _lineBoxes(object);
        if (lines.isEmpty) return;
        if (consumed + lines.length < _collapsedLines) {
          consumed += lines.length;
          return;
        }
        final top = object.localToGlobal(Offset.zero, ancestor: body).dy;
        boundary = top + _lineBottom(lines, _collapsedLines - consumed - 1);
        return;
      }
      object.visitChildren(walk);
    }

    body.visitChildren(walk);
    return boundary;
  }

  /// 段落的行字框（按视觉顺序）。
  List<Rect> _lineBoxes(RenderParagraph paragraph) {
    final length = paragraph.text.toPlainText().length;
    if (length == 0) return const [];
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: length),
    );
    return [for (final b in boxes) b.toRect()];
  }

  /// 第 [index] 行的**下沿**（段落局部坐标）。
  ///
  /// 行的下沿不是字框底：字框只包字形，行距多出来的空隙上下各半，所以取
  /// 「字框底 + 半份空隙」。空隙用**整段的平均行距**推算（相邻行框底之差对唯一
  /// 一对行才是那个行距；用单个字框的高度会因字形升降部不同而算歪）。
  double _lineBottom(List<Rect> lines, int index) {
    if (lines.length <= 1) {
      // 段内只有一行：行距只能按调用方给的行高估。
      final box = lines.first;
      final gap = _lineHeight > box.height ? _lineHeight - box.height : 0.0;
      return box.bottom + gap / 2;
    }
    final pitch = (lines.last.bottom - lines.first.bottom) / (lines.length - 1);
    final lineHeight = (lines.last.bottom - lines.first.top) / lines.length;
    final gap = pitch > lineHeight ? pitch - lineHeight : 0.0;
    final i = index.clamp(0, lines.length - 1);
    return lines[i].bottom + gap / 2;
  }

  /// 「是否需要收起」只在布局阶段才知道，故在帧末回调（禁止在布局中 setState）。
  void _reportNeedsCollapse() {
    final needs = needsCollapse;
    if (_reportedNeedsCollapse == needs) return;
    _reportedNeedsCollapse = needs;
    final callback = _onCollapsedChanged;
    if (callback == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => callback(needs));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final box = child;
    if (box == null) return;
    if (!_clipped) {
      context.paintChild(box, offset);
      return;
    }
    context.pushClipRect(
      needsCompositing,
      offset,
      paintClipRect,
      (context, offset) => context.paintChild(box, offset),
    );
  }

  /// 收起时的绘制裁剪区域（局部坐标）：**严格等于可见区域**，一像素也不多放。
  ///
  /// 这里曾误写成「高度 + 横向留白」：那是给展开控件的**横向**让位（约两行高），
  /// 加到裁剪高度上会让裁剪线多放出正好两行——气泡下方漏出两行文字就是这么来的。
  @visibleForTesting
  Rect get paintClipRect => Offset.zero & size;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (child == null) return false;
    // 被裁掉的部分不接受点击 / 框选（它既看不见，也不该被选中）。
    if (_clipped && position.dy > size.height) return false;
    return super.hitTestChildren(result, position: position);
  }
}
