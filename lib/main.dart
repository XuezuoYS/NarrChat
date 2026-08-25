import 'dart:async';
import 'dart:io' show Platform;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'database/database_helper.dart';
import 'providers/ai_settings_provider.dart';
import 'providers/book_provider.dart';
import 'providers/cloud_sync_provider.dart';
import 'providers/mod_provider.dart';
import 'providers/notification_settings_provider.dart';
import 'providers/round_provider.dart';
import 'providers/sidebar_provider.dart';
import 'providers/ui_settings_provider.dart';
import 'providers/world_book_provider.dart';
import 'screens/home_screen.dart';
import 'services/clipboard_paste_service.dart';
import 'services/manual_licenses_service.dart';
import 'services/image_import_service.dart';
import 'services/notification_service.dart';
import 'services/system_fonts_service.dart';
import 'theme/app_theme.dart';
import 'widgets/ime_caret_sync.dart';
import 'widgets/image_viewer_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面端：初始化窗口管理器（通知点击后把窗口恢复到前台）。
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    // 若是「图片查看器」独立子窗口，则运行最小查看器并结束（不再初始化业务数据）。
    if (await _runAsImageViewerWindowIfNeeded()) return;
  }
  // 提前初始化数据库（桌面端会在此处完成 FFI 工厂切换），
  // 失败时不阻塞启动，后续请求会重试并暴露错误。
  try {
    await DatabaseHelper.instance.database;
  } catch (e) {
    debugPrint('数据库初始化失败: $e');
  }
  // 创建 AI 设置 Provider：API Key 从安全存储（系统密钥库）读取，
  // 其余设置从本地 JSON 配置文件（local_config/app_settings.json）读取。
  final aiSettingsProvider = AiSettingsProvider()..load();
  // UI 设置：加载本地配置；随后台扫描系统字体，
  // 若已配置自定义全局字体则启动时加载，保证界面字体一致。
  final uiSettingsProvider = UiSettingsProvider();
  await uiSettingsProvider.load();
  unawaited(
    SystemFontsService.instance.scan().then((_) async {
      final family = uiSettingsProvider.fontFamily;
      if (family.isNotEmpty) {
        await SystemFontsService.instance.loadFont(family);
      }
    }),
  );
  // 云同步（WebDAV）设置：密码从安全存储读取，其余从本地 JSON 读取。
  final cloudSyncProvider = CloudSyncProvider()..load();
  // 业务数据 Provider：在 main 中创建以注册云同步恢复后的刷新回调。
  final bookProvider = BookProvider()..loadBooks();
  final worldBookProvider = WorldBookProvider();
  final modProvider = ModProvider()..loadUserMods();
  // 生成完成系统通知：生成任务成功完成且用户不在该书 chat 页时弹出系统通知，
  // 点击通知进入对应书 chat 页；进入该书 chat 页则自动删除通知。
  final notificationService = GenerationNotificationService(
    bookProvider: bookProvider,
  );
  await notificationService.init();
  // 通知设置状态：主页检测「未开启系统通知」提示（回到前台自动刷新）。
  final notificationSettingsProvider = NotificationSettingsProvider(
    service: notificationService,
  )..attach();
  final roundProvider = RoundProvider(
    aiSettingsProvider: aiSettingsProvider,
    worldBookProvider: worldBookProvider,
    modProvider: modProvider,
    cloudSyncProvider: cloudSyncProvider,
    onGenerationCompleted: notificationService.onGenerationCompleted,
    onGenerationActiveChanged: notificationService.onGenerationActiveChanged,
  );
  // 云同步下载（替换/合并）完成后，重载本地内存态数据。
  cloudSyncProvider.onDataRestored = () async {
    await bookProvider.loadBooks();
    await modProvider.loadUserMods();
    await worldBookProvider.reloadCurrent();
    await roundProvider.reloadCurrent();
  };
  // 开放源代码许可：注册手动补充的许可证清单（懒加载，仅打开许可证页时解析）。
  ManualLicensesService.register();
  runApp(
    NarrChatApp(
      aiSettingsProvider: aiSettingsProvider,
      uiSettingsProvider: uiSettingsProvider,
      cloudSyncProvider: cloudSyncProvider,
      bookProvider: bookProvider,
      worldBookProvider: worldBookProvider,
      modProvider: modProvider,
      roundProvider: roundProvider,
      notificationSettingsProvider: notificationSettingsProvider,
      navigatorKey: notificationService.navigatorKey,
      navigatorObservers: [notificationService.routeObserver],
    ),
  );
  // 冷启动点通知：首帧后跳转到对应书的 chat 页。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // Windows 主窗口：首帧后预热一个隐藏的图片查看器窗口并复用，
    // 省去每次开图都重新创建 engine + 重跑 main() 的冷启动开销。
    if (Platform.isWindows) {
      unawaited(ImageViewerWindowManager.warm());
    }
    unawaited(notificationService.handleLaunchNotificationIfAny());
  });
}

/// 若当前窗口是「图片查看器」独立子窗口（由 desktop_multi_window 以非空 arguments 创建），
/// 则运行最小查看器 App 并返回 true；否则返回 false 走正常主窗口流程。
/// 主窗口的 `fromCurrentEngine()` 无入参（空 arguments）或调用失败时，均视为主窗口。
Future<bool> _runAsImageViewerWindowIfNeeded() async {
  try {
    final controller = await WindowController.fromCurrentEngine();
    final args = ImageWindowArgs.tryDecode(controller.arguments);
    if (args != null) {
      if (args.warm) {
        // 预热常驻查看器窗口：进入监听模式，等待主窗口送入图片组。
        await runWarmImageViewerWindowApp();
      } else {
        await runImageViewerWindowApp(args);
      }
      return true;
    }
  } catch (_) {
    // 主窗口 / 无法识别：走正常流程。
  }
  return false;
}

class NarrChatApp extends StatelessWidget {
  final AiSettingsProvider aiSettingsProvider;
  final UiSettingsProvider uiSettingsProvider;
  final CloudSyncProvider cloudSyncProvider;
  final BookProvider bookProvider;
  final WorldBookProvider worldBookProvider;
  final ModProvider modProvider;
  final RoundProvider roundProvider;
  final NotificationSettingsProvider notificationSettingsProvider;
  final GlobalKey<NavigatorState> navigatorKey;
  final List<NavigatorObserver> navigatorObservers;

  const NarrChatApp({
    super.key,
    required this.aiSettingsProvider,
    required this.uiSettingsProvider,
    required this.cloudSyncProvider,
    required this.bookProvider,
    required this.worldBookProvider,
    required this.modProvider,
    required this.roundProvider,
    required this.notificationSettingsProvider,
    required this.navigatorKey,
    required this.navigatorObservers,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: aiSettingsProvider),
        ChangeNotifierProvider.value(value: uiSettingsProvider),
        ChangeNotifierProvider.value(value: cloudSyncProvider),
        ChangeNotifierProvider.value(value: bookProvider),
        ChangeNotifierProvider.value(value: worldBookProvider),
        ChangeNotifierProvider.value(value: modProvider),
        ChangeNotifierProvider.value(value: roundProvider),
        ChangeNotifierProvider.value(value: notificationSettingsProvider),
        ChangeNotifierProvider(create: (_) => SidebarProvider()),
        Provider<ImageImportService>(
          create: (_) => PickerImageImportService(),
        ),
        // 剪贴板读取（输入框 Ctrl+V / 右键粘贴，含图片）。
        Provider<ClipboardPasteService>(
          create: (_) => const SystemClipboardPasteService(),
        ),
      ],
      // 监听 UI 设置变化，动态重建主题（含全局字体与亮/暗模式）。
      child: Consumer<UiSettingsProvider>(
        builder: (context, ui, _) {
          // 包裹整个应用：在 Windows 上修复长文本编辑框滚动后
          // 输入法候选窗跑偏（不跟随光标）的问题（见 ImeCaretSync）。
          return ImeCaretSync(
            child: MaterialApp(
              title: 'NarrChat',
              debugShowCheckedModeBanner: false,
              // 通知服务通过该 key 在任意位置导航（通知点击进入对应书 chat 页）。
              navigatorKey: navigatorKey,
              // 通知服务观察路由栈，判断用户是否正在查看某本书的 chat 页。
              navigatorObservers: navigatorObservers,
              // 云同步自动上传等后台操作通过此 key 弹出全局 SnackBar 提示。
              scaffoldMessengerKey: CloudSyncProvider.messengerKey,
              theme: NarrChatTheme.lightWithFont(ui.fontFamily),
              darkTheme: NarrChatTheme.darkWithFont(ui.fontFamily),
              // 主题模式：跟随系统（默认）/ 亮色 / 暗色。
              themeMode: ui.themeMode == AppThemeMode.system
                  ? ThemeMode.system
                  : ui.themeMode == AppThemeMode.dark
                      ? ThemeMode.dark
                      : ThemeMode.light,
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const HomeScreen(),
            ),
          );
        },
      ),
    );
  }
}
