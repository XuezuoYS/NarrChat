import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:window_manager/window_manager.dart';

import '../config/chat_route.dart';
import '../models/book.dart';
import '../providers/book_provider.dart';
import '../screens/chat_screen.dart';

/// 生成完成系统通知服务。
///
/// 职责：
/// - 监听应用生命周期（前台 / 后台 / 未聚焦）；
/// - 通过内部 [NavigatorObserver] 跟踪「当前栈顶是否正在查看某本书的对话页」；
/// - 生成任务成功完成且用户不在该书 chat 页时弹出系统通知（点击可回到对应书 chat 页）；
/// - 用户未点击但自行进入对应书 chat 页时自动删除该通知。
class GenerationNotificationService with WidgetsBindingObserver {
  GenerationNotificationService({
    required BookProvider bookProvider,
    NotificationBackend? backend,
  })  : _backend = backend ?? FlutterLocalNotificationBackend(),
        // ignore: prefer_initializing_formals
        _bookProvider = bookProvider;

  final BookProvider _bookProvider;
  final NotificationBackend _backend;

  /// 挂到 [MaterialApp.navigatorKey]，供通知点击回调在全局任意位置导航。
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// 挂到 [MaterialApp.navigatorObservers]，用于识别当前可见的对话页。
  late final _ChatRouteObserver _routeObserver =
      _ChatRouteObserver(_onRouteStackChanged);
  NavigatorObserver get routeObserver => _routeObserver;

  /// 当前栈顶正在查看的 chat 页 bookId（无则 null）。
  int? get topChatBookId => _topChatBookId;

  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  int? _topChatBookId;

  /// Android 后台生成保活前台服务通知 id（与书籍完成通知的 bookId 错开）。
  static const int _kForegroundNotificationId = 0x4E43;

  /// 当前是否有生成任务在跑（由 [RoundProvider] 上报）。
  bool _backgroundTaskActive = false;

  /// 前台服务是否已启动（避免重复启动）。
  bool _foregroundServiceRunning = false;

  /// 初始化通知插件并注册生命周期监听（在 [main] 中调用一次）。
  Future<void> init() async {
    await _backend.init(onTap: _onNotificationTap);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    // 回到前台（窗口重新获得焦点 / 应用回到前台）时，
    // 若当前正在查看某本书的 chat 页，则删除该书的通知。
    if (state == AppLifecycleState.resumed) {
      final id = _topChatBookId;
      if (id != null) unawaited(dismissForBook(id));
    }
  }

  /// 路由栈变化：更新「当前可见 chat 页」，进入某书 chat 页即删除其通知。
  void _onRouteStackChanged() {
    final newTop = _routeObserver.topChatBookId;
    final changed = newTop != _topChatBookId;
    _topChatBookId = newTop;
    if (changed && newTop != null) {
      unawaited(dismissForBook(newTop));
    }
  }

  /// 生成任务成功完成回调（由 [RoundProvider] 在落库成功后触发）。
  ///
  /// 用户当前正在前台查看该书的 chat 页时不弹；其余情况（后台 / 未聚焦 /
  /// 在设置、首页、其它书等页面）弹出系统通知。
  void onGenerationCompleted(int bookId, String bookTitle) {
    if (_lifecycle == AppLifecycleState.resumed && _topChatBookId == bookId) {
      return;
    }
    unawaited(
      _backend.show(
        id: bookId,
        title: '《$bookTitle》本轮已完成',
        body: '点击打开',
        payload: '$bookId',
      ),
    );
  }

  /// 生成任务活动状态变化（由 [RoundProvider] 在「首个任务开始 / 全部任务结束」时回调）。
  ///
  /// 只要有任务在跑就启动 Android 前台服务保活（应用切后台后联网不受 Doze 限制，
  /// 无需用户改设置）；全部结束即停止。服务通知为低重要性常驻提示，不打扰。
  void onGenerationActiveChanged(bool active) {
    if (_backgroundTaskActive == active) return;
    _backgroundTaskActive = active;
    if (active && !_foregroundServiceRunning) {
      _foregroundServiceRunning = true;
      unawaited(
        _backend.startForeground(
          id: _kForegroundNotificationId,
          title: '正在后台生成',
          body: 'AI 正在生成内容，完成后将通知您',
        ),
      );
    } else if (!active && _foregroundServiceRunning) {
      _foregroundServiceRunning = false;
      unawaited(_backend.stopForeground());
    }
  }

  /// 是否允许应用发送通知（Android；非 Android 返回 null 表示不适用）。
  Future<bool?> areNotificationsEnabled() => _backend.areNotificationsEnabled();

  /// 打开系统通知设置页（Android）。
  Future<void> openNotificationSettings() =>
      _backend.openNotificationSettings();

  /// 删除指定书的生成完成通知（进入对应书 chat 页时调用）。
  Future<void> dismissForBook(int bookId) async {
    await _backend.cancel(bookId);
  }

  /// 通知点击回调：无论应用在前台还是后台，跳转到对应书的 chat 页。
  void _onNotificationTap(int bookId) {
    // 先尝试把窗口恢复到前台（Windows），不阻塞跳转。
    unawaited(_bringToForeground());
    unawaited(openChatBook(bookId));
  }

  /// Windows：通知点击后把窗口恢复到前台（最小化时先还原再聚焦）。
  Future<void> _bringToForeground() async {
    if (!Platform.isWindows) return;
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.focus();
    } catch (_) {
      // 桌面窗口插件未注册（如测试环境）时忽略。
    }
  }

  /// 跳转到指定书的 chat 页（通知点击 / 冷启动点通知共用）。
  ///
  /// - 当前栈顶已是某本 chat 页 → 用 [pushReplacement] 替换（避免无限叠层）；
  /// - 否则（首页 / 设置等）→ [push] 新页。
  Future<void> openChatBook(int bookId) async {
    final book = _findBook(bookId);
    if (book == null) return;
    _bookProvider.selectBook(book);
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => const ChatScreen(),
      settings: RouteSettings(name: chatRouteName, arguments: bookId),
    );
    if (_topChatBookId != null) {
      await nav.pushReplacement(route);
    } else {
      await nav.push(route);
    }
  }

  /// 处理「应用由点通知启动」的冷启动场景：首帧后跳转到对应书 chat 页。
  Future<void> handleLaunchNotificationIfAny() async {
    final id = await _backend.launchNotificationPayload();
    if (id != null) {
      await openChatBook(id);
    }
  }

  Book? _findBook(int id) {
    for (final b in _bookProvider.books) {
      if (b.id == id) return b;
    }
    return null;
  }
}

/// 通知后端抽象：隔离 flutter_local_notifications，便于测试注入 Fake。
abstract interface class NotificationBackend {
  /// 初始化插件；[onTap] 在用户点击通知时回调（参数为 bookId）。
  Future<void> init({required void Function(int bookId) onTap});

  /// 显示通知（id 与 payload 均约定为 bookId 的字符串形式）。
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  });

  /// 删除指定 id 的通知。
  Future<void> cancel(int id);

  /// 读取「应用是否由点通知启动」对应的 bookId（非冷启动返回 null）。
  Future<int?> launchNotificationPayload();

  /// 是否允许应用发送通知（Android；非 Android 返回 null 表示不适用）。
  Future<bool?> areNotificationsEnabled();

  /// 打开系统通知设置页（Android；非 Android 为空操作）。
  Future<void> openNotificationSettings();

  /// 启动后台保活前台服务（Android；非 Android 为空操作）。
  Future<void> startForeground({
    required int id,
    required String title,
    required String body,
  });

  /// 停止后台保活前台服务。
  Future<void> stopForeground();
}

/// 基于 flutter_local_notifications 的真实后端。
class FlutterLocalNotificationBackend implements NotificationBackend {
  FlutterLocalNotificationBackend({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  static const String _channelId = 'generation_done';
  static const String _channelName = '生成完成通知';
  static const String _channelDescription = 'AI 生成任务完成时提醒';

  /// 后台生成保活前台服务的常驻通知渠道（低重要性、无声音，不打扰）。
  static const String _ongoingChannelId = 'generation_ongoing';
  static const String _ongoingChannelName = '生成任务进行中';
  static const String _ongoingChannelDescription = '后台生成任务进行中（保活）';

  @override
  Future<void> init({required void Function(int bookId) onTap}) async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Windows 未打包（Inno 安装）应用无法主动 cancel 通知，
    // 因此正文 Toast 用短时（duration: short）兜底，不驻留通知中心。
    const windowsInit = WindowsInitializationSettings(
      appName: 'NarrChat',
      appUserModelId: 'com.yueshix.narrchat',
      guid: 'f8c1e3a9-1b2c-4d5e-8f7a-9b0c1d2e3f4a',
    );
    final settings = InitializationSettings(
      android: androidInit,
      windows: windowsInit,
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        final id = int.tryParse(response.payload ?? '');
        if (id != null) onTap(id);
      },
    );
    // Android 13+：首次启动申请通知权限（用户已确认在启动时申请）。
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      // 默认开启悬浮（heads-up）通知：高重要级 + 声音/振动。
      playSound: true,
      enableVibration: true,
      visibility: NotificationVisibility.public,
    );
    // Windows：用应用 Logo 覆盖默认空白图标（appLogoOverride）。
    final windowsDetails = WindowsNotificationDetails(
      duration: WindowsNotificationDuration.short,
      images: [
        WindowsImage(
          WindowsImage.getAssetUri('assets/app_icon_rounded.png'),
          altText: 'NarrChat',
          placement: WindowsImagePlacement.appLogoOverride,
        ),
      ],
    );
    final details = NotificationDetails(
      android: androidDetails,
      windows: windowsDetails,
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<int?> launchNotificationPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    final payload = details.notificationResponse?.payload;
    return payload == null ? null : int.tryParse(payload);
  }

  @override
  Future<bool?> areNotificationsEnabled() async {
    if (!Platform.isAndroid) return null;
    return _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.areNotificationsEnabled();
  }

  @override
  Future<void> openNotificationSettings() async {
    if (!Platform.isAndroid) return;
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.openAppNotificationSettings();
  }

  @override
  Future<void> startForeground({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        _ongoingChannelId,
        _ongoingChannelName,
        channelDescription: _ongoingChannelDescription,
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        playSound: false,
        enableVibration: false,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.startForegroundService(
            id: id,
            title: title,
            body: body,
            notificationDetails: androidDetails,
            foregroundServiceTypes: {
              AndroidServiceForegroundType.foregroundServiceTypeDataSync,
            },
          );
    } catch (_) {
      // 个别设备 / 系统版本可能拒绝从后台启动前台服务，失败不崩溃。
    }
  }

  @override
  Future<void> stopForeground() async {
    if (!Platform.isAndroid) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.stopForegroundService();
    } catch (_) {
      // 忽略。
    }
  }
}

/// 跟踪路由栈的观察者：识别栈顶是否为「某本书的对话页」。
class _ChatRouteObserver extends NavigatorObserver {
  _ChatRouteObserver(this._onChanged);

  final VoidCallback _onChanged;
  final List<_RouteEntry> _stack = [];

  /// 栈顶若为 chat 路由则返回其 bookId，否则返回 null（设置 / 首页等）。
  int? get topChatBookId =>
      _stack.isEmpty ? null : _stack.last.bookId;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(_entryOf(route));
    _onChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_stack.isNotEmpty && _stack.last.route == route) {
      _stack.removeLast();
    } else {
      _stack.removeWhere((e) => e.route == route);
    }
    _onChanged();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      _stack.removeWhere((e) => e.route == oldRoute);
    }
    if (newRoute != null) {
      _stack.add(_entryOf(newRoute));
    }
    _onChanged();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.removeWhere((e) => e.route == route);
    _onChanged();
  }

  _RouteEntry _entryOf(Route<dynamic> route) {
    final settings = route.settings;
    int? bookId;
    if (settings.name == chatRouteName && settings.arguments is int) {
      bookId = settings.arguments as int;
    }
    return _RouteEntry(route, bookId);
  }
}

class _RouteEntry {
  _RouteEntry(this.route, this.bookId);

  final Route<dynamic> route;

  /// null = 非 chat 路由。
  final int? bookId;
}
