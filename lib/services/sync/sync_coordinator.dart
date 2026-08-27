import 'dart:async';

import 'sync_models.dart';

/// 一次平面任务的执行结果（由任务处理器返回，协调层据此落定该平面状态）。
class SyncTaskOutcome {
  /// 任务结束后该平面应处于的状态（success / error / idle=已取消）。
  final SyncState state;

  /// 结果提示文案（null = 无提示；静默抑制逻辑由调用方结合 [silent] 处理）。
  final String? message;

  /// 提示是否驻留（失败类需留意）。
  final bool persistent;

  /// 数据平面专属：本次结果的代数（供聚合 getter / 文案）。
  final int? generation;

  const SyncTaskOutcome(
    this.state, {
    this.message,
    this.persistent = false,
    this.generation,
  });
}

/// 协调层注入给平面任务的执行上下文。
class SyncTaskContext {
  final SyncPlane plane;

  /// 本次派发是否静默（轮询 / 回前台 / 被动触发：成功类结果不提示）。
  final bool silent;

  /// 上报进度（仅当该平面仍在执行时生效）。
  final void Function(SyncProgressEvent event) reportProgress;

  /// 协作式取消检查（用户取消本平面后返回 true）。
  final bool Function() isCancelled;

  const SyncTaskContext({
    required this.plane,
    required this.silent,
    required this.reportProgress,
    required this.isCancelled,
  });
}

/// 云同步统一触发 / 串行派发协调层（两平面生命周期的"总闸"）。
///
/// 设计要点（对齐 docs/sync_auto_triggers.md）：
/// - **两条独立生命周期**：数据 / 图片平面各自维护状态、进度、取消与结果，
///   互不遮蔽（图片慢慢传 30 张大图不会让"数据同步"一直转，反之亦然）；
/// - **单执行道串行派发**：两平面共享同一 WebDAV 目录与软锁 `sync.lock`，
///   同设备上并发会让 manifest / 墓碑 / 快照的读-改-写互相覆盖，因此
///   "并行"指生命周期独立，而非同时打网络。跨设备并行由软锁保证；
/// - **执行期间合并待跑**：每平面一个 pending 位 + silent 位（与运算合并：
///   任一非静默触发 → 不静默），任务结束后自动补跑一次；同步幂等，安全；
/// - **数据优先**：双平面同时待跑时先跑数据（数据落地会改变图片引用集，
///   图片随后收敛，避免图片平面先跑完又被引用集变化 invalidate）；
/// - **分平面取消**：只影响本平面（运行中 → 协作式停止；待跑 → 撤销排队），
///   另一平面的排队不受影响。
class SyncCoordinator {
  /// 平面任务处理器：由持有方（CloudSyncProvider）实现，负责建连与落地。
  final Future<SyncTaskOutcome> Function(SyncTaskContext ctx) runTask;

  /// 状态 / 进度变化通知（UI 重建）。
  final void Function() onChanged;

  /// 任务结束回调（结果提示；含本次是否静默）。
  final void Function(SyncPlane plane, SyncTaskOutcome outcome, bool silent)
  onResult;

  SyncCoordinator({
    required this.runTask,
    required this.onChanged,
    required this.onResult,
  });

  SyncPlane? _running;
  bool _forceBusyForTest = false;

  /// 分平面取消请求标记（运行中：协作式停止；待跑：撤销排队）。
  final Map<SyncPlane, bool> _cancelRequested = {
    for (final p in SyncPlane.values) p: false,
  };

  final Map<SyncPlane, bool> _pending = {
    for (final p in SyncPlane.values) p: false,
  };
  final Map<SyncPlane, bool> _pendingSilent = {
    for (final p in SyncPlane.values) p: false,
  };
  final Map<SyncPlane, SyncState> _states = {
    for (final p in SyncPlane.values) p: SyncState.idle,
  };
  final Map<SyncPlane, SyncProgressEvent?> _progress = {
    for (final p in SyncPlane.values) p: null,
  };

  final List<Completer<void>> _idleWaiters = [];

  // ---------------------------------------------------------------------------
  // 读取接口（供 provider / UI）
  // ---------------------------------------------------------------------------
  SyncState stateOf(SyncPlane plane) => _states[plane]!;
  SyncProgressEvent? progressOf(SyncPlane plane) => _progress[plane];
  bool pendingOf(SyncPlane plane) => _pending[plane]!;
  bool get isRunning => _running != null;

  /// 执行道是否被占用（有平面正在跑 / 测试强制忙）。
  bool get laneBusy => _running != null || _forceBusyForTest;

  /// 指定平面是否处于"运行中或已排队待跑"。
  bool isActive(SyncPlane plane) =>
      _running == plane || _pending[plane]! || _forceBusyForTest;

  // ---------------------------------------------------------------------------
  // 触发 / 取消
  // ---------------------------------------------------------------------------

  /// 触发一次指定平面的同步。
  ///
  /// 空闲 → 立即执行；执行道忙 → 置该平面待跑位（多次触发合并为一次补跑）。
  void trigger(SyncPlane plane, {bool silent = false}) {
    if (_pending[plane]!) {
      // 已排队：合并静默标记（任一非静默触发 → 结果需要提示）。
      _pendingSilent[plane] = _pendingSilent[plane]! && silent;
    } else {
      _pending[plane] = true;
      _pendingSilent[plane] = silent;
    }
    _pump();
  }

  /// 取消指定平面：运行中 → 协作式停止（阶段间检查）；待跑 → 撤销排队。
  void cancel(SyncPlane plane) {
    _pending[plane] = false;
    _pendingSilent[plane] = false;
    _cancelRequested[plane] = true;
    onChanged();
  }

  /// 指定平面是否已有未消费的取消请求（HUD 取消按钮断言 / 调试用）。
  bool debugCancelRequested(SyncPlane plane) => _cancelRequested[plane]!;

  /// 等待执行道完全空闲（无运行中、无待跑）。
  Future<void> get onIdle {
    if (!laneBusy &&
        !_pending.values.any((p) => p) &&
        _running == null) {
      return Future.value();
    }
    final c = Completer<void>();
    _idleWaiters.add(c);
    return c.future;
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------
  void _pump() {
    if (_running != null || _forceBusyForTest) return;
    // 数据优先：数据平面落地会改变图片引用集。
    final next = _pending[SyncPlane.data]!
        ? SyncPlane.data
        : _pending[SyncPlane.images]!
        ? SyncPlane.images
        : null;
    if (next == null) {
      _drainIdle();
      onChanged();
      return;
    }
    _pending[next] = false;
    final silent = _pendingSilent[next]!;
    _pendingSilent[next] = false;
    _cancelRequested[next] = false;
    _running = next;
    _states[next] = SyncState.syncing;
    _progress[next] = null;
    onChanged();
    unawaited(_execute(next, silent));
  }

  Future<void> _execute(SyncPlane plane, bool silent) async {
    SyncTaskOutcome outcome;
    try {
      outcome = await runTask(
        SyncTaskContext(
          plane: plane,
          silent: silent,
          reportProgress: (event) {
            if (_running != plane) return;
            _progress[plane] = event;
            onChanged();
          },
          isCancelled: () => _running == plane && _cancelRequested[plane]!,
        ),
      );
    } catch (e) {
      outcome = SyncTaskOutcome(SyncState.error, message: '$e', persistent: true);
    }
    _running = null;
    _states[plane] = outcome.state;
    _progress[plane] = null;
    onResult(plane, outcome, silent);
    _pump();
  }

  void _drainIdle() {
    if (_idleWaiters.isEmpty) return;
    final waiters = [..._idleWaiters];
    _idleWaiters.clear();
    for (final c in waiters) {
      if (!c.isCompleted) c.complete();
    }
  }

  // ---------------------------------------------------------------------------
  // 测试钩子（避免依赖真实网络路径验证队列语义；
  // 生产侧仅由持有方 CloudSyncProvider 的 debug 包装透传，勿在业务代码调用）
  // ---------------------------------------------------------------------------
  void debugSetState(SyncPlane plane, SyncState state) {
    _states[plane] = state;
    onChanged();
  }

  void debugSetProgress(SyncPlane plane, SyncProgressEvent? event) {
    _progress[plane] = event;
    onChanged();
  }

  /// 强制占用执行道（验证排队合并 / 取消语义，不发起任何任务）。
  void debugSetLaneBusy(bool value) {
    _forceBusyForTest = value;
    if (!value) _pump();
  }
}
