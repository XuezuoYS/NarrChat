import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/services/agent/agent_runner.dart';
import 'package:narrchat/services/agent/fetch_page_tool.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/html_search_service.dart';

/// 记录调用参数的假工具。
class _FakeTool implements NarrAgentTool {
  final List<Map<String, dynamic>> calls = [];
  final AgentToolResult result;
  final String toolName;

  _FakeTool({required this.result, this.toolName = 'web_search'});

  @override
  String get name => toolName;

  @override
  String get description => '测试工具';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
    },
    'required': ['query'],
  };

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async {
    calls.add(arguments);
    return result;
  }
}

AiToolCall _toolCall(Map<String, dynamic> args) =>
    AiToolCall(id: 'call_1', name: 'web_search', arguments: args);

/// 构造带 UTF-8 头部的 HTML 响应（供 mock 搜索 / 抓取）。
http.Response htmlResponse(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

void main() {
  group('AgentRunner', () {
    test('工具循环：调用工具、追加消息、聚合结果', () async {
      final tool = _FakeTool(
        result: const AgentToolResult(success: true, content: '搜索结果：青云宗是北域大派'),
      );
      final seenBodies = <Map<String, dynamic>>[];
      final responses = [
        AiCallResult(
          content: '',
          toolCalls: [_toolCall({'query': '青云宗'})],
          promptTokens: 1,
          completionTokens: 1,
        ),
        const AiCallResult(
          content: '## 剧情演绎\n最终正文\n',
          promptTokens: 2,
          completionTokens: 2,
        ),
      ];
      var callIndex = 0;

      final runner = AgentRunner(
        buildBody: (messages, tools) {
          seenBodies.add({'messages': messages, 'tools': tools});
          return {'model': 'test', 'messages': messages, 'tools': tools};
        },
        call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
          return responses[callIndex++];
        },
        tools: [tool],
      );

      final result = await runner.run(
        initialMessages: [
          {'role': 'system', 'content': 'sys'},
          {'role': 'user', 'content': '用户输入'},
        ],
        stream: false,
      );

      expect(callIndex, 2);
      // 两次调用都携带 tools 描述。
      expect((seenBodies[0]['tools'] as List), hasLength(1));
      expect((seenBodies[1]['tools'] as List), hasLength(1));
      // 第二次调用的消息包含 assistant(tool_calls) + tool 消息。
      final messages = (seenBodies[1]['messages'] as List).cast<Map>();
      expect(messages, hasLength(4)); // system + user + assistant + tool
      expect(messages[2]['role'], 'assistant');
      expect((messages[2]['tool_calls'] as List).first['id'], 'call_1');
      expect(messages[3]['role'], 'tool');
      expect(messages[3]['tool_call_id'], 'call_1');
      expect((messages[3]['content'] as String), contains('青云宗是北域大派'));

      // 工具确实被调用。
      expect(tool.calls, hasLength(1));
      expect(tool.calls.first['query'], '青云宗');

      // 结果聚合。
      expect(result.content, contains('最终正文'));
      expect(result.promptTokens, 3);
      expect(result.completionTokens, 3);
    });

    test('搜索失败：错误作为 tool 结果回传，AI 继续执行', () async {
      final tool = _FakeTool(
        result: const AgentToolResult(success: false, content: '联网搜索失败：网络异常'),
      );
      var callIndex = 0;
      final runner = AgentRunner(
        buildBody: (messages, tools) => {'messages': messages, 'tools': tools},
        call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
          if (callIndex == 0) {
            callIndex++;
            return AiCallResult(
              content: '',
              toolCalls: [_toolCall({'query': 'x'})],
              promptTokens: 0,
              completionTokens: 0,
            );
          }
          return const AiCallResult(
            content: '正文',
            promptTokens: 0,
            completionTokens: 0,
          );
        },
        tools: [tool],
      );

      final result = await runner.run(
        initialMessages: [const {'role': 'user', 'content': 'hi'}],
        stream: false,
      );

      expect(tool.calls, hasLength(1));
      expect(result.content, '正文');
    });

    test('工具连续失败 3 次后不再执行，并告知模型停用', () async {
      final tool = _FakeTool(
        result: const AgentToolResult(success: false, content: '联网搜索失败：网络异常'),
      );
      final seenBodies = <Map<String, dynamic>>[];
      var callIndex = 0;
      final runner = AgentRunner(
        buildBody: (messages, tools) {
          seenBodies.add({'messages': messages, 'tools': tools});
          return {'messages': messages, 'tools': tools};
        },
        call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
          if (callIndex < 4) {
            callIndex++;
            return AiCallResult(
              content: '',
              toolCalls: [_toolCall({'query': 'x'})],
              promptTokens: 0,
              completionTokens: 0,
            );
          }
          callIndex++;
          return const AiCallResult(
            content: '正文',
            promptTokens: 0,
            completionTokens: 0,
          );
        },
        tools: [tool],
        maxIterations: 10,
      );

      final result = await runner.run(
        initialMessages: [const {'role': 'user', 'content': 'hi'}],
        stream: false,
      );

      // 只执行了 3 次，第 4 次起被停用（不再调用工具）。
      expect(tool.calls, hasLength(3));
      expect(callIndex, 5);
      expect(result.content, '正文');

      // 最后一次调用（第 5 次）的 tool 消息包含停用提示。
      final messages = (seenBodies.last['messages'] as List).cast<Map>();
      final toolMsgs =
          messages.where((m) => m['role'] == 'tool').cast<Map>().toList();
      expect(
        toolMsgs.last['content'] as String,
        contains('请勿再使用该工具'),
      );
      // 第 4 次调用（第 5 次 body 之前）时工具已停用，不执行。
      expect(toolMsgs, hasLength(4)); // 3 次失败 + 1 次停用提示
    });

    test('拒绝访问（refused）不计入连续失败次数', () async {
      final tool = _FakeTool(
        result: const AgentToolResult(
          success: false,
          content: '页面拒绝访问（HTTP 403）',
          refused: true,
        ),
      );
      var callIndex = 0;
      final runner = AgentRunner(
        buildBody: (messages, tools) => {'messages': messages, 'tools': tools},
        call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
          if (callIndex < 5) {
            callIndex++;
            return AiCallResult(
              content: '',
              toolCalls: [_toolCall({'query': 'x'})],
              promptTokens: 0,
              completionTokens: 0,
            );
          }
          callIndex++;
          return const AiCallResult(
            content: '正文',
            promptTokens: 0,
            completionTokens: 0,
          );
        },
        tools: [tool],
        maxIterations: 10,
      );

      final result = await runner.run(
        initialMessages: [const {'role': 'user', 'content': 'hi'}],
        stream: false,
      );

      // 连续 5 次 refused 仍继续执行工具（不触发 3 次停用）。
      expect(tool.calls, hasLength(5));
      expect(result.content, '正文');
    });

    test('超出最大迭代次数抛 AiException', () async {
      final runner = AgentRunner(
        buildBody: (messages, tools) => {'messages': messages},
        call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
          return AiCallResult(
            content: '',
            toolCalls: [_toolCall({'query': 'x'})],
            promptTokens: 0,
            completionTokens: 0,
          );
        },
        tools: [_FakeTool(result: const AgentToolResult(success: true, content: 'ok'))],
        maxIterations: 2,
      );

      expect(
        runner.run(
          initialMessages: [const {'role': 'user', 'content': 'hi'}],
          stream: false,
        ),
        throwsA(isA<AiException>()),
      );
    });

    test('执行工具前取消抛 AiCancelledException', () async {
      var cancelled = false;
      var callIndex = 0;
      final runner = AgentRunner(
        buildBody: (messages, tools) => {'messages': messages},
        call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
          if (callIndex == 0) {
            callIndex++;
            cancelled = true; // 模拟：返回工具调用后用户点击停止
            return AiCallResult(
              content: '',
              toolCalls: [_toolCall({'query': 'x'})],
              promptTokens: 0,
              completionTokens: 0,
            );
          }
          return const AiCallResult(
            content: '正文',
            promptTokens: 0,
            completionTokens: 0,
          );
        },
        tools: [_FakeTool(result: const AgentToolResult(success: true, content: 'ok'))],
      );

      expect(
        runner.run(
          initialMessages: [const {'role': 'user', 'content': 'hi'}],
          stream: false,
          isCancelled: () => cancelled,
        ),
        throwsA(isA<AiCancelledException>()),
      );
    });
  });

  group('WebSearchTool', () {
    test('格式化搜索结果并回调 onResults', () async {
      final search = HtmlSearchService(
        client: MockClient((request) async => htmlResponse(_bingHtml)),
      );
      List<SearchResult>? seen;
      final tool = WebSearchTool(search: search, onResults: (r) => seen = r);

      final result = await tool.run({'query': '青云宗'});

      expect(result.success, isTrue);
      expect(result.content, contains('搜索「青云宗」的结果'));
      expect(result.content, contains('青云 QingCloud'));
      expect(result.content, contains('链接：https://www.qingcloud.com/'));
      // 结果末尾附加强制打开页面的指令。
      expect(result.content, contains('【接下来必须执行】'));
      expect(result.content, contains('fetch_page'));
      expect(seen, isNotNull);
      expect(seen!.length, 2);
    });

    test('搜索失败返回错误信息（success=false）', () async {
      final search = HtmlSearchService(
        client: MockClient((request) async {
          throw http.ClientException('网络失败');
        }),
      );
      final tool = WebSearchTool(search: search);

      final result = await tool.run({'query': 'x'});

      expect(result.success, isFalse);
      expect(result.content, contains('联网搜索失败'));
    });

    test('搜索失败触发 onFail 回调（异常）', () async {
      final search = HtmlSearchService(
        client: MockClient((request) async {
          throw http.ClientException('网络失败');
        }),
      );
      var onFailCalled = false;
      List<SearchResult>? seen;
      final tool = WebSearchTool(
        search: search,
        onResults: (r) => seen = r,
        onFail: () => onFailCalled = true,
      );

      final result = await tool.run({'query': 'x'});

      expect(result.success, isFalse);
      expect(onFailCalled, isTrue);
      expect(seen, isNull);
    });

    test('无结果触发 onFail 回调且不回调 onResults', () async {
      final search = HtmlSearchService(
        client: MockClient((request) async => htmlResponse('<html><body></body></html>')),
      );
      var onFailCalled = false;
      List<SearchResult>? seen;
      final tool = WebSearchTool(
        search: search,
        onResults: (r) => seen = r,
        onFail: () => onFailCalled = true,
      );

      final result = await tool.run({'query': 'x'});

      expect(result.success, isFalse);
      expect(onFailCalled, isTrue);
      expect(seen, isNull);
    });

    test('空关键词返回错误', () async {
      final tool = WebSearchTool(
        search: HtmlSearchService(
          client: MockClient((request) async => htmlResponse('')),
        ),
      );

      final result = await tool.run(const {});

      expect(result.success, isFalse);
      expect(result.content, contains('搜索关键词为空'));
    });

    test('fetch_page 工具触发 fetching 活动（subject=url）', () async {
      final tool = _FakeTool(
        toolName: 'fetch_page',
        result: const AgentToolResult(success: true, content: '页面正文'),
      );
      final activities = <AgentActivity>[];
      var callIndex = 0;
      final runner = AgentRunner(
        buildBody: (messages, tools) => {'messages': messages, 'tools': tools},
        call: (requestBody, stream, onChunk, onRequestBody, isCancelled) async {
          if (callIndex == 0) {
            callIndex++;
            return AiCallResult(
              content: '',
              toolCalls: [
                AiToolCall(
                  id: 'call_1',
                  name: 'fetch_page',
                  arguments: {'url': 'https://example.com/qingyun'},
                ),
              ],
              promptTokens: 0,
              completionTokens: 0,
            );
          }
          callIndex++;
          return const AiCallResult(
            content: '正文',
            promptTokens: 0,
            completionTokens: 0,
          );
        },
        tools: [tool],
      );

      await runner.run(
        initialMessages: [const {'role': 'user', 'content': 'hi'}],
        stream: false,
        onActivity: activities.add,
      );

      final fetch = activities.firstWhere(
        (a) => a.type == AgentActivityType.fetching,
      );
      expect(fetch.query, 'https://example.com/qingyun');
      // 工具确实被执行（url 参数）。
      expect(tool.calls.single['url'], 'https://example.com/qingyun');
    });
  });

  group('FetchPageTool', () {
    test('打开页面成功：返回正文并回调 onDone', () async {
      final search = HtmlSearchService(
        client: MockClient(
          (request) async => htmlResponse(
            '<html><body><h1>青云宗</h1><p>青云宗是北域大派。</p></body></html>',
          ),
        ),
      );
      var done = false;
      final tool = FetchPageTool(search: search, onDone: () => done = true);

      final result = await tool.run({'url': 'https://example.com'});

      expect(result.success, isTrue);
      expect(result.content, contains('青云宗是北域大派'));
      expect(done, isTrue);
    });

    test('打开页面失败：返回错误并回调 onFail', () async {
      final search = HtmlSearchService(
        client: MockClient((request) async {
          throw http.ClientException('网络失败');
        }),
      );
      var fail = false;
      final tool = FetchPageTool(search: search, onFail: () => fail = true);

      final result = await tool.run({'url': 'https://example.com'});

      expect(result.success, isFalse);
      expect(result.content, contains('打开页面失败'));
      expect(fail, isTrue);
    });

    test('HTTP 4xx：返回 refused 结果并触发 onRefused', () async {
      var refused = false;
      final tool = FetchPageTool(
        search: HtmlSearchService(
          client: MockClient(
            (request) async => http.Response('forbidden', 403),
          ),
        ),
        onRefused: () => refused = true,
      );

      final result = await tool.run({'url': 'https://example.com/403'});

      expect(result.success, isFalse);
      expect(result.refused, isTrue);
      expect(result.content, contains('403'));
      // 拒绝访问时提示换用其它结果页面。
      expect(result.content, contains('请改用 fetch_page'));
      expect(refused, isTrue);
    });

    test('空链接返回错误并回调 onFail', () async {
      var fail = false;
      final tool = FetchPageTool(onFail: () => fail = true);

      final result = await tool.run(const {});

      expect(result.success, isFalse);
      expect(result.content, contains('链接为空'));
      expect(fail, isTrue);
    });
  });
}

const _bingHtml = '''
<html><body>
<li class="b_algo" data-id iid=SERP.1><h2 class=""><a target="_blank" href="https://www.qingcloud.com/">青云 QingCloud</a></h2><div class="b_caption"><p class="b_lineclamp2">青云科技全栈自研。</p></div></li>
<li class="b_algo" data-id iid=SERP.2><h2 class=""><a target="_blank" href="https://example.com/b">第二条结果</a></h2><div class="b_caption"><p class="b_lineclamp2">摘要二。</p></div></li>
</body></html>
''';
