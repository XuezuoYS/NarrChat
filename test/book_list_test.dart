import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/notification_settings_provider.dart';
import 'package:narrchat/services/notification_service.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 首页书籍列表测试：搜索 / 排序 / 导航 / 空态 / 通知提示条。
void main() {
  /// 当前书籍列表中按视觉顺序排列的标题。
  List<String?> visibleTitles(WidgetTester tester) => tester
      .widgetList<ListTile>(find.byType(ListTile))
      .map((t) => (t.title as Text).data)
      .toList();

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
    expect(find.widgetWithText(ListTile, '三体'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '剑来'), findsNothing);

    await tester.enterText(find.byType(TextField), '玄幻');
    await tester.pump();
    expect(find.widgetWithText(ListTile, '剑来'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '三体'), findsNothing);
  });

  testWidgets('搜索：无结果显示空态，可清空恢复', (tester) async {
    await pumpHomeScreen(tester, books: const [Book(uuid: 'b1', title: '剑来')]);

    await tester.enterText(find.byType(TextField), '不存在的书');
    await tester.pump();
    expect(find.text('未找到匹配的书籍'), findsOneWidget);

    await tester.tap(find.text('清空搜索'));
    await tester.pump();
    expect(find.widgetWithText(ListTile, '剑来'), findsOneWidget);
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

  testWidgets('排序：时间按最近对话在前，无对话排最后', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [
        Book(uuid: 'b1', title: 'A'),
        Book(uuid: 'b2', title: 'B'),
        Book(uuid: 'b3', title: 'C'),
      ],
      // 最近对话时间的键就是书籍 uuid；C 无轮次 → 垫底。
      times: {'b2': DateTime(2026, 8, 10), 'b1': DateTime(2026, 8, 1)},
    );
    expect(visibleTitles(tester), ['B', 'A', 'C']);
  });

  testWidgets('点击书籍进入对话页，返回按钮回到首页', (tester) async {
    await pumpHomeScreen(tester, books: const [Book(uuid: 'b1', title: '测试书')]);

    await tester.tap(find.text('测试书'));
    await tester.pumpAndSettle();
    // 对话页：AppBar 显示书名 + 返回按钮。
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('测试书'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('新建书籍'), findsOneWidget, reason: '应已返回首页书籍列表');
  });

  testWidgets('对话页点击顶栏书名直接进入书籍设置', (tester) async {
    await pumpHomeScreen(tester, books: const [Book(uuid: 'b1', title: '测试书')]);

    await tester.tap(find.text('测试书'));
    await tester.pumpAndSettle();
    expect(find.text('测试书'), findsOneWidget, reason: '应已进入对话页（AppBar 显示书名）');

    // 点击顶栏书名，应直接进入书籍设置页。
    await tester.tap(find.text('测试书'));
    await tester.pumpAndSettle();
    expect(find.text('书籍设置'), findsWidgets, reason: '应进入书籍设置页');
    expect(find.text('保存'), findsOneWidget, reason: '设置页应显示保存按钮');
  });

  testWidgets('列表无编辑 / 书籍设置入口，仅保留删除', (tester) async {
    await pumpHomeScreen(tester, books: const [Book(uuid: 'b1', title: '测试书')]);

    expect(find.text('编辑'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byIcon(Icons.book_outlined), findsNothing);

    // 更多操作菜单仅「删除」。
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('删除书籍走软删：确认后从列表移除', (tester) async {
    await pumpHomeScreen(tester, books: const [Book(uuid: 'b1', title: '测试书')]);
    expect(find.widgetWithText(ListTile, '测试书'), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 确认对话框出现。
    expect(find.text('删除书籍'), findsOneWidget);
    // 确认删除。
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    // 软删后列表移除该书，显示空态。
    expect(find.widgetWithText(ListTile, '测试书'), findsNothing);
    expect(find.text('还没有书籍'), findsOneWidget);
  });

  testWidgets('无书籍时显示欢迎空态与新建按钮', (tester) async {
    await pumpHomeScreen(tester, books: const []);
    expect(find.text('还没有书籍'), findsOneWidget);
    expect(find.text('新建书籍'), findsOneWidget);
  });

  testWidgets('系统通知未开启时主页显示提示条', (tester) async {
    const books = [Book(uuid: 'b1', title: '测试书')];
    final bookDao = FakeBookDao(books: books);
    final bookProvider = BookProvider(dao: bookDao)..loadBooks();
    final service = GenerationNotificationService(
      bookProvider: bookProvider,
      backend: FakeNotificationBackend(notificationsEnabled: false),
      attentionBackend: FakeTaskbarAttentionBackend(),
    );
    // 用预构建（已 refresh）的设置 Provider pump 首页，模拟通知关闭态。
    final settings = NotificationSettingsProvider(service: service);
    await settings.refresh();
    await pumpHomeScreen(
      tester,
      books: books,
      notificationSettings: settings,
    );

    expect(find.textContaining('您没有开启系统通知'), findsOneWidget);
    expect(find.text('去开启'), findsOneWidget);
  });
}
