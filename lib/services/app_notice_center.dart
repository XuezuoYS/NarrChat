import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_notice.dart';

/// 应用内悬浮通知中心（单槽位 + FIFO 队列 + 同文案去重）。
///
/// 取代 Flutter 默认的 `ScaffoldMessenger` / `SnackBar`：
/// - **单槽位**：一次只在窗口正中显示一条，前一条消失后自动接上队列下一条；
/// - **去重**：同文案正在显示时重置驻留计时，仍在队列中时忽略新请求
///   （连点「已复制」不叠加）；
/// - **状态机自持**：`queued → visible(进入动画) → dwelling → exiting → removed`，
///   驻留计时归本中心（宿主只负责动画），因此宿主未挂载时也会到期，
///   不会出现「偶发异常下提示一直常驻」；
/// - **提前消失**：点击 / 按住划过调用 [dismissCurrent] 立即进入退出动画，
///   鼠标悬停不触发。
///
/// 由 `AppNoticeOverlay` 作为作用域提供；调用点通过 `context.notices` 取用。
class AppNoticeCenter extends ChangeNotifier {
  /// 进入动画时长（宿主据此播放）。
  static const Duration enterDuration = Duration(milliseconds: 200);

  /// 退出动画时长（宿主据此播放）。
  static const Duration exitDuration = Duration(milliseconds: 1000);

  /// 默认驻留时长（进入动画结束后开始计时）。
  static const Duration defaultDwell = Duration(seconds: 3);

  /// 待显示队列上限：超出时丢弃最旧的一条（保证内存与等待时长可控）。
  static const int maxPending = 8;

  final List<AppNotice> _pending = [];
  AppNotice? _current;
  bool _exiting = false;
  int _nextId = 0;
  Timer? _timer;

  /// 当前正在显示的条目（进入 / 驻留 / 退出动画期间均非空）。
  AppNotice? get current => _current;

  /// 当前条目是否已进入退出动画（宿主据此反向播放动画）。
  bool get isExiting => _exiting;

  /// 队列中待显示的条目数。
  int get pendingCount => _pending.length;

  /// 入队一条通知；[message] 为空白时忽略。
  ///
  /// [dwell] 缺省为 [defaultDwell]；[copyable] 见 [AppNotice.copyable]。
  void show(
    String message, {
    NoticeKind kind = NoticeKind.info,
    Duration? dwell,
    bool copyable = false,
  }) {
    if (message.trim().isEmpty) return;

    // 去重：正在显示（且未在退出）→ 重置驻留计时；仍在队列 → 忽略。
    final showing = _current;
    if (showing != null && !_exiting && showing.message == message) {
      _startDwell(showing);
      return;
    }
    if (_pending.any((n) => n.message == message)) return;

    _pending.add(
      AppNotice(
        id: _nextId++,
        message: message,
        kind: kind,
        dwell: dwell ?? defaultDwell,
        copyable: copyable,
      ),
    );
    if (_pending.length > maxPending) {
      _pending.removeAt(0);
    }
    if (_current == null) _advance();
    notifyListeners();
  }

  /// 成功 / 完成类提示。
  void success(String message, {Duration? dwell, bool copyable = false}) =>
      show(
        message,
        kind: NoticeKind.success,
        dwell: dwell,
        copyable: copyable,
      );

  /// 中性提示。
  void info(String message, {Duration? dwell, bool copyable = false}) => show(
    message,
    kind: NoticeKind.info,
    dwell: dwell,
    copyable: copyable,
  );

  /// 校验 / 需注意（非失败）提示。
  void warning(String message, {Duration? dwell, bool copyable = false}) =>
      show(
        message,
        kind: NoticeKind.warning,
        dwell: dwell,
        copyable: copyable,
      );

  /// 失败类提示。
  void error(String message, {Duration? dwell, bool copyable = false}) => show(
    message,
    kind: NoticeKind.error,
    dwell: dwell,
    copyable: copyable,
  );

  /// 立即进入退出动画（点击 / 按住划过回调）；已在退出中则忽略。
  void dismissCurrent() {
    final current = _current;
    if (current == null || _exiting) return;
    _beginExit(current.id);
  }

  /// 宿主退出动画播完的回调：移除当前条目并接上队列下一条。
  ///
  /// [id] 用于防止过期回调误删后来者（退出期间不会有新条目顶上）。
  void completeDismissal(int id) {
    if (_current?.id != id) return;
    _timer?.cancel();
    _timer = null;
    _current = null;
    _exiting = false;
    if (_pending.isNotEmpty) {
      _advance();
    }
    notifyListeners();
  }

  /// 清空队列与当前条目（测试用）。
  @visibleForTesting
  void reset() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _current = null;
    _exiting = false;
    _nextId = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// 取出队列首条作为当前条目并开始驻留计时。
  void _advance() {
    _current = _pending.removeAt(0);
    _exiting = false;
    _startDwell(_current!);
  }

  /// 重新开始「进入动画 + 驻留」计时，到点进入退出动画。
  void _startDwell(AppNotice notice) {
    _timer?.cancel();
    _timer = Timer(enterDuration + notice.dwell, () => _beginExit(notice.id));
  }

  /// 进入退出动画；同时挂一个兜底定时器，宿主异常（未挂载 / 掉帧）时也能移除。
  void _beginExit(int id) {
    if (_current?.id != id || _exiting) return;
    _exiting = true;
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(
      exitDuration + const Duration(milliseconds: 400),
      () => completeDismissal(id),
    );
  }
}
