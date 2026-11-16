import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/models/api_type.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/raw_exchange.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/round_send_intent.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/fakes.dart';

/// RoundProvider Agent Lv.1（Response API 协议）集成测试。
///
/// 完整 Agent（Lv.2：六工具 + 三小节正文）已移除：本文件只剩 Lv.1 的
/// **两步流程**（第一步调研 + 正文；第二步状态维护），以及该流程下的
/// 通用行为——预览首回合 = 调研回合、强制思考 / 搜索、思考块回传、兼容降级重发、
/// 维护回合请求体 / 截断、警告常驻、空正文失败、**所有步结束后统一入库**。
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

  String textDelta(String text) =>
      'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': text})}';

  String callAdded(String id, String name) =>
      'data: ${jsonEncode({
        'type': 'response.output_item.added',
        'item': {'type': 'function_call', 'id': id, 'name': name},
      })}';

  String callArgs(String id, Map<String, dynamic> arguments) =>
      'data: ${jsonEncode({'type': 'response.function_call_arguments.delta', 'item_id': id, 'delta': jsonEncode(arguments)})}';

  String completed(String id, {int input = 1, int output = 1, int? cached}) =>
      'data: ${jsonEncode({
        'type': 'response.completed',
        'response': {
          'id': id,
          'usage': {
            'input_tokens': input,
            'output_tokens': output,
            if (cached != null) 'input_tokens_details': {'cached_tokens': cached},
          },
        },
      })}';

  /// 一帧内的一块思考（`output_item.added` + 文本增量）。
  List<String> reasoningLines(String id, String text) => [
        'data: ${jsonEncode({
              'type': 'response.output_item.added',
              'item': {'type': 'reasoning', 'id': id},
            })}',
    'data: ${jsonEncode({'type': 'response.reasoning_text.delta', 'item_id': id, 'delta': text})}',
      ];

  /// 单条读取器调用的两行 SSE（item.added → args delta）。
  List<String> readLines(String id, String name, {int round = 1}) => [
        callAdded(id, name),
        callArgs(id, {'round': round}),
      ];

  /// 单条编辑调用的两行 SSE（item.added → args delta）。
  List<String> editLines(
    String id,
    AgentStateSection section,
    List<Map<String, dynamic>> edits,
  ) => [
        callAdded(id, agentEditToolName(section)),
        callArgs(id, {'edits': edits}),
      ];

  /// 只回文本的帧（标题帧 / 空手帧）。
  List<String> textOnlyLines(String narrative) => [
        textDelta(narrative),
        completed('resp_s', input: 1, output: 1),
        '',
      ];

  /// Lv.1 正文回合的 5 区块正文（世界 / 角色 / 时间随正文携带，无记忆区块）。
  const String story5 =
      '## 剧情演绎\n殿前风冷。\n\n## 推荐行动\n递上名帖\n\n'
      '## 当前时间\n第二天 辰时\n\n## 世界状态\n- 地点：青云宗主殿\n\n'
      '## 角色状态\n## 林远\n- 气血：60';

  /// 只回 5 区块正文的帧（正文回合 / 空手回合的通用返回）。
  List<String> story5Lines() => textOnlyLines(story5);

  /// 新格式记忆条目（`轮次 | 时间 | 内容`）。
  const String memoryEntry = '- 1 | 第二天 辰时 | 殿前递帖';

  late TestStack stack;

  // R3 没有假 DAO：用真库 + 临时目录播种。
  setUp(() async {
    stack = await TestStack.create(prefix: 'agent_round_');
    await stack.repos.books.createBook(book);
  });

  tearDown(() async {
    await stack.dispose();
  });

  // ---------------------------------------------------------------------------
  // Lv.1 主流程
  // ---------------------------------------------------------------------------

  test('AGENT Lv.1：调研(读史) → 正文 5 区块 → 维护补记忆；共 3 回合', () async {
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        if (idx == 1) {
          // 第 1 回合 = 调研：读一次历史（只读 → 调研结束）。
          return sse([
            ...readLines('r1', 'narrchat_readHistory'),
            completed('resp_r'),
            '',
          ]);
        }
        if (idx == 2) {
          // 第 2 回合 = 正文：5 区块（世界 / 角色随正文携带，无记忆区块）。
          return sse(story5Lines());
        }
        // 第 3 回合 = 维护：正文完成后单独请求，落本轮记忆条目。
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
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(level: AgentModeLevel.lv1),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '走向主殿', book: book), isTrue);

    // 合规一轮 = 恰好 3 回合：调研（读史）→ 正文 → 维护（补记忆）。
    expect(capturedBodies, hasLength(3), reason: 'Lv.1 合规一轮 3 回合');
    expect(capturedBodies.every((b) => !b.containsKey('tool_choice')), isTrue);
    // 思考强度全回合沿用用户设置：调研 / 正文 / 维护三回合完全一致。
    expect(
      capturedBodies.map((b) => jsonEncode(b['reasoning'])).toSet(),
      hasLength(1),
    );
    expect(jsonDecode(jsonEncode(capturedBodies[0]['reasoning'])), {
      'effort': 'high',
    });

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
    // instructions = Lv.1 的 5 区块契约 + 历史工具契约；三回合共用同一前缀
    //（服务商上下文缓存依赖此）。
    expect('${capturedBodies.first['instructions']}', contains('只输出 5 个二级标题'));
    expect(
      '${capturedBodies.first['instructions']}',
      contains('narrchat_readHistory'),
    );
    for (final b in capturedBodies.skip(1)) {
      expect(b['instructions'], capturedBodies.first['instructions']);
      expect(b['tools'], capturedBodies.first['tools']);
    }

    // 落库：世界 / 角色 / 时间来自正文文本，历史来自工具落地。
    final round = (await stack.repos.rounds.loadChain('b1')).rounds
        .firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(round.aiNarrative, isNot(contains('本轮大纲')));
    expect(round.worldState, '- 地点：青云宗主殿');
    expect(round.characterState, contains('- 气血：60'));
    expect(round.currentTime, '第二天 辰时');
    expect(round.memorySummary, '- 第1轮｜日期：第二天 辰时｜殿前递帖');
    expect(provider.agentWarnings, isEmpty);
    expect(provider.rawExchangesFor(round.uuid), hasLength(3));
    // RAW 轨迹元数据：轮 → 步 → 回合。
    final raw = provider.rawExchangesFor(round.uuid)!;
    expect(raw.map((e) => e.roundIndex).toSet(), {1});
    expect(raw.map((e) => e.step).toList(), [
      RawAgentStep.first,
      RawAgentStep.first,
      RawAgentStep.maintenance,
    ]);
    expect(raw.map((e) => e.turnKind).toList(), [
      RawTurnKind.research,
      RawTurnKind.story,
      RawTurnKind.maintenance,
    ]);
    expect(raw.map((e) => e.turnIndex).toList(), [1, 2, 1]);
  });

  test('AGENT Lv.1 所有步结束后才入库：维护挂起时库里没有本轮，完成后只写一条总 token', () async {
    final maintenanceGate = Completer<void>();
    final maintenanceStarted = Completer<void>();
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async {
        calls++;
        if (calls == 1) {
          return sse([
            ...readLines('r1', 'narrchat_readHistory'),
            completed('resp_r', input: 1, output: 1),
            '',
          ]);
        }
        if (calls == 2) {
          return sse([
            textDelta(story5),
            completed('resp_s', input: 2, output: 2),
            '',
          ]);
        }
        // 第 3 回合：维护请求挂起，模拟“所有步尚未结束”。
        if (!maintenanceStarted.isCompleted) maintenanceStarted.complete();
        await maintenanceGate.future;
        return sse([
          ...editLines('m1', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': memoryEntry},
          ]),
          completed('resp_m', input: 3, output: 4),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final future = provider.sendRound(userInput: '走向主殿', book: book);
    await maintenanceStarted.future;

    // 维护进行中：正文已在内存时间线里，但数据库里还没有本轮。
    expect(provider.streamingContent, contains('殿前风冷'));
    final before = await stack.repos.rounds.loadChain('b1');
    expect(before.rounds, isEmpty, reason: '所有步结束后才统一入库');

    maintenanceGate.complete();
    expect(await future, isTrue);

    final after = await stack.repos.rounds.loadChain('b1');
    expect(after.rounds, hasLength(1), reason: '只写一条正文轮');
    final round = after.rounds.single;
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(round.memorySummary, memoryEntry);
    // token = 调研 1/1 + 正文 2/2 + 维护 3/4。
    expect(round.tokensIn, 6);
    expect(round.tokensOut, 7);
    expect(provider.maintenanceCompletedFor(round.uuid), isTrue);

    // 灰字提示只在内存里：新建 Provider 重新加载后不显示。
    final restarted = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: AiService(client: MockClient((_) async => sse(['']))),
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await restarted.loadRounds('b1');
    expect(restarted.maintenanceCompletedFor(round.uuid), isFalse);
  });

  test('AGENT Lv.1 每轮都发维护请求：调研读史 → 正文 → 维护（RAW 3 回合）', () async {
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        if (idx == 1) {
          // 调研回合：读一次历史 → **本回合只调读取器 → 调研立即结束**。
          return sse([
            ...readLines('fc_r', 'narrchat_readHistory'),
            completed('resp_r'),
            '',
          ]);
        }
        if (idx == 2) {
          // 正文回合：5 区块。
          return sse(story5Lines());
        }
        // 维护回合：正文完成后单独请求，落本轮条目。
        return sse([
          ...editLines('fc_m', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': '- 第1轮｜日期：第二天 辰时｜殿前递帖'},
          ]),
          completed('resp_m'),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(level: AgentModeLevel.lv1),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '走向主殿', book: book), isTrue);

    // 调研 1 回合 + 正文 1 回合 + 维护 1 回合 = **恰好 3 回合**。
    expect(capturedBodies, hasLength(3));
    // 调研回合指令：本步只做调研（不写记忆 / 正文、文本通道零输出）。
    final prepareDirective =
        (capturedBodies.first['input'] as List)
        .cast<Map<String, dynamic>>()
                .lastWhere((i) => i['role'] == 'user')['content']
            as String;
    expect(prepareDirective, startsWith('【调研回合】'));
    expect(prepareDirective, contains('不要'));
    expect(prepareDirective, contains('立刻发正文回合'));
    expect(
      capturedBodies.every((b) => !b.containsKey('tool_choice')),
      isTrue,
      reason: 'Agent 回合一律不发 tool_choice',
    );
    // 维护回合是独立请求，带 [State-maintenance turn] 指令。
    final maintenanceInput = (capturedBodies[2]['input'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      '${maintenanceInput.last['content']}',
      startsWith('[State-maintenance turn]'),
    );

    final round = (await stack.repos.rounds.loadChain('b1')).rounds
        .firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(round.memorySummary, '- 第1轮｜日期：第二天 辰时｜殿前递帖');
    expect(round.worldState, '- 地点：青云宗主殿');
    expect(provider.agentWarnings, isEmpty);
    // RAW：3 次交换，全为成功帧（可追溯）。
    final exchanges = provider.rawExchangesFor(round.uuid)!;
    expect(exchanges, hasLength(3));
    expect(exchanges.where((e) => e.error.isNotEmpty), isEmpty);
  });

  // ---------------------------------------------------------------------------
  // 预览 / 强制选项
  // ---------------------------------------------------------------------------

  test('AGENT Lv.1 预览请求体：首回合 = 调研回合（不是正文回合），工具只含历史两件 + 联网两件', () async {
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: AiService(client: MockClient((_) async => sse(story5Lines()))),
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final preview = await provider.previewRequestBody(
      intent: RoundSendIntent.newRound(userInput: '第一章'),
      book: book,
    );
    final body = preview.firstFrame;
    expect(body['model'], 'deepseek-flash');
    expect('${body['instructions']}', contains('只输出 5 个二级标题'));
    expect('${body['instructions']}', contains('narrchat_readHistory'));
    expect(body['input'], isA<List>());
    // 首回合 = 调研回合：末条是紧随用户输入之后的「【调研回合】」指令，
    // 不是正文回合（正文只在调研结束之后才可能出现）。
    final input = (body['input'] as List).cast<Map<String, dynamic>>();
    expect(input.last['role'], 'user');
    expect('${input.last['content']}', startsWith('【调研回合】'));
    expect(
      input.any((i) => '${i['content']}'.contains('第一章')),
      isTrue,
      reason: '用户输入仍在 input 里',
    );
    // 工具集 = 历史一读一写 + 联网；世界 / 角色工具不再注册。
    final tools = (body['tools'] as List).cast<Map<String, dynamic>>();
    expect(tools.map((t) => t['name']).toList(), [
        'narrchat_readHistory',
        'narrchat_editHistory',
        'narrchat_webSearch',
        'narrchat_webFetchPage',
    ], reason: '顺序即请求体 tools 数组顺序（前缀缓存依赖此）');
    expect(
      tools.map((t) => t['name']),
      isNot(contains('narrchat_advanceTime')),
    );
    // 后续候选回合：正文 → 维护（首回合之后才可能有正文回合）。
    expect(preview.subsequentFrames.map((f) => f.label).toList(), [
      '正文回合',
      '维护回合',
    ]);
    // Responses API 工具形态：name 在工具顶层（非 Chat 的 function 嵌套）。
    expect(tools.first['type'], 'function');
    expect(tools.first.containsKey('function'), isFalse);
    expect(tools.first.containsKey('name'), isTrue);
  });

  test('Agent Lv.1 强制开启思考 / 搜索：忽略用户已保存的 Chat 每轮选项', () async {
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
        rounds: stack.repos.rounds,
        books: stack.repos.books,
        aiService: AiService(
          client: MockClient((_) async => sse(story5Lines())),
        ),
        aiSettingsProvider: settings,
        experimentalSettings: experimental,
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');
      return (await provider.previewRequestBody(
        intent: RoundSendIntent.newRound(userInput: '第一章'),
        book: book,
      )).firstFrame;
    }

    // Agent 开：思考照旧发送（不再被用户选项关掉），联网工具同批注入。
    final agentBody = await previewWith(AgentModeSettings());
    expect(agentBody.containsKey('tools'), isTrue);
    expect(
      (agentBody['tools'] as List).cast<Map<String, dynamic>>().map(
        (t) => t['name'],
      ),
      contains('narrchat_webSearch'),
    );
    // DeepSeek 思考模式默认开启（默认 high）；`none` = 关闭。
    expect('${agentBody['reasoning']}', isNot(contains('none')));
    // 联网随 Agent 强制开启：system **不再**追加联网指令，调用指导
    //（搜索 → 必须打开页面）随工具 description 下发。
    expect('${agentBody['instructions']}', isNot(contains('【联网搜索】')));
    final searchSchema = (agentBody['tools'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((t) => t['name'] == 'narrchat_webSearch');
    expect('${searchSchema['description']}', contains('narrchat_webFetchPage'));

    // Agent 关：用户的 Chat 选项原样生效（思考关闭 + 无搜索工具）。
    final chatBody = await previewWith(ExperimentalSettingsProvider());
    expect(chatBody.containsKey('tools'), isFalse);
    expect((chatBody['reasoning'] as Map)['effort'], 'none');
    expect(chatBody.containsKey('reasoning_effort'), isFalse);
  });

  // ---------------------------------------------------------------------------
  // 帧会话 / 兼容降级
  // ---------------------------------------------------------------------------

  test('AGENT Lv.1 思考块回传：同一回合调两个工具 → 下一回合每调用各配一块（真实 400 复现）', () async {
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        if (idx == 1) {
          // 回合 1：模型先思考，**同一回合调两个工具**（读取器 + 历史编辑器）——
          // 这正是线上 400 的那一回合（服务端按「每个 function_call 一块思考」
          // 逐块校验，只回传一块即整次被拒）。编辑器在第一步被拒绝，但调用条目
          // 与思考块照常回传，正好验证逐块配对。
          return sse([
            ...reasoningLines(
              'rs_r1',
              'Need the history and a memory entry first.',
            ),
            ...readLines('fc_1', 'narrchat_readHistory'),
            ...editLines('fc_2', AgentStateSection.memorySummary, [
              {'op': 'append', 'newLine': memoryEntry},
            ]),
            completed('resp_1'),
            '',
          ]);
        }
        if (idx == 2) {
          // 调研第二回合：只回文本（无工具）→ 调研结束，进入正文。
          return sse(textOnlyLines(''));
        }
        if (idx == 3) {
          // 正文回合。
          return sse(textOnlyLines(story5));
        }
        // 维护回合：落记忆条目。
        return sse([
          ...editLines('fc_3', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': memoryEntry},
          ]),
          completed('resp_3'),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '继续', book: book), isTrue);
    expect(capturedBodies, hasLength(4));

    final input1 = (capturedBodies[0]['input'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      input1.any((i) => i['type'] == 'reasoning'),
      isFalse,
      reason: '首回合还没有思考块',
    );

    // 下一回合：每个 function_call 紧邻其前各有一块非空 reasoning
    //（缺失 → HTTP 400「reasoning_text in the thinking mode must be passed back」）。
    final input2 = (capturedBodies[1]['input'] as List)
        .cast<Map<String, dynamic>>();
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
          'text': 'Need the history and a memory entry first.',
        },
      ]);
    }
  });

  test('AGENT Lv.1 兼容降级重发：拒绝 previous_response_id 的 400 探测回合**不计失败轮**、不计 token，RAW 写明 HTTP 码', () async {
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        final input = (body['input'] as List).cast<Map<String, dynamic>>();
        final lastUser = input.lastWhere((i) => i['role'] == 'user')['content'];
        final isMaintenance = '$lastUser'.startsWith(
          '[State-maintenance turn]',
        );
        // 该兼容实现不支持有状态续接：带 `previous_response_id` 的维护回合被拒
        //（HTTP 400）；执行器就地丢弃续接基点、同一回合全量重发。
        if (body.containsKey('previous_response_id') && isMaintenance) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
              'error': {
                'message': 'Unsupported parameter: previous_response_id',
              },
              }),
            ),
            400,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (bodies.length == 1) {
          // 调研回合：读一次历史（首回合没有续接基点）。
          return sse([
            ...readLines('r1', 'narrchat_readHistory'),
            completed('resp_r', input: 1, output: 1),
            '',
          ]);
        }
        if ('$lastUser'.startsWith('【正文回合】')) {
          // 正文回合（有状态续接）→ 5 区块正文。
          return sse([
            textDelta(story5),
            completed('resp_s', input: 12, output: 5),
            '',
          ]);
        }
        // 维护回合：本轮条目落地（续接被拒后的全量重发也走这条）。
        return sse([
          ...editLines('h1', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': memoryEntry},
          ]),
          completed('resp_m', input: 2, output: 2),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: _ChainingSettings(),
      experimentalSettings: AgentModeSettings(compressNonBodyReasoning: false),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '第一章', book: book), isTrue);

    // 四次底层请求：调研回合（首帧）→ 正文回合续接（带 previous_response_id）→
    // 维护回合续接（被 400 拒绝）→ 同一维护回合全量重发（不带续接基点、重新带上前缀）。
    expect(bodies, hasLength(4));
    expect(bodies[0].containsKey('previous_response_id'), isFalse);
    expect(bodies[1]['previous_response_id'], 'resp_r');
    expect(bodies[1].containsKey('tools'), isFalse, reason: '续接回合不重发前缀');
    expect(bodies[2]['previous_response_id'], 'resp_s');
    expect(bodies[3].containsKey('previous_response_id'), isFalse);
    expect(bodies[3]['tools'], bodies[0]['tools'], reason: '重发回落到全量前缀');
    // 重发的是**同一回合**的内容：续接回合只带的新增项原样落在「全量重发」的末尾
    //（不重跑调研回合、不追加额外指令）。
    final chainedInput = (bodies[2]['input'] as List).cast<Object>();
    final fullInput = (bodies[3]['input'] as List).cast<Object>();
    expect(fullInput.length, greaterThan(chainedInput.length));
    expect(
      fullInput.sublist(fullInput.length - chainedInput.length),
      chainedInput,
    );
    // 思考强度全帧沿用用户设置：降级不改写强度。
    expect(bodies.map((b) => jsonEncode(b['reasoning'])).toSet(), hasLength(1));
    expect(jsonDecode(jsonEncode(bodies[0]['reasoning'])), {'effort': 'high'});

    // 本轮照常成功落库（正文 + 记忆齐备），且**没有被记为失败**：
    final round = (await stack.repos.rounds.loadChain('b1')).rounds
        .firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(round.memorySummary, memoryEntry);
    expect(
      (await stack.repos.rounds.loadChain('b1')).rounds.where((r) => r.isError),
      isEmpty,
      reason: '不产生失败代',
    );
    expect(provider.retryStatus, isNull, reason: '不触发「错误重连……」重试提示');
    expect(provider.roundWarningsFor(1), isEmpty, reason: '不产生常驻黄框');
    expect(provider.error, isNull);

    // **不计 token**：本轮用量只累加三次成功帧（1+2+12 / 1+2+5），
    // 被 400 拒绝的那次探测不产生 usage，也不计入本轮。
    expect(round.tokensIn, 15);
    expect(round.tokensOut, 8);

    // RAW：失败的那次探测保留下来并写明 HTTP 码与报错原文（可追溯）。
    final exchanges = provider.rawExchangesFor(round.uuid)!;
    expect(exchanges, hasLength(4));
    final failed = exchanges.where((e) => e.error.isNotEmpty).toList();
    expect(failed, hasLength(1), reason: '只有探测帧没有返回');
    expect(failed.single.error, contains('HTTP 400'));
    expect(failed.single.error, contains('previous_response_id'));
    // 它确实没有返回内容（三个块全空）——RAW 就是靠 error 说明原因。
    expect(failed.single.thinking, isEmpty);
    expect(failed.single.toolCalls, isEmpty);
    expect(failed.single.content, isEmpty);
    // 成功回合不受影响：正文回合的交换记录有返回内容。
    expect(exchanges.any((e) => e.content.contains('殿前风冷')), isTrue);
  });

  // ---------------------------------------------------------------------------
  // 第二步维护（必发；失败 / 截断）
  // ---------------------------------------------------------------------------

  test('AGENT Lv.1 维护回合请求体：思考强度与输出上限均沿用用户设置 + 不发 tool_choice', () async {
    final bodies = <Map<String, dynamic>>[];
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        calls++;
        if (calls == 1) {
          // 调研回合：读史一次。
          return sse([
            ...readLines('r1', 'narrchat_readHistory'),
            completed('resp_r'),
            '',
          ]);
        }
        if (calls == 2) {
          // 正文回合：5 区块正常产出。
          return sse(textOnlyLines(story5));
        }
        // 维护回合：补上本轮记忆条目。
        return sse([
          ...editLines('h1', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': memoryEntry},
          ]),
          completed('resp_m', input: 2, output: 2),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: _MaxTokensSettings(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '第一章', book: book), isTrue);
    // 调研 1 + 正文 1 + 维护 1 = 3 回合（维护每轮必发）。
    expect(bodies, hasLength(3));

    // 维护回合：只维护记忆总结；读过的历史在上下文里，重复读取会被拒。
    final maintenance =
        (bodies.last['input'] as List).cast<Map<String, dynamic>>().lastWhere(
              (i) => i['role'] == 'user',
            )['content']
            as String;
    expect(maintenance, startsWith('[State-maintenance turn]'));
    expect(maintenance, contains('只维护记忆总结'));
    expect(maintenance, contains('narrchat_editHistory'));
    expect(maintenance, isNot(contains('不输出任何文本')));
    expect(maintenance, contains('重复读取'));

    // 任何回合都不发送 tool_choice；思考强度 / 输出上限全回合完全一致
    //（程序不因步骤改写用户设置）。
    expect(bodies.every((b) => !b.containsKey('tool_choice')), isTrue);
    expect(bodies.map((b) => jsonEncode(b['reasoning'])).toSet(), hasLength(1));
    expect(jsonDecode(jsonEncode(bodies.first['reasoning'])), {
      'effort': 'high',
    });
    expect(bodies.first['max_output_tokens'], 4096);
    expect(bodies.map((b) => b['max_output_tokens']).toSet(), {
      4096,
    }, reason: '维护回合不得改写用户设置的输出上限');
    // 各步共用同一 instructions / tools（前缀缓存依赖此）。
    for (final b in bodies.skip(1)) {
      expect(b['instructions'], bodies.first['instructions']);
      expect(jsonEncode(b['tools']), jsonEncode(bodies.first['tools']));
    }

    // 维护补齐后本轮记忆落地、正文照常落库，且没有常驻警告。
    final round = (await stack.repos.rounds.loadChain('b1')).rounds
        .firstWhere((r) => r.roundIndex == 1);
    expect(round.memorySummary, memoryEntry);
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(provider.agentWarnings, isEmpty);
  });

  test('AGENT Lv.1 维护回合截断：提示用户调高「最大 token」，但请求体上限始终沿用用户设置', () async {
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
        if (calls == 1) {
          return sse([
            ...readLines('r1', 'narrchat_readHistory'),
            completed('resp_r'),
            '',
          ]);
        }
        if (calls == 2) return sse(textOnlyLines(story5));
        // 维护 4 回合：前 3 回合空手文本，第 4 回合被截断（本轮最后一回合 →
        // 截断提示 + 缺项警告同时出现）。
        return sse(calls == 6 ? truncatedLines : textOnlyLines('维护回合空手。'));
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: _MaxTokensSettings(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '第一章', book: book), isTrue);
    expect(bodies, hasLength(6)); // 1 调研 + 1 正文 + 4 维护
    // 截断不再让整轮失败：正文照常落库 + 黄框给出可操作提示。
    expect(
      bodies[1].containsKey('tool_choice'),
      isFalse,
      reason: '维护回合同样不发 tool_choice',
    );
    expect(
      provider.roundWarningsFor(1).any((w) => w.contains('最大 token')),
      isTrue,
    );

    // 全部帧的 max_output_tokens 都等于**用户设置**的值：程序不因截断擅自
    // 抬高上限。
    expect(bodies.first['max_output_tokens'], 4096);
    for (final b in bodies.skip(1)) {
      expect(b['max_output_tokens'], 4096);
    }
    final round = (await stack.repos.rounds.loadChain('b1')).rounds
        .firstWhere((r) => r.roundIndex == 1);
    expect(round.isError, isFalse);
    expect(round.aiNarrative, contains('殿前风冷'));
  });

  // ---------------------------------------------------------------------------
  // 常驻警告 / 空正文失败
  // ---------------------------------------------------------------------------

  test('AGENT Lv.1 记忆未落地 → 警告常驻该轮（随代落库），删除该轮一并清除', () async {
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async {
        calls++;
        // 每回合都只回文本：调研 1 回合、正文 1 回合、维护 4 回合；
        // 记忆条目始终没落地 → 缺项转常驻警告。
        return sse(textOnlyLines(story5));
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');
    expect(await provider.sendRound(userInput: '开始', book: book), isTrue);
    expect(calls, 6);

    final round = (await stack.repos.rounds.loadChain('b1')).rounds
        .firstWhere((r) => r.roundIndex == 1);
    // Lv.1 只有历史栏目经工具维护：世界 / 角色 / 时间都属正文，不参与缺项。
    expect(provider.roundWarningsFor(1), contains('记忆总结本轮未更新'));
    expect(provider.roundWarningsFor(1), isNot(contains('世界状态本轮未更新')));
    expect(provider.roundWarningsFor(1), isNot(contains('角色状态本轮未更新')));
    expect(provider.roundWarningsFor(1), isNot(contains('当前时间')));
    // 提示不是内容：正文照常落库，警告单独挂在这一代上。
    expect(round.aiNarrative, contains('殿前风冷'));

    // 删除该轮（含「重生成此轮 / 修改提问」的前置删除）→ 警告一并消失。
    await provider.deleteRound(round, deleteFollowing: true);
    expect(provider.roundWarningsFor(1), isEmpty);

    // 重新生成同一轮 → 警告重新挂上；没有关闭入口，重新加载后仍在。
    expect(await provider.sendRound(userInput: '开始', book: book), isTrue);
    expect(provider.roundWarningsFor(1), isNotEmpty);
    await provider.loadRounds('b1');
    expect(provider.roundWarningsFor(1), isNotEmpty, reason: '提示随代落库，不是本地副本');
  });

  test('AGENT Lv.1 空正文轮：不写库、失败条目保留输入 + 提示说明状态作废', () async {
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async {
        calls++;
        if (calls == 2) {
          // 调研结束后尝试提前写记忆（第一步会被拒绝）……
          return sse([
            ...editLines('h1', AgentStateSection.memorySummary, [
              {'op': 'append', 'newLine': memoryEntry},
            ]),
            completed('resp_h'),
            '',
          ]);
        }
        // ……其余每个回合只有读取器、从不产出正文 → 正文步耗尽 → 本轮判失败。
        return sse([
          ...readLines('r$calls', 'narrchat_readHistory'),
          completed('resp_r'),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '只调工具', book: book), isFalse);
    // 方案 A：失败也是链上一条真轮次（红条 + 可一键重试），不再有独立失败条目。
    final failedChain = await stack.repos.rounds.loadChain('b1');
    expect(failedChain.rounds, hasLength(1), reason: '只落一条错误代，不写半截正文');
    final failure = failedChain.rounds.single;
    expect(failure.isError, isTrue);
    expect(failure.userInput, '只调工具');
    expect(failure.roundIndex, 1);
    // 提示挂在错误代上：失败原因与过程警告合并成同一条提示。
    expect(
      provider.roundWarningsFor(1).join(),
      contains('本轮未产出正文（模型只返回了工具调用），本轮的状态改动已作废。'),
    );
    // 清除失败条目 → 链尾错误代被删除。
    await provider.clearFailedAttempt();
    expect((await stack.repos.rounds.loadChain('b1')).rounds, isEmpty);
  });

  test('子模型：维护步请求改模型，主 / 子统计分桶落库', () async {
    final captured = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        captured.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = captured.length;
        if (idx == 1) {
          return sse([
            ...readLines('r1', 'narrchat_readHistory'),
            completed('resp_r'),
            '',
          ]);
        }
        if (idx == 2) {
          return sse([textDelta(story5), completed('resp_s'), '']);
        }
        return sse([
          ...editLines('h1', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': '- 第1轮｜日期：第二天 辰时｜殿前递帖'},
          ]),
          completed('resp_h', input: 2, output: 3, cached: 1),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(
        subagentPlatformId: AiPlatforms.deepseekPlatformId,
        subagentModelId: 'deepseek-v4-pro',
        subagentReasoningEffort: 'low',
      ),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '走向主殿', book: book), isTrue);

    expect(captured, hasLength(3));
    expect(captured[0]['model'], 'deepseek-flash', reason: '调研用主模型');
    expect(captured[1]['model'], 'deepseek-flash', reason: '正文用主模型');
    expect(captured[2]['model'], 'deepseek-v4-pro', reason: '维护用子模型');
    expect(
      captured[2]['reasoning'],
      {'effort': 'low'},
      reason: '维护步用子模型选择器记住的思考强度',
    );

    final round = (await stack.repos.rounds.loadChain('b1')).rounds.single;
    expect(round.modelName, 'deepseek-flash');
    expect(round.hasSubagent, isTrue);
    expect(round.subagentModelName, 'deepseek-v4-pro');
    // 主：调研 1/1 + 正文 1/1；子：维护 2/3（缓存 1）。主模型两帧都没带回缓存字段。
    expect(round.tokensIn, 2);
    expect(round.tokensOut, 2);
    expect(round.cachedTokensIn, isNull);
    expect(round.subagentTokensIn, 2);
    expect(round.subagentTokensOut, 3);
    expect(round.subagentCachedTokensIn, 1);
    expect(provider.roundWarningsFor(1), isEmpty);
  });

  test('子模型跨平台 / 跨协议：维护步改走子平台 Chat 线路与子平台 Key', () async {
    final captured = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        captured.add(body);
        if (request.url.path.endsWith('/responses')) {
          final idx = captured.length;
          if (idx == 1) {
            return sse([
              ...readLines('r1', 'narrchat_readHistory'),
              completed('resp_r'),
              '',
            ]);
          }
          return sse([textDelta(story5), completed('resp_s'), '']);
        }
        // 子平台：Chat 非流式（模型能力里 supportsStreaming=false）。
        expect(request.url.host, 'sub.example.com');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': '',
                  'tool_calls': [
                    {
                      'id': 'h1',
                      'type': 'function',
                      'function': {
                        'name': agentEditToolName(
                          AgentStateSection.memorySummary,
                        ),
                        'arguments': jsonEncode({
                          'edits': [
                            {'op': 'append', 'newLine': '- 第1轮｜日期：第二天 辰时｜殿前递帖'},
                          ],
                        }),
                      },
                    },
                  ],
                },
              },
            ],
            'usage': {
              'prompt_tokens': 2,
              'completion_tokens': 3,
              'prompt_tokens_details': {'cached_tokens': 1},
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: _CrossPlatformSettings(),
      experimentalSettings: AgentModeSettings(
        subagentPlatformId: _CrossPlatformSettings.subPlatformId,
        subagentModelId: 'cheap-model',
      ),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '走向主殿', book: book), isTrue);

    expect(captured, hasLength(3));
    expect(captured[0]['model'], 'main-model');
    expect(captured[1]['model'], 'main-model');
    expect(captured[2]['model'], 'cheap-model');
    // 主平台 Responses 用 input；子平台 Chat 用 messages，且明确 stream=false。
    expect(captured[0].containsKey('input'), isTrue);
    expect(captured[2].containsKey('messages'), isTrue);
    expect(captured[2].containsKey('input'), isFalse);
    expect(captured[2]['stream'], isFalse);

    final round = (await stack.repos.rounds.loadChain('b1')).rounds.single;
    expect(round.modelName, 'main-model');
    expect(round.subagentModelName, 'cheap-model');
    expect(round.tokensIn, 2);
    expect(round.tokensOut, 2);
    expect(round.subagentTokensIn, 2);
    expect(round.subagentTokensOut, 3);
    expect(round.subagentCachedTokensIn, 1);
    expect(provider.roundWarningsFor(1), isEmpty);
  });

  test('子模型与主模型相同：折叠为未启用，不发子请求且统计全归主模型', () async {
    final captured = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        captured.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = captured.length;
        if (idx == 1) {
          return sse([
            ...readLines('r1', 'narrchat_readHistory'),
            completed('resp_r'),
            '',
          ]);
        }
        if (idx == 2) {
          return sse([textDelta(story5), completed('resp_s'), '']);
        }
        return sse([
          ...editLines('h1', AgentStateSection.memorySummary, [
            {'op': 'append', 'newLine': '- 第1轮｜日期：第二天 辰时｜殿前递帖'},
          ]),
          completed('resp_h', input: 2, output: 3, cached: 1),
          '',
        ]);
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      experimentalSettings: AgentModeSettings(
        subagentPlatformId: AiPlatforms.deepseekPlatformId,
        subagentModelId: AiPlatforms.defaultModelId,
      ),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '走向主殿', book: book), isTrue);

    expect(captured, hasLength(3));
    expect(captured.map((body) => body['model']).toSet(), {
      'deepseek-flash',
    }, reason: '与主模型相同 → 不切子模型');
    final round = (await stack.repos.rounds.loadChain('b1')).rounds.single;
    expect(round.hasSubagent, isFalse);
    expect(round.subagentModelName, isEmpty);
    expect(round.subagentTokensIn, isNull);
    expect(round.subagentTokensOut, isNull);
    expect(round.subagentCachedTokensIn, isNull);
    // 全部步归主模型：调研 1/1 + 正文 1/1 + 维护 2/3。
    expect(round.tokensIn, 4);
    expect(round.tokensOut, 5);
    expect(round.cachedTokensIn, 1);
  });
}

/// Response 线路 + **开启有状态续接**（`previous_response_id`）的设置替身。
///
/// 供「续接被服务商拒绝 → 同一回合全量重发」的兼容降级用例复用（默认平台
/// `supportsResponseChaining = false`，不续接就测不到这条降级）。
class _ChainingSettings extends AiSettingsProvider {
  @override
  AiPlatform get selectedPlatform =>
      AiPlatforms.defaultPlatform.copyWith(supportsResponseChaining: true);
}

/// 固定输出上限（[AiSettingsProvider.maxTokens] = 4096）的设置替身。
///
/// 供「维护回合不改写用户设置的输出上限」用例使用（内置默认模型未配
/// `maxTokens`，不注入就看不出程序有没有擅自改写）。
class _MaxTokensSettings extends AiSettingsProvider {
  @override
  AiModel get selectedModel => super.selectedModel.copyWith(maxTokens: 4096);
}

/// 主平台 Responses + 子平台 Chat 的双平台设置替身。
///
/// 用来验证子模型「跨平台 / 跨协议」时：baseUrl / API Key / 请求体形态
/// （input vs messages）与流式能力都取子平台自己的配置。
class _CrossPlatformSettings extends AiSettingsProvider {
  static const String mainPlatformId = 'main-platform';
  static const String subPlatformId = 'sub-platform';

  static const AiPlatform _mainPlatform = AiPlatform(
    id: mainPlatformId,
    displayName: '主平台',
    apiType: ApiType.openAiResponses,
    baseUrl: 'https://main.example.com/v1',
    models: [
      AiModel(
        id: 'main-model',
        supportsStreaming: true,
        supportsThinking: true,
        supportsSearch: true,
      ),
    ],
  );

  static const AiPlatform _subPlatform = AiPlatform(
    id: subPlatformId,
    displayName: '子平台',
    apiType: ApiType.openAiCompatible,
    baseUrl: 'https://sub.example.com/v1',
    models: [
      AiModel(
        id: 'cheap-model',
        supportsStreaming: false,
        supportsThinking: false,
        supportsSearch: false,
      ),
    ],
  );

  @override
  List<AiPlatform> get platforms => const [_mainPlatform, _subPlatform];

  @override
  AiPlatform get selectedPlatform => _mainPlatform;

  @override
  String get selectedPlatformId => mainPlatformId;

  @override
  String get selectedModelId => 'main-model';

  @override
  AiModel get selectedModel => _mainPlatform.models.first;

  @override
  String get model => 'main-model';

  @override
  String get baseUrl => 'https://main.example.com/v1';

  @override
  String get apiKey => 'main-key';

  @override
  String apiKeyFor(String platformId) =>
      platformId == subPlatformId ? 'sub-key' : 'main-key';
}
