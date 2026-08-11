import 'package:flutter/gestures.dart';
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
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_field.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';
import 'package:provider/provider.dart';

/// 内存版 DAO，避免测试依赖 sqflite。
class _MockBookDao extends BookDao {
  final List<Book> books;
  _MockBookDao(this.books);
  @override
  Future<List<Book>> getAllBooks() async => books;
  @override
  Future<Map<int, DateTime>> getLastRoundTimes() async => {};
  FailedAttempt _failed = const FailedAttempt();
  @override
  Future<FailedAttempt> getFailedAttempt(int bookId) async => _failed;
  @override
  Future<void> setFailedAttempt(int bookId, FailedAttempt attempt) async {
    _failed = attempt;
  }
}

class _MockRoundDao extends RoundDao {
  final List<Round> _rounds = [];
  int _nextId = 1;
  @override
  Future<List<Round>> getRoundsByBook(int bookId) async =>
      List.of(_rounds.where((r) => r.bookId == bookId));
  @override
  Future<int> insertRound(Round round) async {
    final created = Round(
      id: _nextId++,
      bookId: round.bookId,
      roundIndex: round.roundIndex,
      userInput: round.userInput,
      aiNarrative: round.aiNarrative,
      worldState: round.worldState,
      characterState: round.characterState,
      memorySummary: round.memorySummary,
      currentTime: round.currentTime,
      recommendedAction: round.recommendedAction,
      tokensIn: round.tokensIn,
      tokensOut: round.tokensOut,
      createdAt: round.createdAt,
    );
    _rounds.add(created);
    return created.id!;
  }

  @override
  Future<int> updateRoundFields(
    int roundId,
    Map<String, Object?> fields,
  ) async => 1;

  @override
  Future<void> deleteRound(int roundId, {bool deleteFollowing = false}) async {}
}

class _MockWorldBookDao extends WorldBookDao {
  @override
  Future<List<WorldBookEntry>> getEntriesByBook(int bookId) async => [];
}

void main() {
  Future<void> pumpWideChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const book = Book(id: 1, title: '测试书');
    final bookDao = _MockBookDao([book]);
    final roundProvider = RoundProvider(dao: _MockRoundDao(), bookDao: bookDao);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(
            create: (_) => BookProvider(dao: bookDao)..loadBooks(),
          ),
          ChangeNotifierProvider(
            create: (_) => WorldBookProvider(dao: _MockWorldBookDao()),
          ),
          ChangeNotifierProvider(create: (_) => roundProvider),
          ChangeNotifierProvider(create: (_) => SidebarProvider()),
        ],
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: Scaffold(body: const ChatScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 测试环境中 ChatScreen 的 post-frame 回调执行时书籍可能尚未就绪，
    // 导致 loadRounds 未触发、侧边栏为空态；这里显式加载（第零轮）以保证有内容。
    await roundProvider.loadRounds(1);
    await tester.pumpAndSettle();
  }

  Future<void> pumpNarrowChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const book = Book(id: 1, title: '测试书');
    final bookDao = _MockBookDao([book]);
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
          home: Scaffold(body: const ChatScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('宽屏：右侧栏默认展开，无「打开侧栏」按钮', (tester) async {
    await pumpWideChat(tester);
    expect(find.text('打开侧栏'), findsNothing);
    // 顶栏存在收起按钮。
    expect(find.byIcon(Icons.close), findsWidgets);
  });

  testWidgets('宽屏：点击×收起后出现「打开侧栏」，点击后展开', (tester) async {
    await pumpWideChat(tester);
    // 收起：点击侧栏顶栏的 ×。
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();
    // 动画中途：× 可能已消失，但「打开侧栏」要等 value<0.5 才出现。
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('打开侧栏'), findsOneWidget);
    // 展开：点击「打开侧栏」。
    await tester.tap(find.text('打开侧栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('打开侧栏'), findsNothing);
  });

  testWidgets('窄屏：悬浮按钮呼出抽屉后按钮消失', (tester) async {
    await pumpNarrowChat(tester);

    // 初始：悬浮按钮存在（抽屉关闭）。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
    // 打开抽屉。
    await tester.tap(find.byIcon(Icons.view_sidebar_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // 动画中途采样
    final midLeft = tester.getTopLeft(find.byType(SidebarPanel)).dx;
    final drawerWidth = 600 * 0.88;
    // 中途：侧栏应处于半途（左侧 x 在 [600-drawerWidth, 600] 区间内），证明是平滑滑动而非跳变。
    expect(midLeft, greaterThan(600 - drawerWidth));
    expect(midLeft, lessThan(600));
    await tester.pump(const Duration(milliseconds: 400));
    // 抽屉打开后悬浮按钮消失，且侧栏已完全滑入（左侧 x = 600 - drawerWidth）。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsNothing);
    expect(
      tester.getTopLeft(find.byType(SidebarPanel)).dx,
      closeTo(600 - drawerWidth, 1),
    );
  });

  testWidgets('窄屏：聊天区左滑打开右侧抽屉', (tester) async {
    await pumpNarrowChat(tester);

    // 初始：抽屉关闭，悬浮按钮存在。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);

    // 聊天区任意位置左滑（从右向左）。
    await tester.fling(find.byType(ChatScreen), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();

    // 抽屉打开：悬浮按钮消失，侧栏完全滑入。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsNothing);
    final drawerWidth = 600 * 0.88;
    expect(
      tester.getTopLeft(find.byType(SidebarPanel)).dx,
      closeTo(600 - drawerWidth, 1),
    );
  });

  testWidgets('窄屏：聊天区慢速长距离左拖也可打开抽屉', (tester) async {
    await pumpNarrowChat(tester);

    // 慢速拖动（速度低，但位移超过距离阈值）。
    await tester.drag(find.byType(ChatScreen), const Offset(-150, 0));
    await tester.pumpAndSettle();

    // 抽屉打开：悬浮按钮消失。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsNothing);
  });

  testWidgets('窄屏：聊天区右滑不打开右侧抽屉', (tester) async {
    await pumpNarrowChat(tester);

    // 聊天区右滑（从左向右）。
    await tester.fling(find.byType(ChatScreen), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();

    // 抽屉保持关闭：悬浮按钮仍在。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
  });

  testWidgets('窄屏：抽屉内右滑关闭右侧抽屉', (tester) async {
    await pumpNarrowChat(tester);

    // 先通过悬浮按钮打开抽屉。
    await tester.tap(find.byIcon(Icons.view_sidebar_outlined));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.view_sidebar_outlined), findsNothing);

    // 抽屉内右滑（从左向右）。
    await tester.fling(find.byType(SidebarPanel), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();

    // 抽屉关闭：悬浮按钮重新出现。
    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
  });

  testWidgets('窄屏：鼠标横向拖动不触发滑动开合', (tester) async {
    await pumpNarrowChat(tester);

    // 鼠标横向左拖：不应打开抽屉。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(300, 450));
    await gesture.down(const Offset(300, 450));
    await gesture.moveBy(const Offset(-300, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.view_sidebar_outlined), findsOneWidget);
  });

  testWidgets('点击子模块标题栏可折叠/展开（世界状态）', (tester) async {
    await pumpWideChat(tester);
    // 「世界状态」标题栏位于视口顶部附近，无需滚动即可见。
    expect(find.text('世界状态'), findsOneWidget);
    expect(find.byType(MarkdownField), findsOneWidget);
    // 折叠：点击标题栏。
    await tester.tap(find.text('世界状态'));
    await tester.pumpAndSettle();
    // 折叠后：编辑器消失，标题栏出现「已折叠」提示。
    expect(find.byType(MarkdownField), findsNothing);
    expect(find.text('已折叠'), findsOneWidget);
    // 再次点击展开。
    await tester.tap(find.text('世界状态'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownField), findsOneWidget);
    expect(find.text('已折叠'), findsNothing);
  });
}
