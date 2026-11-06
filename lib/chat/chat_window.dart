import 'package:flutter/foundation.dart';

/// 当前加载的轮次范围（两端都含）。
///
/// 为什么要窗口：一本书可能有几百轮，全量读正文会卡；但用户一次只看得到一屏，
/// 所以只保留「最近 30 轮」这一窗，读到哪扩到哪。
@immutable
class ChatWindow {
  const ChatWindow({required this.firstRoundIndex, required this.lastRoundIndex});

  /// 最早一轮（越大越新，`1` 是最老）。
  final int firstRoundIndex;

  /// 最新一轮。
  final int lastRoundIndex;

  int get roundCount => lastRoundIndex - firstRoundIndex + 1;

  bool contains(int roundIndex) =>
      roundIndex >= firstRoundIndex && roundIndex <= lastRoundIndex;

  /// 是否包含全书最新一轮（决定底部要不要插输入框留白）。
  bool includesTail(int totalRounds) => lastRoundIndex >= totalRounds;

  /// 是否包含全书最早一轮（决定顶部要不要插顶部留白）。
  bool includesHead() => firstRoundIndex <= 1;

  ChatWindow copyWith({int? firstRoundIndex, int? lastRoundIndex}) => ChatWindow(
        firstRoundIndex: firstRoundIndex ?? this.firstRoundIndex,
        lastRoundIndex: lastRoundIndex ?? this.lastRoundIndex,
      );

  @override
  bool operator ==(Object other) =>
      other is ChatWindow &&
      other.firstRoundIndex == firstRoundIndex &&
      other.lastRoundIndex == lastRoundIndex;

  @override
  int get hashCode => Object.hash(firstRoundIndex, lastRoundIndex);

  @override
  String toString() => 'ChatWindow($firstRoundIndex..$lastRoundIndex)';
}

/// 窗口层：决定"现在加载哪一段轮次"。
///
/// 三条原则（来自规格 §5）：
/// - **先看最新**：首屏取最近若干轮，不够两屏就继续往前扩，体感上要"一进来就在底部"；
/// - **只扩不裁**：滚动只会扩窗口，不重建（重建会让已读内容闪一下、也断跨轮复制）；
/// - **跳转才重建**：跳到远处才在目标附近重建窗口。
class ChatWindowController extends ChangeNotifier {
  ChatWindowController({
    this.initialRounds = 30,
    this.expandRounds = 20,
    this.minViewports = 2.0,
    this.prefetchViewports = 1.5,
    this.jumpRadius = 15,
    this.maxRounds = 200,
  });

  /// 首屏轮的轮数。
  final int initialRounds;

  /// 每次向上/向下扩的轮数。
  final int expandRounds;

  /// 首屏至少撑满几个视口。
  final double minViewports;

  /// 距窗口顶多近时预取。
  final double prefetchViewports;

  /// 跳转时在目标两侧各留多少轮。
  final int jumpRadius;

  /// 窗口轮数上限（内存保护）。
  final int maxRounds;

  int _totalRounds = 0;
  ChatWindow? _window;

  /// 全书轮数（不是窗口轮数）。
  int get totalRounds => _totalRounds;

  ChatWindow? get window => _window;

  bool get isInitialized => _window != null;

  /// 首屏建窗。
  ///
  /// [heightOfWindow] 回传"按当前窗口估算/实测的总高"，用来判断要不要继续往前扩；
  /// 首帧（`viewportDimension == 0`）判不出来就先按轮数建窗，布局完成后由
  /// [satisfyMinimumHeight] 补做。
  void initialize({
    required int totalRounds,
    double Function(ChatWindow window)? heightOfWindow,
    double viewportDimension = 0,
  }) {
    _totalRounds = totalRounds < 0 ? 0 : totalRounds;
    if (_totalRounds == 0) {
      _setWindow(null);
      return;
    }
    var first = _clampRound(_totalRounds - initialRounds + 1);
    final last = _totalRounds;
    // 首帧还没有视口高度时这里跳过；布局完成后由 [satisfyMinimumHeight] 补一次。
    if (heightOfWindow != null && viewportDimension > 0) {
      while (first > 1) {
        final height = heightOfWindow(
          ChatWindow(firstRoundIndex: first, lastRoundIndex: last),
        );
        if (height <= 0 || height >= viewportDimension * minViewports) break;
        first = _clampRound(first - expandRounds);
      }
    }
    _setWindow(
      ChatWindow(firstRoundIndex: first, lastRoundIndex: last),
    );
  }

  /// 首屏「至少撑满 [minViewports] 屏」的补做。
  ///
  /// 首帧通常拿不到视口高度（列表还没布局完），[initialize] 只能按轮数建窗；
  /// 布局完成后再调本方法，把窗口继续往前扩。只在**窗口仍贴着末端**时扩，
  /// 用户已经跳走就不要再动。返回是否改了窗口。
  bool satisfyMinimumHeight({
    required double Function(ChatWindow window) heightOfWindow,
    required double viewportDimension,
  }) {
    final window = _window;
    if (window == null || viewportDimension <= 0) return false;
    if (!window.includesTail(_totalRounds)) return false;
    var first = window.firstRoundIndex;
    while (first > 1) {
      final height = heightOfWindow(
        ChatWindow(firstRoundIndex: first, lastRoundIndex: window.lastRoundIndex),
      );
      if (height <= 0 || height >= viewportDimension * minViewports) break;
      final next = _clampRound(first - expandRounds);
      if (next == first) break;
      first = next;
    }
    if (first == window.firstRoundIndex) return false;
    _setWindow(
      ChatWindow(firstRoundIndex: first, lastRoundIndex: window.lastRoundIndex),
    );
    return true;
  }

  /// 换书 / 换分支：忘掉旧链的一切，下一帧按新链重新建窗。
  ///
  /// 刻意**不**通知（调用方正在 build 里换链，自己就会重建）；通知留到
  /// [initialize] / [setTotalRounds] 真正换了窗口时再发。
  void reset() {
    _totalRounds = 0;
    _window = null;
  }

  /// 全书轮数变化（新书 / 新增一轮）。
  ///
  /// 只有窗口本来就贴着末端时才尾随扩展；用户在翻历史时不该被新轮拽走。
  ///
  /// **不变量**：窗口必须落在 `[1, totalRounds]` 且 `first <= last`。旧实现只把
  /// `lastRoundIndex` 夹回新总数、`firstRoundIndex` 不动，链变短（换书 / 切分支 /
  /// 删轮）时会造出 `(91..10)` 这种**倒置窗**：`contains()` 恒 false → 列表一层
  /// 轮次都没有 → 对话页整页空白。这里改成「装不下就按尾部重建」。
  void setTotalRounds(int totalRounds) {
    final next = totalRounds < 0 ? 0 : totalRounds;
    if (next == _totalRounds) return;
    final window = _window;
    final oldTotal = _totalRounds;
    _totalRounds = next;
    if (next == 0) {
      _setWindow(null);
      return;
    }
    if (window == null) {
      initialize(totalRounds: next);
      return;
    }
    if (window.lastRoundIndex > next || window.firstRoundIndex > next) {
      // 新链比窗口覆盖的范围还短：窗口整体作废，从尾部重来。
      initialize(totalRounds: next);
      return;
    }
    final wasAtTail = window.includesTail(oldTotal);
    if (!wasAtTail) {
      // 用户正在翻历史：新轮不该把他拽走。
      notifyListeners();
      return;
    }
    final delta = next - oldTotal;
    _setWindow(
      _shrinkToLimit(ChatWindow(
        firstRoundIndex: window.firstRoundIndex,
        lastRoundIndex: _clampRound(window.lastRoundIndex + delta),
      )),
    );
  }

  /// 视口顶距窗口顶不到 [prefetchViewports] 个视口时，向上扩一页。返回是否扩了。
  bool expandUp({
    required double distanceToWindowTop,
    required double viewportDimension,
  }) {
    final window = _window;
    if (window == null || viewportDimension <= 0) return false;
    if (window.firstRoundIndex <= 1) return false;
    if (distanceToWindowTop > viewportDimension * prefetchViewports) {
      return false;
    }
    final first = _clampRound(window.firstRoundIndex - expandRounds);
    if (first == window.firstRoundIndex) return false;
    _setWindow(window.copyWith(firstRoundIndex: first));
    return true;
  }

  /// 视口底距窗口底不到一页时，向下扩（回看时用）。
  bool expandDown({
    required double distanceToWindowBottom,
    required double viewportDimension,
  }) {
    final window = _window;
    if (window == null || viewportDimension <= 0) return false;
    if (window.lastRoundIndex >= _totalRounds) return false;
    if (distanceToWindowBottom > viewportDimension * prefetchViewports) {
      return false;
    }
    final last = _clampRound(window.lastRoundIndex + expandRounds);
    if (last == window.lastRoundIndex) return false;
    _setWindow(window.copyWith(lastRoundIndex: last));
    return true;
  }

  /// 跳远：在 [targetRoundIndex] 附近重建窗口。
  void rebuildAround(int targetRoundIndex) {
    if (_totalRounds == 0) {
      _setWindow(null);
      return;
    }
    final target = _clampRound(targetRoundIndex);
    var first = _clampRound(target - jumpRadius);
    var last = _clampRound(target + jumpRadius);
    if (last > _totalRounds) last = _totalRounds;
    if (first < 1) first = 1;
    // 目标在很靠末端时，保证至少能看到它后面的（它是最新时就是末端）。
    if (last < target) last = target;
    _setWindow(ChatWindow(firstRoundIndex: first, lastRoundIndex: last));
  }

  int _clampRound(int roundIndex) {
    if (roundIndex < 1) return 1;
    if (_totalRounds > 0 && roundIndex > _totalRounds) return _totalRounds;
    return roundIndex;
  }

  /// 窗口轮数超上限时从远端收缩（保底 1 轮）。
  ChatWindow _shrinkToLimit(ChatWindow window) {
    if (window.roundCount <= maxRounds) return window;
    final overflow = window.roundCount - maxRounds;
    return ChatWindow(
      firstRoundIndex: _clampRound(window.firstRoundIndex + overflow),
      lastRoundIndex: window.lastRoundIndex,
    );
  }

  void _setWindow(ChatWindow? next) {
    if (_window == next) return;
    _window = next;
    notifyListeners();
  }
}
