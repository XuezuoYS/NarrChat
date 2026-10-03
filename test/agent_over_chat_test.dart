import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/fakes.dart';

/// Agent 档位（实验性功能）**开启** + Chat 兼容协议：
/// 分阶段执行器在 Chat 通道运行（Lv.2 = 正文 / 维护两阶段；
/// Lv.1 = 准备 → 记忆 → 正文）——帧转为合法的 Chat messages
/// （assistant 携带 tool_calls、工具结果以 role:tool 回传），
/// 无 instructions / previous_response_id / tool_choice，
/// 思考强度覆盖被拒时就地降级。
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

  /// Chat 流式消息：正文增量（可选）+ 若干状态编辑调用（可选）。
  List<String> chatFrame({
    String content = '',
    List<({String id, AgentStateSection section, String newLine})> tools =
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
                  'function': {
                    'name': agentEditToolName(tool.section),
                    'arguments': '',
                  },
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
                  'function': {
                    'arguments': jsonEncode({
                      'edits': [
                        {'op': 'append', 'newLine': tool.newLine},
                      ],
                    }),
                  },
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
      'data: ${jsonEncode({
        'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
      })}',
    );
    lines.add('data: [DONE]');
    lines.add('');
    return lines;
  }

  List<Map<String, dynamic>> toolSchemas(Map<String, dynamic> body) =>
      ((body['tools'] as List).cast<Map<String, dynamic>>())
          .map((t) => (t['function'] as Map).cast<String, dynamic>())
          .toList();

  test('Agent Lv.2 开 + Chat 协议：两阶段在 Chat 通道（frames 转 tool_calls/tool 消息）', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        expect(request.url.path, '/chat/completions');
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = bodies.length;
        if (idx == 1) {
          return sse(
            chatFrame(
              content: '## 剧情演绎\n主角踏门而入。\n\n## 推荐行动\n叩见掌门。\n\n## 当前时间\n第一天 午时',
              tools: const [
                (
                  id: 'call_1',
                  section: AgentStateSection.worldState,
                  newLine: '- 地点：青云宗',
                ),
              ],
            ),
          );
        }
        // 维护轮：角色 + 历史补齐（一次响应完成清单）。
        return sse(
          chatFrame(
            tools: const [
              (
                id: 'call_2',
                section: AgentStateSection.characterState,
                newLine: '# 主角\n## 林远\n- 气血：100',
              ),
              (
                id: 'call_3',
                section: AgentStateSection.memorySummary,
                newLine: '- 第1轮｜日期：第一天 午时｜入门',
              ),
            ],
          ),
        );
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      // Agent 档位开启 + Chat 兼容协议（全解耦组合）。
      aiSettingsProvider: ChatCompatibleSettings(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(
      await provider.sendRound(userInput: '第一章', book: book),
      isTrue,
    );
    expect(bodies, hasLength(2));

    // 第 1 帧：Chat 线路请求体（messages + 嵌套工具 schema），
    // 无 instructions / input / previous_response_id / tool_choice。
    final body1 = bodies.first;
    expect(body1.containsKey('messages'), isTrue);
    expect(body1.containsKey('input'), isFalse);
    expect(body1.containsKey('instructions'), isFalse);
    expect(body1.containsKey('tool_choice'), isFalse);
    final messages1 = (body1['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages1.first['role'], 'system');
    expect((messages1.first['content'] as String?), contains('这是 Agent 模式'));
    final tools = toolSchemas(body1);
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
    // 联网在 Agent 期间强制开启 → 搜索 / 打开页工具同批注入，
    // 但 system **不**追加联网指令（调用指导随工具 description 下发）。
    expect(
      tools.map((t) => t['name']),
      containsAll(['narrchat_webSearch', 'narrchat_webFetchPage']),
    );
    expect(
      (messages1.first['content'] as String?),
      isNot(contains('【联网搜索】')),
    );
    expect((body1['tools'] as List).first.containsKey('name'), isFalse,
        reason: 'Chat 线路为嵌套 function 形态');

    // 第 2 帧（维护轮）：帧会话转为 chat 消息（tool_calls / role:tool），
    // 同样不发 tool_choice。
    final body2 = bodies[1];
    expect(body2.containsKey('tool_choice'), isFalse);
    expect(body2.containsKey('previous_response_id'), isFalse);
    final messages2 = (body2['messages'] as List).cast<Map<String, dynamic>>();
    final assistant = messages2.firstWhere((m) => m['role'] == 'assistant');
    expect((assistant['tool_calls'] as List), hasLength(1));
    expect(((assistant['tool_calls'] as List).first as Map)['id'], 'call_1');
    final toolMsg = messages2.firstWhere((m) => m['role'] == 'tool');
    expect(toolMsg['tool_call_id'], 'call_1');
    expect((toolMsg['content'] as String?) ?? '', contains('已更新'));
    // 维护轮指令（EN + 中文，先读后编辑；工具名按栏目）。
    final directive = messages2.lastWhere(
      (m) =>
          m['role'] == 'user' &&
          (m['content'] as String? ?? '').contains('State-maintenance turn'),
    );
    expect((directive['content'] as String?), contains('读取器已禁用'));
    expect((directive['content'] as String?), contains('narrchat_editHistory'));

    // 落库：状态来自工作副本合并（工具落地），正文为标题帧内容。
    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('主角踏门而入'));
    expect(round.worldState, '- 地点：青云宗');
    expect(round.characterState, contains('气血：100'));
    expect(round.memorySummary, contains('第1轮'));
    expect(provider.rawExchangesFor(round.id!), hasLength(2));
  });

  test('Agent Lv.1 开 + Chat 协议：准备/记忆/正文三帧（仅历史工具，世界/角色取自正文）', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = bodies.length;
        if (idx == 1) {
          // 准备帧：只有本轮大纲、无工具调用 → 准备阶段闭环（文本不采纳）。
          return sse(
            chatFrame(content: '本轮大纲：主角走向主殿，结束时间 = 第二天 辰时。'),
          );
        }
        if (idx == 2) {
          // 记忆帧：本轮历史条目**先于正文**落地。
          return sse(
            chatFrame(
              tools: const [
                (
                  id: 'call_9',
                  section: AgentStateSection.memorySummary,
                  newLine: '- 第1轮｜日期：第二天 辰时｜殿前递帖',
                ),
              ],
            ),
          );
        }
        // 正文帧：5 区块（世界 / 角色随正文携带；正文不含记忆区块）。
        // 角色状态按新契约带 ```markdown 围栏（提取时剥离，落库为纯文本）。
        return sse(
          chatFrame(
            content: '## 剧情演绎\n殿前风冷。\n\n## 推荐行动\n递上名帖\n\n'
                '## 当前时间\n第二天 辰时\n\n## 世界状态\n- 地点：青云宗主殿\n\n'
                '## 角色状态\n```markdown\n## 林远\n- 气血：60\n```',
          ),
        );
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: ChatCompatibleSettings(),
      // Lv.1：仅历史工具 + 联网。
      experimentalSettings: AgentModeSettings(level: AgentModeLevel.lv1),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '走向主殿', book: book), isTrue);
    // 合规一轮 = 恰好 3 帧：准备 → 记忆 → 正文
    //（维护轮只作兜底，不再「每轮必发」；工具调用靠帧指令驱动）。
    expect(bodies, hasLength(3), reason: 'Lv.1 合规一轮 3 帧、零额外请求');
    expect(
      bodies.every((b) => !b.containsKey('tool_choice')),
      isTrue,
      reason: 'Agent 帧一律不发 tool_choice',
    );

    // Chat 线路形态：messages + 嵌套 function schema，无 instructions / input。
    expect(bodies.first.containsKey('messages'), isTrue);
    expect(bodies.first.containsKey('instructions'), isFalse);
    final tools = toolSchemas(bodies.first);
    expect(
      tools.map((t) => t['name']),
      containsAll([
        'narrchat_readHistory',
        'narrchat_editHistory',
        'narrchat_webSearch',
        'narrchat_webFetchPage',
      ]),
    );
    // 世界 / 角色不在 Lv.1 的工具集里。
    expect(tools.map((t) => t['name']),
        isNot(contains('narrchat_editWorldState')));
    expect(tools.map((t) => t['name']),
        isNot(contains('narrchat_readCharacterState')));
    expect((bodies.first['tools'] as List).first.containsKey('name'), isFalse,
        reason: 'Chat 线路为嵌套 function 形态');
    // 三帧共用同一 system / tools 前缀（服务商上下文缓存依赖此）。
    for (final b in bodies.skip(1)) {
      expect(jsonEncode(b['tools']), jsonEncode(bodies.first['tools']));
    }
    final system = (bodies.first['messages'] as List).first as Map<String, dynamic>;
    expect(system['role'], 'system');
    expect('${system['content']}', contains('只输出 5 个二级标题'));
    expect('${system['content']}', contains('narrchat_readHistory'));

    // 记忆帧的工具调用在 Chat 通道转为合法帧会话：assistant 携带 tool_calls、
    // 工具结果以 `role: tool` 回传（出现在**正文帧**（第 3 帧）的 messages 里）。
    final messages3 = (bodies[2]['messages'] as List).cast<Map<String, dynamic>>();
    final assistant = messages3.firstWhere(
      (m) => m['role'] == 'assistant' && m['tool_calls'] != null,
    );
    expect((assistant['tool_calls'] as List), hasLength(1));
    expect(((assistant['tool_calls'] as List).first as Map)['id'], 'call_9');
    final toolMsg = messages3.firstWhere((m) => m['role'] == 'tool');
    expect(toolMsg['tool_call_id'], 'call_9');
    expect((toolMsg['content'] as String?) ?? '', contains('已更新'));

    // 落库：世界 / 角色 / 时间来自正文文本，历史来自工具落地。
    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(round.aiNarrative, isNot(contains('本轮大纲')));
    expect(round.worldState, '- 地点：青云宗主殿');
    // 围栏在提取时已剥离：落库内容是纯文本（面板/编辑器不再看到围栏）。
    expect(round.characterState, '## 林远\n- 气血：60');
    expect(round.currentTime, '第二天 辰时');
    expect(round.memorySummary, '- 第1轮｜日期：第二天 辰时｜殿前递帖');
    expect(provider.agentWarnings, isEmpty);
    expect(provider.rawExchangesFor(round.id!), hasLength(3));
  });

  test('Agent 开 + Chat 协议：预览请求体为 Chat 形态（messages/tools），无指令字段', () async {
    final provider = RoundProvider(
      dao: FakeRoundDao(),
      bookDao: FakeBookDao(),
      aiService: AiService(client: MockClient((_) async => sse(['']))),
      aiSettingsProvider: ChatCompatibleSettings(),
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
    expect(body['messages'], isA<List>());
    expect(body.containsKey('instructions'), isFalse);
    expect(body.containsKey('tool_choice'), isFalse);
    expect(
      toolSchemas(body).map((t) => t['name']),
      containsAll([
        'narrchat_readWorldState',
        'narrchat_readCharacterState',
        'narrchat_readHistory',
        'narrchat_editWorldState',
        'narrchat_editCharacterState',
        'narrchat_editHistory',
      ]),
    );
  });

  test('Agent 开 + Chat 协议：维护帧思考强度覆盖被拒 → 就地降级重发同一帧', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    var served = 0;
    final ai = AiService(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        if (body['reasoning_effort'] == 'low') {
          // 协议类 4xx：拒绝维护帧的思考强度覆盖（运行中降级，不烧帧预算）。
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'error': {'message': 'reasoning_effort 参数不受支持'},
            })),
            400,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        served++;
        return sse(
          served == 1
              ? chatFrame(
                  content:
                      '## 剧情演绎\n正文。\n\n## 推荐行动\nx\n\n## 当前时间\n第一天 午时',
                  tools: const [
                    (
                      id: 'call_1',
                      section: AgentStateSection.worldState,
                      newLine: '- 地点：青云宗',
                    ),
                  ],
                )
              : chatFrame(
                  tools: const [
                    (
                      id: 'call_2',
                      section: AgentStateSection.characterState,
                      newLine: '# 主角\n## 林远\n- 气血：100',
                    ),
                    (
                      id: 'call_3',
                      section: AgentStateSection.memorySummary,
                      newLine: '- 第1轮｜日期：第一天 午时｜入门',
                    ),
                  ],
                ),
        );
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      aiSettingsProvider: ChatCompatibleSettings(),
      experimentalSettings: AgentModeSettings(),
      retryDelay: Duration.zero,
    );
    await provider.loadRounds('b1');

    final ok = await provider.sendRound(userInput: '第一章', book: book);
    expect(ok, isTrue, reason: provider.failedAttempt.errorMessage);
    // 3 次底层请求（1 次被拒 + 重发同一帧 + 维护轮），2 帧计数。
    expect(bodies, hasLength(3));
    expect(bodies[0]['reasoning_effort'], 'high');
    expect(bodies[1]['reasoning_effort'], 'low');
    expect(bodies[2]['reasoning_effort'], 'high',
        reason: '覆盖被拒后同一帧回落用户设置重发');
    expect(bodies[2]['messages'], bodies[1]['messages'],
        reason: '降级重发的是同一帧：messages 完全一致');
    // Chat 线路同样一律不发 tool_choice。
    expect(bodies.every((b) => !b.containsKey('tool_choice')), isTrue);

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('正文。'));
  });
}
