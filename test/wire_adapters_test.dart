import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/agent/wire_adapters.dart';

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
          'name': 'narrchat_editSection',
          'arguments': '{"section":"worldState"}',
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
                'name': 'narrchat_editSection',
                'arguments': '{"section":"worldState"}',
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
