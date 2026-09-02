import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/fakes.dart';

/// RoundProvider AGENT 模式（Response API 协议）集成测试。
///
/// 覆盖：主响应正文 + 状态工具同响应 → 合并落库；校验失败 → 修复轮
/// （第 2 帧含状态校验反馈、全量重发）；预览请求体为响应式 JSON。
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

  List<String> happySse() => [
        'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n主角踏门而入。\\n\\n## 推荐行动\\n叩见掌门。"}',
        'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","name":"narrchat_editSection"}}',
        'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"section\\":\\"worldState\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 地点：青云宗\\"}]}"}',
        'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_2","name":"narrchat_editSection"}}',
        'data: {"type":"response.function_call_arguments.delta","item_id":"fc_2","delta":"{\\"section\\":\\"characterState\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"# 主角\\\\n## 林远\\\\n- 气血：100\\"}]}"}',
        'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_3","name":"narrchat_advanceTime"}}',
        'data: {"type":"response.function_call_arguments.delta","item_id":"fc_3","delta":"{\\"time\\":\\"第三天 卯时\\"}"}',
        'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_4","name":"narrchat_editSection"}}',
        'data: {"type":"response.function_call_arguments.delta","item_id":"fc_4","delta":"{\\"section\\":\\"memorySummary\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 第1轮｜日期：第三天 卯时｜主角踏门而入\\"}]}"}',
        'data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":12,"output_tokens":5}}}',
        '',
      ];

  test('AGENT 主响应：正文 + 状态工具 → 落库快照来自工作副本合并', () async {
    final dao = FakeRoundDao();
    final ai = AiService(
      client: MockClient((request) async => sse(happySse())),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final ok = await provider.sendRound(userInput: '第一章', book: book);
    expect(ok, isTrue);

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.roundIndex, 1);
    expect(round.aiNarrative, contains('主角踏门而入'));
    expect(round.recommendedAction, contains('叩见掌门'));
    expect(round.worldState, '- 地点：青云宗');
    expect(round.characterState, contains('气血：100'));
    expect(round.characterState, contains('林远'));
    expect(round.currentTime, '第三天 卯时');
    expect(round.memorySummary, contains('第1轮'));
    expect(round.tokensIn, 12);
    expect(round.tokensOut, 5);
    expect(round.modelName, 'deepseek-v4-pro');
    // RAW 完成：1 次交换，工具调用块含状态工具。
    final exchanges = provider.rawExchangesFor(round.id!)!;
    expect(exchanges, hasLength(1));
    expect(exchanges.single.toolCalls, contains('narrchat_editSection'));
    expect(provider.agentWarnings, isEmpty);
  });

  test('AGENT 校验失败 → 修复轮（第 2 帧全量重发 + 反馈），合并修正后落库', () async {
    final dao = FakeRoundDao();
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        if (idx == 1) {
          return sse([
            'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n正文初稿\\n\\n## 推荐行动\\nx"}',
            'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","name":"narrchat_editSection"}}',
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"section\\":\\"memorySummary\\",\\"edits\\":[{\\"op\\":\\"noChange\\"}]}"}',
            'data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":1,"output_tokens":1}}}',
            '',
          ]);
        }
        return sse([
          'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n修正后正文\\n\\n## 推荐行动\\ny"}',
          'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_2","name":"narrchat_editSection"}}',
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_2","delta":"{\\"section\\":\\"worldState\\",\\"edits\\":[{\\"op\\":\\"set\\",\\"before\\":\\"- 地点：青云宗\\",\\"newLine\\":\\"- 地点：主峰\\"}]}"}',
          'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_4","name":"narrchat_editSection"}}',
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_4","delta":"{\\"section\\":\\"characterState\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"# 主角\\\\n## 林远\\\\n- 气血：60\\"}]}"}',
          'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_3","name":"narrchat_advanceTime"}}',
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_3","delta":"{\\"time\\":\\"第一天 申时\\"}"}',
          'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_5","name":"narrchat_editSection"}}',
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_5","delta":"{\\"section\\":\\"memorySummary\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 第2轮｜日期：第一天 申时｜前往主峰\\"}]}"}',
          'data: {"type":"response.completed","response":{"id":"resp_2","usage":{"input_tokens":2,"output_tokens":2}}}',
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      retryDelay: Duration.zero,
    );
    // 预置上一轮（第 1 轮：世界状态基座）。
    dao.rounds.add(const Round(
      bookUuid: 'b1',
      roundIndex: 1,
      worldState: '- 地点：青云宗\n- 天气：晴',
      currentTime: '第一天 午时',
    ));
    await provider.loadRounds('b1');

    final ok = await provider.sendRound(userInput: '前往主峰', book: book);
    expect(ok, isTrue);

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 2);
    // 正文采纳制：本轮正文 = 首个含正文帧（修复帧复读的正文被丢弃）。
    expect(round.aiNarrative, contains('正文初稿'));
    expect(round.aiNarrative, isNot(contains('修正后正文')));
    expect(round.recommendedAction, contains('x'));
    expect(round.worldState, '- 地点：主峰\n- 天气：晴');
    expect(round.currentTime, '第一天 申时');
    expect(round.memorySummary, contains('第2轮'));
    expect(provider.rawExchangesFor(round.id!), hasLength(2));
    // 第 2 帧：全量重发（input 含初始消息）+ 修复轮反馈（声明禁止复读正文）。
    final body2 = capturedBodies[1];
    expect(body2.containsKey('previous_response_id'), isFalse);
    final input = (body2['input'] as List).cast<Map<String, dynamic>>();
    expect(
      input.any(
        (i) => '${i['content']}'.contains('状态维护反馈') &&
            '${i['content']}'.contains('不要'),
      ),
      isTrue,
    );
  });

  test('AGENT 预览请求体：响应式 JSON（instructions/input/tools）', () async {
    final dao = FakeRoundDao();
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: AiService(client: MockClient((_) async => sse(happySse()))),
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
    expect(body['instructions'], contains('【AGENT 模式契约】'));
    expect(body['input'], isA<List>());
    final tools = (body['tools'] as List).cast<Map<String, dynamic>>();
    expect(
      tools.map((t) => t['name']),
      containsAll([
        'narrchat_editSection',
        'narrchat_advanceTime',
      ]),
    );
    // Responses API 工具形态：name 在工具顶层（非 Chat 的 function 嵌套）。
    expect((tools.first as Map)['type'], 'function');
    expect(tools.first.containsKey('function'), isFalse);
    expect(tools.first.containsKey('name'), isTrue);
  });

  test('AGENT 关闭思考：请求体显式 reasoning.effort=none（默认开启必须显式关闭）', () async {
    final dao = FakeRoundDao();
    final settings = AiSettingsProvider();
    await settings.setPerRoundOptions(thinking: false, streaming: true);
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: AiService(client: MockClient((_) async => sse(happySse()))),
      aiSettingsProvider: settings,
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final preview = await provider.previewRequestBody(
      userInput: '第一章',
      book: book,
    );
    final body = jsonDecode(preview) as Map<String, dynamic>;
    // DeepSeek 思考模式默认开启（默认 high）；Responses 格式以
    // reasoning.effort 控制，`none` = 关闭——省略即思考开启（曾经的缺陷）。
    expect((body['reasoning'] as Map)['effort'], 'none');
    expect(body['temperature'], isNotNull);
    expect(body.containsKey('reasoning_effort'), isFalse);
  });

  test('AGENT 搜索开场白：无标题帧不采纳为正文，标题帧正文正常落库', () async {
    final dao = FakeRoundDao();
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        if (idx == 1) {
          // 帧 1：说明性开场白（无 ## 剧情演绎 标题）+ 状态工具调用。
          return sse([
            'data: {"type":"response.output_text.delta","delta":"I\'ll search for information about the two characters before writing the story."}',
            'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","name":"narrchat_editSection"}}',
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"section\\":\\"worldState\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 地点：灯会\\"}]}"}',
            'data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":1,"output_tokens":1}}}',
            '',
          ]);
        }
        // 帧 2：标题帧（真正的正文）+ 剩余状态工具。
        return sse([
          'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n洛天依与乐正绫在灯会深处的小巷里……\\n\\n## 推荐行动\\n继续观察"}',
          'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_2","name":"narrchat_advanceTime"}}',
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_2","delta":"{\\"time\\":\\"第一日 深夜\\"}"}',
          'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_3","name":"narrchat_editSection"}}',
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_3","delta":"{\\"section\\":\\"memorySummary\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 第1轮｜日期：第一日 深夜｜观察到两人走入小巷\\"}]}"}',
          'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_4","name":"narrchat_editSection"}}',
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_4","delta":"{\\"section\\":\\"characterState\\",\\"edits\\":[{\\"op\\":\\"noChange\\"}]}"}',
          'data: {"type":"response.completed","response":{"id":"resp_2","usage":{"input_tokens":2,"output_tokens":2}}}',
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final ok = await provider.sendRound(userInput: '搜索两人资料', book: book);
    expect(ok, isTrue);

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    // 正文 = 标题帧内容；开场白不被采纳（旧缺陷：开场白成为正文并阻塞真正正文）。
    expect(round.aiNarrative, contains('洛天依与乐正绫'));
    expect(round.aiNarrative, isNot(contains('I\'ll search')));
    // 开场白帧的工具状态照常应用。
    expect(round.worldState, '- 地点：灯会');
    expect(round.currentTime, '第一日 深夜');
    expect(round.memorySummary, contains('第1轮'));
    // RAW 保留两帧（开场白帧可追溯）。
    expect(provider.rawExchangesFor(round.id!), hasLength(2));
  });

  test('AGENT 仅输出正文（未用工具）→ 补充轮未生效后按文本状态兜底落库', () async {
    final dao = FakeRoundDao();
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        // 首帧：仅正文 + 状态文本（不调用任何工具）；后续补充帧：仅正文。
        final narrative =
            'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n刀刃出鞘，寒光掠过。\\n\\n## 推荐行动\\n继续赶路"}';
        final lines = <String>[
          narrative,
          if (idx == 1) ...[
            'data: {"type":"response.output_text.delta","delta":"\\n\\n## 当前时间\\n第三天 卯时\\n\\n## 世界状态\\n- 地点：荒原"}',
          ],
          'data: {"type":"response.completed","response":{"id":"r$idx","usage":{"input_tokens":1,"output_tokens":1}}}',
          '',
        ];
        return sse(lines);
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final ok = await provider.sendRound(userInput: '连夜赶路', book: book);
    expect(ok, isTrue);

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('刀刃出鞘'));
    // 文本状态兜底：模型只在正文里写了时间与状态，未调用工具 → 采用解析文本。
    expect(round.currentTime, '第三天 卯时');
    expect(round.worldState, '- 地点：荒原');
    // 两次补充轮后仍无用工具 → 时间/记忆缺失进入钳制警告。
    expect(provider.agentWarnings, isNotEmpty);
    expect(provider.agentWarnings.join(), contains('advanceTime'));
    // 共 3 帧（主帧 + 2 次补充轮）。
    expect(capturedBodies, hasLength(3));
  });
}
