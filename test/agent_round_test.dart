import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/models/book.dart';
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
/// **三段流程**（调研 → 记忆 → 正文；无联网时恰好 3 次请求），以及该流程下的
/// 通用行为——预览首帧 = 调研帧、强制思考 / 搜索、思考块回传、兼容降级重发、
/// 维护帧请求体 / 截断、警告常驻、空正文失败。
///
/// 维护轮（[AgentStage.state]）只在记忆没落地 / 校验失败 / 截断时兜底，
/// 合规流程下**零额外请求**。
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

  /// 一帧内的一块思考（`output_item.added` + 文本增量）。
  List<String> reasoningLines(String id, String text) => [
        'data: ${jsonEncode({
              'type': 'response.output_item.added',
              'item': {'type': 'reasoning', 'id': id},
            })}',
        'data: ${jsonEncode({
              'type': 'response.reasoning_text.delta',
              'item_id': id,
              'delta': text,
            })}',
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
  ) =>
      [
        callAdded(id, agentEditToolName(section)),
        callArgs(id, {'edits': edits}),
      ];

  /// 只回文本的帧（标题帧 / 空手帧）。
  List<String> textOnlyLines(String narrative) => [
        textDelta(narrative),
        completed('resp_s', input: 1, output: 1),
        '',
      ];

  /// Lv.1 正文帧的 5 区块正文（世界 / 角色 / 时间随正文携带，无记忆区块）。
  const String story5 =
      '## 剧情演绎\n殿前风冷。\n\n## 推荐行动\n递上名帖\n\n'
      '## 当前时间\n第二天 辰时\n\n## 世界状态\n- 地点：青云宗主殿\n\n'
      '## 角色状态\n## 林远\n- 气血：60';

  /// 只回 5 区块正文的帧（正文帧 / 空手帧的通用返回）。
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

  test('AGENT Lv.1：调研(读史) → 记忆(推演+先落条目) → 正文 5 区块；维护轮不再是每轮必发', () async {
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        if (idx == 1) {
          // 第 1 帧 = 调研阶段：读一次历史（只读 → 调研阶段立即结束）。
          return sse([
            ...readLines('r1', 'narrchat_readHistory'),
            completed('resp_r'),
            '',
          ]);
        }
        if (idx == 2) {
          // 第 2 帧 = 记忆阶段：同回合推演 + 本轮历史条目**先于正文**落地。
          return sse([
            ...editLines('h1', AgentStateSection.memorySummary, [
              {'op': 'append', 'newLine': '- 第1轮｜日期：第二天 辰时｜殿前递帖'},
            ]),
            completed('resp_h', input: 2, output: 2),
            '',
          ]);
        }
        // 第 3 帧 = 正文阶段：5 区块（世界 / 角色随正文携带，无记忆区块）。
        return sse(story5Lines());
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

    // 合规一轮 = 恰好 3 帧：调研（读史）→ 记忆（推演+落条目）→ 正文
    //（维护轮只作兜底，不再「每轮必发」；工具调用靠帧指令驱动，不发 tool_choice）。
    expect(capturedBodies, hasLength(3), reason: 'Lv.1 合规一轮 3 帧、零额外请求');
    expect(
      capturedBodies.every((b) => !b.containsKey('tool_choice')),
      isTrue,
    );
    // 思考强度全帧沿用用户设置：调研 / 记忆 / 正文三帧完全一致。
    expect(
      capturedBodies.map((b) => jsonEncode(b['reasoning'])).toSet(),
      hasLength(1),
    );
    expect(
      jsonDecode(jsonEncode(capturedBodies[0]['reasoning'])),
      {'effort': 'high'},
    );

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
    // instructions = Lv.1 的 5 区块契约 + 历史工具契约；三帧共用同一前缀
    //（服务商上下文缓存依赖此）。
    expect('${capturedBodies.first['instructions']}',
        contains('只输出 5 个二级标题'));
    expect('${capturedBodies.first['instructions']}',
        contains('narrchat_readHistory'));
    for (final b in capturedBodies.skip(1)) {
      expect(b['instructions'], capturedBodies.first['instructions']);
      expect(b['tools'], capturedBodies.first['tools']);
    }

    // 落库：世界 / 角色 / 时间来自正文文本，历史来自工具落地。
    final round = (await stack.repos.rounds.loadChain('b1'))
        .rounds
        .firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(round.aiNarrative, isNot(contains('本轮大纲')));
    expect(round.worldState, '- 地点：青云宗主殿');
    expect(round.characterState, contains('- 气血：60'));
    expect(round.currentTime, '第二天 辰时');
    expect(round.memorySummary, '- 第1轮｜日期：第二天 辰时｜殿前递帖');
    expect(provider.agentWarnings, isEmpty);
    expect(provider.rawExchangesFor(round.uuid), hasLength(3));
  });

  test('AGENT Lv.1 合规一轮不发维护请求：调研读史 → 推演+记忆 → 正文（RAW 3 帧）', () async {
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        if (idx == 1) {
          // 调研帧：读一次历史 → **本帧只调读取器 → 调研阶段立即结束**
          //（不再有「等模型收手」的中间帧，也就没有中途步复述大纲的机会）。
          return sse([
            ...readLines('fc_r', 'narrchat_readHistory'),
            completed('resp_r'),
            '',
          ]);
        }
        if (idx == 2) {
          // 记忆帧：推演剧情（思考通道）与落条目在**同一回合**完成。
          return sse([
            ...editLines('fc_m', AgentStateSection.memorySummary, [
              {'op': 'append', 'newLine': '- 第1轮｜日期：第二天 辰时｜殿前递帖'},
            ]),
            completed('resp_m'),
            '',
          ]);
        }
        // 正文帧：5 区块。
        return sse(story5Lines());
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

    // 调研 1 帧 + 记忆 1 帧 + 正文 1 帧 = **恰好 3 次请求**；没有维护请求。
    expect(capturedBodies, hasLength(3));
    // 调研帧指令：本阶段只做调研（不写大纲、文本通道零输出）。
    final prepareDirective = (capturedBodies.first['input'] as List)
        .cast<Map<String, dynamic>>()
        .lastWhere((i) => i['role'] == 'user')['content'] as String;
    expect(prepareDirective, startsWith('【调研回合】'));
    expect(prepareDirective, contains('不写大纲'));
    expect(prepareDirective, isNot(contains('把本轮大纲定下来')));
    expect(
      capturedBodies.every((b) => !b.containsKey('tool_choice')),
      isTrue,
      reason: 'Agent 帧一律不发 tool_choice',
    );
    for (final b in capturedBodies) {
      final input = (b['input'] as List).cast<Map<String, dynamic>>();
      expect(
        input.any((i) => '${i['content']}'.contains('[State-maintenance turn]')),
        isFalse,
        reason: '合规流程下 Lv.1 不应出现维护轮指令',
      );
    }

    final round = (await stack.repos.rounds.loadChain('b1'))
        .rounds
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

  test('AGENT Lv.1 预览请求体：首帧 = 调研帧（不是正文帧），工具只含历史两件 + 联网两件', () async {
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
    // 首帧 = 调研帧：末条是紧随用户输入之后的「【调研回合】」指令，
    // 不是正文帧（正文只在记忆阶段之后才可能出现）。
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
    expect(
      tools.map((t) => t['name']).toList(),
      [
        'narrchat_readHistory',
        'narrchat_editHistory',
        'narrchat_webSearch',
        'narrchat_webFetchPage',
      ],
      reason: '顺序即请求体 tools 数组顺序（前缀缓存依赖此）',
    );
    expect(tools.map((t) => t['name']), isNot(contains('narrchat_advanceTime')));
    // 后续候选帧：记忆 → 正文 → 维护（首帧之后才可能有正文帧）。
    expect(
      preview.subsequentFrames.map((f) => f.label).toList(),
      ['记忆帧', '正文帧', '维护帧'],
    );
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
      ))
          .firstFrame;
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

  test('AGENT Lv.1 思考块回传：同一帧调两个工具 → 下一帧每调用各配一块（真实 400 复现）', () async {
    final capturedBodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        capturedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = capturedBodies.length;
        if (idx == 1) {
          // 帧 1：模型先思考，**一帧同时调两个工具**（读取器 + 历史编辑器）——
          // 这正是线上 400 的那一帧（服务端按「每个 function_call 一块思考」
          // 逐块校验，只回传一块即整次被拒）。
          return sse([
            ...reasoningLines('rs_r1', 'Need the history and a memory entry first.'),
            ...readLines('fc_1', 'narrchat_readHistory'),
            ...editLines('fc_2', AgentStateSection.memorySummary, [
              {'op': 'append', 'newLine': memoryEntry},
            ]),
            completed('resp_1'),
            '',
          ]);
        }
        // 帧 2：只回文本（无工具）→ 调研阶段收手；帧 3 = 正文阶段。
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

    expect(await provider.sendRound(userInput: '继续', book: book), isTrue);
    expect(capturedBodies, hasLength(3));

    final input1 =
        (capturedBodies[0]['input'] as List).cast<Map<String, dynamic>>();
    expect(input1.any((i) => i['type'] == 'reasoning'), isFalse,
        reason: '首帧还没有思考块');

    // 下一帧：每个 function_call 紧邻其前各有一块非空 reasoning
    //（缺失 → HTTP 400「reasoning_text in the thinking mode must be passed back」）。
    final input2 =
        (capturedBodies[1]['input'] as List).cast<Map<String, dynamic>>();
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

  test('AGENT Lv.1 兼容降级重发：拒绝 previous_response_id 的 400 探测帧**不计失败轮**、不计 token，RAW 写明 HTTP 码', () async {
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        final inputText = jsonEncode(body['input']);
        // 该兼容实现不支持有状态续接：带 `previous_response_id` 的记忆帧被拒
        //（HTTP 400）；执行器就地丢弃续接基点、同一帧全量重发。
        if (body.containsKey('previous_response_id') &&
            inputText.contains('【记忆回合】')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'error': {
                'message': 'Unsupported parameter: previous_response_id',
              },
            })),
            400,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        final idx = bodies.length;
        if (idx == 1) {
          // 调研帧：读一次历史（首帧没有续接基点）。
          return sse([
            ...readLines('r1', 'narrchat_readHistory'),
            completed('resp_r', input: 1, output: 1),
            '',
          ]);
        }
        if (inputText.contains('【正文回合】')) {
          // 正文帧（有状态续接）→ 5 区块正文。
          return sse([
            textDelta(story5),
            completed('resp_s', input: 12, output: 5),
            '',
          ]);
        }
        // 记忆帧：本轮条目落地（续接被拒后的全量重发也走这条）。
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
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '第一章', book: book), isTrue);

    // 四次底层请求：调研帧（首帧）→ 记忆帧续接（带 previous_response_id，
    // 被 400 拒绝）→ 同一帧全量重发（不带续接基点、重新带上前缀）→ 正文帧续接。
    expect(bodies, hasLength(4));
    expect(bodies[0].containsKey('previous_response_id'), isFalse);
    expect(bodies[1]['previous_response_id'], 'resp_r');
    expect(bodies[1].containsKey('tools'), isFalse, reason: '续接帧不重发前缀');
    expect(bodies[2].containsKey('previous_response_id'), isFalse);
    expect(bodies[2]['tools'], bodies[0]['tools'],
        reason: '重发回落到全量前缀');
    // 重发的是**同一帧**的内容：续接帧只带的新增项原样落在「全量重发」的末尾
    //（不重跑调研帧、不追加额外指令）。
    final chainedInput = (bodies[1]['input'] as List).cast<Object>();
    final fullInput = (bodies[2]['input'] as List).cast<Object>();
    expect(fullInput.length, greaterThan(chainedInput.length));
    expect(
      fullInput.sublist(fullInput.length - chainedInput.length),
      chainedInput,
    );
    // 思考强度全帧沿用用户设置：降级不改写强度。
    expect(
      bodies.map((b) => jsonEncode(b['reasoning'])).toSet(),
      hasLength(1),
    );
    expect(
      jsonDecode(jsonEncode(bodies[0]['reasoning'])),
      {'effort': 'high'},
    );

    // 本轮照常成功落库（正文 + 记忆齐备），且**没有被记为失败**：
    final round = (await stack.repos.rounds.loadChain('b1'))
        .rounds
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
    // 成功帧不受影响：正文帧有返回内容。
    expect(exchanges.last.content, contains('殿前风冷'));
  });

  // ---------------------------------------------------------------------------
  // 维护轮兜底（记忆未落地 / 截断）
  // ---------------------------------------------------------------------------

  test('AGENT Lv.1 维护帧请求体：思考强度与输出上限均沿用用户设置 + 不发 tool_choice', () async {
    final bodies = <Map<String, dynamic>>[];
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        calls++;
        if (calls == 1) {
          // 调研帧：读史一次。
          return sse([
            ...readLines('r1', 'narrchat_readHistory'),
            completed('resp_r'),
            '',
          ]);
        }
        if (calls <= 4) {
          // 记忆帧 ×3：只回文本、不调编辑器 → 本轮条目始终没落地。
          return sse(textOnlyLines('本回合只汇报进度，不调工具。'));
        }
        if (calls == 5) {
          // 正文帧：5 区块正常产出（正文照常落库）。
          return sse(textOnlyLines(story5));
        }
        // 维护帧：补上本轮记忆条目。
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
    // 调研 1 + 记忆提醒 3 + 正文 1 + 维护 1 = 6 帧（维护轮只在记忆未落地时兜底）。
    expect(bodies, hasLength(6));
    // 前三帧记忆提醒：每帧都带「【记忆回合】」指令（条目仍未落地）。
    for (final b in bodies.sublist(1, 4)) {
      final input = (b['input'] as List).cast<Map<String, dynamic>>();
      expect(
        '${input.lastWhere((i) => i['role'] == 'user')['content']}',
        contains('【记忆回合】'),
      );
    }

    // 维护帧：不输出文本、只调历史编辑器；读取器已禁用（不重复读取）。
    final maintenance = (bodies.last['input'] as List)
        .cast<Map<String, dynamic>>()
        .lastWhere((i) => i['role'] == 'user')['content'] as String;
    expect(maintenance, contains('[State-maintenance turn]'));
    expect(maintenance, contains('不输出任何文本'));
    expect(maintenance, contains('已禁用'));
    expect(maintenance, contains('narrchat_editHistory'));

    // 任何帧都不发送 tool_choice；思考强度 / 输出上限全帧完全一致
    //（程序不因阶段改写用户设置）。
    expect(
      bodies.every((b) => !b.containsKey('tool_choice')),
      isTrue,
    );
    expect(
      bodies.map((b) => jsonEncode(b['reasoning'])).toSet(),
      hasLength(1),
    );
    expect(
      jsonDecode(jsonEncode(bodies.first['reasoning'])),
      {'effort': 'high'},
    );
    expect(bodies.first['max_output_tokens'], 4096);
    expect(
      bodies.map((b) => b['max_output_tokens']).toSet(),
      {4096},
      reason: '维护帧不得改写用户设置的输出上限',
    );
    // 各阶段共用同一 instructions / tools（前缀缓存依赖此）。
    for (final b in bodies.skip(1)) {
      expect(b['instructions'], bodies.first['instructions']);
      expect(jsonEncode(b['tools']), jsonEncode(bodies.first['tools']));
    }

    // 维护帧补齐后本轮记忆落地、正文照常落库，且没有常驻警告。
    final round = (await stack.repos.rounds.loadChain('b1'))
        .rounds
        .firstWhere((r) => r.roundIndex == 1);
    expect(round.memorySummary, memoryEntry);
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(provider.agentWarnings, isEmpty);
  });

  test('AGENT Lv.1 维护帧截断：提示用户调高「最大 token」，但请求体上限始终沿用用户设置', () async {
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
        if (calls <= 4) return sse(textOnlyLines('只回文本，记忆未落地。'));
        if (calls == 5) return sse(textOnlyLines(story5));
        // 维护轮 4 帧：前 3 帧空手文本，第 4 帧被截断（本轮最后一帧 →
        // 截断提示 + 缺项警告同时出现）。
        return sse(calls == 9 ? truncatedLines : textOnlyLines('维护回合空手。'));
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
    expect(bodies, hasLength(9)); // 1 调研 + 3 记忆 + 1 正文 + 4 维护
    // 截断不再让整轮失败：正文照常落库 + 黄框给出可操作提示。
    expect(bodies[1].containsKey('tool_choice'), isFalse,
        reason: '维护帧同样不发 tool_choice');
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
    final round = (await stack.repos.rounds.loadChain('b1'))
        .rounds
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
        // 每帧都只回文本：调研 1 帧、记忆 3 帧、正文 1 帧、维护 4 帧；
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
    expect(calls, 9);

    final round = (await stack.repos.rounds.loadChain('b1'))
        .rounds
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
          // 调研结束后先落记忆条目（记忆阶段闭环）……
          return sse([
            ...editLines('h1', AgentStateSection.memorySummary, [
              {'op': 'append', 'newLine': memoryEntry},
            ]),
            completed('resp_h'),
            '',
          ]);
        }
        // ……其余每帧只有读取器、从不产出正文 → 正文阶段耗尽 → 本轮判失败。
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
}

/// Response 线路 + **开启有状态续接**（`previous_response_id`）的设置替身。
///
/// 供「续接被服务商拒绝 → 同一帧全量重发」的兼容降级用例复用（默认平台
/// `supportsResponseChaining = false`，不续接就测不到这条降级）。
class _ChainingSettings extends AiSettingsProvider {
  @override
  AiPlatform get selectedPlatform =>
      AiPlatforms.defaultPlatform.copyWith(supportsResponseChaining: true);
}

/// 固定输出上限（[AiSettingsProvider.maxTokens] = 4096）的设置替身。
///
/// 供「维护帧不改写用户设置的输出上限」用例使用（内置默认模型未配
/// `maxTokens`，不注入就看不出程序有没有擅自改写）。
class _MaxTokensSettings extends AiSettingsProvider {
  @override
  AiModel get selectedModel => super.selectedModel.copyWith(maxTokens: 4096);
}
