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
/// 两阶段执行器在 Chat 通道运行——帧转为合法的 Chat messages
/// （assistant 携带 tool_calls、工具结果以 role:tool 回传），
/// 无 instructions / previous_response_id，tool_choice 被拒时就地降级。
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

    // 第 1 帧：Chat 线路请求体（messages + 嵌套工具 schema + tool_choice），
    // 无 instructions / input / previous_response_id。
    final body1 = bodies.first;
    expect(body1.containsKey('messages'), isTrue);
    expect(body1.containsKey('input'), isFalse);
    expect(body1.containsKey('instructions'), isFalse);
    expect(body1['tool_choice'], 'auto');
    final messages1 = (body1['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages1.first['role'], 'system');
    expect((messages1.first['content'] as String?), contains('【AGENT 模式契约】'));
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

    // 第 2 帧（维护轮）：required + 帧会话转为 chat 消息（tool_calls / role:tool）。
    final body2 = bodies[1];
    expect(body2['tool_choice'], 'required');
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
    expect((directive['content'] as String?), contains('narrchat_readWorldState'));
    expect((directive['content'] as String?), contains('narrchat_editHistory'));

    // 落库：状态来自工作副本合并（工具落地），正文为标题帧内容。
    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('主角踏门而入'));
    expect(round.worldState, '- 地点：青云宗');
    expect(round.characterState, contains('气血：100'));
    expect(round.memorySummary, contains('第1轮'));
    expect(provider.rawExchangesFor(round.id!), hasLength(2));
  });

  test('Agent Lv.1 开 + Chat 协议：正文 5 区块 + 仅历史工具（世界/角色取自正文）', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = bodies.length;
        if (idx == 1) {
          // 正文轮：5 区块（世界 / 角色随正文携带；正文不含记忆区块）。
          return sse(
            chatFrame(
              content: '## 剧情演绎\n殿前风冷。\n\n## 推荐行动\n递上名帖\n\n'
                  '## 当前时间\n第二天 辰时\n\n## 世界状态\n- 地点：青云宗主殿\n\n'
                  '## 角色状态\n## 林远\n- 气血：60',
            ),
          );
        }
        // 维护轮（每轮必发）：补本轮历史条目。
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
    expect(bodies, hasLength(2), reason: 'Lv.1 维护轮每轮必发');

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
    final system = (bodies.first['messages'] as List).first as Map<String, dynamic>;
    expect('${system['content']}', contains('完整输出以下 5 个二级标题'));
    expect('${system['content']}', contains('narrchat_readHistory'));

    // 落库：世界 / 角色 / 时间来自正文文本，历史来自工具落地。
    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('殿前风冷'));
    expect(round.worldState, '- 地点：青云宗主殿');
    expect(round.characterState, contains('- 气血：60'));
    expect(round.currentTime, '第二天 辰时');
    expect(round.memorySummary, '- 第1轮｜日期：第二天 辰时｜殿前递帖');
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
    expect(body['tool_choice'], 'auto');
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

  test('Agent 开 + Chat 协议：tool_choice 被拒 → 就地降级重发同一帧', () async {
    final dao = FakeRoundDao();
    final bodies = <Map<String, dynamic>>[];
    final ai = AiService(
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final idx = bodies.length;
        if (idx == 1) {
          // 协议类 4xx：拒绝 tool_choice（运行中降级，不烧帧预算）。
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'error': {'message': 'tool_choice 参数不受支持'},
            })),
            400,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return sse(
          idx == 2
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
    expect(bodies[0]['tool_choice'], 'auto');
    expect(bodies[1].containsKey('tool_choice'), isFalse,
        reason: 'tool_choice 被拒后同一帧重发不再携带该字段');
    expect(bodies[2].containsKey('tool_choice'), isFalse);

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('正文。'));
  });
}
