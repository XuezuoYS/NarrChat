import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/notification_service.dart';

/// 通知设置状态：供主页提示「未开启系统通知」。
///
/// 仅 Android 有意义；[notificationsEnabled] 为 null 表示非 Android / 尚未检测。
/// 应用回到前台时自动重新检测（用户可能在系统设置里修改了通知开关）。
class NotificationSettingsProvider extends ChangeNotifier
    with WidgetsBindingObserver {
  NotificationSettingsProvider({required GenerationNotificationService service})
      : _service = service; // ignore: prefer_initializing_formals

  final GenerationNotificationService _service;

  bool? _notificationsEnabled;

  /// 是否允许应用发送通知（null = 非 Android / 未知）。
  bool? get notificationsEnabled => _notificationsEnabled;

  /// 注册生命周期监听并立即检测一次（在 [main] 中调用）。
  void attach() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
    }
  }

  /// 重新检测系统通知是否开启。
  Future<void> refresh() async {
    final value = await _service.areNotificationsEnabled();
    if (value == _notificationsEnabled) return;
    _notificationsEnabled = value;
    notifyListeners();
  }

  /// 打开系统通知设置页（Android）。
  Future<void> openSettings() => _service.openNotificationSettings();
}
