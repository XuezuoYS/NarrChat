import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/notification_service.dart';

/// 通知设置状态：供主页提示「未开启系统通知」与「生成完成渠道悬浮 / 铃声被关」。
///
/// 仅 Android 有意义；[notificationsEnabled] 为 null 表示非 Android / 尚未检测。
/// 应用回到前台时自动重新检测（用户可能在系统设置里修改了通知开关）。
class NotificationSettingsProvider extends ChangeNotifier
    with WidgetsBindingObserver {
  NotificationSettingsProvider({required GenerationNotificationService service})
      : _service = service; // ignore: prefer_initializing_formals

  final GenerationNotificationService _service;

  bool? _notificationsEnabled;
  GenerationDoneChannelState? _channelState;

  /// 是否允许应用发送通知（null = 非 Android / 未知）。
  bool? get notificationsEnabled => _notificationsEnabled;

  /// 生成完成通知渠道的系统侧状态（null = 非 Android / 渠道尚未创建）。
  GenerationDoneChannelState? get generationDoneChannelState => _channelState;

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

  /// 重新检测系统通知开关与生成完成渠道的悬浮 / 铃声状态。
  Future<void> refresh() async {
    final enabled = await _service.areNotificationsEnabled();
    // 通知总开关都关了时渠道状态无意义，跳过探测（减少一次平台调用）。
    final channel = enabled == false
        ? null
        : await _service.generationDoneChannelState();
    if (enabled == _notificationsEnabled && channel == _channelState) return;
    _notificationsEnabled = enabled;
    _channelState = channel;
    notifyListeners();
  }

  /// 打开系统通知设置页（Android）。
  Future<void> openSettings() => _service.openNotificationSettings();
}
