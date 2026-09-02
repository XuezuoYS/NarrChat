import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/fakes.dart';

/// Agent 模式（实验性开关）**开启** + Chat 兼容协议：
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

  /// Chat 流式消息：正文增量（可选）+ 一个状态工具调用（可选）。
  List<String> chatFrame({
    String content = '',
    ({String id, String section})? tool,
  }) {
    final lines = <String>[];
    if (content.isNotEmpty) {
      lines.add(line({
        'choices': [
          {'delta': {'role': 'assistant', 'content': content}},
        ],
      }));
    }
    if (tool != null) {
      lines.add(line({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': tool.id,
                  'type': 'function',
                  'function': {
                    'name': 'narrchat_editSection',
                    'arguments': '',
                  },
                },
              ],
            },
          },
        ],
      }));
      final arguments = jsonEncode({
        'section': tool.section,
        'edits': [
          {'op': 'append', 'newLine': '- 地点：青云宗'},
        ],
      });
      lines.add(line({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {'index': 0, 'function': {'arguments': arguments}},
              ],
            },
          },
        ],
      }));
    }
    lines.add(line({
      'choices': [
        {'delta': {}, 'finish_reason': tool == null ? 'stop' : 'tool_calls'},
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

  /// 状态轮帧：一次响应补齐「角色 + 记忆」两个栏目（清单完成）。
  List<String> stateToolsFrame() => [
        line({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_2',
                    'type': 'function',
                    'function': {
                      'name': 'narrchat_editSection',
                      'arguments': '',
                    },
                  },
                ],
              },
            },
          ],
        }),
        line({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {
                      'arguments': jsonEncode({
                        'section': 'characterState',
                        'edits': [
                          {
                            'op': 'append',
                            'newLine': '# 主角\n## 林远\n- 气血：100',
                          },
                        ],
                      }),
                    },
                  },
                ],
              },
            },
          ],
        }),
        line({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 1,
                    'id': 'call_3',
                    'type': 'function',
                    'function': {
                      'name': 'narrchat_editSection',
                      'arguments': '',
                    },
                  },
                ],
              },
            },
          ],
        }),
        line({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 1,
                    'function': {
                      'arguments': jsonEncode({
                        'section': 'memorySummary',
                        'edits': [
                          {
                            'op': 'append',
                            'newLine': '- 第1轮｜日期：第一天 午时｜入门',
                          },
                        ],
                      }),
                    },
                  },
                ],
              },
            },
          ],
        }),
        line({
          'choices': [
            {'delta': {}, 'finish_reason': 'tool_calls'},
          ],
        }),
        'data: ${jsonEncode({
          'usage': {'prompt_tokens': 2, 'completion_tokens': 2},
        })}',
        'data: [DONE]',
        '',
      ];

  test('Agent 开 + Chat 协议：两阶段在 Chat 通道（frames 转 tool_calls/tool 消息）', () async {
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
              tool: (id: 'call_1', section: 'worldState'),
            ),
          );
        }
        // 状态轮：角色 + 记忆补齐（一次响应完成清单）。
        return sse(stateToolsFrame());
      }),
    );
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(),
      aiService: ai,
      // Agent 实验性开关开启 + Chat 兼容协议（全解耦组合）。
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
    final tools = (body1['tools'] as List).cast<Map<String, dynamic>>();
    expect(
      tools.map((t) => (t['function'] as Map)['name']),
      containsAll(['narrchat_readState', 'narrchat_editSection']),
    );
    expect(tools.first.containsKey('name'), isFalse, reason: 'Chat 线路为嵌套 function 形态');

    // 第 2 帧（状态轮）：required + 帧会话转为 chat 消息（tool_calls / role:tool）。
    final body2 = bodies[1];
    expect(body2['tool_choice'], 'required');
    expect(body2.containsKey('previous_response_id'), isFalse);
    final messages2 = (body2['messages'] as List).cast<Map<String, dynamic>>();
    final assistant = messages2.firstWhere((m) => m['role'] == 'assistant');
    expect((assistant['tool_calls'] as List), hasLength(1));
    expect(
      ((assistant['tool_calls'] as List).first as Map)['id'],
      'call_1',
    );
    final toolMsg = messages2.firstWhere((m) => m['role'] == 'tool');
    expect(toolMsg['tool_call_id'], 'call_1');
    expect((toolMsg['content'] as String?) ?? '', contains('已更新'));
    // 状态轮指令（EN + 中文，先调 readState 后编辑）。
    final directive = messages2.lastWhere(
      (m) =>
          m['role'] == 'user' &&
          (m['content'] as String? ?? '').contains('State-maintenance turn'),
    );
    expect((directive['content'] as String?), contains('narrchat_readState'));

    // 落库：状态来自工作副本合并（工具落地），正文为标题帧内容。
    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('主角踏门而入'));
    expect(round.worldState, '- 地点：青云宗');
    expect(round.characterState, contains('气血：100'));
    expect(round.memorySummary, contains('第1轮'));
    expect(provider.rawExchangesFor(round.id!), hasLength(2));
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
    expect(body['model'], 'deepseek-v4-pro');
    expect(body['messages'], isA<List>());
    expect(body.containsKey('instructions'), isFalse);
    expect(body['tool_choice'], 'auto');
    final tools = (body['tools'] as List).cast<Map<String, dynamic>>();
    expect(
      tools.map((t) => (t['function'] as Map)['name']),
      containsAll(['narrchat_readState', 'narrchat_editSection']),
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
                  tool: (id: 'call_1', section: 'worldState'),
                )
              : stateToolsFrame(),
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
    // 3 次底层请求（1 次被拒 + 重发同一帧 + 状态轮），2 帧计数。
    expect(bodies, hasLength(3));
    expect(bodies[0]['tool_choice'], 'auto');
    expect(bodies[1].containsKey('tool_choice'), isFalse,
        reason: 'tool_choice 被拒后同一帧重发不再携带该字段');
    expect(bodies[2].containsKey('tool_choice'), isFalse);

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('正文。'));
  });
}
