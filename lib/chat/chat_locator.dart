import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'chat_geometry.dart';
import 'chat_viewport.dart';

/// 对话页「定位」能力的门面：轨道（ChatRail）只依赖这个接口。
///
/// 分开定义的原因：轨道是纯 UI，不该知道几何模型、窗口、滚动位置这些东西；
/// 它只要「现在第几轮 / 进度多少 / 跳到哪里 / 往上滚多快」。
/// 继承 [Listenable]：轨道要跟着进度刷新拇指，但不关心是谁在动。
abstract class ChatLocator implements Listenable {
  /// 视口顶部所在的轮号；几何为空时返回 null。
  int? get currentRoundIndex;

  /// 滚动进度：0 = 贴底（最新），1 = 顶部（最早）；未挂上滚动位置时为 null。
  double? get progress;

  Future<void> jumpToRound(int roundIndex);

  Future<void> jumpToTop();

  Future<void> jumpToBottom();

  /// 按速度滚动（单位：**视口/秒**，正 = 往历史翻）。由轨道拖动驱动。
  void scrollByVelocity(double viewportsPerSecond);

  /// 立即归零（无惯性）。
  void stopVelocity();
}

/// 用几何模型当唯一坐标系的定位器实现。
///
/// 为什么不用 `ScrollController.animateTo`：窗口化之后列表里只有一窗内容，
/// 「第 N 轮在哪」只能由几何模型算出来，滚动容器自己的 extent 不再等于全书。
class ChatViewportController extends ChangeNotifier implements ChatLocator {
  ChatViewportController({
    required this.viewport,
    TickerProvider? vsync,
    ChatGeometry? geometry,
    this.maxVelocity = 1.6,
  }) : _geometry = geometry ?? ChatGeometry() {
    viewport.addListener(_onViewportChanged);
    // 不传 [vsync] 时保持 null：测试直接调 `advance` / `stepVelocity` 逐帧驱动
    // （纯 `test()` 里没有 SchedulerBinding，建了 Ticker 也没法 start）。
    _ticker = vsync?.createTicker(_onTick);
  }

  /// 被驱动的滚动视口（公开只读：调试与测试要读实时像素）。
  final ChatViewport viewport;

  /// 速度上限（视口/秒）。轨道满位移时用它。
  final double maxVelocity;

  ChatGeometry _geometry;

  /// 见构造注释：null = 由调用方逐帧驱动。
  Ticker? _ticker;

  double _velocity = 0;
  Duration _lastTick = Duration.zero;

  /// 几何模型（窗口重建时整体替换）。
  ChatGeometry get geometry => _geometry;

  set geometry(ChatGeometry value) {
    if (identical(_geometry, value)) return;
    _geometry = value;
    notifyListeners();
  }

  /// 是否正在按速度滚动（轨道据此决定是否常亮）。
  bool get isScrolling => _velocity != 0;

  @override
  int? get currentRoundIndex {
    if (_geometry.itemCount == 0) return null;
    return _geometry.roundIndexAt(_geometry.indexAt(viewport.pixels));
  }

  @override
  double? get progress {
    if (!viewport.hasClients || _geometry.itemCount == 0) return null;
    return _geometry.progressAt(viewport.pixels, viewport.viewportDimension);
  }

  @override
  Future<void> jumpToRound(int roundIndex) async {
    final index = _geometry.indexOfRound(roundIndex);
    if (index == null) return; // 该轮不在当前窗口里：调用方先扩窗（见窗口层）
    stopVelocity();
    // 落点口径：让目标轮的**首条目顶边**贴住视口顶。
    // `offsetOf(i)` 是「条目底边距底部的距离」，所以还要补这一条自己的高度；
    // 只用 offsetOf 会把目标条目的底边滚到视口顶 —— 看起来就是"跳过了半屏"。
    final offset = _geometry.offsetOf(index) + _geometry.heightOf(index);
    viewport.jumpTo(_clampOffset(offset));
    notifyListeners();
  }

  @override
  Future<void> jumpToTop() async {
    stopVelocity();
    viewport.jumpTo(_clampOffset(double.infinity));
    notifyListeners();
  }

  @override
  Future<void> jumpToBottom() async {
    stopVelocity();
    viewport.jumpTo(0);
    notifyListeners();
  }

  @override
  void scrollByVelocity(double viewportsPerSecond) {
    if (!viewportsPerSecond.isFinite || !viewport.hasClients) return;
    final clamped =
        viewportsPerSecond.clamp(-maxVelocity, maxVelocity).toDouble();
    if (clamped == 0) {
      stopVelocity();
      return;
    }
    final reversed = clamped != _velocity && (clamped > 0) != (_velocity > 0);
    _velocity = clamped;
    final ticker = _ticker;
    if (ticker == null) return; // 无 Ticker：由调用方逐帧驱动
    if (!ticker.isActive) {
      _lastTick = Duration.zero;
      ticker.start();
    } else if (reversed) {
      // 反向时不要拿很久以前的时间差算位移。
      _lastTick = Duration.zero;
    }
  }

  @override
  void stopVelocity() {
    _velocity = 0;
    final ticker = _ticker;
    if (ticker != null && ticker.isActive) ticker.stop();
    _lastTick = Duration.zero;
  }

  /// 推进一帧。Ticker 每帧调它；测试直接调它，不必真的跑动画。
  @visibleForTesting
  void advance(Duration timestamp) {
    final last = _lastTick;
    _lastTick = timestamp;
    if (last == Duration.zero) return; // 起步帧只记时间
    final dt = (timestamp - last).inMicroseconds / 1000000.0;
    if (dt <= 0) return;
    stepVelocity(dt);
  }

  /// 按 [dtSeconds] 推进一帧位移。测试可直接调用。
  @visibleForTesting
  void stepVelocity(double dtSeconds) {
    if (_velocity == 0 || !viewport.hasClients) return;
    final delta = _velocity * viewport.viewportDimension * dtSeconds;
    if (delta == 0) return;
    final next = _clampOffset(viewport.pixels + delta);
    if (next == viewport.pixels) {
      // 已经贴到边界：保持速度（手指还在推），但不再重绘。
      return;
    }
    viewport.jumpTo(next);
    notifyListeners();
  }

  void _onTick(Duration timestamp) => advance(timestamp);

  void _onViewportChanged() => notifyListeners();

  double _clampOffset(double offset) {
    if (!viewport.hasClients) return offset;
    return offset.clamp(0.0, math.max(0.0, viewport.maxOffset)).toDouble();
  }

  @override
  void dispose() {
    viewport.removeListener(_onViewportChanged);
    _ticker?.dispose();
    super.dispose();
  }
}
