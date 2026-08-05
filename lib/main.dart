import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database/database_helper.dart';
import 'providers/ai_settings_provider.dart';
import 'providers/book_provider.dart';
import 'providers/round_provider.dart';
import 'providers/sidebar_provider.dart';
import 'providers/world_book_provider.dart';
import 'screens/home_screen.dart';
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
  // 初始化偏好设置，并创建 AI 设置 Provider（API Key 从安全存储读取）。
  final prefs = await SharedPreferences.getInstance();
  final aiSettingsProvider = AiSettingsProvider(prefs)..load();
  runApp(NarrChatApp(aiSettingsProvider: aiSettingsProvider));
}

class NarrChatApp extends StatelessWidget {
  final AiSettingsProvider aiSettingsProvider;

  const NarrChatApp({super.key, required this.aiSettingsProvider});

  @override
  Widget build(BuildContext context) {
    final worldBookProvider = WorldBookProvider();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: aiSettingsProvider),
        ChangeNotifierProvider(create: (_) => BookProvider()..loadBooks()),
        ChangeNotifierProvider.value(value: worldBookProvider),
        ChangeNotifierProvider(
          create: (_) => RoundProvider(
            aiSettingsProvider: aiSettingsProvider,
            worldBookProvider: worldBookProvider,
          ),
        ),
        ChangeNotifierProvider(create: (_) => SidebarProvider()),
      ],
      child: MaterialApp(
        title: 'NarrChat',
        debugShowCheckedModeBanner: false,
        theme: NarrChatTheme.light,
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
  }
}
