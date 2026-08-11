import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/world_book_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/failed_attempt.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/home_screen.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// 内存版 DAO，避免测试依赖 sqflite。
class _MockBookDao extends BookDao {
  final List<Book> books;
  final Map<int, DateTime> times;
  _MockBookDao(this.books, {this.times = const {}});

  @override
  Future<List<Book>> getAllBooks() async => books;

  @override
  Future<Map<int, DateTime>> getLastRoundTimes() async => times;

  @override
  Future<FailedAttempt> getFailedAttempt(int bookId) async =>
      const FailedAttempt();

  @override
  Future<void> setFailedAttempt(int bookId, FailedAttempt attempt) async {}
}

class _MockRoundDao extends RoundDao {
  @override
  Future<List<Round>> getRoundsByBook(int bookId) async => [];

  @override
  Future<int> insertRound(Round round) async => 1;

  @override
  Future<int> updateRoundFields(int roundId, Map<String, Object?> fields) async =>
      1;

  @override
  Future<void> deleteRound(int roundId, {bool deleteFollowing = false}) async {}
}

class _MockWorldBookDao extends WorldBookDao {
  @override
  Future<List<WorldBookEntry>> getEntriesByBook(int bookId) async => [];
}

/// 以宽屏渲染首页（书籍列表），可注入书籍与最近对话时间。
Future<void> pumpHome(
  WidgetTester tester, {
  required List<Book> books,
  Map<int, DateTime> times = const {},
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final bookDao = _MockBookDao(books, times: times);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => BookProvider(dao: bookDao)..loadBooks(),
        ),
        ChangeNotifierProvider(
          create: (_) => WorldBookProvider(dao: _MockWorldBookDao()),
        ),
        ChangeNotifierProvider(
          create: (_) => RoundProvider(dao: _MockRoundDao(), bookDao: bookDao),
        ),
        ChangeNotifierProvider(create: (_) => SidebarProvider()),
      ],
      child: MaterialApp(
        theme: NarrChatTheme.light,
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 当前书籍列表中按视觉顺序排列的标题。
List<String?> visibleTitles(WidgetTester tester) => tester
    .widgetList<ListTile>(find.byType(ListTile))
    .map((t) => (t.title as Text).data)
    .toList();

void main() {
  testWidgets('搜索：按标题 / 分类过滤', (tester) async {
    await pumpHome(tester, books: const [
      Book(id: 1, title: '剑来', category: '玄幻'),
      Book(id: 2, title: '三体', category: '科幻'),
    ]);

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
    await pumpHome(tester, books: const [Book(id: 1, title: '剑来')]);

    await tester.enterText(find.byType(TextField), '不存在的书');
    await tester.pump();
    expect(find.text('未找到匹配的书籍'), findsOneWidget);

    await tester.tap(find.text('清空搜索'));
    await tester.pump();
    expect(find.widgetWithText(ListTile, '剑来'), findsOneWidget);
  });

  testWidgets('排序：A-Z 按拼音', (tester) async {
    await pumpHome(tester, books: const [
      Book(id: 1, title: '张三'),
      Book(id: 2, title: '阿伟'),
      Book(id: 3, title: 'Book'),
    ]);

    await tester.tap(find.text('A-Z'));
    await tester.pumpAndSettle();
    expect(visibleTitles(tester), ['阿伟', 'Book', '张三']);
  });

  testWidgets('排序：时间按最近对话在前，无对话排最后', (tester) async {
    await pumpHome(
      tester,
      books: const [
        Book(id: 1, title: 'A'),
        Book(id: 2, title: 'B'),
        Book(id: 3, title: 'C'),
      ],
      times: {2: DateTime(2026, 8, 10), 1: DateTime(2026, 8, 1)},
    );
    expect(visibleTitles(tester), ['B', 'A', 'C']);
  });

  testWidgets('点击书籍进入对话页，返回按钮回到首页', (tester) async {
    await pumpHome(tester, books: const [Book(id: 1, title: '测试书')]);

    await tester.tap(find.text('测试书'));
    await tester.pumpAndSettle();
    // 对话页：AppBar 显示书名 + 返回按钮。
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('测试书'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('新建书籍'), findsOneWidget, reason: '应已返回首页书籍列表');
  });

  testWidgets('列表无编辑 / 书籍设置入口，仅保留删除', (tester) async {
    await pumpHome(tester, books: const [Book(id: 1, title: '测试书')]);

    expect(find.text('编辑'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byIcon(Icons.book_outlined), findsNothing);

    // 更多操作菜单仅「删除」。
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('无书籍时显示欢迎空态与新建按钮', (tester) async {
    await pumpHome(tester, books: const []);
    expect(find.text('还没有书籍'), findsOneWidget);
    expect(find.text('新建书籍'), findsOneWidget);
  });
}
