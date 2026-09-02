import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/fakes.dart';

/// Agent 模式（实验性开关）**关闭** + Response API 协议（默认平台）：
/// 协议只决定线路格式——单轮走 /responses 纯文本（instructions + input），
/// 无任何工具 / 状态机制；开启联网搜索时工具循环同样走 responses 线路。
void main() {
  const book = Book(
    uuid: 'b1',
    title: '测试书',
    category: '玄幻',
    baseSetting: '北域修仙世界。',
    historyRounds: 2,
    roleCategories: [RoleCategory(name: '主角', format: '- 气血：')],
  );

  http.Response sse(List<String> lines) => http.Response.bytes(
        utf8.encode(lines.join('\n')),
        200,
        headers: {'content-type': 'text/event-stream; charset=utf-8'},
      );

  /// 6 区块（Chat 格式）正文的 responses 流式事件。
  List<String> chatBlocksSse() => [
        'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n主角踏门而入。\\n\\n## 推荐行动\\n叩见掌门。\\n\\n## 当前时间\\n第三天 卯时\\n\\n## 世界状态\\n- 地点：青云宗\\n\\n## 角色状态\\n## 主角\\n- 气血：100\\n\\n## 记忆总结\\n- 第1轮｜日期：第三天 卯时｜入宗"}',
        'data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":12,"output_tokens":5}}}',
        '',
      ];

  test('Agent 关 + Response 协议（默认平台）：单轮 /responses，无工具与状态机制', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        expect(request.url.path, '/responses');
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return sse(chatBlocksSse());
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      // 不注入实验性设置 → Agent 开关关闭（默认）。
      aiSettingsProvider: AiSettingsProvider(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final ok = await provider.sendRound(userInput: '第一章', book: book);
    expect(ok, isTrue);

    // 单次 /responses 请求：仅协议形态的纯文本轮。
    expect(bodies, hasLength(1));
    final body = bodies.single;
    expect(body['model'], 'deepseek-v4-pro');
    // Chat 模式提示词（6 区块要求），而非 AGENT 契约。
    expect(body['instructions'], contains('【绝对服从】'));
    expect(body['instructions'], isNot(contains('AGENT 模式契约')));
    expect(body['input'], isA<List>());
    final input = (body['input'] as List).cast<Map<String, dynamic>>();
    expect(input.any((i) => i['role'] == 'user'), isTrue);
    // 无工具 / 无 tool_choice / 无指令字段残留（协议无 Agent 状态机制）。
    expect(body.containsKey('tools'), isFalse);
    expect(body.containsKey('tool_choice'), isFalse);
    expect(body.containsKey('previous_response_id'), isFalse);

    // 6 区块正常解析落库（与 Chat 语义一致）。
    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('主角踏门而入'));
    expect(round.recommendedAction, contains('叩见掌门'));
    expect(round.currentTime, '第三天 卯时');
    expect(round.worldState, contains('青云宗'));
    expect(round.characterState, contains('气血：100'));
    expect(round.memorySummary, contains('第1轮'));
    // RAW 捕获走 responses 通道。
    expect(provider.rawExchangesFor(round.id!), hasLength(1));
  });

  test('Agent 关 + Response 协议：预览请求体为响应式 JSON（无工具）', () async {
    final provider = RoundProvider(
      dao: FakeRoundDao(),
      bookDao: FakeBookDao(),
      aiService: AiService(client: MockClient((_) async => sse(chatBlocksSse()))),
      aiSettingsProvider: AiSettingsProvider(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final preview = await provider.previewRequestBody(
      userInput: '第一章',
      book: book,
    );
    final body = jsonDecode(preview) as Map<String, dynamic>;
    expect(body['model'], 'deepseek-v4-pro');
    expect(body['instructions'], contains('【绝对服从】'));
    expect(body['input'], isA<List>());
    expect(body.containsKey('tools'), isFalse);
    expect(body.containsKey('max_tokens'), isFalse); // 未设置 Max Tokens → 省略键
  });

  test('Agent 关 + Response 协议 + 联网搜索：工具循环走 /responses（顶层 schema）', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        expect(request.url.path, '/responses');
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = bodies.length;
        return sse(
          idx == 1
              ? [
                  'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"narrchat_webSearch"}}',
                  'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{"query":"青云宗"}"}',
                  'data: {"type":"response.completed","response":{"id":"r1","usage":{"input_tokens":1,"output_tokens":1}}}',
                  '',
                ]
              : chatBlocksSse(),
        );
      }),
    );
    // 注入假搜索工具：不发起真实网络请求。
    final searchTool = _StubSearchTool();
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      // 强制开启联网搜索（覆写 getter，不触碰本地配置文件）。
      aiSettingsProvider: _SearchEnabledResponsesSettings(),
      webSearchTool: searchTool,
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(
      await provider.sendRound(userInput: '查一下青云宗', book: book),
      isTrue,
    );
    expect(searchTool.calls, 1);
    expect(bodies, hasLength(2));

    // 第 1 帧：instructions 已从 system 消息 extraction（含联网搜索指令），
    // 工具为 Responses 顶层形态（name 在顶层，无嵌套 function）。
    final body1 = bodies.first;
    expect(body1['instructions'], contains('【联网搜索】'));
    final tools = (body1['tools'] as List).cast<Map<String, dynamic>>();
    expect(
      tools.map((t) => t['name']),
      contains('narrchat_webSearch'),
    );
    expect(tools.first.containsKey('function'), isFalse, reason: 'Responses 顶层形态');
    // 第 2 帧 input 累积 function_call + function_call_output items。
    final input2 = (bodies[1]['input'] as List).cast<Map<String, dynamic>>();
    expect(
      input2.any(
        (i) => i['type'] == 'function_call' && i['name'] == 'narrchat_webSearch',
      ),
      isTrue,
    );
    expect(
      input2.any((i) => i['type'] == 'function_call_output'),
      isTrue,
    );
    // 无 Agent 状态机制：不发送 tool_choice（搜索循环不需要）。
    expect(body1.containsKey('tool_choice'), isFalse);

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('主角踏门而入'));
  });
}

/// 强制开启联网搜索的 Response 协议设置（覆写 getter，不触碰本地配置文件）。
class _SearchEnabledResponsesSettings extends AiSettingsProvider {
  @override
  bool get lastSearch => true;

  @override
  bool get supportsSearch => true;
}

/// 假搜索工具：记录调用次数，返回固定结果（不发网络请求）。
class _StubSearchTool extends WebSearchTool {
  int calls = 0;

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async {
    calls++;
    return const AgentToolResult(
      success: true,
      content:
          '搜索「青云宗」的结果：\n1. 青云 QingCloud（https://www.qingcloud.com/）',
    );
  }
}
