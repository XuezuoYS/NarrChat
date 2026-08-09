import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'database/database_helper.dart';
import 'providers/ai_settings_provider.dart';
import 'providers/book_provider.dart';
import 'providers/cloud_sync_provider.dart';
import 'providers/mod_provider.dart';
import 'providers/round_provider.dart';
import 'providers/sidebar_provider.dart';
import 'providers/ui_settings_provider.dart';
import 'providers/world_book_provider.dart';
import 'screens/home_screen.dart';
import 'services/system_fonts_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  final roundProvider = RoundProvider(
    aiSettingsProvider: aiSettingsProvider,
    worldBookProvider: worldBookProvider,
    modProvider: modProvider,
    cloudSyncProvider: cloudSyncProvider,
  );
  // 云同步下载（替换/合并）完成后，重载本地内存态数据。
  cloudSyncProvider.onDataRestored = () async {
    await bookProvider.loadBooks();
    await modProvider.loadUserMods();
    await worldBookProvider.reloadCurrent();
    await roundProvider.reloadCurrent();
  };
  runApp(
    NarrChatApp(
      aiSettingsProvider: aiSettingsProvider,
      uiSettingsProvider: uiSettingsProvider,
      cloudSyncProvider: cloudSyncProvider,
      bookProvider: bookProvider,
      worldBookProvider: worldBookProvider,
      modProvider: modProvider,
      roundProvider: roundProvider,
    ),
  );
}

class NarrChatApp extends StatelessWidget {
  final AiSettingsProvider aiSettingsProvider;
  final UiSettingsProvider uiSettingsProvider;
  final CloudSyncProvider cloudSyncProvider;
  final BookProvider bookProvider;
  final WorldBookProvider worldBookProvider;
  final ModProvider modProvider;
  final RoundProvider roundProvider;

  const NarrChatApp({
    super.key,
    required this.aiSettingsProvider,
    required this.uiSettingsProvider,
    required this.cloudSyncProvider,
    required this.bookProvider,
    required this.worldBookProvider,
    required this.modProvider,
    required this.roundProvider,
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
        ChangeNotifierProvider(create: (_) => SidebarProvider()),
      ],
      // 监听 UI 设置变化，动态重建主题（含全局字体与亮/暗模式）。
      child: Consumer<UiSettingsProvider>(
        builder: (context, ui, _) {
          return MaterialApp(
            title: 'NarrChat',
            debugShowCheckedModeBanner: false,
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
          );
        },
      ),
    );
  }
}
