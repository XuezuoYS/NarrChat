import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'chat_geometry.dart';
import 'chat_viewport.dart';

/// 帧末回调注入（默认由页面传 `addPostFrameCallback`）。
///
/// 抽成 typedef 是为了让定位器在纯 `test()` 里也能测：不传就没有"跳转后复核"，
/// 单次落点必须是精确的。
typedef ChatPostFrame = void Function(VoidCallback callback);

/// 页面侧把「窗口」变成真实列表的那一小部分能力。
///
/// 定位层自己不渲染任何东西，但它需要知道四件事：
/// 1. 目标轮在不在当前窗口里（顶部 / 底部跳转用）；
/// 2. 窗口的「坐标零点」在全书里的位置（把列表本地 `pixels` 换算成**全书偏移**）；
/// 3. 列表前导留白（底部避让输入面板那段）；
/// 4. 如何为一次显式轮次跳转准备窗口（目标要成为窗口第一行）。
///
/// 全书偏移换算（`reverse` 语义，`pixels = 0` 是列表最新端）：
/// ```
/// 书内距离 = 窗口基准 - 前导留白 + 本地距离
/// ```
/// 轮次跳转的窗口基准由**窗口最早一行 + 列表真实边界**反推：目标成为窗口首行时，
/// 落点只取决于这条真实边界，不再把目标之后几十个未构建行的估算高度累加进来。
abstract class ChatWindowHost {
  /// 目标轮是否已在当前窗口内。
  bool windowContainsRound(int roundIndex);

  /// 当前窗口是否包含全书最新一轮（贴底跟随 / 底部留白的判据）。
  bool get windowIncludesTail;

  /// 窗口最新一端距书底的距离（全书坐标）。
  double get windowBookOffsetBase;

  /// 列表前导留白（`reverse` 下是贴底一侧；没有留白时返回 0）。
  double get windowLeadingInset;

  /// 把窗口重建到目标轮附近并等它落地（顶部 / 底部跳转用）。
  Future<void> rebuildWindowAround(int roundIndex);

  /// 为「跳到第 [roundIndex] 轮」准备窗口并等它落地。
  ///
  /// 与 [rebuildWindowAround] 分开：显式轮次跳转要求目标成为窗口第一行，
  /// 且窗口坐标基准切到由真实列表边界反推的口径（见类注释）。
  Future<void> rebuildWindowForJump(int roundIndex);

  /// 请求按当前滚动方向预取一页（异步；拖动速度不受影响）。
  void ensureWindowExpanded();
}

/// 对话页「定位」能力的门面：轨道（ChatRail）、侧栏跳转、回底按钮只依赖它。
///
/// 分开定义的原因：组件是纯 UI，不该知道几何模型、窗口、滚动位置这些东西；
/// 它只要「现在第几轮 / 进度多少 / 跳到哪里 / 往上滚多快」。
/// 继承 [Listenable]：轨道要跟着进度刷新拇指，但不关心是谁在动。
abstract class ChatLocator implements Listenable {
  /// 视口**顶部**所在轮号（规格 §6.4）；几何为空时返回 null。
  int? get currentRoundIndex;

  /// 全书进度：0 = 贴底（最新），1 = 顶部（最早）；未挂上滚动位置时为 null。
  double? get progress;

  /// 视口占全书高度的比例（轨道的拇指长度）；未布局时为 null。
  double? get visibleFraction;

  /// 本书最大轮号（胶囊显示、数字跳转的上限）。
  int? get maxRoundIndex;

  /// 消息区可视高度（速度模型的满量程 = 1 个视口高）。
  double? get viewportDimension;

  /// 是否贴在底部（且窗口含末轮）：新内容到达时的自动跟随据此判断。
  bool get isPinnedToBottom;

  /// 跳到指定轮的起点。目标不存在时按「向下就近取整」；完全跳不了返回 false。
  Future<bool> jumpToRound(int roundIndex);

  Future<bool> jumpToTop();

  Future<bool> jumpToBottom();

  /// 按速度滚动（单位：**视口/秒**，正 = 往历史翻）。由轨道拖动驱动。
  void scrollByVelocity(double viewportsPerSecond);

  /// 立即归零（无惯性）。
  void stopVelocity();

  /// 放弃进行中的跳转复核（用户接管滚动时调用）。
  void cancelPendingJump();

  /// 几何高度变了（实测回填 / 占位高度变化）后通知监听者刷新拇指与进度。
  void notifyGeometryChanged();
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
    this.window,
    this.postFrame,
    this.maxVelocity = 1.6,
    this.maxJumpChecks = 10,
  }) : _geometry = geometry ?? ChatGeometry() {
    viewport.addListener(_onViewportChanged);
    // 不传 [vsync] 时保持 null：测试直接调 `advance` / `stepVelocity` 逐帧驱动
    // （纯 `test()` 里没有 SchedulerBinding，建了 Ticker 也没法 start）。
    _ticker = vsync?.createTicker(_onTick);
  }

  /// 被驱动的滚动视口（公开只读：调试与测试要读实时像素）。
  final ChatViewport viewport;

  /// 页面侧的窗口能力（纯单元测试可不传）。
  final ChatWindowHost? window;

  /// 跳转后的帧末复核（不传 = 只跳一次，不再复核）。
  final ChatPostFrame? postFrame;

  /// 速度上限（视口/秒）。轨道满位移时用它。
  final double maxVelocity;

  /// 跳转后最多复核几帧（高度回填会改变落点）。
  final int maxJumpChecks;

  ChatGeometry _geometry;

  /// 见构造注释：null = 由调用方逐帧驱动。
  Ticker? _ticker;

  double _velocity = 0;
  Duration _lastTick = Duration.zero;

  /// 待复核的跳转目标轮与已复核次数。
  int? _pendingJumpRound;
  int _jumpChecks = 0;

  /// 上一次落点是否被「列表当前可滚动上限」夹住（懒加载还在建行时会发生）。
  bool _lastJumpClamped = false;

  /// 一次跳转视为「已经稳定」的位移阈值。
  static const double _kJumpEpsilon = 1;

  /// 几何模型（窗口重建时整体替换）。
  ChatGeometry get geometry => _geometry;

  set geometry(ChatGeometry value) {
    if (identical(_geometry, value)) return;
    _geometry = value;
    notifyListeners();
  }

  /// 是否正在按速度滚动（轨道据此决定是否常亮）。
  bool get isScrolling => _velocity != 0;

  /// 是否还有待复核的轮次跳转。
  ///
  /// 页面据此在落点稳定前暂停向上预取：目标此刻是窗口第一行，若立刻把更早的轮次
  /// 插到它前面，就会把刚对齐的目标推走。向下预取不受影响（目标仍是第一行）。
  bool get hasPendingJump => _pendingJumpRound != null;

  /// 列表前导留白（底部避让输入面板那段）。
  double get _leadingInset => window?.windowLeadingInset ?? 0;

  /// 列表本地偏移 0 对应的**全书**偏移：`窗口基准 - 前导留白`。
  double get _bookBase => (window?.windowBookOffsetBase ?? 0) - _leadingInset;

  @override
  int? get currentRoundIndex {
    if (_geometry.itemCount == 0) return null;
    if (!viewport.hasClients) return _geometry.maxRoundIndex;
    // 视口顶边在全书坐标里的位置（规格 §6.4：当前轮 = 视口顶部那一轮）。
    final topOffset =
        _bookBase + viewport.pixels + viewport.viewportDimension;
    return _geometry.roundIndexAtOffset(topOffset);
  }

  @override
  double? get progress {
    if (!viewport.hasClients || _geometry.itemCount == 0) return null;
    return _geometry.progressOf(
      _bookBase + viewport.pixels,
      viewport.viewportDimension,
    );
  }

  @override
  double? get visibleFraction {
    if (!viewport.hasClients || _geometry.total <= 0) return null;
    return (viewport.viewportDimension / _geometry.total).clamp(0.0, 1.0);
  }

  @override
  int? get maxRoundIndex => _geometry.maxRoundIndex;

  @override
  double? get viewportDimension =>
      viewport.hasClients ? viewport.viewportDimension : null;

  @override
  bool get isPinnedToBottom {
    if (!viewport.hasClients) return true;
    final includesTail = window?.windowIncludesTail ?? true;
    return includesTail && viewport.pixels <= 1;
  }

  @override
  Future<bool> jumpToRound(int roundIndex) async {
    stopVelocity();
    cancelPendingJump();
    final resolved = _resolveRound(roundIndex);
    if (resolved == null) return false;
    // 先登记待复核，再重建窗口：重建过程本身会触发滚动通知，页面从这一刻起
    // 暂停向上预取，避免「目标刚成为窗口首行就被更早轮次挤走」。
    _pendingJumpRound = resolved;
    _jumpChecks = 0;
    final host = window;
    if (host != null) {
      // 即便目标已在当前窗口也要准备：旧窗口的基准可能把大量未构建行的估算高度
      // 累计进落点，这正是早期轮次越跳越偏的根因。
      await host.rebuildWindowForJump(resolved);
      // 等待期间被用户滚动取消：不要再把用户刚接管的视图拽回目标。
      if (_pendingJumpRound != resolved) return true;
      // 重建后仍然查不到：这一轮已经不在了（删轮 / 脏数据），什么都不做。
      if (_geometry.indexOfRound(resolved) == null) {
        _pendingJumpRound = null;
        return false;
      }
    }
    final moved = _applyJumpOffset(resolved);
    if (!moved && !_lastJumpClamped) {
      // 已经在目标位置：不算失败，也不再复核。
      _pendingJumpRound = null;
      return true;
    }
    // 落点被夹住 = 列表内容还在逐帧建出来，必须继续复核。
    _scheduleVerify();
    return true;
  }

  @override
  Future<bool> jumpToTop() async {
    stopVelocity();
    cancelPendingJump();
    final first = _geometry.firstRoundIndex;
    if (first == null) return false;
    final host = window;
    if (host != null) {
      // 即便首轮已在窗口内也要通知一次：页面可能还停在轮次跳转的“首行锚点”
      // 口径，顶部跳转要把它恢复成默认口径。
      await host.rebuildWindowAround(first);
    }
    if (!viewport.hasClients) return false;
    viewport.jumpTo(_clampOffset(double.infinity));
    notifyListeners();
    return true;
  }

  @override
  Future<bool> jumpToBottom() async {
    stopVelocity();
    cancelPendingJump();
    final host = window;
    final max = _geometry.maxRoundIndex;
    if (host != null && max != null) {
      // 窗口不含末轮时先把窗口挪回末端，否则「底部」只是当前窗口的底部；
      // 已含末轮时这次调用也让页面恢复默认基准（见 jumpToTop 的同类说明）。
      await host.rebuildWindowAround(max);
    }
    if (!viewport.hasClients) return false;
    viewport.jumpTo(_clampOffset(0));
    notifyListeners();
    return true;
  }

  @override
  void scrollByVelocity(double viewportsPerSecond) {
    if (!viewportsPerSecond.isFinite || !viewport.hasClients) return;
    cancelPendingJump();
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

  @override
  void cancelPendingJump() {
    _pendingJumpRound = null;
    _jumpChecks = 0;
  }

  @override
  void notifyGeometryChanged() => notifyListeners();

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
      // 已经贴到窗口边界：保持速度（手指还在推），并请页面扩窗。
      window?.ensureWindowExpanded();
      return;
    }
    viewport.jumpTo(next);
    // 逼近窗口边界时顺手预取，落地后速度继续。
    window?.ensureWindowExpanded();
    notifyListeners();
  }

  /// 目标轮不存在时「向下就近取整」到实际存在的轮（规格 §12）。
  int? _resolveRound(int roundIndex) {
    final max = _geometry.maxRoundIndex;
    if (max == null) return null;
    var target = roundIndex > max ? max : roundIndex;
    if (target < 1) return null;
    while (target >= 1 && _geometry.indexOfRound(target) == null) {
      target--;
    }
    return target >= 1 ? target : null;
  }

  /// 把目标轮的**顶边**对齐到视口顶部。返回是否真的移动了。
  bool _applyJumpOffset(int roundIndex) {
    if (!viewport.hasClients) return false;
    final index = _geometry.indexOfRound(roundIndex);
    if (index == null) return false;
    // `reverse` 下 `pixels` 是视口底边、且列表前置了一段留白：
    //   视口顶的书内距离 = 窗口基准 + (pixels + 视口高 - 前导留白)
    // 让目标顶边等于它即可。
    final target = _geometry.topEdgeOf(index) -
        (window?.windowBookOffsetBase ?? 0) +
        _leadingInset -
        viewport.viewportDimension;
    final maxOffset = math.max(0.0, viewport.maxOffset);
    // 落点被夹住 = 列表内容还在逐帧建出来（懒加载），这一跳不算定稿。
    _lastJumpClamped = target > maxOffset;
    final before = viewport.pixels;
    viewport.jumpTo(_clampOffset(target));
    notifyListeners();
    return (viewport.pixels - before).abs() >= _kJumpEpsilon;
  }

  /// 复核足够「稳定」所需的最少帧数。
  ///
  /// 为什么不能"一稳就停"：落点跳到新位置后，懒加载列表才逐帧把附近的行建出来
  /// 并回填实测高度（估算值常常差几倍），目标**下方**条目的高度一变，落点就变。
  /// 实测：跳到长书的第 1 轮时，前 4 帧每帧都还在新建行。给够几帧再判稳定。
  static const int _kJumpMinChecks = 4;

  void _scheduleVerify() {
    final post = postFrame;
    if (post == null || _pendingJumpRound == null) return;
    post(() {
      final round = _pendingJumpRound;
      if (round == null || !viewport.hasClients) return;
      if (_jumpChecks >= maxJumpChecks) {
        _pendingJumpRound = null;
        return;
      }
      _jumpChecks++;
      final moved = _applyJumpOffset(round);
      final settled =
          !moved && !_lastJumpClamped && _jumpChecks >= _kJumpMinChecks;
      if (settled) {
        _pendingJumpRound = null;
        return;
      }
      _scheduleVerify();
    });
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
