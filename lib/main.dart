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
import 'services/storage_service.dart';
import 'services/sync/image_revival.dart';
import 'services/sync/image_deletion.dart';
import 'services/system_fonts_service.dart';
import 'services/windows_paste_fix.dart';
import 'theme/app_theme.dart';
import 'widgets/ime_caret_sync.dart';
import 'widgets/image_viewer_window.dart';
import 'widgets/sync_hud.dart';
import 'widgets/sync_result_bubble.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面端：初始化窗口管理器（通知点击后把窗口恢复到前台）。
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    // 若是「图片查看器」独立子窗口，则运行最小查看器并结束（不再初始化业务数据）。
    if (await _runAsImageViewerWindowIfNeeded()) return;
  }
  // Windows 11：修复 Win+V 剪贴板历史粘贴（引擎下发的畸形 Ctrl+V 序列）。
  WindowsPasteFix.instance.inject();
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
  // 启动前加载完成，保证首帧后的自动同步能按已保存的同步模式正确触发。
  final cloudSyncProvider = CloudSyncProvider();
  await cloudSyncProvider.load();
  // 接入生命周期：回前台触发一次静默同步（距上次同步 2 分钟内自动跳过）。
  // 自动同步只由用户操作节点发起，空闲时不再有任何定时轮询。
  cloudSyncProvider.attachLifecycle();
  // 业务数据 Provider：在 main 中创建以注册云同步恢复后的刷新回调；
  // 传入云同步 Provider 以在书籍数据变更节点触发全自动同步。
  final bookProvider = BookProvider(cloudSyncProvider: cloudSyncProvider)
    ..loadBooks();
  final worldBookProvider = WorldBookProvider(cloudSyncProvider: cloudSyncProvider);
  final modProvider = ModProvider(cloudSyncProvider: cloudSyncProvider)
    ..loadUserMods();
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
    // 全自动同步节点之一：打开软件。
    cloudSyncProvider.triggerSync();
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
        // 存储管理：本地数据库信息 / 导出、图片目录管理。
        Provider<StorageService>(
          create: (_) => LocalStorageService(),
        ),
        // 图片"再添加复活"：导入/粘贴保存后取消待推送删除墓碑。
        Provider<ImageRevivalService>(
          create: (_) => SyncImageRevivalService(),
        ),
        // 图片删除：删除本机文件 + 记录待推送删除墓碑（同步删云端并传播）。
        Provider<ImageDeletionService>(
          create: (_) => SyncImageDeletionService(),
        ),
      ],
      // 监听 UI 设置变化，动态重建主题（含全局字体与亮/暗模式）。
      child: Consumer<UiSettingsProvider>(
        builder: (context, ui, _) {
          // 包裹整个应用：在 Windows 上修复长文本编辑框滚动后
          // 输入法候选窗跑偏（不跟随光标）的问题（见 ImeCaretSync）。
          // 同步流程也复用同一 Navigator（弹首连分支对话框用）。
          CloudSyncProvider.navigatorKey = navigatorKey;
          // HUD 在 MaterialApp.builder 中位于 Navigator 之上（无 Overlay 可挂
          // Tooltip），因此为「子内容 + 同步 HUD」包一层专属 Overlay。
          return ImeCaretSync(
            child: MaterialApp(
              builder: (context, child) => Overlay(
                initialEntries: [
                  OverlayEntry(
                    builder: (_) => Stack(
                      fit: StackFit.expand,
                      children: [
                        child ?? const SizedBox.shrink(),
                        // 应用级同步悬浮 HUD：仅同步进行时出现。
                        const SyncHud(),
                        // 应用级同步结果悬浮气泡：成功 2 秒自动消失，
                        // 失败驻留待关闭（内容可复制）。
                        const SyncResultBubble(),
                      ],
                    ),
                  ),
                ],
              ),
              title: 'NarrChat',
              debugShowCheckedModeBanner: false,
              // 通知服务通过该 key 在任意位置导航（通知点击进入对应书 chat 页）。
              navigatorKey: navigatorKey,
              // 通知服务观察路由栈，判断用户是否正在查看某本书的 chat 页。
              navigatorObservers: navigatorObservers,
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
