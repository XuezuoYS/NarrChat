import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/providers/mod_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/repositories/world_book_repository.dart';
import 'package:narrchat/screens/agent_book_creation_page.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/app_notice_center.dart';
import 'package:narrchat/services/book_creation/book_creation_writer.dart';
import 'package:narrchat/services/clipboard_paste_service.dart';
import 'package:narrchat/services/image_import_service.dart';
import 'package:narrchat/services/sync/image_deletion.dart';
import 'package:narrchat/services/sync/image_revival.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_editing_controller.dart';
import 'package:provider/provider.dart';

import 'helpers/book_creation_fixtures.dart';
import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

/// 「Agent 创建新书」页面测试：输入契约、成功 / 失败 / 不完整 / 取消 / 回滚。
void main() {
  late TestStack stack;
  late BookProvider bookProvider;
  late WorldBookProvider worldBookProvider;
  late ModProvider modProvider;
  late FakeCloudSyncProvider cloud;
  late AppNoticeCenter noticeCenter;
  late GlobalKey<NavigatorState> navigatorKey;

  setUp(() async {
    stack = await TestStack.create();
    bookProvider = BookProvider(repository: stack.repos.books);
    await bookProvider.loadBooks();
    worldBookProvider = WorldBookProvider(repository: stack.repos.worldBook);
    modProvider = ModProvider(repository: stack.repos.mod);
    cloud = FakeCloudSyncProvider();
    noticeCenter = AppNoticeCenter();
    navigatorKey = GlobalKey<NavigatorState>();
  });

  tearDown(() async {
    noticeCenter.reset();
    noticeCenter.dispose();
    await stack.dispose();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    ScriptedAiService ai, {
    BookCreationWriter? writer,
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AiSettingsProvider>(
            create: (_) => ChatCompatibleSettings(),
          ),
          ChangeNotifierProvider(create: (_) => ExperimentalSettingsProvider()),
          ChangeNotifierProvider(
            create: (_) => UiSettingsProvider(persist: (_) async {}),
          ),
          ChangeNotifierProvider<BookProvider>.value(value: bookProvider),
          ChangeNotifierProvider<WorldBookProvider>.value(
            value: worldBookProvider,
          ),
          ChangeNotifierProvider<ModProvider>.value(value: modProvider),
          ChangeNotifierProvider(
            create: (_) => RoundProvider(
              rounds: stack.repos.rounds,
              books: stack.repos.books,
            ),
          ),
          ChangeNotifierProvider(create: (_) => SidebarProvider()),
          ChangeNotifierProvider<CloudSyncProvider>.value(value: cloud),
          Provider<ImageImportService>(
            create: (_) => FakeImageImportService(),
          ),
          Provider<ClipboardPasteService>(
            create: (_) => FakeClipboardPasteService(),
          ),
          Provider<ImageRevivalService>(
            create: (_) => FakeImageRevivalService(),
          ),
          Provider<ImageDeletionService>(
            create: (_) => FakeImageDeletionService(),
          ),
        ],
        child: MaterialApp(
          theme: NarrChatTheme.light,
          navigatorKey: navigatorKey,
          builder: floatingNoticeBuilder(center: noticeCenter),
          home: const Scaffold(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => AgentBookCreationPage(
          aiService: ai,
          writer: writer ??
              BookCreationWriter(
                books: stack.repos.books,
                worldBooks: stack.repos.worldBook,
                mods: stack.repos.mod,
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 在输入页填好创意并走完二次确认（不等待生成）。
  Future<void> startFlow(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('agent_book_idea_field')),
      kBookCreationIdea,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agent_book_start_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent_book_confirm_dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('agent_book_confirm_start')));
    await tester.pump();
  }

  /// 推进真实异步（真库 / AI 回调），直到 [finder] 出现。
  Future<void> waitForFinder(
    WidgetTester tester,
    Finder finder, {
    int rounds = 300,
  }) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      if (finder.evaluate().isNotEmpty) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('等待超时：$finder');
  }

  /// 等待一个同步条件（如 gateStarted / 异步调用已开始）。
  Future<void> waitForCondition(
    WidgetTester tester,
    bool Function() condition, {
    int rounds = 120,
  }) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      if (condition()) return;
    }
    fail('等待条件超时');
  }

  String ideaFieldText(WidgetTester tester) {
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('agent_book_idea_field')),
    );
    return field.controller!.text;
  }

  testWidgets('输入页：Markdown 控制器、不保存提示、模型选择、空输入禁用开始', (
    tester,
  ) async {
    final ai = ScriptedAiService(completeBookCreationResponses());
    await pumpPage(tester, ai);

    final fieldFinder = find.byKey(const ValueKey('agent_book_idea_field'));
    expect(fieldFinder, findsOneWidget);
    final field = tester.widget<TextField>(fieldFinder);
    expect(field.controller, isA<MarkdownEditingController>());
    expect(find.textContaining('输入内容不会被保存'), findsWidgets);
    expect(find.text('生成模型'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent_book_start_button')), findsOneWidget);

    // 空输入：开始按钮禁用。
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('agent_book_start_button')),
          )
          .onPressed,
      isNull,
    );

    // 输入后启用；点开始弹二次确认，取消后留在输入页、不发起 AI。
    await tester.enterText(fieldFinder, kBookCreationIdea);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('agent_book_start_button')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('agent_book_start_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent_book_confirm_dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('内容不会被保存'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('agent_book_confirm_cancel')));
    await tester.pumpAndSettle();

    expect(fieldFinder, findsOneWidget);
    expect(ai.calls, 0);
    expect(await tester.runAsync(() => stack.repos.books.listBooks()), isEmpty);
  });

  testWidgets('成功：分步 Token -> 设置页保存 -> 新书聊天页', (tester) async {
    final ai = ScriptedAiService(completeBookCreationResponses());
    await pumpPage(tester, ai);
    await startFlow(tester);

    await waitForFinder(
      tester,
      find.byKey(const ValueKey('agent_book_success_dialog')),
    );
    expect(find.text('创建成功'), findsOneWidget);
    final successDialog = find.byKey(
      const ValueKey('agent_book_success_dialog'),
    );
    expect(
      find.descendant(
        of: successDialog,
        matching: find.textContaining('输入 Tokens 50'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: successDialog,
        matching: find.textContaining('输出 Tokens 100'),
      ),
      findsOneWidget,
    );
    expect(cloud.triggers, 1, reason: '落库成功后只触发一次同步');

    await tester.tap(find.byKey(const ValueKey('agent_book_success_confirm')));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.text('书籍设置'), findsOneWidget);
    expect(find.widgetWithText(TextField, kBookCreationTitle), findsOneWidget);

    // 修改标题并保存 -> 设置页关闭 -> 直接进入新书聊天页。
    await tester.enterText(
      find.widgetWithText(TextField, kBookCreationTitle),
      '改过的书名',
    );
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await settle(tester);

    expect(find.byType(ChatScreen), findsOneWidget);
    final uuid = bookProvider.currentBook!.uuid;
    final stored = await tester.runAsync(
      () => stack.repos.books.loadBook(uuid),
    );
    expect(stored!.title, '改过的书名');
  });

  testWidgets('AI 失败：弹失败框 -> 返回编辑页且输入仍在、无书', (tester) async {
    final ai = ScriptedAiService([
      const ScriptedAiResponse(kBookTitleScript),
      const ScriptedAiResponse(kBookModsScript),
      const ScriptedAiResponse('', error: AiException('模拟网络失败')),
    ]);
    await pumpPage(tester, ai);
    await startFlow(tester);

    await waitForFinder(
      tester,
      find.byKey(const ValueKey('agent_book_failure_dialog')),
    );
    final failureDialog = find.byKey(
      const ValueKey('agent_book_failure_dialog'),
    );
    expect(
      find.descendant(
        of: failureDialog,
        matching: find.textContaining('基础设定与世界书失败'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: failureDialog,
        matching: find.textContaining('模拟网络失败'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('agent_book_failure_back')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('agent_book_idea_field')),
      findsOneWidget,
    );
    expect(ideaFieldText(tester), kBookCreationIdea);
    expect(cloud.triggers, 0);
    expect(await tester.runAsync(() => stack.repos.books.listBooks()), isEmpty);
  });

  testWidgets('不完整：返回重新编辑，输入保留且不建书', (tester) async {
    final ai = ScriptedAiService(incompleteBookCreationResponses());
    await pumpPage(tester, ai);
    await startFlow(tester);

    await waitForFinder(
      tester,
      find.byKey(const ValueKey('agent_book_incomplete_dialog')),
    );
    expect(find.text('内容不完整'), findsOneWidget);
    final incompleteDialog = find.byKey(
      const ValueKey('agent_book_incomplete_dialog'),
    );
    expect(
      find.descendant(
        of: incompleteDialog,
        matching: find.textContaining('书名缺失'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: incompleteDialog,
        matching: find.textContaining('文笔要求缺失'),
      ),
      findsOneWidget,
    );
    expect(ai.calls, 7, reason: '5 个基础阶段 + 2 次补充轮');

    await tester.tap(find.byKey(const ValueKey('agent_book_incomplete_edit')));
    await tester.pumpAndSettle();

    expect(ideaFieldText(tester), kBookCreationIdea);
    expect(await tester.runAsync(() => stack.repos.books.listBooks()), isEmpty);
    expect(cloud.triggers, 0);
  });

  testWidgets('不完整 -> 保留此书：标题兜底，进设置页，返回后到聊天页', (tester) async {
    final ai = ScriptedAiService(incompleteBookCreationResponses());
    await pumpPage(tester, ai);
    await startFlow(tester);

    await waitForFinder(
      tester,
      find.byKey(const ValueKey('agent_book_incomplete_dialog')),
    );
    await tester.tap(find.byKey(const ValueKey('agent_book_incomplete_keep')));
    await tester.pump();

    await waitForFinder(
      tester,
      find.byKey(const ValueKey('agent_book_success_dialog')),
    );
    expect(find.text('已保留此书（内容不完整）'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('agent_book_success_dialog')),
        matching: find.textContaining('书名缺失'),
      ),
      findsOneWidget,
    );
    expect(cloud.triggers, 1, reason: '落库成功后只触发一次同步');

    await tester.tap(find.byKey(const ValueKey('agent_book_success_confirm')));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.widgetWithText(TextField, '未命名书籍'), findsOneWidget);

    // 未编辑直接关闭 -> 新书聊天页。
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.byType(ChatScreen), findsOneWidget);

    final books = await tester.runAsync(() => stack.repos.books.listBooks());
    expect(books!.single.title, '未命名书籍');
  });

  testWidgets('数据库错误：删除半成品书、报错返回编辑页', (tester) async {
    final ai = ScriptedAiService(completeBookCreationResponses());
    await pumpPage(
      tester,
      ai,
      writer: BookCreationWriter(
        books: stack.repos.books,
        worldBooks: _FailingWorldBookRepository(
          books: stack.repos.worldBook.books,
        ),
        mods: stack.repos.mod,
      ),
    );
    await startFlow(tester);

    await waitForFinder(
      tester,
      find.byKey(const ValueKey('agent_book_failure_dialog')),
    );
    final failureDialog = find.byKey(
      const ValueKey('agent_book_failure_dialog'),
    );
    expect(
      find.descendant(
        of: failureDialog,
        matching: find.textContaining('数据库写入失败'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: failureDialog,
        matching: find.textContaining('已清理'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('agent_book_failure_back')));
    await tester.pumpAndSettle();
    expect(ideaFieldText(tester), kBookCreationIdea);
    expect(
      await tester.runAsync(
        () => stack.repos.books.listBooks(includeDeleted: true),
      ),
      isEmpty,
    );
    expect(cloud.triggers, 0);
  });

  testWidgets('生成中取消：不写库、输入保留', (tester) async {
    final ai = ScriptedAiService(completeBookCreationResponses());
    ai.gate = Completer<void>();
    ai.gateStarted = Completer<void>();
    await pumpPage(tester, ai);
    await startFlow(tester);

    await waitForCondition(tester, () => ai.gateStarted!.isCompleted);
    expect(
      find.byKey(const ValueKey('agent_book_cancel_button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('agent_book_cancel_button')));
    // 生成中步骤有无限转圈动画，不能用 pumpAndSettle；推进弹窗动画即可。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('agent_book_cancel_dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('agent_book_cancel_confirm')));
    await tester.pump();
    ai.gate!.complete();

    await waitForFinder(
      tester,
      find.byKey(const ValueKey('agent_book_idea_field')),
    );
    expect(ideaFieldText(tester), kBookCreationIdea);
    expect(await tester.runAsync(() => stack.repos.books.listBooks()), isEmpty);
    expect(cloud.triggers, 0);
    // 取消时弹过「正在取消…」提示：清掉驻留定时器，避免测试收尾报 pending timer。
    await flushNotices(tester);
  });
}

/// 世界书仓储替身：`replaceAll` 直接抛错（模拟数据库故障）。
class _FailingWorldBookRepository extends WorldBookRepository {
  _FailingWorldBookRepository({required super.books});

  @override
  Future<void> replaceAll(
    String bookUuid,
    List<WorldBookEntry> entries,
  ) async {
    throw StateError('模拟世界书写入失败');
  }
}
