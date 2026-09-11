import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/fakes.dart';

/// RoundProvider Agent 档位（Response API 协议）集成测试。
///
/// 覆盖：Lv.2（六工具 + 三小节正文）主响应落库 / 缺口修复轮 / 预览 /
/// 强制选项；Lv.1（仅历史工具 + 5 区块正文）的混合落库与维护轮必发。
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

  String textDelta(String text) => 'data: ${jsonEncode({
        'type': 'response.output_text.delta',
        'delta': text,
      })}';

  String callAdded(String id, String name) => 'data: ${jsonEncode({
        'type': 'response.output_item.added',
        'item': {'type': 'function_call', 'id': id, 'name': name},
      })}';

  String callArgs(String id, Map<String, dynamic> arguments) =>
      'data: ${jsonEncode({
        'type': 'response.function_call_arguments.delta',
        'item_id': id,
        'delta': jsonEncode(arguments),
      })}';

  String completed(String id, {int input = 1, int output = 1}) =>
      'data: ${jsonEncode({
        'type': 'response.completed',
        'response': {
          'id': id,
          'usage': {'input_tokens': input, 'output_tokens': output},
        },
      })}';

  /// 单条编辑调用的三行 SSE（item.added → args delta）。
  List<String> editLines(
    String id,
    AgentStateSection section,
    List<Map<String, dynamic>> edits,
  ) =>
      [
        callAdded(id, agentEditToolName(section)),
        callArgs(id, {'edits': edits}),
      ];

  /// Lv.2 主响应：正文三小节 + 三栏编辑（一次响应闭环）。
  List<String> happySse() => [
        textDelta('## 剧情演绎\n主角踏门而入。\n\n## 推荐行动\n叩见掌门。\n'
            '\n## 当前时间\n第三天 卯时'),
        ...editLines('fc_1', AgentStateSection.worldState, [
          {'op': 'append', 'newLine': '- 地点：青云宗'},
        ]),
        ...editLines('fc_2', AgentStateSection.characterState, [
          {'op': 'append', 'newLine': '# 主角\n## 林远\n- 气血：100'},
        ]),
        ...editLines('fc_3', AgentStateSection.memorySummary, [
          {'op': 'append', 'newLine': '- 第1轮｜日期：第三天 卯时｜主角踏门而入'},
        ]),
        completed('resp_1', input: 12, output: 5),
        '',
      ];

  /// 只回正文的帧（三栏全缺 → 触发维护轮）。
  List<String> storyOnlyLines(String narrative) => [
        textDelta(narrative),
        completed('resp_s', input: 1, output: 1),
        '',
      ];

  test('AGENT Lv.2 主响应：正文 + 状态工具 → 落库快照来自工作副本合并', () async {
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
      // Agent 档位与协议解耦：显式开启实验性档位（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final ok = await provider.sendRound(userInput: '第一章', book: book);
    expect(ok, isTrue);

    // 请求体形态：单次请求闭环（正文轮把状态补齐 → 不发起维护轮）。
    expect(bodies, hasLength(1));
    final body = bodies.single;
    expect(body['tool_choice'], 'auto');
    expect(body['instructions'], contains('【AGENT 模式契约】'));
    // 工具集 = 六个状态工具 + 强制开启的联网工具（时间属于正文，无时间工具）。
    final names = (body['tools'] as List)
        .cast<Map<String, dynamic>>()
        .map((t) => t['name'])
        .toList();
    expect(
      names,
      containsAll([
        'narrchat_readWorldState',
        'narrchat_readCharacterState',
        'narrchat_readHistory',
        'narrchat_editWorldState',
        'narrchat_editCharacterState',
        'narrchat_editHistory',
      ]),
    );
    expect(names, containsAll(['narrchat_webSearch', 'narrchat_webFetchPage']));
    expect(names, isNot(contains('narrchat_readState')));
    expect(names, isNot(contains('narrchat_advanceTime')));
    // 状态**不预置**：input 里没有应用伪造的 function_call 序列。
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
    expect(round.modelName, 'deepseek-flash');
    // RAW 完成：1 次交换，工具调用块含状态工具。
    final exchanges = provider.rawExchangesFor(round.id!)!;
    expect(exchanges, hasLength(1));
    expect(exchanges.single.toolCalls, contains('narrchat_editWorldState'));
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
          // 第 1 帧：正文 + 历史声明无变化（每轮必须补条目 → 被拒）。
          return sse([
            textDelta('## 剧情演绎\n正文初稿\n\n## 推荐行动\nx\n\n## 当前时间\n第一天 申时'),
            ...editLines('fc_1', AgentStateSection.memorySummary, [
              {'op': 'noChange'},
            ]),
            completed('resp_1', input: 1, output: 1),
            '',
          ]);
        }
        return sse([
          textDelta('## 剧情演绎\n修正后正文\n\n## 推荐行动\ny'),
          ...editLines('fc_2', AgentStateSection.worldState, [
            {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
          ]),
          ...editLines('fc_4', AgentStateSection.characterState, [
            {'op': 'append', 'newLine': '# 主角\n## 林远\n- 气血：60'},
          ]),
          ...editLines('fc_5', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': '- 第2轮｜日期：第一天 申时｜前往主峰'},
          ]),
          completed('resp_2', input: 2, output: 2),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
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
    // 正文采纳制：本轮正文 = 正文轮的标题帧；维护轮复读的正文被结构性丢弃。
    expect(round.aiNarrative, contains('正文初稿'));
    expect(round.aiNarrative, isNot(contains('修正后正文')));
    expect(round.recommendedAction, contains('x'));
    expect(round.worldState, '- 地点：主峰\n- 天气：晴');
    expect(round.currentTime, '第一天 申时');
    expect(round.memorySummary, contains('第2轮'));
    expect(provider.rawExchangesFor(round.id!), hasLength(2));
    // 第 2 帧 = 维护轮：全量重发（无 previous_response_id），
    // 且 instructions / tools 前缀与第 1 帧**逐字节一致**（缓存命中前提）。
    final body1 = capturedBodies[0];
    final body2 = capturedBodies[1];
    expect(body2.containsKey('previous_response_id'), isFalse);
    expect(body2['instructions'], body1['instructions']);
    expect(jsonEncode(body2['tools']), jsonEncode(body1['tools']));
    // 正文轮 auto，维护轮 required（模型无法只回文本逃避维护状态）。
    expect(body1['tool_choice'], 'auto');
    expect(body2['tool_choice'], 'required');
    final input = (body2['input'] as List).cast<Map<String, dynamic>>();
    // 状态**不再预置**：应用侧没有任何伪造的读取轨迹。
    expect(
      input.where(
        (i) =>
            i['type'] == 'function_call' &&
            kReadStateToolNames.contains(i['name']),
      ),
      isEmpty,
      reason: '状态改为模型自取（各栏读取器），应用不预置',
    );
    // 维护轮指令要求「读取器已禁用，直接用正文回合读到的结果编辑」。
    expect(
      input.any(
        (i) =>
            '${i['content']}'.contains('[State-maintenance turn]') &&
            '${i['content']}'.contains('narrchat_readWorldState'),
      ),
      isTrue,
    );
    expect(
      input.any(
        (i) =>
            '${i['content']}'.contains('[State-maintenance turn]') &&
            '${i['content']}'.contains('读取器') &&
            '${i['content']}'.contains('已禁用'),
      ),
      isTrue,
      reason: '维护轮不再重复读取：指令明示读取器已禁用',
    );
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
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final preview = await provider.previewRequestBody(
      userInput: '第一章',
      book: book,
    );
    final body = jsonDecode(preview) as Map<String, dynamic>;
    expect(body['model'], 'deepseek-flash');
    expect(body['instructions'], contains('【AGENT 模式契约】'));
    expect(body['input'], isA<List>());
    final tools = (body['tools'] as List).cast<Map<String, dynamic>>();
    expect(
      tools.map((t) => t['name']),
      containsAll([
        'narrchat_readWorldState',
        'narrchat_readCharacterState',
        'narrchat_readHistory',
        'narrchat_editWorldState',
        'narrchat_editCharacterState',
        'narrchat_editHistory',
      ]),
    );
    expect(tools.map((t) => t['name']), isNot(contains('narrchat_advanceTime')));
    // Responses API 工具形态：name 在工具顶层（非 Chat 的 function 嵌套）。
    expect((tools.first as Map)['type'], 'function');
    expect(tools.first.containsKey('function'), isFalse);
    expect(tools.first.containsKey('name'), isTrue);
  });

  test('Agent 强制开启思考 / 搜索：忽略用户已保存的 Chat 每轮选项', () async {
    // 先把用户的 Chat 每轮选项全关（思考/流式/搜索）。
    final settings = AiSettingsProvider();
    await settings.setPerRoundOptions(
      thinking: false,
      streaming: false,
      search: false,
    );
    expect(settings.thinking, isFalse);
    expect(settings.streaming, isFalse);
    expect(settings.lastSearch, isFalse);

    Future<Map<String, dynamic>> previewWith(
      ExperimentalSettingsProvider experimental,
    ) async {
      final provider = RoundProvider(
        dao: FakeRoundDao(),
        bookDao: FakeBookDao(),
        aiService: AiService(client: MockClient((_) async => sse(happySse()))),
        aiSettingsProvider: settings,
        experimentalSettings: experimental,
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');
      return jsonDecode(
        await provider.previewRequestBody(userInput: '第一章', book: book),
      ) as Map<String, dynamic>;
    }

    // Agent 开：思考照旧发送（不再被用户选项关掉），联网工具同批注入。
    final agentBody = await previewWith(AgentModeSettings());
    expect(agentBody.containsKey('tools'), isTrue);
    expect(
      (agentBody['tools'] as List)
          .cast<Map<String, dynamic>>()
          .map((t) => t['name']),
      contains('narrchat_webSearch'),
    );
    // DeepSeek 思考模式默认开启（默认 high）；`none` = 关闭。
    expect('${agentBody['reasoning']}', isNot(contains('none')));
    // 联网随 Agent 强制开启：system **不再**追加联网指令，调用指导
    // （搜索 → 必须打开页面）随工具 description 下发。
    expect('${agentBody['instructions']}', isNot(contains('【联网搜索】')));
    final searchSchema = (agentBody['tools'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((t) => t['name'] == 'narrchat_webSearch');
    expect('${searchSchema['description']}', contains('narrchat_webFetchPage'));

    // Agent 关：用户的 Chat 选项原样生效（思考关闭 + 无搜索工具）。
    final chatBody =
        await previewWith(ExperimentalSettingsProvider());
    expect(chatBody.containsKey('tools'), isFalse);
    expect((chatBody['reasoning'] as Map)['effort'], 'none');
    expect(chatBody.containsKey('reasoning_effort'), isFalse);
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
            textDelta(
                'I\'ll search for information about the two characters before writing the story.'),
            ...editLines('fc_1', AgentStateSection.worldState, [
              {'op': 'append', 'newLine': '- 地点：灯会'},
            ]),
            completed('resp_1'),
            '',
          ]);
        }
        // 帧 2：标题帧（真正的正文 + 当前时间）+ 剩余状态工具。
        return sse([
          textDelta(
              '## 剧情演绎\n洛天依与乐正绫在灯会深处的小巷里……\n\n## 推荐行动\n继续观察\n\n## 当前时间\n第一日 深夜'),
          ...editLines('fc_3', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': '- 第1轮｜日期：第一日 深夜｜观察到两人走入小巷'},
          ]),
          ...editLines('fc_4', AgentStateSection.characterState, [
            {'op': 'noChange', 'reason': '两人状态本轮未发生变化'},
          ]),
          completed('resp_2', input: 2, output: 2),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
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

  test('AGENT 思考块回传：一次调两个工具 → 第 2 帧每调用各配一块（真实 400 复现）', () async {
    final dao = FakeRoundDao();
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        if (idx == 1) {
          // 帧 1：模型先思考，**一帧同时调两个工具**（读取器 + 联网搜索）——
          // 这正是线上 400 的那一帧（服务端按「每个 function_call 一块思考」
          // 逐块校验，只回传一块即整次被拒）。
          return sse([
            'data: ${jsonEncode({
                  'type': 'response.output_item.added',
                  'item': {'type': 'reasoning', 'id': 'rs_r1'},
                })}',
            'data: ${jsonEncode({
                  'type': 'response.reasoning_text.delta',
                  'item_id': 'rs_r1',
                  'delta': 'Need the world state and a web lookup first.',
                })}',
            callAdded('fc_1', agentReadToolName(AgentStateSection.worldState)),
            callArgs('fc_1', {'round': 1}),
            callAdded('fc_2', 'narrchat_webSearch'),
            callArgs('fc_2', {'query': '青云宗'}),
            completed('resp_1'),
            '',
          ]);
        }
        // 帧 2：正文 + 三栏闭环（无缺口 → 不再发维护轮）。
        return sse([
          textDelta('## 剧情演绎\n主角踏门而入。\n\n## 推荐行动\n叩见掌门。\n'
              '\n## 当前时间\n第三天 卯时'),
          ...editLines('fc_3', AgentStateSection.worldState, [
            {'op': 'append', 'newLine': '- 地点：青云宗'},
          ]),
          ...editLines('fc_4', AgentStateSection.characterState, [
            {'op': 'noChange', 'reason': '角色状态本轮未变化'},
          ]),
          ...editLines('fc_5', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': '- 第1轮｜日期：第三天 卯时｜主角踏门而入'},
          ]),
          completed('resp_2', input: 2, output: 2),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '继续', book: book), isTrue);
    expect(capturedBodies, hasLength(2));

    final input1 = (capturedBodies[0]['input'] as List).cast<Map<String, dynamic>>();
    expect(input1.any((i) => i['type'] == 'reasoning'), isFalse,
        reason: '首帧还没有思考块');

    // 第 2 帧：每个 function_call 紧邻其前各有一块非空 reasoning
    //（缺失 → HTTP 400「reasoning_text in the thinking mode must be passed back」）。
    final input2 = (capturedBodies[1]['input'] as List).cast<Map<String, dynamic>>();
    final callIndexes = <int>[
      for (var i = 0; i < input2.length; i++)
        if (input2[i]['type'] == 'function_call') i,
    ];
    expect(callIndexes, hasLength(2));
    for (final at in callIndexes) {
      expect(at, greaterThan(0));
      final block = input2[at - 1];
      expect(block['type'], 'reasoning');
      expect(block['content'], [
        {
          'type': 'reasoning_text',
          'text': 'Need the world state and a web lookup first.',
        },
      ]);
    }
  });

  test('AGENT 只写正文不调工具 → 维护轮接管（文本状态区块不再兜底落库）', () async {
    final dao = FakeRoundDao();
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        // 首帧：正文 + 违规的状态文本区块（不调用任何工具）；维护帧：只有文本。
        final narrative = textDelta(
            '## 剧情演绎\n刀刃出鞘，寒光掠过。\n\n## 推荐行动\n继续赶路');
        final lines = <String>[
          narrative,
          if (idx == 1)
            textDelta('\n\n## 当前时间\n第三天 卯时\n\n## 世界状态\n- 地点：荒原'),
          completed('r$idx'),
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
    // 正文轮 1 帧 + 维护轮 4 帧（维护帧只回文本 → 空手帧不再立即止损，
    // 继续给修复机会直到帧数上限，缺项转常驻警告）。
    expect(capturedBodies, hasLength(5));
    expect(capturedBodies[1]['tool_choice'], 'required');
    // 未落地的缺项转为常驻警告（时间属正文，不再出现在缺项里）。
    expect(provider.agentWarnings, isNotEmpty);
    expect(provider.agentWarnings.join(), contains('世界状态'));
    expect(provider.agentWarnings.join(), isNot(contains('当前时间')));
  });

  test('AGENT Lv.2 历史：上一轮 assistant 只带三个正文小节（状态区块不再是模仿通道）', () async {
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
        return sse(storyOnlyLines('## 剧情演绎\n殿前风冷。\n\n## 推荐行动\n递上名帖'));
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
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
      reason: '状态改为模型自取（各栏读取器），应用不预置',
    );
  });

  test('AGENT Lv.1：正文 5 区块 + 仅历史工具 → 世界/角色取自正文、历史取自工具', () async {
    final dao = FakeRoundDao();
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        if (idx == 1) {
          // 正文轮：5 区块（世界 / 角色随正文携带，无记忆区块）。
          return sse(storyOnlyLines(
              '## 剧情演绎\n殿前风冷。\n\n## 推荐行动\n递上名帖\n\n## 当前时间\n第二天 辰时\n\n'
              '## 世界状态\n- 地点：青云宗主殿\n\n## 角色状态\n## 林远\n- 气血：60'));
        }
        // 维护轮（每轮必发）：只补本轮历史条目。
        return sse([
          ...editLines('h1', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': '- 第1轮｜日期：第二天 辰时｜殿前递帖'},
          ]),
          completed('resp_h', input: 2, output: 2),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(level: AgentModeLevel.lv1),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '走向主殿', book: book), isTrue);
    expect(capturedBodies, hasLength(2), reason: 'Lv.1 维护轮每轮必发');

    // 工具集 = 历史一读一写 + 联网（世界 / 角色不在其中）。
    final names = (capturedBodies.first['tools'] as List)
        .cast<Map<String, dynamic>>()
        .map((t) => t['name'])
        .toList();
    expect(
      names,
      containsAll([
        'narrchat_readHistory',
        'narrchat_editHistory',
        'narrchat_webSearch',
        'narrchat_webFetchPage',
      ]),
    );
    expect(names, isNot(contains('narrchat_editWorldState')));
    expect(names, isNot(contains('narrchat_readCharacterState')));
    // instructions = Lv.1 的 5 区块契约 + 历史工具契约。
    expect('${capturedBodies.first['instructions']}',
        contains('完整输出以下 5 个二级标题'));
    expect('${capturedBodies.first['instructions']}',
        contains('narrchat_readHistory'));

    // 落库：世界 / 角色 / 时间来自正文文本，历史来自工具落地。
    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(round.worldState, '- 地点：青云宗主殿');
    expect(round.characterState, contains('- 气血：60'));
    expect(round.currentTime, '第二天 辰时');
    expect(round.memorySummary, '- 第1轮｜日期：第二天 辰时｜殿前递帖');
    expect(provider.agentWarnings, isEmpty);
  });

  test('兼容降级重发：400 探测帧**不计失败轮**、不计 token，RAW 写明 HTTP 码', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        // 模拟「只接受 auto、不接受 required」的兼容实现：维护帧探测被拒（HTTP 400）。
        if (body['tool_choice'] == 'required') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'error': {'message': 'tool_choice 参数不受支持'},
            })),
            400,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        // 正文帧（带 auto）→ 只写正文；维护帧重发（无 tool_choice）→ 补齐三栏。
        return sse(
          body.containsKey('tool_choice')
              ? storyOnlyLines('## 剧情演绎\n正文。\n\n## 推荐行动\n行动')
              : happySse(),
        );
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '第一章', book: book), isTrue);

    // 三次底层请求：正文帧(auto) → 维护帧探测(required，被 400 拒绝) → 同一帧重发(无 tool_choice)。
    expect(bodies, hasLength(3));
    expect(bodies[0]['tool_choice'], 'auto');
    expect(bodies[1]['tool_choice'], 'required');
    expect(bodies[2].containsKey('tool_choice'), isFalse,
        reason: '降级后就地重发同一帧：不再携带 tool_choice');
    // 重发的是**同一帧**：input 完全一致（帧序号不变、不重跑正文轮）。
    expect(bodies[2]['input'], bodies[1]['input']);

    // 本轮照常成功落库（正文 + 状态齐备），且**没有被记为失败**：
    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('正文。'));
    expect(round.memorySummary, contains('第1轮'));
    expect(provider.failedAttempt.isEmpty, isTrue, reason: '不产生失败条目');
    expect(provider.retryStatus, isNull, reason: '不触发「错误重连……」重试提示');
    expect(provider.roundWarningsFor(1), isEmpty, reason: '不产生常驻黄框');
    expect(provider.error, isNull);

    // **不计 token**：本轮用量只累加两次成功帧（正文帧 1/1 + 维护帧 12/5），
    // 被 400 拒绝的那次探测不产生 usage，也不计入本轮。
    expect(round.tokensIn, 13);
    expect(round.tokensOut, 6);

    // RAW：失败的那次探测保留下来并写明 HTTP 码与报错原文（可追溯）。
    final exchanges = provider.rawExchangesFor(round.id!)!;
    expect(exchanges, hasLength(3));
    final failed = exchanges.where((e) => e.error.isNotEmpty).toList();
    expect(failed, hasLength(1), reason: '只有探测帧没有返回');
    expect(failed.single.error, contains('HTTP 400'));
    expect(failed.single.error, contains('tool_choice'));
    // 它确实没有返回内容（三个块全空）——RAW 就是靠 error 说明原因。
    expect(failed.single.thinking, isEmpty);
    expect(failed.single.toolCalls, isEmpty);
    expect(failed.single.content, isEmpty);
    // 成功帧不受影响：正文帧与维护帧重发都有返回内容。
    expect(exchanges.first.content, contains('正文。'));
    expect(exchanges.last.content, contains('主角踏门而入'));
  });

  test('维护帧请求体：required + 思考降为 low + 不改 max_output_tokens', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        calls++;
        // 帧 1 只写正文（状态全缺）→ 帧 2 维护轮补齐。
        return sse(
          calls == 1
              ? storyOnlyLines('## 剧情演绎\n主角踏门而入。\n\n## 推荐行动\n叩见掌门。')
              : happySse(),
        );
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '第一章', book: book), isTrue);
    expect(bodies, hasLength(2));

    // 正文轮：沿用用户设置（保留思考）。
    expect(bodies[0]['tool_choice'], 'auto');
    expect('${bodies[0]['reasoning']}', isNot(contains('none')));

    // 维护帧：强制调工具 + 思考强度降为 low（用户开启思考时不硬关）；
    // `max_output_tokens` 与正文轮**完全一致**——程序不擅自抬高。
    expect(bodies[1]['tool_choice'], 'required');
    expect(
      bodies[1]['max_output_tokens'],
      bodies[0]['max_output_tokens'],
      reason: '维护帧不得改写用户设置的输出上限',
    );
    expect(bodies[1]['reasoning'], {'effort': 'low'});
    // 两阶段共用同一 instructions / tools（前缀缓存依赖此）。
    expect(bodies[1]['instructions'], bodies[0]['instructions']);
    expect(bodies[1]['tools'], bodies[0]['tools']);
  });

  test('维护帧截断：提示用户调高「最大 token」，但请求体上限始终沿用用户设置', () async {
    final storyLines = storyOnlyLines('## 剧情演绎\n正文。\n\n## 推荐行动\n行动');
    // 触顶截断（无 error 字段，只有 incomplete_details）。
    final truncatedLines = [
      'data: ${jsonEncode({
        'type': 'response.incomplete',
        'response': {
          'id': 'rs',
          'status': 'incomplete',
          'incomplete_details': {'reason': 'max_output_tokens'},
          'usage': {'input_tokens': 9, 'output_tokens': 4096},
        },
      })}',
    ];
    final bodies = <Map<String, dynamic>>[];
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        calls++;
        // 每轮：正文帧（只写正文）→ 维护帧（前 3 帧空手文本，第 4 帧被截断，
        // 作为本轮最后一帧 → 截断提示 + 缺项警告同时出现）。
        return sse(calls == 5 ? truncatedLines : storyLines);
      }),
    );
    final provider = RoundProvider(
      dao: FakeRoundDao(),
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '第一章', book: book), isTrue);
    expect(bodies, hasLength(5)); // 1 正文 + 4 维护（空手帧不再提前止损）
    // 截断不再让整轮失败：正文照常落库 + 黄框给出可操作提示。
    expect(bodies[1]['tool_choice'], 'required');
    expect(
      provider.roundWarningsFor(1).any((w) => w.contains('最大 token')),
      isTrue,
    );

    expect(await provider.sendRound(userInput: '第二章', book: book), isTrue);
    // 三轮请求（含下一轮的维护帧）的 max_output_tokens 全等于正文轮的值：
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
        // 每帧都只回文本：正文轮一帧收工，维护帧空手帧不再止损 →
        // 直到帧数上限，缺项转警告。
        return sse(storyOnlyLines('## 剧情演绎\n正文。\n\n## 推荐行动\n行动'));
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');
    expect(await provider.sendRound(userInput: '开始', book: book), isTrue);
    expect(calls, greaterThan(1));

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    // 时间属正文、不参与缺项；世界/角色/历史缺项全部点名。
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
        ...editLines('fc_1', AgentStateSection.worldState, [
          {'op': 'append', 'newLine': '- 地点：荒原'},
        ]),
        completed('r1'),
        '',
      ])),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
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
