import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// 搜索 BETA 标黄的警告色（取自浅色主题，与 UI 实现一致）。
final Color _kWarningYellow = NarrChatColors.light.warning;

/// 内存版 DAO，避免测试依赖 sqflite。
class _MockBookDao extends BookDao {
  final List<Book> books;
  _MockBookDao([this.books = const []]);
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

/// 立即返回成功结果的 AI（不触发真实网络/搜索工具）。
class _ToggleAiService extends AiService {
  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    onRequestBody?.call('{"model":"test","messages":[]}');
    return const AiCallResult(
      content: '## 剧情演绎\n成功正文\n'
          '## 推荐行动\n\n'
          '## 当前时间\n第一天 午时\n'
          '## 世界状态\n\n'
          '## 角色状态\n\n'
          '## 记忆总结\n',
      promptTokens: 1,
      completionTokens: 1,
    );
  }
}

/// 全部选项关闭的设置（用于「无」摘要用例）。
class _AllDisabledSettings extends AiSettingsProvider {
  @override
  bool get thinking => false;
  @override
  bool get streaming => false;
  @override
  bool get lastSearch => false;
}

/// 记录对话完成回调的测试通知器。
class _RecordingNotifier implements CompletionNotifier {
  final List<({String bookTitle, String userInput})> calls = [];

  @override
  void notifyConversationCompleted({
    required String bookTitle,
    required String userInput,
  }) {
    calls.add((bookTitle: bookTitle, userInput: userInput));
  }
}

void main() {
  const book = Book(id: 1, title: '测试书');

  Future<RoundProvider> pumpChat(
    WidgetTester tester,
    AiService ai,
    _MockBookDao bookDao,
    _MockRoundDao dao, {
    AiSettingsProvider? settings,
    CompletionNotifier? completionNotifier,
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final roundProvider = RoundProvider(
      dao: dao,
      aiService: ai,
      bookDao: bookDao,
    );
    await roundProvider.loadRounds(1);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => settings ?? AiSettingsProvider()),
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
          home: Scaffold(
            body: ChatScreen(
              completionNotifier:
                  completionNotifier ?? const NoopCompletionNotifier(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return roundProvider;
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

  /// 主输入框（悬浮输入卡内，按占位文案定位，避免与侧栏字段混淆）。
  Finder composerField() => find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == '输入你的行动或对话…',
      );

  testWidgets('输入框：预设 3 行起步，最高 8 行（超出内滚）', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    final field = tester.widget<TextField>(composerField());
    expect(field.minLines, 3);
    expect(field.maxLines, 8);
  });

  testWidgets('宽屏侧栏常驻：仅显示滚动到底部按钮（侧栏按钮隐藏）', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 宽屏 + 侧栏默认展开（常驻）：只保留滚动到底部按钮，自动右对齐。
    expect(find.byIcon(Icons.vertical_align_bottom), findsOneWidget);
    expect(find.byIcon(Icons.view_sidebar_outlined), findsNothing);
  });

  testWidgets('窄屏：两个 1:1 方形按钮齐全（从右往左 = 打开侧栏在右）', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(
      tester,
      _ToggleAiService(),
      bookDao,
      dao,
      size: const Size(600, 900),
    );

    final scrollBtn = find.byIcon(Icons.vertical_align_bottom);
    final sidebarBtn = find.byIcon(Icons.view_sidebar_outlined);
    expect(scrollBtn, findsOneWidget);
    expect(sidebarBtn, findsOneWidget);

    // 从右往左：打开侧栏在右，滚动到底部在左。
    final scrollX = tester.getCenter(scrollBtn).dx;
    final sidebarX = tester.getCenter(sidebarBtn).dx;
    expect(sidebarX, greaterThan(scrollX));
  });

  testWidgets('下拉摘要：默认显示「流式 | 思考 | 搜索(BETA)」，搜索段黄色加粗', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 摘要富文本整体文本。
    final summary = find.textContaining('搜索(BETA)');
    expect(summary, findsOneWidget);
    expect(find.textContaining('流式'), findsOneWidget);
    expect(find.textContaining('思考'), findsOneWidget);

    // 搜索(BETA) 段为警告色（不加粗）。
    final text = tester.widget<Text>(summary);
    final span = text.textSpan! as TextSpan;
    final searchSpan = span.children!
        .cast<TextSpan>()
        .firstWhere((s) => s.text == '搜索(BETA)');
    expect(searchSpan.style?.color, _kWarningYellow);
    expect(searchSpan.style?.fontWeight, FontWeight.w500);
  });

  testWidgets('下拉摘要：全部选项关闭时显示「无」', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(
      tester,
      _ToggleAiService(),
      bookDao,
      dao,
      settings: _AllDisabledSettings(),
    );

    expect(find.text('无'), findsOneWidget);
    expect(find.textContaining('搜索(BETA)'), findsNothing);
  });

  testWidgets('开启联网搜索：菜单内显示黄色 BETA 警告', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 打开选项下拉。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // 搜索开启 → 黄色警告文案出现。
    const warnText = '此功能为试验版，存在大量问题，启动会数倍增加 token 消耗';
    final warn = find.text(warnText);
    expect(warn, findsOneWidget);
    expect(tester.widget<Text>(warn).style?.color, _kWarningYellow);
  });

  testWidgets('联网搜索二级提示：禁用时仍显示，点击二级文本本身可启用', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 打开菜单：默认搜索启用，二级提示显示。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    const warnText = '此功能为试验版，存在大量问题，启动会数倍增加 token 消耗';
    expect(find.text(warnText), findsOneWidget);

    // 点击「搜索」行禁用：二级提示仍在（启用/禁用始终显示）。
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(find.text(warnText), findsOneWidget);
    // 未启用时二级文字为灰色（非警告色）。
    expect(
      tester.widget<Text>(find.text(warnText)).style?.color,
      isNot(_kWarningYellow),
    );

    // 点击二级提示文本本身（位于按钮内）→ 重新启用搜索。
    await tester.tap(find.text(warnText));
    await tester.pumpAndSettle();

    // 收起菜单：摘要含 搜索(BETA)（已重新启用）。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.textContaining('搜索(BETA)'), findsOneWidget);
  });

  testWidgets('下拉菜单：切换选项后摘要实时更新', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 默认全开：摘要含「思考」。
    expect(find.textContaining('思考'), findsOneWidget);

    // 打开菜单，点击「思考」行关闭该选项。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('思考'));
    await tester.pumpAndSettle();

    // closeOnActivate:false → 菜单保持展开（警告仍在）。
    expect(
      find.text('此功能为试验版，存在大量问题，启动会数倍增加 token 消耗'),
      findsOneWidget,
    );

    // 收起菜单 → 摘要不再含「思考」。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.textContaining('思考'), findsNothing);
    expect(find.textContaining('流式'), findsOneWidget);
    expect(find.textContaining('搜索(BETA)'), findsOneWidget);
  });

  testWidgets('对话完成后调用 CompletionNotifier（预留推送接口）', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    final notifier = _RecordingNotifier();
    final roundProvider = await pumpChat(
      tester,
      _ToggleAiService(),
      bookDao,
      dao,
      completionNotifier: notifier,
    );

    await tester.enterText(composerField(), '开始新的剧情');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await waitSendDone(tester, roundProvider);

    expect(notifier.calls, hasLength(1));
    expect(notifier.calls.single.bookTitle, book.title);
    expect(notifier.calls.single.userInput, '开始新的剧情');
  });
}
