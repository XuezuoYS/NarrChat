import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narrchat/models/agent_event.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/raw_exchange.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/html_search_service.dart';
import 'package:narrchat/widgets/raw_dialog.dart';

import 'helpers/fakes.dart';

/// 禁用联网搜索的 AI 设置（强制走 Chat 直发路径，且不触碰本地配置文件）。
class _SearchDisabledSettings extends ChatCompatibleSettings {
  @override
  bool get lastSearch => false;
}

/// 强制开启联网搜索的 AI 设置（走 Chat Agent 工具循环；不触碰本地配置文件）。
class _SearchEnabledSettings extends ChatCompatibleSettings {
  @override
  bool get lastSearch => true;

  @override
  bool get supportsSearch => true;
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
  const book = Book(uuid: 'b1', title: '测试书');

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

    test('extractRawImages 提取 data URL 并估算字节数', () {
      final urls = extractRawImages(
        '{"url":"data:image/png;base64,AA=="}',
      );
      expect(urls, hasLength(1));
      expect(urls[0].index, 1);
      expect(urls[0].ext, 'png');
      expect(urls[0].data, 'data:image/png;base64,AA==');
      expect(urls[0].byteLength, 1);
    });

    test('extractRawImages：多张图片按出现顺序编号', () {
      const text = '{"a":"data:image/jpg;base64,AA==","b":"data:image/png;base64,foobar"}';
      final urls = extractRawImages(text);
      expect(urls, hasLength(2));
      expect(urls[0].index, 1);
      expect(urls[0].ext, 'jpg');
      expect(urls[1].index, 2);
      expect(urls[1].ext, 'png');
    });

    test('collapseRawImages 折叠为短占位符，无图原样返回', () {
      const raw = '{"url":"data:image/png;base64,AA=="}';
      final collapsed = collapseRawImages(raw, extractRawImages(raw));
      expect(collapsed, contains('「图像 1 · png · base64 已折叠」'));
      expect(collapsed, isNot(contains('AA==')));
      expect(collapseRawImages('无图', const []), '无图');
    });

    test('extractRawImages 处理超长 base64 不触发 StackOverflowError', () {
      // 之前用 RegExp 会因贪婪量词扫描超长 base64 而栈溢出，此处线性扫描应安全。
      final bigB64 = base64Encode(List<int>.filled(6_000_000, 7));
      final raw = '{"url":"data:image/png;base64,$bigB64"}';
      final imgs = extractRawImages(raw);
      expect(imgs, hasLength(1));
      expect(imgs.single.data.length, greaterThan(bigB64.length));
      // 折叠后文本远短于原始 base64。
      final collapsed = collapseRawImages(raw, imgs);
      expect(collapsed.length, lessThan(200));
      // base64 起始偏移 = 前缀长度（{"url":"data:image/ 为 8 字符 + 资源 11 + ext 3 + ;base64, 8 = 30）。
      expect(imgs.single.start, 8);
      expect(imgs.single.end, bigB64.length + 30);
    });

    test('extractRawImages 优先匹配最近一次 data URL（多张按序）', () {
      const raw =
          '{"a":"data:image/jpg;base64,AAAA"}'
          '{"b":"data:image/png;base64,BBBB"}';
      final imgs = extractRawImages(raw);
      expect(imgs, hasLength(2));
      expect(imgs[0].index, 1);
      expect(imgs[0].ext, 'jpg');
      expect(imgs[1].index, 2);
      expect(imgs[1].ext, 'png');
    });
  });

  group('RoundProvider RAW 捕获', () {
    test('直发路径：捕获 1 对请求/返回三块', () async {
      final dao = FakeRoundDao();
      final bookDao = FakeBookDao();
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
      await provider.loadRounds('b1');

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
      expect(ex.toolCalls, isEmpty);
      expect(ex.content, contains('正文内容'));
    });

    test('Agent 路径：多对交换且搜索块为 tool_calls JSON', () async {
      final dao = FakeRoundDao();
      final bookDao = FakeBookDao();
      final ai = _ScriptAiService([
        AiCallResult(
          content: '',
          reasoningContent: '思考1',
          toolCalls: [
            const AiToolCall(
              id: 'call_1',
              name: 'narrchat_webSearch',
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
      await provider.loadRounds('b1');

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
      expect(exchanges[0].toolCalls, contains('narrchat_webSearch'));
      expect(exchanges[0].toolCalls, contains('青云宗'));
      expect(exchanges[0].content, isEmpty);
      // 第 2 对：正文块，无搜索。
      expect(exchanges[1].content, contains('正文内容'));
      expect(exchanges[1].toolCalls, isEmpty);
    });

    test('Agent 路径：搜索 → 打开页面（fetch 事件与 RAW 捕获）', () async {
      final dao = FakeRoundDao();
      final bookDao = FakeBookDao();
      final ai = _ScriptAiService([
        AiCallResult(
          content: '',
          reasoningContent: '思考1',
          toolCalls: [
            const AiToolCall(
              id: 'call_1',
              name: 'narrchat_webSearch',
              arguments: {'query': '青云宗'},
            ),
          ],
          promptTokens: 1,
          completionTokens: 1,
        ),
        AiCallResult(
          content: '',
          reasoningContent: '思考2',
          toolCalls: [
            const AiToolCall(
              id: 'call_2',
              name: 'narrchat_webFetchPage',
              arguments: {'url': 'https://example.com/qingyun'},
            ),
          ],
          promptTokens: 1,
          completionTokens: 1,
        ),
        AiCallResult(
          content: _fullContent,
          reasoningContent: '思考3',
          toolCalls: const [],
          promptTokens: 1,
          completionTokens: 1,
        ),
      ]);
      // 共享 mock 搜索服务：搜索结果页与页面正文均由它返回。
      final search = HtmlSearchService(
        client: MockClient(
          (request) async => http.Response.bytes(
            utf8.encode(
              '<li class="b_algo"><h2><a href="https://example.com/qingyun">'
              '青云宗</a></h2><div class="b_caption"><p>青云宗是北域大派。</p>'
              '</div></li>',
            ),
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      );
      final provider = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: ai,
        searchService: search,
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');

      // 运行期间监听事件（sendRound 成功后 _agentEvents 会被清空，须实时捕获）。
      var searchDone = false;
      var fetchDone = false;
      void captureEvents() {
        for (final e in provider.agentEvents) {
          if (e.type == AgentEventType.search && e.done) searchDone = true;
          if (e.type == AgentEventType.fetch &&
              e.content == 'https://example.com/qingyun' &&
              e.done &&
              !e.failed) {
            fetchDone = true;
          }
        }
      }

      provider.addListener(captureEvents);
      final ok = await provider.sendRound(userInput: '查一下青云宗', book: book);
      provider.removeListener(captureEvents);
      expect(ok, isTrue);

      // Agent 时间线：搜索事件完成 + fetch 事件完成（含链接、未失败）。
      expect(searchDone, isTrue, reason: '应有完成的搜索事件');
      expect(fetchDone, isTrue, reason: '应有完成的打开页面事件');

      // RAW 捕获 3 对交换，第 2 对搜索块含 narrchat_webFetchPage 调用。
      final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
      final exchanges = provider.rawExchangesFor(round.id!)!;
      expect(ai.calls, 3);
      expect(exchanges, hasLength(3));
      expect(exchanges[1].toolCalls, contains('narrchat_webFetchPage'));
      expect(exchanges[1].toolCalls, contains('https://example.com/qingyun'));
    });

    test('请求失败：捕获失败条目的请求（无返回三块）', () async {
      final dao = FakeRoundDao();
      final bookDao = FakeBookDao();
      final provider = RoundProvider(
        dao: dao,
        bookDao: bookDao,
        aiService: _FailingAiService(),
        aiSettingsProvider: _SearchDisabledSettings(),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');

      expect(await provider.sendRound(userInput: '触发失败', book: book), isFalse);

      final failed = provider.failedRawExchanges;
      expect(failed, isNotNull);
      expect(failed, hasLength(1));
      expect(jsonDecode(failed!.single.requestBody), isA<Map>());
      expect(failed.single.thinking, isEmpty);
      expect(failed.single.content, isEmpty);
    });
  });

  group('RoundProvider 预览请求体', () {
    test('直发路径：预览 JSON 与实发首帧逐字一致', () async {
      final dao = FakeRoundDao();
      final bookDao = FakeBookDao();
      final ai = _ScriptAiService([
        AiCallResult(
          content: _fullContent,
          reasoningContent: '',
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
      await provider.loadRounds('b1');

      // 预览在发送前基于同一状态构建（0 个聊天轮次）；sendRound 随后以
      // 相同输入发出，RAW 捕获的首帧请求体应与预览完全一致。
      final preview = await provider.previewRequestBody(
        userInput: '你好',
        book: book,
      );
      expect(await provider.sendRound(userInput: '你好', book: book), isTrue);

      final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
      final actual = provider.rawExchangesFor(round.id!)!.single.requestBody;
      expect(actual, preview);

      // 结构校验：system 在首、user 在末且包含输入。
      final req = jsonDecode(preview) as Map<String, dynamic>;
      final messages = req['messages'] as List;
      expect((messages.first as Map)['role'], 'system');
      expect((messages.last as Map)['role'], 'user');
      expect((messages.last as Map)['content'], contains('你好'));
    });

    test('联网搜索开启：预览含工具 schema 与【联网搜索】指令', () async {
      final provider = RoundProvider(
        dao: FakeRoundDao(),
        bookDao: FakeBookDao(),
        aiService: _ScriptAiService([
          AiCallResult(content: _fullContent, promptTokens: 1, completionTokens: 1),
        ]),
        aiSettingsProvider: _SearchEnabledSettings(),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');

      final preview = await provider.previewRequestBody(
        userInput: '查一下青云宗',
        book: book,
      );
      final req = jsonDecode(preview) as Map<String, dynamic>;
      final messages = req['messages'] as List;
      // system 追加【联网搜索】指令，末条 user 包含输入。
      expect((messages.first as Map)['content'], contains('【联网搜索】'));
      expect((messages.last as Map)['content'], contains('查一下青云宗'));
      // 与 Agent 实发首帧一致：注入 narrchat_webSearch / narrchat_webFetchPage 工具。
      final tools = (req['tools'] as List).cast<Map<String, dynamic>>();
      expect(tools, hasLength(2));
      expect(
        tools.map((t) => (t['function'] as Map)['name']),
        containsAll(['narrchat_webSearch', 'narrchat_webFetchPage']),
      );
    });

    test('未选择书籍：抛出 StateError', () async {
      final provider = RoundProvider(
        dao: FakeRoundDao(),
        bookDao: FakeBookDao(),
        aiService: _ScriptAiService([
          AiCallResult(content: _fullContent, promptTokens: 1, completionTokens: 1),
        ]),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');

      await expectLater(
        provider.previewRequestBody(userInput: '你好', book: null),
        throwsStateError,
      );
    });
  });

  group('RawDialog 组件', () {
    testWidgets('展示请求 JSON 与三块（缺失显示无）', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{\n  "model": "deepseek-v4-flash"\n}',
          thinking: '思考内容',
          toolCalls: '',
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
      expect(find.text('工具调用块'), findsOneWidget);
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
          toolCalls: '',
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
          toolCalls: '',
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
          toolCalls: '',
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
          toolCalls: '',
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

    testWidgets('请求体含图片：折叠长 base64 并显示二级「图像 N 个」', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody:
              '{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]}',
          thinking: '',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RawDialog(exchanges: exchanges))),
      );
      await tester.pumpAndSettle();

      // 默认全部折叠：无可选中文本、无「图像」二级菜单。
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('图像 1 个（base64 已折叠）'), findsNothing);

      // 展开请求体：出现折叠占位文本与「图像 1 个」二级菜单。
      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('图像 1 个（base64 已折叠）'), findsOneWidget);

      // 点开头像二级菜单：出现图片详情（扩展名 / 字节数）与完整 data URL。
      await tester.tap(find.text('图像 1 个（base64 已折叠）'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNWidgets(2));
      expect(find.text('图 1 · png · 1 B'), findsOneWidget);
    });

    testWidgets('超长 base64：展开二级菜单渲染截断预览 + 复制按钮，而非完整 base64', (tester) async {
      final bigB64 = base64Encode(List<int>.filled(100000, 7));
      final exchanges = [
        RawExchange(
          requestBody:
              '{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,$bigB64"}}]}',
          thinking: '',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RawDialog(exchanges: exchanges))),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('图像 1 个（base64 已折叠）'));
      await tester.pumpAndSettle();

      expect(find.textContaining('图 1 · png ·'), findsOneWidget);
      // 截断预览：出现「共 N 字符」，而不是完整 base64。
      expect(find.textContaining('共 '), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsOneWidget);
    });

    testWidgets('预览请求体模式：标题变更且仅展示请求体块', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{"model":"deepseek-v4-pro"}',
          thinking: '不该出现的思考',
          toolCalls: '',
          content: '不该出现的正文',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RawDialog(exchanges: exchanges, previewRequestOnly: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('预览请求体'), findsOneWidget);
      expect(find.text('RAW'), findsNothing);
      expect(find.text('【请求体 1】'), findsOneWidget);
      expect(find.text('【AI返回 1】'), findsNothing);
      expect(find.text('思考块'), findsNothing);
      expect(find.text('请求已中断，无 AI 返回'), findsNothing);
      expect(find.text('请求失败，无 AI 返回'), findsNothing);
    });

    testWidgets('预览请求体含图片：base64 折叠为占位，二级菜单可展开', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody:
              '{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]}',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RawDialog(exchanges: exchanges, previewRequestOnly: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('图像 1 个（base64 已折叠）'), findsOneWidget);
      // 展示折叠占位符而非完整 base64。
      final text = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .textSpan!
          .toPlainText();
      expect(text, contains('「图像 1 · png · base64 已折叠」'));
      expect(text, isNot(contains('AA==')));

      await tester.tap(find.text('图像 1 个（base64 已折叠）'));
      await tester.pumpAndSettle();
      expect(find.text('图 1 · png · 1 B'), findsOneWidget);
    });
  });
}
