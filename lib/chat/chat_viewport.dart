import 'package:flutter/widgets.dart';

/// 视口的**像素接口**：几何模型只说"这一条该出现在哪个偏移"，
/// 真正把画面挪过去的是滚动容器。把这一层抽出来，定位器就能脱离 widget 树测试。
///
/// 坐标约定与 `ChatGeometry` 一致：**0 = 贴底（最新一端）**，值越大越往历史翻。
abstract class ChatViewport {
  /// 当前像素偏移（0 = 贴底）。
  double get pixels;

  /// 可视高度。
  double get viewportDimension;

  /// 可滚动上限（= 内容总高 - 视口高，且 ≥ 0）。
  double get maxOffset;

  /// 是否已经挂上滚动位置（首帧 / 页面切换期间可能为 false）。
  bool get hasClients;

  /// 立即跳到偏移（不带动画，超出范围由实现夹取）。
  void jumpTo(double offset);

  void addListener(VoidCallback listener);

  void removeListener(VoidCallback listener);
}

/// 包一层 [ScrollController] 的生产实现。
class ScrollViewport implements ChatViewport {
  ScrollViewport(this.controller);

  final ScrollController controller;

  ScrollPosition? get _position =>
      controller.hasClients ? controller.position : null;

  @override
  double get pixels {
    final position = _position;
    // 尚未完成首次布局时 `pixels` 也是不可读的（与 viewportDimension 同理）。
    if (position == null || !position.hasViewportDimension) return 0;
    return position.pixels;
  }

  @override
  double get viewportDimension {
    final position = _position;
    // `ScrollPosition.viewportDimension` 在首帧布局前读会抛 null check：
    // 轨道可能在列表完成布局之前就被构建（拖拽 / 侧栏联动触发的重建），
    // 这里按「尚无高度」处理，等下一帧布局完成自然拿到真值。
    if (position == null || !position.hasViewportDimension) return 0;
    return position.viewportDimension;
  }

  @override
  double get maxOffset {
    final position = _position;
    if (position == null || !position.hasContentDimensions) return 0;
    // reverse 列表的 atTop/atBottom 与正向相反，这里只认「距最新的像素距离」，
    // 上限恒为 maxScrollExtent - minScrollExtent。
    final extent =
        position.maxScrollExtent - position.minScrollExtent;
    return extent < 0 ? 0 : extent;
  }

  @override
  bool get hasClients => controller.hasClients;

  @override
  void jumpTo(double offset) {
    final position = _position;
    if (position == null) return;
    position.jumpTo(
      (position.minScrollExtent + offset)
          .clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);
}
