import 'dart:convert';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narrchat/models/agent_event.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/raw_exchange.dart';
import 'package:narrchat/models/round_send_intent.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/html_search_service.dart';
import 'package:narrchat/services/request_frame_outline.dart';
import 'package:narrchat/widgets/raw_dialog.dart';

import 'helpers/fakes.dart';
import 'helpers/raw_dialog_harness.dart';
import 'helpers/selection_harness.dart';

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
const _fullContent =
    '## 剧情演绎\n正文内容\n'
    '## 推荐行动\n\n'
    '## 当前时间\n第一天 午时\n'
    '## 世界状态\n\n'
    '## 角色状态\n\n'
    '## 记忆总结\n';

/// RAW 检索是**手动触发**的（大 RAW 下边打字边扫会让输入框明显卡），
/// 用例统一走这个入口：输入关键词 → 点「搜索」→ 等扫描与滚动动画结束。
Future<void> _searchRaw(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const Key('raw_search_field')), query);
  await tester.tap(find.byKey(const Key('raw_search_button')));
  await tester.pumpAndSettle();
}

/// 展开着的 RAW 内容块。
///
/// 每块一个 `SelectionArea`（内部按 2 万字符分段渲染多个 `RichText`）；
/// 块内的 `SelectableText` 已全部并入统一选中容器，数「展开了几块」只能靠它。
/// 读取函数统一在 `test/helpers/raw_dialog_harness.dart`。
final Finder _rawDialog = find.byType(RawDialog);
final Finder _rawBlocks = rawBlocks(_rawDialog);

/// 第 [index] 个展开块里各段的 render paragraph（顺序与分段一致）。
List<RenderParagraph> _rawParagraphs(WidgetTester tester, int index) =>
    rawParagraphs(_rawDialog, tester, block: index);

/// 第 [index] 个展开块渲染出的全部文字（分段渲染，拼回整块）。
String _rawBlockText(WidgetTester tester, int index) =>
    rawBlockText(_rawDialog, tester, block: index);

/// 当前展开着的所有块的文字（按上屏顺序）。
List<String> _rawBlockTexts(WidgetTester tester) =>
    rawBlockTexts(_rawDialog, tester);

/// 第 [index] 个展开块里全部 span（各段的子 span 平铺）。
List<InlineSpan> _rawBlockSpans(WidgetTester tester, int index) =>
    rawBlockSpans(_rawDialog, tester, block: index);

/// 各段起点（与块内全文偏移同轴），用来挑跨段样本。
List<int> _rawSegmentStarts(WidgetTester tester, int index) =>
    rawSegmentStarts(_rawDialog, tester, block: index);

/// 块内第 [flat] 个字符所在处的全局坐标（跨分段定位拖动用）。
Offset _rawOffsetAt(WidgetTester tester, int blockIndex, int flat) =>
    rawOffsetAt(_rawDialog, tester, flat, block: blockIndex);

/// 超过分段预算（2 万字符）的请求体：首 / 中 / 尾各一处 [word]。
String _bigRawBody({int lines = 800, String word = '青云宗'}) {
  final pad = 'x' * 60;
  final buf = StringBuffer()..writeln('{"头": "$word",');
  for (var i = 0; i < lines; i++) {
    if (i == lines ~/ 2) buf.writeln('  "中": "$word",');
    buf.writeln('  "行$i": "$pad",');
  }
  buf.writeln('  "尾": "$word",');
  buf.write('  "末": "无"}');
  return buf.toString();
}

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

    test('splitAtNewlines 只在换行后切，拼回逐字相同', () {
      const text = '行一\n行二\n行三\n';
      // 预算 3 字符：切点全落在 `\n` 之后。
      final pieces = splitAtNewlines(text, 3);
      expect(pieces.join(), text, reason: '拼回必须与原文逐字相同');
      expect(pieces.length, greaterThan(1));
      for (final piece in pieces.take(pieces.length - 1)) {
        expect(piece.endsWith('\n'), isTrue, reason: '非末段必须以换行收尾');
        expect(piece.length, lessThanOrEqualTo(4)); // 预算 3 + 那个换行
      }
      // 无换行 / 空文本：整块一段，绝不出空段。
      expect(splitAtNewlines('abcdef', 3), ['abcdef']);
      expect(splitAtNewlines('', 3), isEmpty);
      expect(splitAtNewlines('a\nbbbbb\nc', 2), ['a\n', 'bbbbb\n', 'c']);
    });

    test('splitAtNewlines 超长单行不切（无换行可下刀）', () {
      final text = '${'x' * 50000}\ny';
      final pieces = splitAtNewlines(text, 20000);
      expect(pieces, hasLength(2), reason: '首段只能一路吃到下一个换行');
      expect(pieces.first, '${'x' * 50000}\n');
      expect(pieces.last, 'y');
      expect(pieces.join(), text);
    });

    test('extractRawImages 提取 data URL 并估算字节数', () {
      final urls = extractRawImages('{"url":"data:image/png;base64,AA=="}');
      expect(urls, hasLength(1));
      expect(urls[0].index, 1);
      expect(urls[0].ext, 'png');
      expect(urls[0].data, 'data:image/png;base64,AA==');
      expect(urls[0].byteLength, 1);
    });

    test('extractRawImages：多张图片按出现顺序编号', () {
      const text =
          '{"a":"data:image/jpg;base64,AA==","b":"data:image/png;base64,foobar"}';
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
        roundStackService: FakeRoundStackService(roundDao: dao),
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
        roundStackService: FakeRoundStackService(roundDao: dao),
        bookDao: bookDao,
        aiService: ai,
        webSearchTool: _FakeWebSearchTool(),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');

      expect(await provider.sendRound(userInput: '查一下青云宗', book: book), isTrue);

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
        roundStackService: FakeRoundStackService(roundDao: dao),
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
        roundStackService: FakeRoundStackService(roundDao: dao),
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
        roundStackService: FakeRoundStackService(roundDao: dao),
        bookDao: bookDao,
        aiService: ai,
        aiSettingsProvider: _SearchDisabledSettings(),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');

      // 预览在发送前基于同一状态构建（0 个聊天轮次）；sendRound 随后以
      // 相同输入发出，RAW 捕获的首帧请求体应与预览完全一致。
      final preview = await provider.previewRequestBody(
        intent: RoundSendIntent.newRound(userInput: '你好'),
        book: book,
      );
      expect(await provider.sendRound(userInput: '你好', book: book), isTrue);

      final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
      final actual = provider.rawExchangesFor(round.id!)!.single.requestBody;
      expect(actual, preview.firstFrameJson);

      // 结构校验：system 在首、user 在末且包含输入。
      final req = preview.firstFrame;
      final messages = req['messages'] as List;
      expect((messages.first as Map)['role'], 'system');
      expect((messages.last as Map)['role'], 'user');
      expect((messages.last as Map)['content'], contains('你好'));
    });

    test('联网搜索开启：预览含工具 schema，system 不再追加联网指令', () async {
      final roundDao = FakeRoundDao();
      final provider = RoundProvider(
        dao: roundDao,
        roundStackService: FakeRoundStackService(roundDao: roundDao),
        bookDao: FakeBookDao(),
        aiService: _ScriptAiService([
          AiCallResult(
            content: _fullContent,
            promptTokens: 1,
            completionTokens: 1,
          ),
        ]),
        aiSettingsProvider: _SearchEnabledSettings(),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');

      final preview = await provider.previewRequestBody(
        intent: RoundSendIntent.newRound(userInput: '查一下青云宗'),
        book: book,
      );
      final req = preview.firstFrame;
      // 联网工具循环：首帧之后还有「工具循环续接帧」（仅增量）。
      expect(preview.subsequentFrames.map((f) => f.label), ['工具循环续接帧']);
      final messages = req['messages'] as List;
      // system 只有用户提示词（联网指令不再注入），末条 user 包含输入。
      expect((messages.first as Map)['content'], isNot(contains('【联网搜索】')));
      expect((messages.last as Map)['content'], contains('查一下青云宗'));
      // 与 Agent 实发首帧一致：注入 narrchat_webSearch / narrchat_webFetchPage 工具。
      final tools = (req['tools'] as List).cast<Map<String, dynamic>>();
      expect(tools, hasLength(2));
      expect(
        tools.map((t) => (t['function'] as Map)['name']),
        containsAll(['narrchat_webSearch', 'narrchat_webFetchPage']),
      );
      // 调用指导随工具 description 下发：搜索后必须打开页面读正文。
      expect(
        '${tools.firstWhere((t) => (t['function'] as Map)['name'] == 'narrchat_webSearch')['function']['description']}',
        contains('narrchat_webFetchPage'),
      );
    });

    test('未选择书籍：抛出 StateError', () async {
      final roundDao = FakeRoundDao();
      final provider = RoundProvider(
        dao: roundDao,
        roundStackService: FakeRoundStackService(roundDao: roundDao),
        bookDao: FakeBookDao(),
        aiService: _ScriptAiService([
          AiCallResult(
            content: _fullContent,
            promptTokens: 1,
            completionTokens: 1,
          ),
        ]),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');

      await expectLater(
        provider.previewRequestBody(
          intent: RoundSendIntent.newRound(userInput: '你好'),
          book: null,
        ),
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
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
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
      expect(_rawBlockTexts(tester), contains('请求失败，无 AI 返回'));
    });

    testWidgets('无返回的交换：优先展示该次请求的失败原因（协议降级探测帧）', (tester) async {
      // 成功轮里也可能出现「无返回」的交换：协议兼容降级前的探测帧被服务商
      // 拒绝（随后同一帧重发），原因写在 exchange.error 里而不是含糊的「无返回」。
      final exchanges = [
        RawExchange(
          requestBody: '{"reasoning":{"effort":"low"}}',
          error: 'API 请求失败（HTTP 400）：reasoning_effort 参数不受支持',
        ),
        RawExchange(
          requestBody: '{"reasoning":{"effort":"high"}}',
          content: '第二轮（回落用户设置后重发成功）',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _rawBlockTexts(tester),
        contains('请求失败：API 请求失败（HTTP 400）：reasoning_effort 参数不受支持'),
      );
      // 有正常返回的那一条照常展示三块，不受影响。
      expect(find.text('正文块'), findsOneWidget);
    });

    testWidgets('无返回且无原因：显示中性「无 AI 返回内容」', (tester) async {
      final exchanges = [RawExchange(requestBody: '{}')];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      expect(_rawBlockTexts(tester), ['（无 AI 返回内容）']);
      expect(find.text('请求已中断，无 AI 返回'), findsNothing);
    });

    testWidgets('失败信息可选中复制，并参与关键词检索定位', (tester) async {
      const reason =
          'API 请求失败（HTTP 400）：{"error":{"message":"The reasoning_text in '
          'the thinking mode must be passed back to the API"}}';
      final exchanges = [RawExchange(requestBody: '{}', error: reason)];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      // 以**可选中文本**渲染（SelectionArea + 分段 RichText）：可鼠标选中后 Ctrl+C 复制。
      expect(_rawBlockTexts(tester), ['请求失败：$reason']);

      // 参与检索定位（块序号与渲染一一对应）：只出现在失败原因里的关键词可命中。
      await _searchRaw(tester, 'reasoning_text');
      expect(find.text('1/1'), findsOneWidget);
    });

    testWidgets('关键词检索：输入不触发，点「搜索」后才扫描并按块计数', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{"a": "青云宗 青云宗"}',
          thinking: '青云宗',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      // 只输入不检索（大 RAW 下打字不卡的根本前提）：无计数、无定位控件。
      await tester.enterText(find.byKey(const Key('raw_search_field')), '青云宗');
      await tester.pump();
      expect(find.text('· 2 处'), findsNothing);
      expect(find.byKey(const Key('raw_match_next')), findsNothing);

      // 点「搜索」→ 先画「搜索中」，再扫一次。
      await tester.tap(find.byKey(const Key('raw_search_button')));
      await tester.pump();
      expect(find.text('搜索中…'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('搜索中…'), findsNothing);

      // 请求体 2 处、思考块 1 处。
      expect(find.text('· 2 处'), findsOneWidget);
      expect(find.text('· 1 处'), findsOneWidget);
    });

    testWidgets('关键词检索：回车等同于点「搜索」', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{"a": "青云宗"}',
          thinking: '',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('raw_search_field')), '青云宗');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('1/1'), findsOneWidget);
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
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      // 查询为空：无导航控件。
      expect(find.byKey(const Key('raw_match_next')), findsNothing);

      // 搜索关键词：命中 3 处，只展开第一处所在块（请求体），当前 1/3。
      await _searchRaw(tester, '青云宗');
      expect(find.text('1/3'), findsOneWidget);
      expect(_rawBlocks, findsOneWidget);
      expect(find.text('· 1 处'), findsOneWidget); // 折叠的思考块照常报数

      // 下一处：仍在请求体内（2/3），开着的还是同一块。
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      expect(_rawBlocks, findsOneWidget);

      // 第三处在思考块：思考块展开、请求体收回 —— 任何时刻只有一块是被检索打开的。
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);
      expect(_rawBlocks, findsOneWidget);
      expect(_rawBlockText(tester, 0), '青云宗'); // 开着的是内容恰为该词的思考块

      // 循环回 1/3：请求体重新展开，思考块收回。
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);
      expect(_rawBlockText(tester, 0), '{"a": "青云宗 青云宗"}');

      // 上一处：回 3/3。
      await tester.tap(find.byKey(const Key('raw_match_prev')));
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);

      // 清空搜索：导航消失、恢复全部折叠。
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('raw_match_next')), findsNothing);
      expect(_rawBlocks, findsNothing);
    });

    testWidgets('检索定位与手点展开互不干扰', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{"a": "青云宗"}',
          thinking: '青云宗',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();
      await _searchRaw(tester, '青云宗');
      expect(_rawBlocks, findsOneWidget);

      // 手点展开思考块 → 两块都开着；定位不影响手点的那块。
      await tester.tap(find.text('思考块'));
      await tester.pumpAndSettle();
      expect(_rawBlocks, findsNWidgets(2));

      // 点标题折叠「当前定位块」→ 连检索那份展开一起收掉。
      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();
      expect(_rawBlocks, findsOneWidget);

      // 下一处（2/2）落在手点的思考块上：请求体不会因此被重新带开。
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget);
      expect(_rawBlocks, findsOneWidget);

      // 循环回 1/2：请求体作为当前定位块被检索重新展开，手点的思考块仍在。
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);
      expect(_rawBlocks, findsNWidgets(2));
    });

    testWidgets('命中高亮只换底色，不加粗', (tester) async {
      // 加粗要另走一套字形：普通段与高亮段交替的大段落排版暴涨十几倍；只给
      // 「当前定位」加粗也不行——它随定位挪动，每点一次上一处/下一处都要
      // 整块重排。故高亮一律只改底色（实测依据见 .agents/2026-10-12-raw-perf.md）。
      // 给点返回内容，免得走「无返回」那条常驻文本（本例只关心请求体块）。
      final exchanges = [
        RawExchange(
          requestBody: '{"a": "青云宗 青云宗 青云宗"}',
          thinking: '暂无思考',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();
      await _searchRaw(tester, '青云宗');

      final styles = _rawBlockSpans(
        tester,
        0,
      ).where((s) => s.toPlainText() == '青云宗').map((s) => s.style!).toList();
      expect(styles, hasLength(3));
      expect(styles.every((s) => s.backgroundColor != null), isTrue);
      expect(
        styles.every((s) => s.fontWeight == null),
        isTrue,
        reason: '命中高亮不得换字重',
      );
      // 当前定位（第一处）改用橙色底，靠颜色而非字重区分。
      final current = const Color(0xFFFFB74D).withValues(alpha: 0.6);
      expect(styles.first.backgroundColor, current);
      expect(styles.skip(1).every((s) => s.backgroundColor != current), isTrue);
    });

    testWidgets('定位下一处：滚动位置真的跟着移动（取块内已排好的版面）', (tester) async {
      // 一个几百行的请求体：两处命中分列首尾，用来验证定位不是「只改文字不着地」。
      final buf = StringBuffer(r'{"首": "青云宗", ');
      for (var i = 0; i < 300; i++) {
        buf.write('"行$i": "$i", ');
      }
      buf.write(r'"尾": "青云宗"}');
      final exchanges = [RawExchange(requestBody: buf.toString())];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      ScrollController scroller() => tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;

      // 第一处在开头：几乎不用滚。
      await _searchRaw(tester, '青云宗');
      expect(scroller().offset, lessThan(200));

      // 下一处（同块内的末尾）：滚到接近底部（末尾超出最大滚动量时被夹住）。
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(scroller().offset, greaterThan(500));
      expect(
        scroller().offset,
        greaterThan(scroller().position.maxScrollExtent - 200),
      );
    });

    testWidgets('交换回填后重新检索：命中请求返回才有的内容', (tester) async {
      // 派生块按「对象身份 + 返回侧字段值副本」缓存：思考 / 正文是请求返回后
      // 才回填的，只比对象身份会让回填的内容永远搜不到（块数也会错位）。
      final ex = RawExchange(requestBody: '{"a": "x"}');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: [ex])),
        ),
      );
      await tester.pumpAndSettle();
      await _searchRaw(tester, '青云宗');
      expect(find.text('0/0'), findsOneWidget);

      ex.content = '青云宗';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: [ex])),
        ),
      );
      await tester.pumpAndSettle();
      await _searchRaw(tester, '青云宗');
      expect(find.text('1/1'), findsOneWidget);
    });

    testWidgets('检索后切换「转译换行符」：命中随展示文本一起重算', (tester) async {
      final exchanges = [RawExchange(requestBody: r'{"a": "x\ny"}')];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      // 默认开启转译：`\n` 已成真实换行，字面量反斜杠不再存在。
      await _searchRaw(tester, r'\n');
      expect(find.text('0/0'), findsOneWidget);

      // 关闭转译 → 展示文本变回字面量，已激活的检索跟着重算。
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('1/1'), findsOneWidget);
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
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      // 默认折叠：无内容块上屏。
      expect(_rawBlocks, findsNothing);

      // 点击请求体标题展开 → 1 块。
      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();
      expect(_rawBlocks, findsOneWidget);
      expect(_rawBlockText(tester, 0), '{"model":"x"}');

      // 点击思考块标题展开 → 2 块。
      await tester.tap(find.text('思考块'));
      await tester.pumpAndSettle();
      expect(_rawBlocks, findsNWidgets(2));
      expect(_rawBlockText(tester, 1), '思考内容');
    });

    testWidgets('转译换行符：默认开启，\n 字面量展开为真实换行；关闭后恢复字面量', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: r'{"a": "x\ny"}',
          thinking: '行一\n行二',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();
      // 展开请求体块以读取内容。
      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();

      // 默认开启转译：\n 展开为真实换行（无字面量反斜杠 + n）。
      final opened = _rawBlockText(tester, 0);
      expect(opened.contains(r'\n'), isFalse);
      expect(opened, contains('\n'));
      expect(opened, '{"a": "x\ny"}'); // 分段拼回必须与整块逐字相同

      // 关闭转译换行符：恢复 \n 字面量，无真实换行。
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      final closed = _rawBlockText(tester, 0);
      expect(closed, contains(r'\n'));
      expect(closed.contains('\n'), isFalse);
    });

    testWidgets('请求体含图片：折叠长 base64 并显示二级「图像 N 个」', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]}',
          thinking: '',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      // 默认全部折叠：请求体内容不渲染（唯一上屏的是常驻「无返回」说明块）。
      expect(_rawBlocks, findsOneWidget);
      expect(_rawBlockText(tester, 0), '（无 AI 返回内容）');
      expect(find.text('图 1 · png · 1 B'), findsNothing);
      expect(find.text('图像 1 个（base64 已折叠）'), findsNothing);

      // 展开请求体：出现折叠占位文本与「图像 1 个」二级菜单。
      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();
      expect(_rawBlocks, findsNWidgets(2));
      expect(_rawBlockText(tester, 0), contains('「图像 1 · png · base64 已折叠」'));
      expect(find.text('图像 1 个（base64 已折叠）'), findsOneWidget);

      // 点开头像二级菜单：出现图片详情（扩展名 / 字节数）与完整 data URL。
      await tester.tap(find.text('图像 1 个（base64 已折叠）'));
      await tester.pumpAndSettle();
      expect(
        find.byType(SelectableText),
        findsNothing,
        reason: '详情文本统一走选中容器（SelectableTextArea），不再用 SelectableText',
      );
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
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
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
      expect(find.text('（无 AI 返回内容）'), findsNothing);
      expect(find.text('请求失败，无 AI 返回'), findsNothing);
    });

    testWidgets('预览请求体含图片：base64 折叠为占位，二级菜单可展开', (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: '{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]}',
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
      expect(_rawBlocks, findsOneWidget);
      expect(find.text('图像 1 个（base64 已折叠）'), findsOneWidget);
      // 展示折叠占位符而非完整 base64。
      final text = _rawBlockText(tester, 0);
      expect(text, contains('「图像 1 · png · base64 已折叠」'));
      expect(text, isNot(contains('AA==')));

      await tester.tap(find.text('图像 1 个（base64 已折叠）'));
      await tester.pumpAndSettle();
      expect(find.text('图 1 · png · 1 B'), findsOneWidget);
    });

    testWidgets('预览请求体含后续可用帧：默认折叠，展开后只显示增量字段', (tester) async {
      const frames = [
        PlannedFrame(
          label: '记忆帧',
          note: '调研结束、本轮记忆尚未落地时发出',
          addedFields: {
            'input': {
              '…': '前 2 项同上一帧',
              '+': [
                {'role': 'user', 'content': '阶段指令原文'},
              ],
            },
          },
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RawDialog(
              exchanges: [RawExchange(requestBody: '{"model":"m","input":[]}')],
              previewRequestOnly: true,
              subsequentFrames: frames,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('【后续可用帧 1】'), findsOneWidget);
      expect(find.text('【记忆帧】'), findsOneWidget);
      expect(find.text('调研结束、本轮记忆尚未落地时发出'), findsOneWidget);
      // 默认折叠：增量内容不上屏（只有请求体与后续帧两个块标题）。
      expect(_rawBlocks, findsNothing);

      await tester.tap(find.text('【记忆帧】'));
      await tester.pumpAndSettle();
      final diff = _rawBlockText(tester, 0);
      expect(diff, contains('阶段指令原文'));
      expect(diff, contains('前 2 项同上一帧'));
    });

    testWidgets('超预算的块分段渲染：跨段命中依旧处处可达', (tester) async {
      final text = _bigRawBody();
      expect(text.length, greaterThan(40000), reason: '夹具必须跨到第三段');
      final exchanges = [
        RawExchange(
          requestBody: text,
          thinking: '无',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();

      ScrollController scroller() => tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;

      await _searchRaw(tester, '青云宗');
      expect(find.text('1/3'), findsOneWidget);
      final paras = _rawParagraphs(tester, 0);
      expect(paras.length, greaterThan(2), reason: '夹具必须真的被切成多段');
      // 分段不丢文字：各段拼回与整块逐字相同。
      expect(_rawBlockText(tester, 0), text);

      // 第二处命中在中间段：定位必须跟着滚过去。
      final firstOffset = scroller().offset;
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      expect(scroller().offset, greaterThan(firstOffset + 500));

      // 第三处在最后一段：仍能滚到。
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);
      expect(scroller().offset, greaterThan(firstOffset + 1000));

      // 「当前定位」的橙底必须落在命中真正所在的那一段（段内序号按各段命中数折算）。
      final currentBg = const Color(0xFFFFB74D).withValues(alpha: 0.6);
      final highlighted = <int>[
        for (var i = 0; i < paras.length; i++)
          if ((paras[i].text as TextSpan).children!.any(
            (s) => s.style?.backgroundColor == currentBg,
          ))
            i,
      ];
      expect(highlighted, [paras.length - 1], reason: '末位命中在末段，橙底也只能在末段');
    });

    testWidgets('跨段选中：复制文字与整块逐字相同', (tester) async {
      final text = _bigRawBody(lines: 400);
      final exchanges = [
        RawExchange(
          requestBody: text,
          thinking: '无',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();

      final copied = mockClipboard(tester);
      final starts = _rawSegmentStarts(tester, 0);
      expect(starts.length, greaterThan(1), reason: '夹具必须真的被切成多段');
      expect(text, _rawBlockText(tester, 0), reason: '拼回必须与上屏文字逐字相同');

      // 起点在第一段内、终点在第二段内：拖动必须跨过段间接缝。
      final end = starts[1] + 20;
      final expected = text.substring(5, end);
      expect(expected.contains('\n'), isTrue, reason: '样本必须真的跨过换行');

      final gesture = await tester.startGesture(
        _rawOffsetAt(tester, 0, 5),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(_rawOffsetAt(tester, 0, end));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      copySelection(
        tester,
        find
            .descendant(of: _rawBlocks.first, matching: find.byType(RichText))
            .first,
      );
      await tester.pump();

      expect(copied, hasLength(1), reason: '跨段拖动应产生一份可复制的选中内容');
      expect(copied.single, expected, reason: '切段后的复制必须与整块逐字相同（含接缝处的换行）');
    });

    testWidgets('块内选中文字后自动弹出「复制 / 全选」工具条（与其他可选中区域共用一个容器）',
        (tester) async {
      final exchanges = [
        RawExchange(
          requestBody: _bigRawBody(lines: 5),
          thinking: '无',
          toolCalls: '',
          content: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RawDialog(exchanges: exchanges)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('【请求体 1】'));
      await tester.pumpAndSettle();

      final copied = mockClipboard(tester);
      final onScreen = _rawBlockText(tester, 0);

      // 鼠标拖拽选中开头 8 个字符：松手即弹工具条，不必再右键 / Ctrl+C。
      final gesture = await tester.startGesture(
        _rawOffsetAt(tester, 0, 0),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(_rawOffsetAt(tester, 0, 8));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('复制'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);

      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();

      expect(copied, hasLength(1));
      expect(copied.single, onScreen.substring(0, 8));
    });
  });
}
