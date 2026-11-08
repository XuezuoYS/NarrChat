import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/default_cover_style.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/notification_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/screens/home_screen.dart';
import 'package:narrchat/services/image_store.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/utils/book_list_utils.dart';
import 'package:narrchat/widgets/book_cover.dart';
import 'package:narrchat/widgets/book_grid_card.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';
import 'helpers/image_fixtures.dart';

/// 首页书籍列表测试：搜索 / 排序 / 排列 / 导航 / 空态 / 通知提示条。
void main() {
  /// 当前方格列表中按视觉顺序排列的标题。
  List<String?> visibleTitles(WidgetTester tester) => tester
      .widgetList<BookGridCard>(find.byType(BookGridCard))
      .map((card) => card.book.title)
      .toList();

  /// 切到列表模式（现有更多操作入口在列表行上）。
  Future<void> switchToList(WidgetTester tester) async {
    await tester.tap(find.byTooltip('列表排列'));
    await tester.pumpAndSettle();
  }

  testWidgets('默认方格排列 + 更新时间排序', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
    );

    expect(find.byType(BookGridCard), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    final sort = tester.widget<SegmentedButton<BookSortMode>>(
      find.byType(SegmentedButton<BookSortMode>),
    );
    expect(sort.selected, {BookSortMode.time});
    final layout = tester.widget<SegmentedButton<BookLayoutMode>>(
      find.byType(SegmentedButton<BookLayoutMode>),
    );
    expect(layout.selected, {BookLayoutMode.grid});
  });

  testWidgets('方格与列表之间切换', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
    );
    expect(find.byType(BookGridCard), findsOneWidget);

    await switchToList(tester);
    expect(find.byType(BookGridCard), findsNothing);
    expect(find.byType(ListTile), findsOneWidget);

    await tester.tap(find.byTooltip('方格排列'));
    await tester.pumpAndSettle();
    expect(find.byType(BookGridCard), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('搜索：按标题 / 分类过滤', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [
        Book(uuid: 'b1', title: '剑来', category: '玄幻'),
        Book(uuid: 'b2', title: '三体', category: '科幻'),
      ],
    );

    await tester.enterText(find.byType(TextField), '三体');
    await tester.pump();
    expect(find.widgetWithText(BookGridCard, '三体'), findsOneWidget);
    expect(find.widgetWithText(BookGridCard, '剑来'), findsNothing);

    await tester.enterText(find.byType(TextField), '玄幻');
    await tester.pump();
    expect(find.widgetWithText(BookGridCard, '剑来'), findsOneWidget);
    expect(find.widgetWithText(BookGridCard, '三体'), findsNothing);
  });

  testWidgets('搜索：无结果显示空态，可清空恢复', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '剑来')],
    );

    await tester.enterText(find.byType(TextField), '不存在的书');
    await tester.pump();
    expect(find.text('未找到匹配的书籍'), findsOneWidget);

    await tester.tap(find.text('清空搜索'));
    await tester.pump();
    expect(find.widgetWithText(BookGridCard, '剑来'), findsOneWidget);
  });

  testWidgets('排序：A-Z 按拼音', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [
        Book(uuid: 'b1', title: '张三'),
        Book(uuid: 'b2', title: '阿伟'),
        Book(uuid: 'b3', title: 'Book'),
      ],
    );

    await tester.tap(find.text('A-Z'));
    await tester.pumpAndSettle();
    expect(visibleTitles(tester), ['阿伟', 'Book', '张三']);
  });

  testWidgets('排序：更新时间新的在前', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [
        Book(uuid: 'b1', title: 'A'),
        Book(uuid: 'b2', title: 'B'),
        Book(uuid: 'b3', title: 'C'),
      ],
      // 三本书都给更新时间：默认排序必须完全按这张表来，不受创建时间影响。
      updatedTimes: {
        'b2': DateTime(2026, 8, 10),
        'b1': DateTime(2026, 8, 1),
        'b3': DateTime(2026, 7, 1),
      },
    );
    expect(visibleTitles(tester), ['B', 'A', 'C']);
  });

  testWidgets('方格卡片：2:3 封面、三行标题省略、灰色分类', (tester) async {
    const longTitle = '这是一个非常非常长的标题，用来验证最多三行并且超出部分显示省略号的效果';
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: longTitle, category: '玄幻')],
    );

    final coverSize = tester.getSize(find.byType(BookCover));
    expect(coverSize.height / coverSize.width, closeTo(1.5, 0.001));

    final title = tester.widget<Text>(find.text(longTitle));
    expect(title.maxLines, 3);
    expect(title.overflow, TextOverflow.ellipsis);

    final category = tester.widget<Text>(find.text('玄幻'));
    final cardContext = tester.element(find.byType(BookGridCard));
    expect(category.style?.color, cardContext.narrColors.textSecondary);
  });

  testWidgets('方格卡片：短标题的灰色分类紧贴标题，不平移到三行外', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '剑来', category: '玄幻')],
    );

    final title = tester.getRect(find.text('剑来'));
    final category = tester.getRect(find.text('玄幻'));
    expect(
      category.top - title.bottom,
      lessThan(10),
      reason: '分类必须紧跟实际标题行数，不能按三行槽位下移',
    );
  });

  testWidgets('默认封面为插画1：首页加载默认插画', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '插画书')],
    );

    final cover = find.byType(BookCover);
    expect(cover, findsOneWidget);
    expect(
      find.descendant(of: cover, matching: find.byType(Image)),
      findsOneWidget,
    );
  });

  testWidgets('默认封面设为无插画：首页显示含书名的生成封面', (tester) async {
    final ui = UiSettingsProvider(persist: (_) async {});
    await ui.setDefaultCoverStyle(DefaultCoverStyle.noIllustration);
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '灰皮书')],
      uiSettings: ui,
    );

    final cover = find.byType(BookCover);
    expect(cover, findsOneWidget);
    expect(
      find.descendant(of: cover, matching: find.text('灰皮书')),
      findsOneWidget,
      reason: '生成封面必须包含书名',
    );
    expect(
      find.descendant(of: cover, matching: find.byType(Image)),
      findsNothing,
      reason: '无插画模式不应再加载插画',
    );
  });

  testWidgets('自定义封面：首页方格显示文件图片（cover 居中）', (tester) async {
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    final userData = Directory(p.join(stack.rootDir.path, 'user_data'));
    ImageStore.testUserDataRoot = userData.path;
    addTearDown(() => ImageStore.testUserDataRoot = null);

    final bytes = await makePngBytes(tester, width: 4, height: 6);
    final rel = (await tester.runAsync(
      () => writeImageFixture(userData, bytes),
    ))!;

    await pumpHomeScreen(
      tester,
      stack: stack,
      books: [Book(uuid: 'b1', title: '封面书', bookCoverImg: rel)],
    );

    final cover = find.byType(BookCover);
    final image = tester.widget<Image>(
      find.descendant(of: cover, matching: find.byType(Image)),
    );
    expect(image.fit, BoxFit.cover);
    expect(image.alignment, Alignment.center);
    expect(image.image, isA<ResizeImage>());
    expect(
      ((image.image as ResizeImage).imageProvider as FileImage)
          .file
          .path
          .replaceAll('\\', '/'),
      endsWith('img/cover.png'),
      reason: '封面应直接读 user_data/img 下的文件',
    );
    expect(find.text('未设置封面'), findsNothing);
    expect(find.text('图片已损坏'), findsNothing);
  });

  testWidgets('封面文件丢失：首页回落默认插画，不出现灰块', (tester) async {
    final userData = Directory.systemTemp.createTempSync('narrchat_home_cover_');
    ImageStore.testUserDataRoot = userData.path;
    addTearDown(() {
      ImageStore.testUserDataRoot = null;
      try {
        userData.deleteSync(recursive: true);
      } catch (_) {
        // 清理失败不影响结论。
      }
    });

    await pumpHomeScreen(
      tester,
      books: const [
        Book(uuid: 'b1', title: '封面书', bookCoverImg: 'img/gone.png'),
      ],
    );

    final cover = find.byType(BookCover);
    final image = tester.widget<Image>(
      find.descendant(of: cover, matching: find.byType(Image)),
    );
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    expect((provider as ResizeImage).imageProvider, isA<AssetImage>());
    expect(find.text('未设置封面'), findsNothing);
    expect(find.text('图片已损坏'), findsNothing);
  });

  testWidgets('点击书籍进入对话页，返回按钮回到首页', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
    );

    await tester.tap(find.text('测试书'));
    await tester.pumpAndSettle();
    // 对话页：AppBar 显示书名 + 返回按钮。
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('测试书'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byTooltip('新建书籍'), findsOneWidget, reason: '应已返回首页书籍列表');
  });

  testWidgets('对话页返回首页后：可见书籍汇报被清空（生成提示能再次出现）', (tester) async {
    // 回归：驻场提示排除「当前可见对话页的那本书」；若返回首页后仍残留该书，
    // 就会变成「生成中的书回到主页反而不提示，进别的页才提示」。
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
    );
    final round = Provider.of<RoundProvider>(
      tester.element(find.byType(HomeScreen)),
      listen: false,
    );
    expect(round.visibleChatBookUuid, isNull, reason: '首页没有可见的对话页');

    await tester.tap(find.text('测试书'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(round.visibleChatBookUuid, 'b1', reason: '停留对话页：汇报本书');

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsNothing);
    expect(
      round.visibleChatBookUuid,
      isNull,
      reason: '回到首页必须清空，否则该书正在生成时首页不提示',
    );
  });

  testWidgets('对话页点击顶栏书名直接进入书籍设置', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
    );

    await tester.tap(find.text('测试书'));
    await tester.pumpAndSettle();
    expect(find.text('测试书'), findsOneWidget, reason: '应已进入对话页（AppBar 显示书名）');

    // 点击顶栏书名，应直接进入书籍设置页。
    await tester.tap(find.text('测试书'));
    await tester.pumpAndSettle();
    expect(find.text('书籍设置'), findsWidgets, reason: '应进入书籍设置页');
    expect(find.text('保存'), findsOneWidget, reason: '设置页应显示保存按钮');
  });

  testWidgets('列表模式无编辑 / 书籍设置入口，仅保留删除', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
    );
    await switchToList(tester);

    expect(find.text('编辑'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byIcon(Icons.book_outlined), findsNothing);

    // 更多操作菜单仅「删除」。
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('方格模式：右键弹出删除菜单并进入删除确认', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(BookGridCard)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除书籍'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.byType(BookGridCard), findsOneWidget, reason: '取消后书籍保留');
  });

  testWidgets('方格模式：长按也弹出删除菜单', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
    );

    await tester.longPress(find.byType(BookGridCard));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('删除书籍：输入书名最后确认后才从列表移除', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
    );
    await switchToList(tester);
    expect(find.widgetWithText(ListTile, '测试书'), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 第二次确认：说明影响范围与不可恢复。
    expect(find.text('删除书籍'), findsOneWidget);
    expect(find.textContaining('云端备份'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    // 第三次确认：必须逐字输入书名；未匹配时删除按钮禁用。
    expect(find.text('最后确认'), findsOneWidget);
    expect(find.textContaining('不可恢复'), findsOneWidget);
    final confirm = find.widgetWithText(FilledButton, '永久删除');
    expect(
      tester.widget<FilledButton>(confirm).onPressed,
      isNull,
      reason: '没输入书名时不能删除',
    );

    final input = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(input, '测试书（错）');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(confirm).onPressed,
      isNull,
      reason: '书名不一致不能删除',
    );

    // 一键填入：内容与当前书名一致，删除按钮解锁。
    await tester.tap(find.text('一键填入'));
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '测试书');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

    await tester.tap(confirm);
    await settle(tester);

    // 删除后列表移除该书，显示空态。
    expect(find.widgetWithText(ListTile, '测试书'), findsNothing);
    expect(find.text('还没有书籍'), findsOneWidget);
  });

  testWidgets('最后确认取消：书籍保留', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
    );
    await switchToList(tester);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('最后确认'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, '测试书'), findsOneWidget);
  });

  testWidgets('无书籍时显示欢迎空态与右上角新建入口', (tester) async {
    await pumpHomeScreen(tester, books: const []);
    expect(find.text('还没有书籍'), findsOneWidget);
    expect(find.text('点击右上角 + 新建你的第一本书'), findsOneWidget);
    expect(find.byTooltip('新建书籍'), findsOneWidget);
  });

  /// 构建已 refresh 的通知设置 Provider 与其假后端（模拟指定系统侧状态）。
  Future<(NotificationSettingsProvider, FakeNotificationBackend)> makeSettings(
    WidgetTester tester, {
    bool? notificationsEnabled,
    GenerationDoneChannelState channelState = const GenerationDoneChannelState(
      headsUp: true,
      sound: true,
    ),
  }) async {
    // 真库 I/O 要放在真实事件循环里跑，否则 fake-async 区域里会永远等下去。
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    final bookProvider = BookProvider(repository: stack.repos.books);
    await tester.runAsync(bookProvider.loadBooks);
    final backend = FakeNotificationBackend(
      notificationsEnabled: notificationsEnabled,
      channelState: channelState,
    );
    final service = GenerationNotificationService(
      bookProvider: bookProvider,
      backend: backend,
      attentionBackend: FakeTaskbarAttentionBackend(),
    );
    final settings = NotificationSettingsProvider(service: service);
    await settings.refresh();
    return (settings, backend);
  }

  testWidgets('系统通知未开启时主页显示提示条', (tester) async {
    const books = [Book(uuid: 'b1', title: '测试书')];
    // 用预构建（已 refresh）的设置 Provider pump 首页，模拟通知关闭态。
    final (settings, _) = await makeSettings(
      tester,
      notificationsEnabled: false,
    );
    await pumpHomeScreen(tester, books: books, notificationSettings: settings);

    expect(find.textContaining('您没有开启系统通知'), findsOneWidget);
    expect(find.text('去开启'), findsOneWidget);
  });

  testWidgets('通知总开关关闭时优先显示总开关提示而非渠道提示', (tester) async {
    final (settings, _) = await makeSettings(
      tester,
      notificationsEnabled: false,
    );
    await pumpHomeScreen(
      tester,
      books: const [],
      notificationSettings: settings,
    );

    expect(find.textContaining('您没有开启系统通知'), findsOneWidget);
    expect(find.textContaining('已被关闭'), findsNothing);
  });

  testWidgets('生成完成渠道悬浮通知被关闭时主页显示提示条并可跳转设置', (tester) async {
    final (settings, backend) = await makeSettings(
      tester,
      notificationsEnabled: true,
      channelState: const GenerationDoneChannelState(
        headsUp: false,
        sound: true,
      ),
    );
    await pumpHomeScreen(
      tester,
      books: const [],
      notificationSettings: settings,
    );

    expect(find.textContaining('悬浮通知已被关闭'), findsOneWidget);
    expect(find.textContaining('您没有开启系统通知'), findsNothing);

    await tester.tap(find.text('去开启'));
    expect(backend.openSettingsCount, 1);
  });

  testWidgets('生成完成渠道悬浮与铃声均被关闭时提示两者', (tester) async {
    final (settings, _) = await makeSettings(
      tester,
      notificationsEnabled: true,
      channelState: const GenerationDoneChannelState(
        headsUp: false,
        sound: false,
      ),
    );
    await pumpHomeScreen(
      tester,
      books: const [],
      notificationSettings: settings,
    );

    expect(find.textContaining('悬浮通知、通知铃声已被关闭'), findsOneWidget);
  });

  testWidgets('生成完成渠道悬浮与铃声全开时主页不显示提示条', (tester) async {
    final (settings, _) = await makeSettings(
      tester,
      notificationsEnabled: true,
    );
    await pumpHomeScreen(
      tester,
      books: const [],
      notificationSettings: settings,
    );

    expect(find.text('去开启'), findsNothing);
    expect(find.textContaining('已被关闭'), findsNothing);
  });
}
