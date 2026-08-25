import 'dart:async';

/// 连点检测器：在 [window] 时间内累计点击达到 3 次触发 [onTripleTap] 并清零；
/// 若两次点击间隔超过 [window] 则计数量重置。
///
/// 使用 [Timer] 而非基于 `DateTime.now()` 的差值实现，是为了让 `testWidgets`
/// 中的 `tester.pump(Duration)` 也能可靠地驱动「超窗重置」，便于隔离测试。
class TripleTapDetector {
  TripleTapDetector({
    this.window = const Duration(milliseconds: 800),
    required this.onTripleTap,
  });

  /// 相邻两次点击的时间窗口（超时则重新计数）。
  final Duration window;

  /// 累计 3 次点击时触发的回调。
  final void Function() onTripleTap;

  int _count = 0;
  Timer? _resetTimer;

  /// 记录一次点击；达到 3 次触发 [onTripleTap] 并清零，否则重置窗口计时。
  void tap() {
    _resetTimer?.cancel();
    _count++;
    if (_count >= 3) {
      _count = 0;
      onTripleTap();
      return;
    }
    _resetTimer = Timer(window, () => _count = 0);
  }

  /// 释放内部计时器（页面销毁时调用）。
  void dispose() {
    _resetTimer?.cancel();
    _resetTimer = null;
    _count = 0;
  }
}
