import 'dart:async';

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

/// 可控流式 AI：测试驱动 [emit]/[complete]，模拟逐 chunk 输出与生成结束。
class _FakeStreamingAiService extends AiService {
  final Completer<void> _done = Completer<void>();
  void Function(AiStreamChunk chunk)? _onChunk;

  void emit(String delta) => _onChunk?.call(AiStreamChunk(contentDelta: delta));
  void complete() => _done.complete();

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
    _onChunk = onChunk;
    onRequestBody?.call('{"model":"test","messages":[]}');
    await _done.future;
    _onChunk?.call(const AiStreamChunk(done: true));
    return const AiCallResult(
      content: '## 剧情演绎\n流式生成的最终正文\n'
          '## 推荐行动\n\n'
          '## 当前时间\n第一天 午时\n'
          '## 世界状态\n\n'
          '## 角色状态\n\n'
          '## 记忆总结\n',
      promptTokens: 10,
      completionTokens: 20,
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

  /// 「滚动到底部」按钮上的「有新内容」红点（圆形红色 Container）。
  Finder redDot() => find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle &&
            (w.decoration as BoxDecoration).color == Colors.red,
      );

  /// 预置多轮长正文，使对话列表可滚动（红点用例需要离开底部的滚动空间）。
  Future<void> seedRounds(_MockRoundDao dao, {int count = 4}) async {
    for (var i = 1; i <= count; i++) {
      await dao.insertRound(
        Round(
          bookId: 1,
          roundIndex: i,
          userInput: '第 $i 轮的用户输入',
          aiNarrative: '第 $i 轮的剧情正文。' * 40,
          currentTime: '第一天 午时',
          createdAt: DateTime.now(),
        ),
      );
    }
  }

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

  testWidgets('下拉摘要：默认「流式 | 思考」（搜索默认关闭），开启后搜索段警告色', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 默认：思考/流式开启、联网搜索关闭。
    expect(find.textContaining('流式'), findsOneWidget);
    expect(find.textContaining('思考'), findsOneWidget);
    expect(find.textContaining('搜索(BETA)'), findsNothing);

    // 打开菜单，点击「搜索」行启用。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    // 收起菜单 → 摘要含 搜索(BETA)。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // 搜索(BETA) 段为警告色（不加粗）。
    final summary = find.textContaining('搜索(BETA)');
    expect(summary, findsOneWidget);
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

  testWidgets('下拉菜单：打开与关闭带 Material 动画（淡入淡出）', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 任一祖先 FadeTransition 透明度 < 1 → 动画进行中（淡入/淡出）。
    bool anyFading() {
      for (final e in find
          .ancestor(
            of: find.text('流式'),
            matching: find.byType(FadeTransition),
          )
          .evaluate()) {
        if ((e.widget as FadeTransition).opacity.value < 1.0) return true;
      }
      return false;
    }

    // 打开：停在动画中途（100ms < 打开时长 500ms），菜单项应处于淡入中。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(anyFading(), isTrue, reason: '菜单打开应带动画（淡入中）');

    // 动画完成后菜单项完全可见。
    await tester.pumpAndSettle();
    expect(find.text('流式'), findsOneWidget);

    // 关闭：停在动画中途（100ms < 关闭时长 150ms），菜单项应处于淡出中。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(anyFading(), isTrue, reason: '菜单关闭应带动画（淡出中）');

    // 关闭动画完成后菜单项消失。
    await tester.pumpAndSettle();
    expect(find.text('流式'), findsNothing);
  });

  testWidgets('联网搜索：未启用时二级提示灰色，启用后变警告色', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 打开选项下拉：搜索默认关闭 → 二级提示为灰色。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    const warnText = '此功能为试验版，存在大量问题，启动会数倍增加 token 消耗';
    final warn = find.text(warnText);
    expect(warn, findsOneWidget);
    expect(
      tester.widget<Text>(warn).style?.color,
      isNot(_kWarningYellow),
      reason: '搜索未启用时二级提示为灰色',
    );

    // 点击「搜索」行启用 → 二级提示变为警告色。
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text(warnText)).style?.color,
      _kWarningYellow,
    );
  });

  testWidgets('联网搜索二级提示：未启用为灰且可点二级文本启用', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 打开菜单：搜索默认关闭，二级提示显示且为灰色。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    const warnText = '此功能为试验版，存在大量问题，启动会数倍增加 token 消耗';
    expect(find.text(warnText), findsOneWidget);
    expect(
      tester.widget<Text>(find.text(warnText)).style?.color,
      isNot(_kWarningYellow),
    );

    // 点击二级提示文本本身（位于按钮内）→ 启用搜索 → 变警告色。
    await tester.tap(find.text(warnText));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text(warnText)).style?.color,
      _kWarningYellow,
    );

    // 收起菜单：摘要含 搜索(BETA)（已启用）。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.textContaining('搜索(BETA)'), findsOneWidget);
  });

  testWidgets('下拉菜单：切换选项后摘要实时更新', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 默认：思考/流式开启、联网搜索关闭。
    expect(find.textContaining('思考'), findsOneWidget);
    expect(find.textContaining('搜索(BETA)'), findsNothing);

    // 打开菜单，点击「思考」行关闭该选项。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('思考'));
    await tester.pumpAndSettle();

    // closeOnActivate:false → 菜单保持展开（二级提示仍在）。
    expect(
      find.text('此功能为试验版，存在大量问题，启动会数倍增加 token 消耗'),
      findsOneWidget,
    );

    // 收起菜单 → 摘要不再含「思考」。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.textContaining('思考'), findsNothing);
    expect(find.textContaining('流式'), findsOneWidget);
    expect(find.textContaining('搜索(BETA)'), findsNothing);
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

  testWidgets('生成结束红点：生成中不显示，结束离开底部显示，回到底部消失', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await seedRounds(dao);
    final ai = _FakeStreamingAiService();
    final roundProvider = await pumpChat(tester, ai, bookDao, dao);

    // 触发生成（UI 发送，流式进行中）。
    await tester.enterText(composerField(), '继续剧情');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    ai.emit('第一段内容');
    await tester.pump();
    expect(redDot(), findsNothing, reason: '生成过程中不应显示红点');

    // 生成中上翻离开底部：仍不显示红点。
    await tester.drag(find.byType(ListView), const Offset(0, 150));
    await tester.pump();
    expect(redDot(), findsNothing, reason: '生成过程中上翻也不应显示红点');

    // 生成结束（此时用户未在底部）→ 显示红点。
    ai.complete();
    for (var i = 0; i < 20 && roundProvider.isSending; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(redDot(), findsOneWidget, reason: '生成结束且未在底部时应显示红点');

    // 滚动回底部 → 红点消失。
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(redDot(), findsNothing, reason: '滚动回底部后红点应消失');
  });

  testWidgets('红点不因调整窗口宽度/修改左下角选项误触发', (tester) async {
    final bookDao = _MockBookDao([book]);
    final dao = _MockRoundDao();
    await seedRounds(dao, count: 2);
    await pumpChat(tester, _ToggleAiService(), bookDao, dao);

    // 位于底部：无红点。
    expect(redDot(), findsNothing);

    // 修改左下角选项（打开下拉 → 切换流式 → 收起）。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('流式'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(redDot(), findsNothing, reason: '修改左下角选项不应触发红点');

    // 调整窗口宽度（1200 仍为宽屏）→ 恢复。
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpAndSettle();
    expect(redDot(), findsNothing, reason: '调整窗口宽度不应触发红点');
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(redDot(), findsNothing);
  });
}
