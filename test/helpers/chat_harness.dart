import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/providers/mod_provider.dart';
import 'package:narrchat/providers/notification_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/screens/home_screen.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/clipboard_paste_service.dart';
import 'package:narrchat/services/html_search_service.dart';
import 'package:narrchat/services/image_import_service.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:narrchat/services/non_stream_replay.dart';
import 'package:narrchat/services/sync/image_revival.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';
import 'notice_harness.dart';

/// 公共 widget 测试脚手架（harness）。
///
/// 统一收口「TestStack + MultiProvider + MaterialApp + 视口」这套组合，
/// 各测试文件只关心交互与断言。
///
/// 数据层一律是**真实临时库**（见 `TestStack`）：schema / 事务 / 唯一键
/// 只有真库才测得出来，假 DAO 那套已经删除。

/// 脚手架预置书籍的 uuid（书籍主键即身份，测试断言直接引用）。
const String kHarnessBookUuid = 'book-1';

/// 以 [size] 视口 pump 对话页（ChatScreen），返回 RoundProvider。
///
/// 参数均为可覆盖项：
/// - [stack]：共享的测试存储（不传则内部新建，并在用例结束时自动 dispose）；
/// - [ai]：AI 服务替身（默认 [ToggleAiService]）；
/// - [settings] / [aiSettingsProvider]：AI 设置（默认新建）；
/// - [experimentalSettings]：实验性功能设置（Agent 模式开关；默认关闭）；
/// - [uiSettings]：UI 设置（默认新建，不 load，避免触碰真实配置文件）；
/// - [webSearchTool]：注入的搜索工具替身（AGENT / Chat 工具循环共用）；
/// - [onGenerationCompleted]：生成完成回调（通知服务接线用）；
/// - [retryDelay]：网络类失败自动重试间隔（测试可注入零时长）；
/// - [searchService]：Agent 默认搜索工具共用的搜索服务替身；
/// - [nonStreamReplayer]：非流式展示回放器（测试可注入零间隔加速）；
/// - [seedRounds]：预置的对话轮次（第 1..n 轮，正文足够长便于滚动断言）；
/// - [seedBodyRepeats]：预置轮次正文的重复次数（默认 40；需要"单轮高于视口"
///   的场景可加大）；
/// - [theme]：应用主题（默认浅色主题；深色用例可传 dark）；
/// - [textScale]：全局文字缩放倍率（默认 1.0）；
/// - [onOpenBook]：驻场岛展开区点「正在生成的书」的回调；
/// - [preloadRounds]：pump 前是否先 `loadRounds`（默认 true）。置 false 可复现
///   「新页面首帧时全局 provider 里还是上一本书的活动链」这条真实路径；
/// - [beforePump]：pumpWidget **之前**的预热钩子（拿到两个 provider），用来摆出
///   「上一本书的链 + 当前书已选」这种跨书首帧状态。
Future<RoundProvider> pumpChatScreen(
  WidgetTester tester, {
  TestStack? stack,
  AiService? ai,
  AiSettingsProvider? settings,
  AiSettingsProvider? aiSettingsProvider,
  ExperimentalSettingsProvider? experimentalSettings,
  UiSettingsProvider? uiSettings,
  ImageImportService? imageImport,
  ClipboardPasteService? clipboardPaste,
  WebSearchTool? webSearchTool,
  void Function(String bookUuid, String bookTitle)? onGenerationCompleted,
  Duration retryDelay = const Duration(milliseconds: 800),
  HtmlSearchService? searchService,
  NonStreamReplayer? nonStreamReplayer,
  int seedRounds = 0,
  int seedBodyRepeats = 40,
  ThemeData? theme,
  Size size = const Size(1400, 900),
  double textScale = 1.0,
  void Function(String bookUuid)? onOpenBook,
  bool preloadRounds = true,
  FutureOr<void> Function(RoundProvider rounds, BookProvider books)? beforePump,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = await _resolveStack(tester, stack);
  // 建库 + 播种：真库 I/O，必须放在真实事件循环里跑（见 [_resolveStack]）。
  final bookProvider = BookProvider(repository: store.repos.books);
  final roundProvider = RoundProvider(
    rounds: store.repos.rounds,
    books: store.repos.books,
    aiService: ai ?? ToggleAiService(),
    aiSettingsProvider: aiSettingsProvider,
    experimentalSettings: experimentalSettings,
    webSearchTool: webSearchTool,
    retryDelay: retryDelay,
    searchService: searchService,
    nonStreamReplayer: nonStreamReplayer,
    onGenerationCompleted: onGenerationCompleted,
  );
  await tester.runAsync(() async {
    await store.seedBook(uuid: kHarnessBookUuid, title: '测试书');
    await store.seedRounds(
      kHarnessBookUuid,
      count: seedRounds,
      bodyRepeats: seedBodyRepeats,
    );
    await bookProvider.loadBooks();
    if (preloadRounds) {
      await roundProvider.loadRounds(kHarnessBookUuid);
    }
  });
  bookProvider.selectBook(bookProvider.books.first);
  if (beforePump != null) {
    await tester.runAsync(() async {
      await beforePump(roundProvider, bookProvider);
    });
  }

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => settings ?? AiSettingsProvider()),
        ChangeNotifierProvider(
          create: (_) => experimentalSettings ?? ExperimentalSettingsProvider(),
        ),
        ChangeNotifierProvider(
          create: (_) => uiSettings ?? UiSettingsProvider(),
        ),
        ChangeNotifierProvider<BookProvider>.value(value: bookProvider),
        ChangeNotifierProvider(
          create: (_) => WorldBookProvider(repository: store.repos.worldBook),
        ),
        // 书籍设置页读取 / 提交启用的 Mod 清单。
        ChangeNotifierProvider(
          create: (_) => ModProvider(repository: store.repos.mod),
        ),
        ChangeNotifierProvider<RoundProvider>.value(value: roundProvider),
        ChangeNotifierProvider(create: (_) => SidebarProvider()),
        // 云同步（ChatScreen 进入书籍时触发自动同步；未配置时内部忽略）。
        ChangeNotifierProvider(create: (_) => CloudSyncProvider()),
        Provider<ImageImportService>(
          create: (_) => imageImport ?? FakeImageImportService(),
        ),
        Provider<ClipboardPasteService>(
          create: (_) => clipboardPaste ?? FakeClipboardPasteService(),
        ),
        Provider<ImageRevivalService>(create: (_) => FakeImageRevivalService()),
      ],
      child: MaterialApp(
        theme: theme ?? NarrChatTheme.light,
        // 应用内通知宿主（悬浮 + 驻场岛），等价于生产 main.dart 的接线；
        // 全局字体缩放同样等价（见生产 builder）。
        builder: noticeHostBuilder(
          onOpenBook: onOpenBook,
          textScale: textScale,
        ),
        home: Scaffold(body: const ChatScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return roundProvider;
}

/// 以 [size] 视口 pump 首页（HomeScreen，书籍列表）。
///
/// [books] 注入书籍列表；[updatedTimes]（键 = 书籍 uuid）注入"更新时间"
/// （`book_meta.updated_at` 的缓存副本）；[notificationBackend] 注入通知后端
/// （缺省 [FakeNotificationBackend]，避免走真实插件通道）；
/// [notificationSettings] 注入预先 refresh 过的设置；
/// [theme]：页面主题（默认浅色；深色用例可传 dark）；
/// [uiSettings]：注入 UI 设置（默认新建不写盘实例，可预设默认封面等）；
/// [textScale]：全局文字缩放倍率；[onOpenBook]：驻场岛展开区回调。
Future<BookProvider> pumpHomeScreen(
  WidgetTester tester, {
  required List<Book> books,
  Map<String, DateTime> updatedTimes = const {},
  TestStack? stack,
  NotificationBackend? notificationBackend,
  NotificationSettingsProvider? notificationSettings,
  Size size = const Size(1400, 900),
  ThemeData? theme,
  UiSettingsProvider? uiSettings,
  double textScale = 1.0,
  void Function(String bookUuid)? onOpenBook,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = await _resolveStack(tester, stack);
  final bookProvider = BookProvider(repository: store.repos.books);
  await tester.runAsync(() async {
    for (final book in books) {
      await store.repos.books.createBook(book);
      final time = updatedTimes[book.uuid];
      if (time != null) {
        await store.setBookUpdatedAt(book.uuid, time);
      }
    }
    await bookProvider.loadBooks();
  });

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AiSettingsProvider()),
        ChangeNotifierProvider(create: (_) => ExperimentalSettingsProvider()),
        ChangeNotifierProvider<BookProvider>.value(value: bookProvider),
        // 首页可进入书籍对话页（对话页布局读取 UI 设置）。
        // 排序 / 排列切换会写本地配置：测试注入空写入器，避免真实文件 I/O。
        ChangeNotifierProvider(
          create: (_) =>
              uiSettings ?? UiSettingsProvider(persist: (_) async {}),
        ),
        // 云同步（SyncStatusChip 需读取其 syncState）。
        ChangeNotifierProvider(create: (_) => CloudSyncProvider()),
        ChangeNotifierProvider(
          create: (_) => WorldBookProvider(repository: store.repos.worldBook),
        ),
        // 对话页可经顶栏书名进入书籍设置页，设置页读取 Mod 草稿。
        ChangeNotifierProvider(
          create: (_) => ModProvider(repository: store.repos.mod),
        ),
        ChangeNotifierProvider(
          create: (_) => RoundProvider(
            rounds: store.repos.rounds,
            books: store.repos.books,
          ),
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
                attentionBackend: FakeTaskbarAttentionBackend(),
              ),
            ),
          ),
        ChangeNotifierProvider(create: (_) => SidebarProvider()),
        Provider<ImageRevivalService>(create: (_) => FakeImageRevivalService()),
      ],
      child: MaterialApp(
        theme: theme ?? NarrChatTheme.light,
        builder: noticeHostBuilder(
          onOpenBook: onOpenBook,
          textScale: textScale,
        ),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return bookProvider;
}

/// 以 [service] 的 navigatorKey / 路由观察者 pump 一个「首页 + 通知服务」宿主。
///
/// 与 [pumpChatScreen] 的区别：首页不是对话页，通知跳转（含冷启动点通知）
/// 会真实地把 ChatScreen 推上栈，供通知链路测试观察栈顶与选中书籍。
/// Provider 组合与 [pumpChatScreen] 保持一致，`onGenerationCompleted` 已接到
/// [service]（生成完成 → 通知的接线由生产代码负责）。
Future<({BookProvider books, RoundProvider rounds})> pumpNotificationHost(
  WidgetTester tester, {
  required GenerationNotificationService service,
  required BookProvider bookProvider,
  required TestStack stack,
  AiService? ai,
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final roundProvider = RoundProvider(
    rounds: stack.repos.rounds,
    books: stack.repos.books,
    aiService: ai ?? ToggleAiService(),
    onGenerationCompleted: service.onGenerationCompleted,
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AiSettingsProvider()),
        ChangeNotifierProvider(create: (_) => ExperimentalSettingsProvider()),
        // 通知跳转会把 ChatScreen 推上路由栈（其布局读取 UI 设置）。
        ChangeNotifierProvider(create: (_) => UiSettingsProvider()),
        ChangeNotifierProvider<BookProvider>.value(value: bookProvider),
        ChangeNotifierProvider(
          create: (_) => WorldBookProvider(repository: stack.repos.worldBook),
        ),
        // 通知跳转进入的对话页可打开书籍设置（设置页读取 Mod 草稿）。
        ChangeNotifierProvider(
          create: (_) => ModProvider(repository: stack.repos.mod),
        ),
        ChangeNotifierProvider<RoundProvider>.value(value: roundProvider),
        ChangeNotifierProvider(create: (_) => SidebarProvider()),
        ChangeNotifierProvider(create: (_) => CloudSyncProvider()),
        Provider<ImageImportService>(create: (_) => FakeImageImportService()),
        Provider<ClipboardPasteService>(
          create: (_) => FakeClipboardPasteService(),
        ),
        Provider<ImageRevivalService>(create: (_) => FakeImageRevivalService()),
      ],
      child: MaterialApp(
        theme: NarrChatTheme.light,
        navigatorKey: service.navigatorKey,
        navigatorObservers: [service.routeObserver],
        // 通知宿主（悬浮 + 驻场岛）：等价生产 main.dart 的接线。
        builder: noticeHostBuilder(),
        home: const Scaffold(body: Center(child: Text('首页'))),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (books: bookProvider, rounds: roundProvider);
}

/// 拿到可用的 TestStack：外面传了就用外面的（不负责销毁），否则新建并在
/// 用例结束时自动 dispose。
///
/// **必须经 [WidgetTester.runAsync]**：`testWidgets` 的测试体跑在 fake-async
/// 区域里，真实的文件 / sqlite 回调只有在真实事件循环里才会推进；直接 `await`
/// 会永远卡住（现象是「did not complete」）。见 `test/zz_probe_test.dart`。
Future<TestStack> _resolveStack(
  WidgetTester tester,
  TestStack? provided,
) async {
  if (provided != null) return provided;
  final stack = await tester.runAsync(TestStack.create);
  addTearDown(() => tester.runAsync(stack!.dispose));
  return stack!;
}

/// 让「真库 I/O + UI 动画」一起推进到静止。
///
/// 为什么需要它：`testWidgets` 的测试体跑在 fake-async 区域，`pump()` 只负责
/// flush 微任务；真实文件 / sqlite 那一层要等真实事件循环转起来才会往下走。
/// 所以「点一下 → provider 写库 → 重新加载列表」这类交互，光 `pumpAndSettle`
/// 会在数据还没落地时就断言（现象：软删后书还在 / 提交后链上没新代）。
///
/// 一次 `runAsync` 只够推进**一步**真实异步，所以按轮次循环；
/// 发一轮要经过「校验 → 插代 → 归一化 is_using → 落正文 → 重载链」好几步，
/// 轮次给足（默认 12）比猜时长可靠。
Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 等待 sendRound 结束（isSending 期间发送按钮有无限转圈动画，
/// 不能用 pumpAndSettle，须等 isSending 变 false 后再 settle）。
Future<void> waitSendDone(WidgetTester tester, RoundProvider provider) async {
  // 先给几步把「点击 → 真正开始生成」推进出来，否则第一轮判断时
  // isSending 还是 false，会误以为已经结束。
  for (var i = 0; i < 40 && !provider.isSending; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  for (var i = 0; i < 60 && provider.isSending; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  await settle(tester);
}

/// 侧栏面板内容区（[SidebarPanel] 内的 CustomScrollView）的滚动控制器。
///
/// 面板与快速定位导轨共用该控制器（面板私有持有，经 widget 暴露），
/// 供「跳转轮次后保持滚动位置」等断言读取当前 offset。宽窄屏、独立 pump
/// 的面板均适用（子树内仅有这一个 CustomScrollView）。
ScrollController sidebarScrollController(WidgetTester tester) {
  final csv = tester.widget<CustomScrollView>(
    find.descendant(
      of: find.byType(SidebarPanel),
      matching: find.byType(CustomScrollView),
    ),
  );
  return csv.controller!;
}

/// 结束 [FakeStreamingAiService] 的流式并等待本轮收尾，返回生成是否成功。
///
/// 与 [waitSendDone] 的分工：先放行流式（`complete()`），再等收尾。
Future<bool> finishStream(
  WidgetTester tester,
  FakeStreamingAiService ai,
  RoundProvider provider,
  Future<bool> sendFuture,
) async {
  ai.complete();
  await waitSendDone(tester, provider);
  return await sendFuture;
}
