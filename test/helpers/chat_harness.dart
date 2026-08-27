import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/notification_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/screens/home_screen.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/clipboard_paste_service.dart';
import 'package:narrchat/services/image_import_service.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:narrchat/services/sync/image_revival.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

/// 公共 widget 测试脚手架（harness）。
///
/// 此前各测试文件各自复制“MultiProvider + MaterialApp + ChatScreen/HomeScreen
/// + 视口设置”组合（累计约 500 行）。统一收口到本文件后：
/// - 新增对话页 / 首页测试直接复用，不再复制脚手架；
/// - 视口 / Provider 组合行为保持一致，减少微小漂移。
///
/// 约定：仅包含“把被测页面 pump 起来”的公共流程；具体交互与断言
/// 留在各测试文件内。

/// 以 [size] 视口 pump 对话页（ChatScreen），返回 RoundProvider。
///
/// 参数均为可覆盖项：
/// - [ai]：AI 服务替身（默认 [ToggleAiService]）；
/// - [bookDao] / [roundDao] / [worldBookDao]：数据层替身（默认新建）；
/// - [settings]：AI 设置（默认新建）；
/// - [onGenerationCompleted]：生成完成回调（通知服务接线用）；
/// - [retryDelay]：网络类失败自动重试间隔（测试可注入零时长）；
/// - [seedRounds]：预置的对话轮次（roundIndex 1..n，正文足够长便于滚动断言）；
/// - [seedBodyRepeats]：预置轮次正文的重复次数（默认 40；楼层跳转等需要
///   “单轮高于视口”的场景可加大）。
Future<RoundProvider> pumpChatScreen(
  WidgetTester tester, {
  AiService? ai,
  FakeBookDao? bookDao,
  FakeRoundDao? roundDao,
  FakeWorldBookDao? worldBookDao,
  AiSettingsProvider? settings,
  ImageImportService? imageImport,
  ClipboardPasteService? clipboardPaste,
  void Function(int bookId, String bookTitle)? onGenerationCompleted,
  Duration retryDelay = const Duration(milliseconds: 800),
  int seedRounds = 0,
  int seedBodyRepeats = 40,
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  const book = Book(id: 1, title: '测试书');
  final bookDao0 = bookDao ?? FakeBookDao(books: [book]);
  final dao = roundDao ?? FakeRoundDao();
  final worldDao = worldBookDao ?? FakeWorldBookDao();
  for (var i = 1; i <= seedRounds; i++) {
    await dao.insertRound(
      Round(
        bookId: 1,
        roundIndex: i,
        userInput: '第 $i 轮的用户输入',
        aiNarrative: '第 $i 轮的剧情正文。' * seedBodyRepeats,
        currentTime: '第一天 午时',
        createdAt: DateTime.now(),
      ),
    );
  }

  final roundProvider = RoundProvider(
    dao: dao,
    aiService: ai ?? ToggleAiService(),
    bookDao: bookDao0,
    retryDelay: retryDelay,
    onGenerationCompleted: onGenerationCompleted,
  );
  await roundProvider.loadRounds(1);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => settings ?? AiSettingsProvider()),
        ChangeNotifierProvider(
          create: (_) => BookProvider(dao: bookDao0)..loadBooks(),
        ),
        ChangeNotifierProvider(create: (_) => WorldBookProvider(dao: worldDao)),
        ChangeNotifierProvider(create: (_) => roundProvider),
        ChangeNotifierProvider(create: (_) => SidebarProvider()),
        // 云同步（ChatScreen 进入书籍时触发自动同步；未配置时内部忽略）。
        ChangeNotifierProvider(create: (_) => CloudSyncProvider()),
        Provider<ImageImportService>(
          create: (_) => imageImport ?? FakeImageImportService(),
        ),
        Provider<ClipboardPasteService>(
          create: (_) => clipboardPaste ?? FakeClipboardPasteService(),
        ),
        Provider<ImageRevivalService>(
          create: (_) => FakeImageRevivalService(),
        ),
      ],
      child: MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(body: const ChatScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return roundProvider;
}

/// 以 [size] 视口 pump 首页（HomeScreen，书籍列表）。
///
/// [books] / [times] 注入书籍列表与最近对话时间；
/// [notificationBackend] 注入通知后端（缺省时用 [FakeNotificationBackend]，
/// 避免默认走真实 flutter_local_notifications 插件）；
/// [notificationSettings] 注入预先构建（已 refresh）的通知设置 Provider，
/// 用于「未开启通知提示条」等需要预置开关状态的用例。
Future<BookProvider> pumpHomeScreen(
  WidgetTester tester, {
  required List<Book> books,
  Map<int, DateTime> times = const {},
  NotificationBackend? notificationBackend,
  NotificationSettingsProvider? notificationSettings,
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final bookDao = FakeBookDao(books: books, times: times);
  final bookProvider = BookProvider(dao: bookDao)..loadBooks();
  final roundDao = FakeRoundDao();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AiSettingsProvider()),
        ChangeNotifierProvider(create: (_) => bookProvider),
        // 云同步（SyncStatusChip 需读取其 syncState）。
        ChangeNotifierProvider(create: (_) => CloudSyncProvider()),
        ChangeNotifierProvider(
          create: (_) => WorldBookProvider(dao: FakeWorldBookDao()),
        ),
        ChangeNotifierProvider(
          create: (_) => RoundProvider(dao: roundDao, bookDao: bookDao),
        ),
        if (notificationSettings != null)
          ChangeNotifierProvider<NotificationSettingsProvider>.value(
            value: notificationSettings,
          )
        else
          ChangeNotifierProvider(
            create: (_) => NotificationSettingsProvider(
              service: GenerationNotificationService(
                bookProvider: bookProvider,
                backend: notificationBackend ?? FakeNotificationBackend(),
              ),
            ),
          ),
        ChangeNotifierProvider(create: (_) => SidebarProvider()),
        Provider<ImageRevivalService>(
          create: (_) => FakeImageRevivalService(),
        ),
      ],
      child: MaterialApp(theme: NarrChatTheme.light, home: const HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return bookProvider;
}

/// 等待 sendRound 结束（isSending 期间发送按钮有无限转圈动画，
/// 不能用 pumpAndSettle，须等 isSending 变 false 后再 settle）。
Future<void> waitSendDone(
  WidgetTester tester,
  RoundProvider provider,
) async {
  for (var i = 0; i < 20 && provider.isSending; i++) {
    await tester.pump();
  }
  await tester.pumpAndSettle();
}
