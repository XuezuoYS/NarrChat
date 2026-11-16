import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/round_send_intent.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/fakes.dart';

/// Agent 档位（实验性功能）**开启** + Chat 兼容协议：
/// Lv.1 两步执行器在 Chat 通道运行（调研 → 正文 → 维护）——回合转为合法的
/// Chat messages（assistant 携带 tool_calls、工具结果以 role:tool 回传），
/// 无 instructions / previous_response_id / tool_choice；工具集只有历史
/// 一读一写 + 联网两件；思考强度全帧沿用用户设置。
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

  String line(Map<String, dynamic> json) => 'data: ${jsonEncode(json)}';

  /// Chat 流式消息：正文增量（可选）+ 若干工具调用（可选）。
  List<String> chatFrame({
    String content = '',
    List<({String id, String name, Map<String, dynamic> args})> tools =
        const [],
  }) {
    final lines = <String>[];
    if (content.isNotEmpty) {
      lines.add(line({
        'choices': [
          {'delta': {'role': 'assistant', 'content': content}},
        ],
      }));
    }
    for (var i = 0; i < tools.length; i++) {
      final tool = tools[i];
      lines.add(line({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': i,
                  'id': tool.id,
                  'type': 'function',
                  'function': {'name': tool.name, 'arguments': ''},
                },
              ],
            },
          },
        ],
      }));
      lines.add(line({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': i,
                  'function': {'arguments': jsonEncode(tool.args)},
                },
              ],
            },
          },
        ],
      }));
    }
    lines.add(line({
      'choices': [
        {'delta': {}, 'finish_reason': tools.isEmpty ? 'stop' : 'tool_calls'},
      ],
    }));
    lines.add(
      line({
        'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
      }),
    );
    lines.add('data: [DONE]');
    lines.add('');
    return lines;
  }

  /// Lv.1 历史编辑器调用（记忆条目先于正文落地）。
  ({String id, String name, Map<String, dynamic> args}) editHistory(
    String id,
    String newLine,
  ) =>
      (
        id: id,
        name: 'narrchat_editHistory',
        args: {
          'edits': [
            {'op': 'append', 'newLine': newLine},
          ],
        },
      );

  /// Lv.1 历史读取器调用（调研阶段只读一次）。
  ({String id, String name, Map<String, dynamic> args}) readHistory(String id) =>
      (id: id, name: 'narrchat_readHistory', args: {'round': 1});

  List<Map<String, dynamic>> toolSchemas(Map<String, dynamic> body) =>
      ((body['tools'] as List).cast<Map<String, dynamic>>())
          .map((t) => (t['function'] as Map).cast<String, dynamic>())
          .toList();

  test('Agent Lv.1 开 + Chat 协议：调研/正文/维护三回合（仅历史工具，世界/角色取自正文）', () async {
    final stack = await TestStack.create();
    addTearDown(stack.dispose);
    await stack.seedBook(uuid: 'b1', title: '测试书');
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        expect(request.url.path, '/chat/completions');
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = bodies.length;
        if (idx == 1) {
          // 调研回合：读一次历史（只读 → 调研结束）。
          return sse(chatFrame(tools: [readHistory('call_r')]));
        }
        if (idx == 2) {
          // 正文回合：5 区块（世界 / 角色随正文携带；正文不含记忆区块）。
          // 角色状态按新契约带 ```markdown 围栏（提取时剥离，落库为纯文本）。
          return sse(
            chatFrame(
              content: '## 剧情演绎\n殿前风冷。\n\n## 推荐行动\n递上名帖\n\n'
                  '## 当前时间\n第二天 辰时\n\n## 世界状态\n- 地点：青云宗主殿\n\n'
                  '## 角色状态\n```markdown\n## 林远\n- 气血：60\n```',
            ),
          );
        }
        // 维护回合：正文完成后单独请求，只落本轮记忆条目。
        return sse(
          chatFrame(
            tools: [
              editHistory('call_9', '- 第1轮｜日期：第二天 辰时｜殿前递帖'),
            ],
          ),
        );
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: ChatCompatibleSettings(),
      // Lv.1：仅历史工具 + 联网。
      experimentalSettings: AgentModeSettings(level: AgentModeLevel.lv1),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '走向主殿', book: book), isTrue);
    // 合规一轮 = 恰好 3 回合：调研 → 正文 → 维护（维护每轮必发）。
    expect(bodies, hasLength(3), reason: 'Lv.1 合规一轮 3 回合');
    expect(
      bodies.every((b) => !b.containsKey('tool_choice')),
      isTrue,
      reason: 'Agent 回合一律不发 tool_choice',
    );

    // Chat 线路形态：messages + 嵌套 function schema，无 instructions / input。
    expect(bodies.first.containsKey('messages'), isTrue);
    expect(bodies.first.containsKey('instructions'), isFalse);
    final tools = toolSchemas(bodies.first);
    expect(
      tools.map((t) => t['name']).toList(),
      [
        'narrchat_readHistory',
        'narrchat_editHistory',
        'narrchat_webSearch',
        'narrchat_webFetchPage',
      ],
      reason: 'Lv.1 工具集 = 历史一读一写 + 联网两件（顺序稳定）',
    );
    // 世界 / 角色不在 Lv.1 的工具集里。
    expect(tools.map((t) => t['name']),
        isNot(contains('narrchat_editWorldState')));
    expect(tools.map((t) => t['name']),
        isNot(contains('narrchat_readCharacterState')));
    expect((bodies.first['tools'] as List).first.containsKey('name'), isFalse,
        reason: 'Chat 线路为嵌套 function 形态');
    // 三回合共用同一 system / tools 前缀（服务商上下文缓存依赖此）。
    for (final b in bodies.skip(1)) {
      expect(jsonEncode(b['tools']), jsonEncode(bodies.first['tools']));
    }
    final system =
        (bodies.first['messages'] as List).first as Map<String, dynamic>;
    expect(system['role'], 'system');
    expect('${system['content']}', contains('仅输出 5 个二级标题'));
    expect('${system['content']}', contains('narrchat_readHistory'));

    // 调研回合的工具调用在 Chat 通道转为合法会话：assistant 携带 tool_calls、
    // 工具结果以 `role: tool` 回传（出现在正文回合的 messages 里）。
    final storyMessages =
        (bodies[1]['messages'] as List).cast<Map<String, dynamic>>();
    final assistant = storyMessages.firstWhere(
      (m) => m['role'] == 'assistant' && m['tool_calls'] != null,
    );
    expect((assistant['tool_calls'] as List), hasLength(1));
    expect(((assistant['tool_calls'] as List).first as Map)['id'], 'call_r');
    final toolMsg = storyMessages.firstWhere((m) => m['role'] == 'tool');
    expect(toolMsg['tool_call_id'], 'call_r');
    expect((toolMsg['content'] as String?) ?? '', contains('NARRCHAT_STATE'));
    // 维护回合是独立请求，且带维护指令。
    final maintenanceMessages =
        (bodies[2]['messages'] as List).cast<Map<String, dynamic>>();
    expect(
      '${maintenanceMessages.last['content']}',
      startsWith('[State-maintenance turn]'),
    );

    // 落库：世界 / 角色 / 时间来自正文文本，历史来自维护工具落地。
    final round = (await stack.repos.rounds.loadChain('b1'))
        .rounds
        .firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(round.aiNarrative, isNot(contains('本轮大纲')));
    expect(round.worldState, '- 地点：青云宗主殿');
    // 围栏在提取时已剥离：落库内容是纯文本（面板/编辑器不再看到围栏）。
    expect(round.characterState, '## 林远\n- 气血：60');
    expect(round.currentTime, '第二天 辰时');
    expect(round.memorySummary, '- 第1轮｜日期：第二天 辰时｜殿前递帖');
    expect(provider.agentWarnings, isEmpty);
    expect(provider.rawExchangesFor(round.uuid), hasLength(3));
  });

  test('Agent Lv.1 开 + Chat 协议：预览首帧 = 调研帧（工具只含历史两件 + 联网两件）', () async {
    final stack = await TestStack.create();
    addTearDown(stack.dispose);
    await stack.seedBook(uuid: 'b1', title: '测试书');
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: AiService(client: MockClient((_) async => sse(['']))),
      aiSettingsProvider: ChatCompatibleSettings(),
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
    expect(body['messages'], isA<List>());
    expect(body.containsKey('instructions'), isFalse);
    expect(body.containsKey('tool_choice'), isFalse);
    // Lv.1 首回合 = 调研回合：末条是「【调研回合】」指令，不是正文回合。
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages.last['role'], 'user');
    expect('${messages.last['content']}', startsWith('【调研回合】'));
    expect(
      toolSchemas(body).map((t) => t['name']).toList(),
      [
        'narrchat_readHistory',
        'narrchat_editHistory',
        'narrchat_webSearch',
        'narrchat_webFetchPage',
      ],
    );
    expect(
      preview.subsequentFrames.map((f) => f.label).toList(),
      ['正文回合', '维护回合'],
    );
  });

  test('Agent Lv.1 开 + Chat 协议：思考强度全程沿用用户设置（调研/正文/维护一致）', () async {
    final stack = await TestStack.create();
    addTearDown(stack.dispose);
    await stack.seedBook(uuid: 'b1', title: '测试书');
    final bodies = <Map<String, dynamic>>[];
    var served = 0;
    final ai = AiService(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        served++;
        if (served == 1) {
          // 调研回合：读一次历史（只读 → 调研结束）。
          return sse(chatFrame(tools: [readHistory('call_r')]));
        }
        if (served == 2) {
          // 正文回合：5 区块。
          return sse(
            chatFrame(
              content: '## 剧情演绎\n正文。\n\n## 推荐行动\nx\n\n'
                  '## 当前时间\n第一天 午时\n\n## 世界状态\n- 地点：青云宗\n\n'
                  '## 角色状态\n## 林远\n- 气血：100',
            ),
          );
        }
        // 维护回合：历史条目落地。
        return sse(
          chatFrame(
            tools: [
              editHistory('call_m', '- 1 | 第一天 午时 | 入门'),
            ],
          ),
        );
      }),
    );
    final provider = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai,
      aiSettingsProvider: ChatCompatibleSettings(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final ok = await provider.sendRound(userInput: '第一章', book: book);
    expect(
      ok,
      isTrue,
      reason: provider.rounds
          .where((r) => r.isError)
          .map((r) => r.message)
          .join('；'),
    );
    // 3 回合（调研 / 正文 / 维护）：所有回合的思考强度**都**来自用户设置
    //（默认 high），执行器不为任何步覆盖。
    expect(bodies, hasLength(3));
    expect(
      bodies.map((b) => b['reasoning_effort']).toSet(),
      {'high'},
      reason: '任何回合都不覆盖用户设置的思考强度',
    );
    // Chat 线路每回合全量重发：会话只增不减。
    expect(
      (bodies[1]['messages'] as List).length,
      greaterThan((bodies[0]['messages'] as List).length),
    );
    expect(
      (bodies[2]['messages'] as List).length,
      greaterThan((bodies[1]['messages'] as List).length),
    );
    // Chat 线路同样一律不发 tool_choice。
    expect(bodies.every((b) => !b.containsKey('tool_choice')), isTrue);

    final round = (await stack.repos.rounds.loadChain('b1'))
        .rounds
        .firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('正文。'));
    expect(round.memorySummary, '- 1 | 第一天 午时 | 入门');
  });
}
