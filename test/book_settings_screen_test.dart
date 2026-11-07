import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/mod_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/book_settings_screen.dart';
import 'package:narrchat/services/app_notice_center.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/memory_summary_round_selector.dart';
import 'package:narrchat/widgets/prompt_input_hint.dart';
import 'package:provider/provider.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

void main() {
  late TestStack stack;
  late BookProvider bookProvider;

  setUp(() async {
    stack = await TestStack.create();
    await stack.seedBook(
      uuid: 'b1',
      title: '当前标题',
      category: '当前分类',
      baseSetting: '当前设定',
    );
    bookProvider = BookProvider(repository: stack.repos.books);
    await bookProvider.loadBooks();
  });

  tearDown(() async {
    await stack.dispose();
  });

  /// 改库里那本书（模拟云备份落地），再让 provider 重载。
  Future<void> patchStoredBook(
    WidgetTester tester,
    Book Function(Book current) update,
  ) async {
    await tester.runAsync(() async {
      final current = await stack.repos.books.loadBook('b1');
      await stack.repos.books.saveBook(update(current!));
    });
    await tester.runAsync(bookProvider.loadBooks);
  }

  /// 以编辑模式 pump 书籍设置页（可注入一个"陈旧"的 Book 快照，模拟调用方持有旧实例）。
  ///
  /// 设置页被压在宿主路由之上：保存成功会 `pop` 回宿主，用例可断言落库结果。
  Future<void> pumpSettings(WidgetTester tester, {Book? book}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigatorKey = GlobalKey<NavigatorState>();
    final noticeCenter = AppNoticeCenter();
    addTearDown(noticeCenter.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: bookProvider),
          ChangeNotifierProvider(
            create: (_) => WorldBookProvider(repository: stack.repos.worldBook),
          ),
          ChangeNotifierProvider(
            create: (_) => ModProvider(repository: stack.repos.mod),
          ),
          ChangeNotifierProvider(create: (_) => CloudSyncProvider()),
          ChangeNotifierProvider(
            create: (_) => RoundProvider(
              rounds: stack.repos.rounds,
              books: stack.repos.books,
            ),
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
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => BookSettingsScreen(book: book)),
    );
    await settle(tester);
  }

  testWidgets('打开时以 Provider 最新实例为准：陈旧快照不决定展示值', (tester) async {
    // 库中已有最新设置（模拟云同步落地后重载过）。
    await patchStoredBook(tester, (b) => b.copyWith(title: '云端新标题', category: '云端新分类'));
    await bookProvider.loadBooks();

    // 调用方传入陈旧快照（同步落地前打开的对话页遗留引用）。
    await pumpSettings(
      tester,
      book: const Book(uuid: 'b1', title: '陈旧标题', category: '旧分类'),
    );

    expect(find.widgetWithText(TextField, '云端新标题'), findsOneWidget,
        reason: '打开即解析 Provider 最新实例');
    expect(find.widgetWithText(TextField, '云端新分类'), findsOneWidget);
    expect(find.widgetWithText(TextField, '陈旧标题'), findsNothing);
  });

  testWidgets('打开期间远端设置落地：未编辑字段即时刷新，已编辑字段保留草稿', (tester) async {
    await pumpSettings(tester, book: bookProvider.currentBook);

    // 用户正在编辑「书籍总类别」。
    await tester.enterText(
      find.widgetWithText(TextField, '当前分类'),
      '用户草稿',
    );
    await tester.pump();
    expect(find.widgetWithText(TextField, '用户草稿'), findsOneWidget);

    // 云同步落地：标题 / 分类均被远端修改。
    await patchStoredBook(tester, (b) => b.copyWith(
      title: '远端新标题',
      category: '远端新分类',
    ));
    await bookProvider.loadBooks();
    await tester.pump();

    expect(find.widgetWithText(TextField, '远端新标题'), findsOneWidget,
        reason: '未编辑字段跟随远端最新值');
    expect(find.widgetWithText(TextField, '用户草稿'), findsOneWidget,
        reason: '用户编辑中的字段保留草稿');
    expect(find.widgetWithText(TextField, '远端新分类'), findsNothing);

    // 再次落地：已编辑字段仍不被覆盖。
    await patchStoredBook(tester, (b) => b.copyWith(title: '远端标题2'));
    await bookProvider.loadBooks();
    await tester.pump();

    expect(find.widgetWithText(TextField, '远端标题2'), findsOneWidget);
    expect(find.widgetWithText(TextField, '用户草稿'), findsOneWidget);
  });

  testWidgets('保存设置不重置未改动项：记忆总结轮次合并沿用既有档位', (tester) async {
    await patchStoredBook(tester, (b) => b.copyWith(memorySummaryRounds: 10));
    await bookProvider.loadBooks();
    await pumpSettings(tester, book: bookProvider.currentBook);

    await tester.enterText(find.widgetWithText(TextField, '当前标题'), '改后标题');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await settle(tester);

    expect((await tester.runAsync(() => stack.repos.books.loadBook('b1')))!.title, '改后标题');
    expect(
      (await tester.runAsync(() => stack.repos.books.loadBook('b1')))!.memorySummaryRounds,
      10,
      reason: '用户未改档位，保存必须沿用既有值（不得重置为 0）',
    );
  });

  testWidgets('概览页：记忆总结轮次合并控件在历史轮次数下方，含标题 / 小字注释 / 0-5-10 三档',
      (tester) async {
    await pumpSettings(tester, book: bookProvider.currentBook);

    expect(find.text(MemorySummaryRoundSelector.label), findsOneWidget);
    expect(find.text(MemorySummaryRoundSelector.note), findsOneWidget);

    final segmented = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    expect(segmented.segments.map((s) => s.value).toList(), [0, 5, 10]);
    expect(segmented.selected, {0}, reason: '默认不开启');

    // 位置：控件顶部在历史轮次数下方。
    expect(
      tester.getTopLeft(find.text(MemorySummaryRoundSelector.label)).dy,
      greaterThan(tester.getTopLeft(find.text('历史轮次数')).dy),
    );
  });

  testWidgets('选中 5 档并保存：库内落为 5', (tester) async {
    await pumpSettings(tester, book: bookProvider.currentBook);

    await tester.tap(find.descendant(
      of: find.byType(SegmentedButton<int>),
      matching: find.text('5'),
    ));
    await tester.pump();
    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      {5},
      reason: '选中态即时跟随',
    );

    await tester.tap(find.text('保存'));
    await settle(tester);
    expect((await tester.runAsync(() => stack.repos.books.loadBook('b1')))!.memorySummaryRounds, 5);
  });

  testWidgets('库内为非三档位（7）：控件按 0 展示，保存后按 0 落库', (tester) async {
    // 越界档位在**模型边界**收敛：`Book.fromMap` 读到 7 即按 0 处理。
    final dirty = Book.fromMap(const {
      'uuid': 'b1',
      'title': '当前标题',
      'category': '当前分类',
      'base_setting': '当前设定',
      'memory_summary_rounds': 7,
    });
    expect(dirty.memorySummaryRounds, 0, reason: '模型边界收敛为受支持档位');
    await patchStoredBook(tester, (_) => dirty);
    await pumpSettings(tester, book: bookProvider.currentBook);

    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      {0},
      reason: '越界档位读取即按 0 执行',
    );

    await tester.tap(find.text('保存'));
    await settle(tester);
    expect((await tester.runAsync(() => stack.repos.books.loadBook('b1')))!.memorySummaryRounds, 0,
        reason: '落库只会是受支持档位');
  });

  testWidgets('窄屏（手机宽度）下档位控件不溢出且仍可选中', (tester) async {
    await pumpSettings(tester, book: bookProvider.currentBook);

    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    await settle(tester);

    expect(find.text(MemorySummaryRoundSelector.label), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '窄屏布局不得溢出');

    await tester.tap(find.descendant(
      of: find.byType(SegmentedButton<int>),
      matching: find.text('10'),
    ));
    await tester.pump();
    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      {10},
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑态有「其它设置」栏，点开显示删除未启用代的入口', (tester) async {
    await tester.runAsync(() async {
      await stack.seedRound(
        'b1',
        roundIndex: 1,
        uuid: 'g1',
        isUsing: true,
        aiNarrative: '当前代',
      );
      await stack.seedRound(
        'b1',
        roundIndex: 1,
        uuid: 'g1-old',
        isUsing: false,
        aiNarrative: '旧代',
      );
    });
    await pumpSettings(tester, book: bookProvider.currentBook);

    expect(find.text('其它设置'), findsOneWidget, reason: '编辑态导航含其它设置');
    await tester.tap(find.text('其它设置'));
    await settle(tester);

    expect(find.text('删除未启用的代'), findsWidgets, reason: '卡片标题 + 按钮');
    expect(find.textContaining('全书共 2 代'), findsOneWidget);
    expect(find.textContaining('其中 1 个未启用'), findsOneWidget);
  });

  testWidgets('每个子页都带 #/## 输入提示（灰字小字，文案单一真源）', (tester) async {
    await pumpSettings(tester, book: bookProvider.currentBook);

    // 「其它设置」是维护页，没有文本输入，刻意不要求该提示，不在此列。
    const pages = [
      '书籍概览',
      '角色类别与描述格式',
      '基础设定',
      '世界书',
      '文笔参考段落',
      'Mod 管理',
    ];
    for (final label in pages) {
      await tester.tap(find.text(label).first);
      await settle(tester);
      expect(
        find.text(PromptInputHint.text),
        findsOneWidget,
        reason: '「$label」页缺少 #/## 输入提示',
      );
    }
  });
}
