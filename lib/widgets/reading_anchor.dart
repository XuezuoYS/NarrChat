import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 「阅读位置锚定」：`reverse: true` 底部锚定列表中，**离底阅读期间**内容长高时
/// 把增长量补回滚动偏移，使读者正在看的内容原地不动。
///
/// ## 为什么需要
/// `reverse: true` 把新内容插在滚动坐标系起点（视觉底部）：
/// - **贴底时**这正是我们想要的——新正文把旧内容顶上去，读者始终看着最新一行；
/// - **用户已上翻阅读历史时**，视口**下方**的条目长高会把可视内容整体向上推
///   （`visualY = viewportDimension + pixels − offset`，下方内容长高 ⇒ 可视内容的
///   offset 变大 ⇒ 视觉上移）。实测：合成宿主里位移**恰好等于**长高的量；
///   真实对话页里一次结构插入 85px、持续流式增长 150px+（详见
///   `.agents/perf/reading_drift_probe_test.dart`）——表现为「读着读着整段内容自己
///   往上跑」。
///
/// ## 怎么做到
/// 1. [ReadingAnchorItem] 包住每个条目，只有**列表逻辑末尾**那一条（= 视口下方最近的
///    条目，流式正文就长在这里）在布局阶段把自己的实高上报给 [ReadingAnchor]；
/// 2. [ReadingAnchorScrollPhysics] 在**同一帧的布局阶段**取出「自上次读取以来的高度
///    增量」并补进滚动偏移 —— 修正发生在 `RenderViewport.performLayout` 的重试循环里
///    （`rendering/viewport.dart:1723-1740`），本帧即按修正后的位置重排重绘，
///    因此**不会产生可见的漂移帧**，也不会打断用户拖拽（不改滚动活动）。
///
/// ⚠️ 不以 `maxScrollExtent` 的增量为依据：懒加载列表的 extent 是**估算值**
/// （`rendering/sliver_list.dart:299-311`），一个超高子项会把平均高度拉爆，
/// 实测增量可达真实增长量的数十倍（7.6k px vs 数百 px）——按它补偿会一次跳飞。
///
/// 已知不覆盖：视口**上方**条目长高（不会推动可视内容，无需补偿）、
/// 底部留白变化（输入面板长高会推动内容，属 P1「底部留白不再依赖帧末测量」）。
class ReadingAnchor {
  Object? _source;
  double _height = 0;
  double _consumed = 0;

  /// 布局阶段由 [ReadingAnchorItem] 上报「视口下方最近条目」的实高。
  ///
  /// [source] 是上报者的身份（渲染对象）：来源换了（条目被重建、或末尾条目易主）
  /// 就重新对基，不把新来源的绝对高度当成增长量。
  void record(Object source, double height) {
    if (!identical(source, _source)) {
      _source = source;
      _consumed = height;
    }
    _height = height;
  }

  /// 取出「自上次读取以来的高度增量」（读取即清零；无增长返回 0）。
  double takeGrowth() {
    final growth = _height - _consumed;
    _consumed = _height;
    return growth;
  }
}

/// 把「视口下方内容长高」补回滚动偏移的滚动物理。
///
/// 贴底（`pixels == minScrollExtent`）时**不补偿**：保留「新内容自动把旧内容顶上去」
/// 的贴底语义；只有读者已离开底部时才补偿，从而保持阅读位置。
class ReadingAnchorScrollPhysics extends ScrollPhysics {
  const ReadingAnchorScrollPhysics({required this.anchor, super.parent});

  /// 测量来源（由宿主 State 持有，见 [ReadingAnchor]）。
  final ReadingAnchor anchor;

  /// 视为「已贴底、不补偿」的残余误差（px）。
  static const double atBottomEpsilon = 0.5;

  @override
  ReadingAnchorScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      ReadingAnchorScrollPhysics(anchor: anchor, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    // 先让父级物理（平台默认 + RangeMaintaining）把位置修到合法范围。
    final result = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    // 读取即清零：同一次布局的重试（本修正会触发 `RenderViewport` 重排一次）
    // 再进来时增量已为 0，不会重复补偿。
    final growth = anchor.takeGrowth();
    if (growth == 0) return result;
    if (newPosition.pixels <= newPosition.minScrollExtent + atBottomEpsilon) {
      // 贴底：不补偿，让新内容把旧内容顶上去。
      return result;
    }
    return (result + growth).clamp(
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
  }
}

/// 挂在每个条目上的「视口下方最近条目」实高测量部件（纯代理，不改变布局）。
///
/// 只有 [active] 为 true 的那一条（列表**逻辑末尾**、`reverse` 下位于视觉底部）
/// 参与测量：那里是流式正文生长的地方，它的长高会推动可视内容。
class ReadingAnchorItem extends SingleChildRenderObjectWidget {
  const ReadingAnchorItem({
    super.key,
    required this.anchor,
    required this.active,
    required super.child,
  });

  /// 测量结果去向（见 [ReadingAnchor]）。
  final ReadingAnchor anchor;

  /// 本条是否为「视口下方最近的条目」（列表逻辑末尾那一条）。
  final bool active;

  @override
  RenderReadingAnchorItem createRenderObject(BuildContext context) =>
      RenderReadingAnchorItem(anchor: anchor, active: active);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderReadingAnchorItem renderObject,
  ) {
    renderObject.anchor = anchor;
    if (renderObject.active != active) {
      renderObject.active = active;
      // 新上任的末尾条目本帧就要上报实高（条目易主时它的布局未必是脏的）。
      if (active) renderObject.markNeedsLayout();
    }
  }
}

/// [ReadingAnchorItem] 的渲染对象：布局阶段把自身实高上报给 [ReadingAnchor]。
class RenderReadingAnchorItem extends RenderProxyBox {
  RenderReadingAnchorItem({required this.anchor, required this.active});

  /// 测量结果去向（见 [ReadingAnchor]）。
  ReadingAnchor anchor;

  /// 本条是否为「视口下方最近的条目」。
  bool active;

  @override
  void performLayout() {
    super.performLayout();
    // 布局阶段上报：同一帧的 `RenderViewport` → `ScrollPhysics` 修正即读到它。
    // 只有布局过的条目会有实高；未布局（在 cache 区之外）的条目不会上报，
    // 那种情况下框架本身也不会因它重排可视内容（无需补偿）。
    if (active) anchor.record(this, size.height);
  }
}
