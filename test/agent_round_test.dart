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
        'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n主角踏门而入。\\n\\n## 推荐行动\\n叩见掌门。\\n\\n## 当前时间\\n第三天 卯时"}',
        'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","name":"narrchat_editSection"}}',
        'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"section\\":\\"worldState\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 地点：青云宗\\"}]}"}',
        'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_2","name":"narrchat_editSection"}}',
        'data: {"type":"response.function_call_arguments.delta","item_id":"fc_2","delta":"{\\"section\\":\\"characterState\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"# 主角\\\\n## 林远\\\\n- 气血：100\\"}]}"}',
        'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_3","name":"narrchat_editSection"}}',
        'data: {"type":"response.function_call_arguments.delta","item_id":"fc_3","delta":"{\\"section\\":\\"memorySummary\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 第1轮｜日期：第三天 卯时｜主角踏门而入\\"}]}"}',
        'data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":12,"output_tokens":5}}}',
        '',
      ];

  test('AGENT 主响应：正文 + 状态工具 → 落库快照来自工作副本合并', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return sse(happySse());
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final ok = await provider.sendRound(userInput: '第一章', book: book);
    expect(ok, isTrue);

    // 请求体形态：单次请求闭环（正文轮把状态补齐 → 不发起状态轮）。
    expect(bodies, hasLength(1));
    final body = bodies.single;
    expect(body['tool_choice'], 'auto');
    expect(body['instructions'], contains('【AGENT 模式契约】'));
    // 工具集 = 读取器 + 编辑器（时间属于正文，无时间工具）。
    expect(
      (body['tools'] as List).cast<Map<String, dynamic>>().map((t) => t['name']),
      containsAll(['narrchat_readState', 'narrchat_editSection']),
    );
    expect(
      (body['tools'] as List).cast<Map<String, dynamic>>().map((t) => t['name']),
      isNot(contains('narrchat_advanceTime')),
    );
    // 快照**不预置**：input 里没有应用伪造的 function_call 序列。
    final input = (body['input'] as List).cast<Map<String, dynamic>>();
    expect(input.where((i) => i['type'] == 'function_call'), isEmpty);

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
            'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n正文初稿\\n\\n## 推荐行动\\nx\\n\\n## 当前时间\\n第一天 申时"}',
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
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
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
    // 正文采纳制：本轮正文 = 正文轮的标题帧；状态轮复读的正文被结构性丢弃。
    expect(round.aiNarrative, contains('正文初稿'));
    expect(round.aiNarrative, isNot(contains('修正后正文')));
    expect(round.recommendedAction, contains('x'));
    expect(round.worldState, '- 地点：主峰\n- 天气：晴');
    expect(round.currentTime, '第一天 申时');
    expect(round.memorySummary, contains('第2轮'));
    expect(provider.rawExchangesFor(round.id!), hasLength(2));
    // 第 2 帧 = 状态轮：全量重发（无 previous_response_id），
    // 且 instructions / tools 前缀与第 1 帧**逐字节一致**（缓存命中前提）。
    final body1 = capturedBodies[0];
    final body2 = capturedBodies[1];
    expect(body2.containsKey('previous_response_id'), isFalse);
    expect(body2['instructions'], body1['instructions']);
    expect(jsonEncode(body2['tools']), jsonEncode(body1['tools']));
    // 正文轮 auto，状态轮 required（模型无法只回文本逃避维护状态）。
    expect(body1['tool_choice'], 'auto');
    expect(body2['tool_choice'], 'required');
    final input = (body2['input'] as List).cast<Map<String, dynamic>>();
    // 状态轮**不再预置**快照：应用侧没有任何伪造的 readState 轨迹
    // （正文轮自己调用的编辑工具条目是模型产物，正常存在）。
    expect(
      input.where(
        (i) => i['type'] == 'function_call' && i['name'] == 'narrchat_readState',
      ),
      isEmpty,
      reason: '状态快照改为模型自取（narrchat_readState），应用不预置',
    );
    // 状态轮指令要求「先调用 readState 再按清单编辑」。
    expect(
      input.any(
        (i) =>
            '${i['content']}'.contains('[State-maintenance turn]') &&
            '${i['content']}'.contains('narrchat_readState'),
      ),
      isTrue,
    );
    // 状态轮指令（EN 标记 + 中文标记 + 缺项清单）。
    expect(
      input.any(
        (i) =>
            '${i['content']}'.contains('[State-maintenance turn]') &&
            '${i['content']}'.contains('状态维护轮'),
      ),
      isTrue,
    );
    // 正文轮 assistant 消息被完整回传（旧缺陷：续接帧看不到自己写过的正文）。
    expect(
      input.any((i) =>
          i['role'] == 'assistant' && '${i['content']}'.contains('正文初稿')),
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
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
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
        'narrchat_readState',
        'narrchat_editSection',
      ]),
    );
    expect(tools.map((t) => t['name']), isNot(contains('narrchat_advanceTime')));
    // Responses API 工具形态：name 在工具顶层（非 Chat 的 function 嵌套）。
    expect((tools.first as Map)['type'], 'function');
    expect(tools.first.containsKey('function'), isFalse);
    expect(tools.first.containsKey('name'), isTrue);
  });

  test('AGENT 用户关闭思考：请求体显式 reasoning.effort=none（平台规则）', () async {
    final dao = FakeRoundDao();
    final settings = AiSettingsProvider();
    await settings.setPerRoundOptions(thinking: false, streaming: true);
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: AiService(client: MockClient((_) async => sse(happySse()))),
      aiSettingsProvider: settings,
      experimentalSettings: AgentModeSettings(),
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

  test('AGENT 搜索开场白：无标题帧不采纳为正文，标题帧正文正常落库', () async {    final dao = FakeRoundDao();
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
        // 帧 2：标题帧（真正的正文 + 当前时间）+ 剩余状态工具。
        return sse([
          'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n洛天依与乐正绫在灯会深处的小巷里……\\n\\n## 推荐行动\\n继续观察\\n\\n## 当前时间\\n第一日 深夜"}',
          'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_3","name":"narrchat_editSection"}}',
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_3","delta":"{\\"section\\":\\"memorySummary\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 第1轮｜日期：第一日 深夜｜观察到两人走入小巷\\"}]}"}',
          'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_4","name":"narrchat_editSection"}}',
          'data: {"type":"response.function_call_arguments.delta","item_id":"fc_4","delta":"{\\"section\\":\\"characterState\\",\\"edits\\":[{\\"op\\":\\"noChange\\",\\"reason\\":\\"两人状态本轮未发生变化\\"}]}"}',
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
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
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

  test('AGENT 只写正文不调工具 → 状态轮接管（文本状态区块不再兜底落库）', () async {
    final dao = FakeRoundDao();
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        // 首帧：正文 + 违规的状态文本区块（不调用任何工具）；状态帧：只有文本。
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
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final ok = await provider.sendRound(userInput: '连夜赶路', book: book);
    expect(ok, isTrue);

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('刀刃出鞘'));
    expect(round.aiNarrative, isNot(contains('## 世界状态')));
    // 时间属于正文：`## 当前时间` 解析落库；`## 世界状态` 是 banned 段被剥离。
    expect(round.currentTime, '第三天 卯时');
    expect(round.worldState, isEmpty);
    // 正文轮 1 帧 + 状态轮 4 帧（状态帧只回文本 → 空手帧不再立即止损，
    // 继续给修复机会直到帧数上限，缺项转常驻警告）。
    expect(capturedBodies, hasLength(5));
    expect(capturedBodies[1]['tool_choice'], 'required');
    // 未落地的缺项转为常驻警告（时间属正文，不再出现在缺项里）。
    expect(provider.agentWarnings, isNotEmpty);
    expect(provider.agentWarnings.join(), contains('世界状态'));
    expect(provider.agentWarnings.join(), isNot(contains('当前时间')));
  });

  test('AGENT 历史：上一轮 assistant 只带三个正文小节（状态区块不再是模仿通道）', () async {
    final dao = FakeRoundDao();
    await dao.insertRound(const Round(
      bookUuid: 'b1',
      roundIndex: 1,
      userInput: '踏入山门',
      aiNarrative: '山门巍峨。',
      worldState: '- 地点：青云宗',
      characterState: '## 林远\n- 气血：80',
      memorySummary: '- 第1轮｜日期：第二天 午时｜初入宗门',
      currentTime: '第二天 午时',
      recommendedAction: '拜见掌门。',
    ));
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return sse([
          'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n殿前风冷。\\n\\n## 推荐行动\\n递上名帖"}',
          'data: {"type":"response.completed","response":{"id":"r1","usage":{"input_tokens":1,"output_tokens":1}}}',
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');
    await provider.sendRound(userInput: '走向主殿', book: book);

    final input = (capturedBodies.first['input'] as List)
        .cast<Map<String, dynamic>>();
    // 历史 assistant = 三个正文小节（剧情 / 行动 / 时间；状态区块不出现）。
    expect(
      input.where((i) => i['role'] == 'assistant').single['content'],
      '## 剧情演绎\n山门巍峨。\n\n## 推荐行动\n拜见掌门。\n\n## 当前时间\n第二天 午时',
    );
    // 同一份状态事实不再由应用预置：读取是模型自己的动作（工具结果形态）。
    expect(
      input.where((i) => i['type'] == 'function_call'),
      isEmpty,
      reason: '状态快照改为模型自取（narrchat_readState），应用不预置',
    );
  });

  test('AGENT 状态帧请求体：required + 思考降为 low + 不改 max_output_tokens', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        calls++;
        // 帧 1 只写正文（状态全缺）→ 帧 2 状态轮补齐。
        return sse(
          calls == 1
              ? [
                  'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n主角踏门而入。\\n\\n## 推荐行动\\n叩见掌门。"}',
                  'data: {"type":"response.completed","response":{"id":"resp_a","usage":{"input_tokens":12,"output_tokens":5}}}',
                  '',
                ]
              : happySse(),
        );
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '第一章', book: book), isTrue);
    expect(bodies, hasLength(2));

    // 正文轮：沿用用户设置（保留思考）。
    expect(bodies[0]['tool_choice'], 'auto');
    expect('${bodies[0]['reasoning']}', isNot(contains('none')));

    // 状态帧：强制调工具 + 思考强度降为 low（用户开启思考时不硬关）；
    // `max_output_tokens` 与正文轮**完全一致**——程序不擅自抬高。
    expect(bodies[1]['tool_choice'], 'required');
    expect(
      bodies[1]['max_output_tokens'],
      bodies[0]['max_output_tokens'],
      reason: '状态帧不得改写用户设置的输出上限',
    );
    expect(bodies[1]['reasoning'], {'effort': 'low'});
    // 两阶段共用同一 instructions / tools（前缀缓存依赖此）。
    expect(bodies[1]['instructions'], bodies[0]['instructions']);
    expect(bodies[1]['tools'], bodies[0]['tools']);
  });

  test('状态帧截断：提示用户调高「最大 token」，但请求体上限始终沿用用户设置', () async {
    const storyLines = [
      'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n正文。\\n\\n## 推荐行动\\n行动"}',
      'data: {"type":"response.completed","response":{"id":"rs","usage":{"input_tokens":9,"output_tokens":9}}}',
    ];
    // 触顶截断（无 error 字段，只有 incomplete_details）。
    const truncatedLines = [
      'data: {"type":"response.incomplete","response":{"id":"rs","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":9,"output_tokens":4096}}}',
    ];
    final bodies = <Map<String, dynamic>>[];
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        calls++;
        // 每轮：正文帧（只写正文）→ 状态帧（前 3 帧空手文本，第 4 帧被截断，
        // 作为本轮最后一帧 → 截断提示 + 缺项警告同时出现）。
        return sse(calls == 5 ? truncatedLines : storyLines);
      }),
    );
    final provider = RoundProvider(
      dao: FakeRoundDao(),
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '第一章', book: book), isTrue);
    expect(bodies, hasLength(5)); // 1 正文 + 4 状态（空手帧不再提前止损）
    // 截断不再让整轮失败：正文照常落库 + 黄框给出可操作提示。
    expect(bodies[1]['tool_choice'], 'required');
    expect(
      provider.roundWarningsFor(1).any((w) => w.contains('最大 token')),
      isTrue,
    );

    expect(await provider.sendRound(userInput: '第二章', book: book), isTrue);
    // 三轮请求（含下一轮的状态帧）的 max_output_tokens 全等于正文轮的值：
    // 程序不因截断擅自抬高用户设置。
    for (final b in bodies.skip(1)) {
      expect(b['max_output_tokens'], bodies.first['max_output_tokens']);
    }
  });

  test('AGENT 状态未落地 → 警告常驻该轮（仅内存），删除该轮一并清除、可手动关闭', () async {
    final dao = FakeRoundDao();
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async {
        calls++;
        // 每帧都只回文本：正文轮一帧收工，状态轮空手帧不再止损 →
        // 直到帧数上限，缺项转警告。
        return sse([
          'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n正文。\\n\\n## 推荐行动\\n行动"}',
          'data: {"type":"response.completed","response":{"id":"r$calls","usage":{"input_tokens":1,"output_tokens":1}}}',
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');
    expect(await provider.sendRound(userInput: '开始', book: book), isTrue);

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    // 时间属正文、不参与缺项；世界/角色/记忆缺项全部点名。
    expect(provider.roundWarningsFor(1), contains('世界状态本轮未更新'));
    expect(provider.roundWarningsFor(1), contains('记忆总结本轮未更新'));
    expect(provider.roundWarningsFor(1), isNot(contains('当前时间')));
    // 仅内存：轮次记录本身与 Chat 完全同构（不带任何警告字段）。
    expect(round.aiNarrative, contains('正文。'));

    // 删除该轮（含「重生成此轮 / 修改提问」的前置删除）→ 警告一并消失。
    await provider.deleteRound(round, deleteFollowing: true);
    expect(provider.roundWarningsFor(1), isEmpty);

    // 重新生成同一轮 → 警告重新挂上；手动关闭后不再出现。
    expect(await provider.sendRound(userInput: '开始', book: book), isTrue);
    expect(provider.roundWarningsFor(1), isNotEmpty);
    provider.dismissRoundWarnings(1);
    expect(provider.roundWarningsFor(1), isEmpty);
  });

  test('AGENT 空正文轮：不写库、失败条目保留输入 + 黄框说明状态作废', () async {
    final dao = FakeRoundDao();
    final ai = AiService(
      client: MockClient((request) async => sse([
        // 每帧只有状态工具调用，从不产出正文 → 正文轮耗尽 → 本轮判失败。
        'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","name":"narrchat_editSection"}}',
        'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"section\\":\\"worldState\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 地点：荒原\\"}]}"}',
        'data: {"type":"response.completed","response":{"id":"r1","usage":{"input_tokens":1,"output_tokens":1}}}',
        '',
      ])),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '只调工具', book: book), isFalse);
    // 不写入半截轮次；用户输入走既有失败条目（可一键重试）。
    expect(dao.rounds.where((r) => r.roundIndex > 0), isEmpty);
    expect(provider.failedAttempt.userInput, '只调工具');
    // 黄框挂在「本该产生的那一轮」上，说明状态改动已作废（仅内存）。
    expect(
      provider.roundWarningsFor(provider.nextRoundIndex),
      contains('本轮未产出正文（模型只返回了工具调用），本轮的状态改动已作废。'),
    );
    // 清除失败条目 → 该黄框一并清除。
    await provider.clearFailedAttempt();
    expect(provider.roundWarningsFor(provider.nextRoundIndex), isEmpty);
  });
}
