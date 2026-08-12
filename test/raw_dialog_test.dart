import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/failed_attempt.dart';
import 'package:narrchat/models/raw_exchange.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/widgets/raw_dialog.dart';

/// 内存版 BookDao，避免测试依赖 sqflite。
class _MockBookDao extends BookDao {
  FailedAttempt failed = const FailedAttempt();

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
  Future<int> updateRoundFields(
    int roundId,
    Map<String, Object?> fields,
  ) async => 1;

  @override
  Future<void> deleteRound(
    int roundId, {
    bool deleteFollowing = false,
  }) async {}
}

/// 禁用联网搜索的 AI 设置（强制走直发路径，且不触碰本地配置文件）。
class _SearchDisabledSettings extends AiSettingsProvider {
  @override
  bool get lastSearch => false;
}

/// 按调用次数依次返回脚本结果的 AI。
class _ScriptAiService extends AiService {
  final List<AiCallResult> script;
  int calls = 0;

  _ScriptAiService(this.script);

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
    calls++;
    onChunk?.call(const AiStreamChunk(done: true));
    return script[(calls - 1).clamp(0, script.length - 1)];
  }
}

/// 恒失败的 AI（api 类异常，不触发自动重试）。
class _FailingAiService extends AiService {
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
    throw const AiException('模拟失败');
  }
}

/// 假搜索工具：不发起真实网络请求。
class _FakeWebSearchTool extends WebSearchTool {
  _FakeWebSearchTool() : super();

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async {
    return const AgentToolResult(
      success: true,
      content: '搜索「青云宗」的结果：\n1. 青云 QingCloud（https://www.qingcloud.com/）',
    );
  }
}

/// 合法 6 区块正文。
const _fullContent = '## 剧情演绎\n正文内容\n'
    '## 推荐行动\n\n'
    '## 当前时间\n第一天 午时\n'
    '## 世界状态\n\n'
    '## 角色状态\n\n'
    '## 记忆总结\n';

void main() {
  const book = Book(id: 1, title: '测试书');

  group('RawDialog 纯函数', () {
    test('expandEscapes 展开转义序列为真实换行 / 制表符', () {
      expect(expandEscapes(r'a\nb\r\nc\td'), 'a\nb\nc\td');
      expect(expandEscapes('无转义'), '无转义');
      // 已含真实换行不受影响。
      expect(expandEscapes('a\nb'), 'a\nb');
    });

    test('countMatches 大小写不敏感计数', () {
      expect(countMatches('青云宗 与 青云宗', '青云'), 2);
      expect(countMatches('AbC AbC', 'abc'), 2);
      expect(countMatches('abc', ''), 0);
      expect(countMatches('', 'x'), 0);
    });

    test('highlightSpans 命中处高亮分割', () {
      const base = TextStyle(fontSize: 12);
      const hl = TextStyle(backgroundColor: Color(0xFFFFFFFF));
      final spans = highlightSpans('a青云b青云', '青云', base, hl);
      expect(spans, hasLength(4));
      expect(spans[0].text, 'a');
      expect(spans[1].text, '青云');
      expect(spans[1].style?.backgroundColor, const Color(0xFFFFFFFF));
      expect(spans[2].text, 'b');
      expect(spans[3].text, '青云');
      // 空查询返回整段。
      final whole = highlightSpans('abc', '', base, hl);
      expect(whole, hasLength(1));
      expect(whole.single.text, 'abc');
    });

    test('highlightSpans 当前定位命中使用 currentStyle', () {
      const base = TextStyle(fontSize: 12);
      const hl = TextStyle(backgroundColor: Color(0xFFFFF176));
      const cur = TextStyle(backgroundColor: Color(0xFFFFB74D));
      final spans = highlightSpans(
        '青云 青云',
        '青云',
        base,
        hl,
        currentIndex: 1,
        currentStyle: cur,
      );
      expect(spans, hasLength(3));
      expect(spans[0].style?.backgroundColor, const Color(0xFFFFF176));
      expect(spans[1].style?.backgroundColor, isNull); // 中间空格普通
      expect(spans[2].style?.backgroundColor, const Color(0xFFFFB74D));
    });
  });

  group('RoundProvider RAW 捕获', () {
    test('直发路径：捕获 1 对请求/返回三块', () async {
      final dao = _MockRoundDao();
      final bookDao = _MockBookDao();
      final ai = _ScriptAiService([
        AiCallResult(
          content: _fullContent,
          reasoningContent: '思考内容A',
          toolCalls: const [],
          promptTokens: 1,
          completionTokens: 1,
        ),
      ]);
      final provider = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        aiSettingsProvider: _SearchDisabledSettings(),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds(1);

      expect(await provider.sendRound(userInput: '你好', book: book), isTrue);

      final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
      final exchanges = provider.rawExchangesFor(round.id!);
      expect(exchanges, isNotNull);
      expect(exchanges, hasLength(1));
      final ex = exchanges!.single;
      // 请求 JSON 可解析且含 messages。
      final req = jsonDecode(ex.requestBody) as Map<String, dynamic>;
      expect(req.containsKey('model'), isTrue);
      expect(req['messages'] as List, isNotEmpty);
      // 三块：思考 / 搜索（无 tool_calls 为空）/ 正文。
      expect(ex.thinking, '思考内容A');
      expect(ex.search, isEmpty);
      expect(ex.content, contains('正文内容'));
    });

    test('Agent 路径：多对交换且搜索块为 tool_calls JSON', () async {
      final dao = _MockRoundDao();
      final bookDao = _MockBookDao();
      final ai = _ScriptAiService([
        AiCallResult(
          content: '',
          reasoningContent: '思考1',
          toolCalls: [
            const AiToolCall(
              id: 'call_1',
              name: 'web_search',
              arguments: {'query': '青云宗'},
            ),
          ],
          promptTokens: 1,
          completionTokens: 1,
        ),
        AiCallResult(
          content: _fullContent,
          reasoningContent: '思考2',
          toolCalls: const [],
          promptTokens: 1,
          completionTokens: 1,
        ),
      ]);
      final provider = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        webSearchTool: _FakeWebSearchTool(),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds(1);

      expect(
        await provider.sendRound(userInput: '查一下青云宗', book: book),
        isTrue,
      );

      final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
      final exchanges = provider.rawExchangesFor(round.id!)!;
      expect(ai.calls, 2);
      expect(exchanges, hasLength(2));
      // 第 1 对：思考 + 搜索块（tool_calls JSON），无正文。
      expect(exchanges[0].thinking, '思考1');
      expect(exchanges[0].search, contains('web_search'));
      expect(exchanges[0].search, contains('青云宗'));
      expect(exchanges[0].content, isEmpty);
      // 第 2 对：正文块，无搜索。
      expect(exchanges[1].content, contains('正文内容'));
      expect(exchanges[1].search, isEmpty);
    });

    test('请求失败：捕获失败条目的请求（无返回三块）', () async {
      final dao = _MockRoundDao();
      final bookDao = _MockBookDao();
      final provider = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: _FailingAiService(),
        aiSettingsProvider: _SearchDisabledSettings(),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds(1);

      expect(await provider.sendRound(userInput: '触发失败', book: book), isFalse);

      final failed = provider.failedRawExchanges;
      expect(failed, isNotNull);
      expect(failed, hasLength(1));
      expect(jsonDecode(failed!.single.requestBody), isA<Map>());
      expect(failed.single.thinking, isEmpty);
      expect(failed.single.content, isEmpty);
    });
  });

  group('RawDialog 组件', () {
    testWidgets('展示请求 JSON 与三块（缺失显示无）', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{\n  "model": "deepseek-v4-flash"\n}',
          thinking: '思考内容',
          search: '',
          content: '正文内容',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RawDialog(exchanges: exchanges))),
      );
      await tester.pumpAndSettle();

      expect(find.text('RAW'), findsOneWidget);
      expect(find.text('【请求体 1】'), findsOneWidget);
      expect(find.text('【AI返回 1】'), findsOneWidget);
      expect(find.text('思考块'), findsOneWidget);
      expect(find.text('搜索块'), findsOneWidget);
      expect(find.text('正文块'), findsOneWidget);
      // 搜索块为空 → 显示（无）。
      expect(find.text('（无）'), findsOneWidget);
    });

    testWidgets('失败对话框：展示错误与「无 AI 返回」提示', (tester) async {
      final exchanges = [RawExchange(requestBody: '{}')];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RawDialog(exchanges: exchanges, failedError: '网络失败'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('请求失败：网络失败'), findsOneWidget);
      expect(find.text('请求失败，无 AI 返回'), findsOneWidget);
    });

    testWidgets('关键词检索：输入后按块显示计数', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{"a": "青云宗 青云宗"}',
          thinking: '青云宗',
          search: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RawDialog(exchanges: exchanges))),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('raw_search_field')),
        '青云宗',
      );
      await tester.pump();

      // 请求体 2 处、思考块 1 处。
      expect(find.text('· 2 处'), findsOneWidget);
      expect(find.text('· 1 处'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('关键词检索：上一处/下一处循环定位与计数', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{"a": "青云宗 青云宗"}',
          thinking: '青云宗',
          search: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RawDialog(exchanges: exchanges))),
      );
      await tester.pumpAndSettle();

      // 查询为空：无导航控件。
      expect(find.byKey(const Key('raw_match_next')), findsNothing);

      // 输入关键词：命中 3 处，自动展开含匹配块，当前 1/3。
      await tester.enterText(
        find.byKey(const Key('raw_search_field')),
        '青云宗',
      );
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);
      expect(find.byType(SelectableText), findsNWidgets(2));

      // 下一处：2/3 → 3/3 → 循环回 1/3。
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);

      // 上一处：回 3/3。
      await tester.tap(find.byKey(const Key('raw_match_prev')));
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);

      // 清空搜索：导航消失、恢复全部折叠。
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('raw_match_next')), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('各块默认折叠，点击标题展开', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{"model":"x"}',
          thinking: '思考内容',
          search: '',
          content: '正文内容',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RawDialog(exchanges: exchanges))),
      );
      await tester.pumpAndSettle();

      // 默认折叠：无可选中文本内容。
      expect(find.byType(SelectableText), findsNothing);

      // 点击请求体标题展开 → 出现 1 个可选中文本。
      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);

      // 点击思考块标题展开 → 2 个。
      await tester.tap(find.text('思考块'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNWidgets(2));
    });

    testWidgets('转译换行符：开启后 \n 字面量展开为真实换行', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: r'{"a": "x\ny"}',
          thinking: '行一\n行二',
          search: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RawDialog(exchanges: exchanges))),
      );
      await tester.pumpAndSettle();
      // 展开请求体块以读取内容。
      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();

      String plainOf(int index) =>
          tester
              .widget<SelectableText>(find.byType(SelectableText).at(index))
              .textSpan
              ?.toPlainText() ??
          '';

      // 转译前：请求 JSON 中 \n 为字面量（反斜杠 + n），无真实换行。
      final before = plainOf(0);
      expect(before, contains(r'\n'));
      expect(before.contains('\n'), isFalse);

      // 开启转译换行符：\n 展开为真实换行。
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      final after = plainOf(0);
      expect(after.contains(r'\n'), isFalse);
      expect(after, contains('\n'));
    });
  });
}
