import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/chat_route.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/world_book_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/failed_attempt.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:provider/provider.dart';

const bookA = Book(id: 1, title: '书A');
const bookB = Book(id: 2, title: '书B');

/// 记录调用并可由测试手动触发点击的假通知后端。
class _FakeBackend implements NotificationBackend {
  final List<({int id, String title, String body, String payload})> shown = [];
  final List<int> cancelled = [];
  final List<int> startedForeground = [];
  int stopForegroundCount = 0;
  void Function(int bookId)? onTap;
  int? launchPayload;
  bool? notificationsEnabled;

  @override
  Future<void> init({required void Function(int bookId) onTap}) async {
    this.onTap = onTap;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    shown.add((id: id, title: title, body: body, payload: payload));
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);

  @override
  Future<int?> launchNotificationPayload() async => launchPayload;

  @override
  Future<bool?> areNotificationsEnabled() async => notificationsEnabled;

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Future<void> startForeground({
    required int id,
    required String title,
    required String body,
  }) async {
    startedForeground.add(id);
  }

  @override
  Future<void> stopForeground() async {
    stopForegroundCount++;
  }

  /// 模拟用户点击通知。
  void tap(int bookId) => onTap?.call(bookId);
}

class _MockBookDao extends BookDao {
  _MockBookDao(this.books);
  final List<Book> books;
  FailedAttempt failed = const FailedAttempt();

  @override
  Future<List<Book>> getAllBooks() async => books;

  @override
  Future<Map<int, DateTime>> getLastRoundTimes() async => {};

  @override
  Future<FailedAttempt> getFailedAttempt(int bookId) async => failed;

  @override
  Future<void> setFailedAttempt(int bookId, FailedAttempt attempt) async {
    failed = attempt;
  }
}

class _MockRoundDao extends RoundDao {
  final List<Round> rounds = [];
  int _nextId = 1;

  @override
  Future<List<Round>> getRoundsByBook(int bookId) async =>
      List.of(rounds.where((r) => r.bookId == bookId));

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
    rounds.add(created);
    return created.id!;
  }

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

/// 构造一个已初始化、注入假后端的服务。
Future<GenerationNotificationService> _makeService(_FakeBackend backend) async {
  final bookDao = _MockBookDao([bookA, bookB]);
  final bookProvider = BookProvider(dao: bookDao);
  await bookProvider.loadBooks();
  final service = GenerationNotificationService(
    bookProvider: bookProvider,
    backend: backend,
  );
  await service.init();
  return service;
}

/// 构造一条标记为「书 [bookId] 的 chat 页」的路由。
Route<void> chatRoute(int bookId) => MaterialPageRoute<void>(
      builder: (_) => const SizedBox(),
      settings: RouteSettings(name: chatRouteName, arguments: bookId),
    );

void main() {
  testWidgets('前台且正在该书 chat 页时不弹通知', (tester) async {
    final backend = _FakeBackend();
    final service = await _makeService(backend);

    // 模拟栈顶正在查看书 1 的 chat 页（生命周期默认 resumed）。
    service.routeObserver.didPush(chatRoute(1), null);
    expect(service.topChatBookId, 1);

    service.onGenerationCompleted(1, '书A');

    expect(backend.shown, isEmpty);
  });

  testWidgets('后台完成生成时弹出通知', (tester) async {
    final backend = _FakeBackend();
    final service = await _makeService(backend);
    service.didChangeAppLifecycleState(AppLifecycleState.paused);

    service.onGenerationCompleted(1, '书A');

    expect(backend.shown, hasLength(1));
    expect(backend.shown.single.id, 1);
    expect(backend.shown.single.payload, '1');
    expect(backend.shown.single.title, '《书A》本轮已完成');
    expect(backend.shown.single.body, '点击打开');
  });

  testWidgets('前台但在其它页面（栈顶非 chat）时弹出通知', (tester) async {
    final backend = _FakeBackend();
    final service = await _makeService(backend);

    service.onGenerationCompleted(2, '书B');

    expect(backend.shown, hasLength(1));
    expect(backend.shown.single.id, 2);
  });

  testWidgets('进入对应书 chat 页时自动删除该通知', (tester) async {
    final backend = _FakeBackend();
    final service = await _makeService(backend);

    // 后台先弹出一条书 2 的通知。
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    service.onGenerationCompleted(2, '书B');
    backend.cancelled.clear();

    // 前台进入书 2 的 chat 页。
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    service.routeObserver.didPush(chatRoute(2), null);

    expect(backend.cancelled, contains(2));
  });

  testWidgets('生成任务进行中启动保活前台服务，全部结束后停止', (tester) async {
    final backend = _FakeBackend();
    final service = await _makeService(backend);

    // 首个生成任务开始 → 启动前台服务。
    service.onGenerationActiveChanged(true);
    await tester.pump();
    expect(backend.startedForeground, hasLength(1));

    // 全部结束 → 停止前台服务。
    service.onGenerationActiveChanged(false);
    await tester.pump();
    expect(backend.stopForegroundCount, 1);

    // 重复上报同状态不重复启停。
    service.onGenerationActiveChanged(false);
    await tester.pump();
    expect(backend.stopForegroundCount, 1);
  });

  testWidgets('点通知跳转到对应书 chat 页', (tester) async {
    final backend = _FakeBackend();
    final bookDao = _MockBookDao([bookA, bookB]);
    final bookProvider = BookProvider(dao: bookDao);
    await bookProvider.loadBooks();
    final roundProvider = RoundProvider(dao: _MockRoundDao(), bookDao: bookDao);
    final service = GenerationNotificationService(
      bookProvider: bookProvider,
      backend: backend,
    );
    await service.init();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AiSettingsProvider>(
            create: (_) => AiSettingsProvider(),
          ),
          ChangeNotifierProvider<BookProvider>.value(value: bookProvider),
          ChangeNotifierProvider<WorldBookProvider>(
            create: (_) => WorldBookProvider(dao: _MockWorldBookDao()),
          ),
          ChangeNotifierProvider<RoundProvider>.value(value: roundProvider),
          ChangeNotifierProvider(create: (_) => SidebarProvider()),
        ],
        child: MaterialApp(
          navigatorKey: service.navigatorKey,
          navigatorObservers: [service.routeObserver],
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 模拟点击「书 B 生成完成」通知。
    backend.tap(bookB.id!);
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(bookProvider.currentBook?.id, bookB.id);
  });
}
