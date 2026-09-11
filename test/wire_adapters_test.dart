import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/agent/wire_adapters.dart';
import 'package:narrchat/services/ai_service.dart';

/// 协议线路适配（纯函数）测试：Agent 与协议解耦的关键——
/// 内部会话（Responses 形状平铺 items）↔ Chat messages 双向转换
/// 与工具 schema 两种形状。
void main() {
  group('chatItemsFromAgentItems（Responses 形状 → Chat messages）', () {
    test('普通消息原样透传', () {
      final items = [
        {'role': 'system', 'content': '指令'},
        {'role': 'user', 'content': '你好'},
      ];
      expect(chatItemsFromAgentItems(items), items);
    });

    test('function_call 并入前一条 assistant 消息的 tool_calls', () {
      final out = chatItemsFromAgentItems(const [
        {'role': 'assistant', 'content': '正文'},
        {
          'type': 'function_call',
          'call_id': 'call_1',
          'name': 'narrchat_editWorldState',
          'arguments': '{"edits":[{"op":"append"}]}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'call_1',
          'output': '已更新',
        },
      ]);
      expect(out, [
        {
          'role': 'assistant',
          'content': '正文',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'narrchat_editWorldState',
                'arguments': '{"edits":[{"op":"append"}]}',
              },
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': '已更新'},
      ]);
    });

    test('function_call 前无 assistant 消息时自动补 assistant(content: null)', () {
      final out = chatItemsFromAgentItems(const [
        {
          'type': 'function_call',
          'call_id': 'call_1',
          'name': 'narrchat_webSearch',
          'arguments': '{"query":"青云宗"}',
        },
      ]);
      expect(out, hasLength(1));
      expect(out.single['role'], 'assistant');
      expect(out.single['content'], isNull);
      expect((out.single['tool_calls'] as List), hasLength(1));
    });

    test('多次调用追加到同一 assistant 消息（同帧多工具）', () {
      final out = chatItemsFromAgentItems(const [
        {'role': 'assistant', 'content': ''},
        {'type': 'function_call', 'call_id': 'a', 'name': 't1', 'arguments': '{}'},
        {'type': 'function_call', 'call_id': 'b', 'name': 't2', 'arguments': '{}'},
      ]);
      expect((out.single['tool_calls'] as List).length, 2);
    });

    test('reasoning 条目并入紧随的 assistant 消息（reasoning_content 回传）', () {
      // 执行器的实际顺序 = reasoning → assistant(正文) → function_call。
      final out = chatItemsFromAgentItems(const [
        {'role': 'user', 'content': '继续'},
        {'type': 'reasoning', 'id': 'r1', 'text': '先读状态再写', 'summary': false},
        {'role': 'assistant', 'content': '## 剧情演绎\n正文'},
        {'type': 'function_call', 'call_id': 'c1', 'name': 't1', 'arguments': '{}'},
        {'type': 'function_call_output', 'call_id': 'c1', 'output': 'ok'},
      ]);
      expect(out, [
        {'role': 'user', 'content': '继续'},
        {
          'role': 'assistant',
          'content': '## 剧情演绎\n正文',
          'reasoning_content': '先读状态再写',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {'name': 't1', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c1', 'content': 'ok'},
      ]);
    });

    test('纯工具帧：reasoning 先于 function_call，补 content:null 的 assistant', () {
      final out = chatItemsFromAgentItems(const [
        {'role': 'user', 'content': '写正文'},
        {'type': 'reasoning', 'id': '', 'text': '需要搜索', 'summary': false},
        {'type': 'function_call', 'call_id': 'c1', 'name': 'narrchat_webSearch', 'arguments': '{}'},
      ]);
      expect(out, hasLength(2));
      final assistant = out.last;
      expect(assistant['role'], 'assistant');
      expect(assistant['content'], isNull);
      expect(assistant['reasoning_content'], '需要搜索');
      expect((assistant['tool_calls'] as List), hasLength(1));
    });

    test('空文本思考条目被忽略（不得产出无意义的 reasoning_content）', () {
      final out = chatItemsFromAgentItems(const [
        {'type': 'reasoning', 'id': 'r1', 'text': '', 'summary': false},
        {'role': 'user', 'content': '你好'},
      ]);
      expect(out, [
        {'role': 'user', 'content': '你好'},
      ]);
    });

    test('思考条目后紧跟 assistant 消息 → 合并为一条（不产生占位消息）', () {
      final out = chatItemsFromAgentItems(const [
        {'type': 'reasoning', 'id': 'r1', 'text': '想一下', 'summary': false},
        {'role': 'assistant', 'content': '正文'},
      ]);
      expect(out, hasLength(1));
      expect(out.single['role'], 'assistant');
      expect(out.single['content'], '正文');
      expect(out.single['reasoning_content'], '想一下');
    });
  });

  group('responsesItemsFromChatMessages（Chat messages → Responses items）', () {
    test('普通消息保留 role/content，vision 块转换', () {
      final out = responsesItemsFromChatMessages(const [
        {'role': 'system', 'content': '指令'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '看图'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,AAA'},
            },
          ],
        },
      ]);
      expect(out, [
        {'role': 'system', 'content': '指令'},
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': '看图'},
            {
              'type': 'input_image',
              'image_url': 'data:image/png;base64,AAA',
            },
          ],
        },
      ]);
    });

    test('assistant tool_calls 展开为 message + function_call items；tool 消息转 output', () {
      final out = responsesItemsFromChatMessages(const [
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'narrchat_webSearch',
                'arguments': '{"query":"青云宗"}',
              },
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': '结果…'},
      ]);
      expect(out, [
        {'role': 'assistant', 'content': ''},
        {
          'type': 'function_call',
          'call_id': 'call_1',
          'name': 'narrchat_webSearch',
          'arguments': '{"query":"青云宗"}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'call_1',
          'output': '结果…',
        },
      ]);
    });

    test('assistant reasoning_content 展开为先行的 reasoning item（思考回传硬要求）', () {
      final out = responsesItemsFromChatMessages(const [
        {'role': 'user', 'content': '继续'},
        {
          'role': 'assistant',
          'content': '## 剧情演绎\n正文',
          'reasoning_content': '先读状态',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'narrchat_editWorldState',
                'arguments': '{"edits":[]}',
              },
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': '已更新'},
      ]);
      expect(out, [
        {'role': 'user', 'content': '继续'},
        {
          'type': 'reasoning',
          'content': [
            {'type': 'reasoning_text', 'text': '先读状态'},
          ],
        },
        {'role': 'assistant', 'content': '## 剧情演绎\n正文'},
        {
          'type': 'function_call',
          'call_id': 'call_1',
          'name': 'narrchat_editWorldState',
          'arguments': '{"edits":[]}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'call_1',
          'output': '已更新',
        },
      ]);
    });
  });

  group('responsesItemsFromAgentItems（AGENT 会话条目 → Responses input）', () {
    test('思考 / 工具 / 输出 / 普通消息按类型逐一还原（顺序不变）', () {
      final out = responsesItemsFromAgentItems(const [
        {'role': 'user', 'content': '继续'},
        {'type': 'reasoning', 'id': 'r1', 'text': '先读状态', 'summary': false},
        {'role': 'assistant', 'content': '## 剧情演绎\n正文'},
        {
          'type': 'function_call',
          'call_id': 'c1',
          'name': 'narrchat_editWorldState',
          'arguments': '{"edits":[]}',
        },
        {'type': 'function_call_output', 'call_id': 'c1', 'output': '已更新'},
      ]);

      expect(out, [
        {'role': 'user', 'content': '继续'},
        {
          'type': 'reasoning',
          'id': 'r1',
          'content': [
            {'type': 'reasoning_text', 'text': '先读状态'},
          ],
        },
        {'role': 'assistant', 'content': '## 剧情演绎\n正文'},
        {
          'type': 'function_call',
          'call_id': 'c1',
          'name': 'narrchat_editWorldState',
          'arguments': '{"edits":[]}',
        },
        {'type': 'function_call_output', 'call_id': 'c1', 'output': '已更新'},
      ]);
    });

    test('空文本思考条目被丢弃（不产出空 reasoning item）', () {
      final out = responsesItemsFromAgentItems(const [
        {'type': 'reasoning', 'id': '', 'text': '', 'summary': false},
        {'role': 'user', 'content': '你好'},
      ]);
      expect(out, [
        {'role': 'user', 'content': '你好'},
      ]);
    });

    test('vision 用户消息沿用 Chat→Responses 的图片块转换', () {
      final out = responsesItemsFromAgentItems(const [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '看图'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,AAA'},
            },
          ],
        },
      ]);
      expect(out.single['content'], [
        {'type': 'input_text', 'text': '看图'},
        {'type': 'input_image', 'image_url': 'data:image/png;base64,AAA'},
      ]);
    });
  });

  group('reasoningItemFrom / reasoningResponseItem（思考条目 ↔ 线路形态）', () {    test('会话条目还原为 content 形态 input item（带 id）', () {
      expect(
        reasoningItemFrom(
          const AiReasoningItem(id: 'r1', text: '先读状态'),
        ),
        {'type': 'reasoning', 'id': 'r1', 'text': '先读状态', 'summary': false},
      );
      expect(
        reasoningResponseItem(
          reasoningItemFrom(const AiReasoningItem(id: 'r1', text: '先读状态')),
        ),
        {
          'type': 'reasoning',
          'id': 'r1',
          'content': [
            {'type': 'reasoning_text', 'text': '先读状态'},
          ],
        },
      );
    });

    test('摘要形态按 summary parts 还原；无 id 时省略该键', () {
      final item = reasoningItemFrom(
        const AiReasoningItem(text: '摘要思考', summary: true),
      );
      expect(item['id'], '');
      final wire = reasoningResponseItem(item);
      expect(wire.containsKey('id'), isFalse);
      expect(wire['content'], isNull);
      expect(wire['summary'], [
        {'type': 'summary_text', 'text': '摘要思考'},
      ]);
    });
  });

  group('responsesPartsFromChatMessages（system → instructions 拆分）', () {
    test('system 合并为 instructions，其余转 items', () {
      final parts = responsesPartsFromChatMessages(const [
        {'role': 'system', 'content': '系统指令一'},
        {'role': 'user', 'content': '你好'},
      ]);
      expect(parts.instructions, '系统指令一');
      expect(parts.items, [
        {'role': 'user', 'content': '你好'},
      ]);
    });

    test('无 system 消息时 instructions 为 null（请求体省略该键）', () {
      final parts = responsesPartsFromChatMessages(const [
        {'role': 'user', 'content': '你好'},
      ]);
      expect(parts.instructions, isNull);
    });
  });
}
