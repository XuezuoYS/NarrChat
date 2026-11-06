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
    this.minRounds = 10,
    this.minViewports = 2.0,
    this.prefetchViewports = 1.5,
    this.jumpRadius = 15,
    this.maxRounds = 200,
    this.trimViewports = 4.0,
  });

  /// 首屏轮的轮数。
  final int initialRounds;

  /// 每次向上/向下扩的轮数。
  final int expandRounds;

  /// 首屏最少轮数（即使一屏都撑不满也不再往前扩）。
  final int minRounds;

  /// 首屏至少撑满几个视口。
  final double minViewports;

  /// 距窗口顶多近时预取。
  final double prefetchViewports;

  /// 跳转时在目标两侧各留多少轮。
  final int jumpRadius;

  /// 窗口轮数上限（内存保护）。
  final int maxRounds;

  /// 某一端距视口超过几个视口高时允许裁剪。
  final double trimViewports;

  int _totalRounds = 0;
  ChatWindow? _window;

  /// 全书轮数（不是窗口轮数）。
  int get totalRounds => _totalRounds;

  ChatWindow? get window => _window;

  bool get isInitialized => _window != null;

  /// 首屏建窗。
  ///
  /// [heightOfWindow] 回传"按当前窗口估算/实测的总高"，用来判断要不要继续往前扩；
  /// 返回 [viewerHeightUnknown] 表示高度还测不出来（首帧），那就先按轮数终止。
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
    var last = _totalRounds;
    // 不足两屏就继续往前扩（最少也留 minRounds 轮）。
    while (first > 1 &&
        last - first + 1 < minRounds) {
      first = _clampRound(first - expandRounds);
    }
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

  /// 全书轮数变化（新书 / 新增一轮）。
  ///
  /// 只有窗口本来就贴着末端时才尾随扩展；用户在翻历史时不该被新轮拽走。
  void setTotalRounds(int totalRounds) {
    final next = totalRounds < 0 ? 0 : totalRounds;
    if (next == _totalRounds) return;
    final window = _window;
    final oldTotal = _totalRounds;
    final wasAtTail = window != null && window.includesTail(oldTotal);
    _totalRounds = next;
    if (next == 0) {
      _setWindow(null);
      return;
    }
    if (window == null) {
      initialize(totalRounds: next);
      return;
    }
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

  /// 空闲时裁剪：轮数超上限、且某一端已经离视口很远，就把那一端丢掉。返回是否裁了。
  ///
  /// [keepRoundIndex] 是"用户正看着的那一轮"——裁到它就算到底，绝不让它被裁掉
  /// （否则用户会看到内容突然跳走）。
  bool trimIfNeeded({
    required double distanceToWindowTop,
    required double distanceToWindowBottom,
    required double viewportDimension,
    int? keepRoundIndex,
  }) {
    final window = _window;
    if (window == null || viewportDimension <= 0) return false;
    if (window.roundCount <= maxRounds) return false;
    final farTop =
        distanceToWindowTop > viewportDimension * trimViewports;
    final farBottom =
        distanceToWindowBottom > viewportDimension * trimViewports;
    if (!farTop && !farBottom) return false;
    // 优先裁离得远的那一端；两端都远就裁更远的。
    final trimTop = farTop && (!farBottom || distanceToWindowTop >= distanceToWindowBottom);
    final drop = expandRounds;
    final maxDrop = window.roundCount - minRounds;
    if (maxDrop <= 0) return false;
    var actual = drop > maxDrop ? maxDrop : drop;
    if (keepRoundIndex != null) {
      final allowed = trimTop
          ? keepRoundIndex - window.firstRoundIndex
          : window.lastRoundIndex - keepRoundIndex;
      if (allowed < actual) actual = allowed < 0 ? 0 : allowed;
    }
    if (actual <= 0) return false;
    _setWindow(
      trimTop
          ? window.copyWith(firstRoundIndex: _clampRound(window.firstRoundIndex + actual))
          : window.copyWith(lastRoundIndex: _clampRound(window.lastRoundIndex - actual)),
    );
    return true;
  }

  int _clampRound(int roundIndex) {
    if (roundIndex < 1) return 1;
    if (_totalRounds > 0 && roundIndex > _totalRounds) return _totalRounds;
    return roundIndex;
  }

  /// 窗口轮数超上限时从远端收缩（保底 [minRounds] 轮）。
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
