import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/world_book_dao.dart';
import 'package:narrchat/models/book.dart';
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
  _MockBookDao(this.books);
  @override
  Future<List<Book>> getAllBooks() async => books;
}

class _MockRoundDao extends RoundDao {
  @override
  Future<List<Round>> getRoundsByBook(int bookId) async => [];
  @override
  Future<int> insertRound(Round round) async => 1;
  @override
  Future<int> updateRoundFields(int roundId, Map<String, Object?> fields) async => 1;
  @override
  Future<void> deleteRound(int roundId, {bool deleteFollowing = false}) async {}
}

class _MockWorldBookDao extends WorldBookDao {
  @override
  Future<List<WorldBookEntry>> getEntriesByBook(int bookId) async => [];
}

void main() {
  /// 以移动端窄屏（安卓）渲染主界面，并预置一本已选中的书。
  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const book = Book(id: 1, title: '测试书');
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(
            create: (_) => BookProvider(dao: _MockBookDao([book]))..loadBooks(),
          ),
          ChangeNotifierProvider(
            create: (_) => WorldBookProvider(dao: _MockWorldBookDao()),
          ),
          ChangeNotifierProvider(
            create: (_) => RoundProvider(dao: _MockRoundDao()),
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

  /// 模拟系统返回键（安卓），并等待弹窗/动画完成。
  Future<void> pressBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  /// 左侧书籍抽屉当前左偏移（0 表示完全展开，负值表示收起）。
  double leftDrawerOffset(WidgetTester tester) =>
      tester.widget<AnimatedPositioned>(
        find.byKey(const Key('left_book_drawer')),
      ).left!;

  /// 右侧状态抽屉当前右偏移（0 表示完全展开，正值表示收起）。
  double rightDrawerOffset(WidgetTester tester) =>
      tester.widget<AnimatedPositioned>(
        find.byKey(const Key('right_sidebar_drawer')),
      ).right!;

  const exitDialogTitle = '退出 NarrChat';
  const exitDialogContent = '确定要退出 NarrChat 吗？';

  testWidgets('无抽屉打开时按返回键弹出退出确认，取消后不退出', (tester) async {
    await pumpHome(tester);
    expect(find.text(exitDialogContent), findsNothing);

    await pressBack(tester);

    // 弹出二次确认对话框。
    expect(find.text(exitDialogTitle), findsOneWidget);
    expect(find.text(exitDialogContent), findsOneWidget);

    // 点「取消」：对话框关闭，应用未退出。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text(exitDialogContent), findsNothing);
  });

  testWidgets('确认退出时调用 SystemNavigator.pop', (tester) async {
    final log = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        log.add(call);
        return null;
      },
    );
    await pumpHome(tester);

    await pressBack(tester);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();

    expect(
      log.any((c) => c.method == 'SystemNavigator.pop'),
      isTrue,
      reason: '确认退出后应调用 SystemNavigator.pop 退出应用',
    );
  });

  testWidgets('左侧书籍抽屉打开时按返回键先关闭抽屉，不弹退出确认', (tester) async {
    await pumpHome(tester);

    // 打开左侧书籍抽屉（AppBar 汉堡按钮）。
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(leftDrawerOffset(tester), 0, reason: '左侧抽屉应完全展开');

    // 返回：关闭抽屉，不弹退出确认。
    await pressBack(tester);
    expect(leftDrawerOffset(tester), lessThan(0), reason: '左侧抽屉应收起');
    expect(find.text(exitDialogContent), findsNothing);
  });

  testWidgets('右侧状态抽屉打开时按返回键先关闭抽屉，不弹退出确认', (tester) async {
    await pumpHome(tester);

    // 打开右侧状态抽屉（悬浮按钮）。
    await tester.tap(find.byIcon(Icons.view_sidebar_outlined));
    await tester.pumpAndSettle();
    expect(rightDrawerOffset(tester), 0, reason: '右侧抽屉应完全展开');

    // 返回：关闭抽屉，不弹退出确认。
    await pressBack(tester);
    expect(rightDrawerOffset(tester), lessThan(0), reason: '右侧抽屉应收起');
    expect(find.text(exitDialogContent), findsNothing);
  });
}
