import 'package:flutter/material.dart';

/// 宽窄屏适配断点：可用宽度小于该值时使用窄屏（竖版）布局。
const double kResponsiveBreakpoint = 520;

/// 响应式构建器：以 [kResponsiveBreakpoint] 为界回调 [builder]。
///
/// 供各处「宽屏 / 窄屏双布局」复用，避免断点魔法数与 `LayoutBuilder` 样板重复。
///
/// 用法：
/// ```dart
/// ResponsiveBuilder(
///   builder: (context, isWide) =>
///       isWide ? _buildWide(context) : _buildNarrow(context),
/// )
/// ```
class ResponsiveBuilder extends StatelessWidget {
  final Widget Function(BuildContext context, bool isWide) builder;

  const ResponsiveBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          builder(context, constraints.maxWidth >= kResponsiveBreakpoint),
    );
  }
}
