import 'package:flutter/material.dart';

/// 宽窄屏适配断点：可用宽度小于该值时使用窄屏（竖版）布局。
const double kResponsiveBreakpoint = 520;

/// 判断[available]（可用宽度）是否为窄屏（竖版）布局。
///
/// 供气泡等子组件与 [ResponsiveBuilder] 共用同一断点，避免魔法数重复。
/// 非有限宽度（极少见的无限约束上下文）按宽屏处理。
bool isNarrowWidth(double available) =>
    available.isFinite && available < kResponsiveBreakpoint;

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
