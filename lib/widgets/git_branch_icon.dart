import 'package:flutter/material.dart';

/// Git 分支图标（描边版，参照常见「git-branch」图形）。
///
/// 为什么自绘：Material 图标里没有形状对得上的分支图标（`alt_route` 是折线
/// 箭头、`call_split` 是分叉线、`account_tree` 是层级树），而分支入口散落在
/// 顶栏、链首卡片、分支面板与右键菜单多处，必须共用同一份绘制——以后调整
/// 分支图标只改这一处，不会出现「这页是树、那页是分叉」的混搭。
///
/// 形状：左侧主干上下各一个节点，右侧一个节点经圆角折线并入主干。
class GitBranchIcon extends StatelessWidget {
  const GitBranchIcon({super.key, this.size, this.color});

  /// 图标边长；不传时取 [IconTheme] 的 size（与 [Icon] 同一套口径）。
  final double? size;

  /// 描边颜色；不传时取 [IconTheme] 的 color，再回落到 `onSurface`。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 18;
    final resolvedColor =
        color ?? iconTheme.color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: resolvedSize,
      height: resolvedSize,
      child: CustomPaint(painter: GitBranchPainter(color: resolvedColor)),
    );
  }
}

/// [GitBranchIcon] 的画笔：按 24×24 设计稿等比缩放（线宽随尺寸一起缩）。
class GitBranchPainter extends CustomPainter {
  const GitBranchPainter({required this.color});

  final Color color;

  /// 设计稿边长。
  static const double _designSize = 24;

  /// 描边宽度（设计稿单位）。
  static const double _strokeWidth = 1.6;

  /// 节点圆环的描边中心线半径。
  static const double _nodeRadius = 2.4;

  /// 左侧主干上、下节点中心。
  static const Offset _topNode = Offset(7.6, 5.1);
  static const Offset _bottomNode = Offset(7.6, 18.9);

  /// 右侧分支节点中心。
  static const Offset _branchNode = Offset(16.4, 8.9);

  /// 分支折线并入主干的横段高度。
  static const double _joinY = 13.9;

  /// 折角圆半径。
  static const double _cornerRadius = 1.6;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _designSize;
    if (scale <= 0) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.scale(scale);
    // 主干：连接上下节点。端点落在圆环描边中心线上，与圆环无缝相接。
    canvas.drawLine(
      Offset(_topNode.dx, _topNode.dy + _nodeRadius),
      Offset(_bottomNode.dx, _bottomNode.dy - _nodeRadius),
      paint,
    );
    // 分支：从右侧节点下沿出发，圆角折向左并入主干。
    final branch = Path()
      ..moveTo(_branchNode.dx, _branchNode.dy + _nodeRadius)
      ..lineTo(_branchNode.dx, _joinY - _cornerRadius)
      ..quadraticBezierTo(
        _branchNode.dx,
        _joinY,
        _branchNode.dx - _cornerRadius,
        _joinY,
      )
      ..lineTo(_bottomNode.dx, _joinY);
    canvas.drawPath(branch, paint);
    // 三个节点圆环。
    for (final center in const [_topNode, _bottomNode, _branchNode]) {
      canvas.drawCircle(center, _nodeRadius, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(GitBranchPainter oldDelegate) =>
      oldDelegate.color != color;
}
