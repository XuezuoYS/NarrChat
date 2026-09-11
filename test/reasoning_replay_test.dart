import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/services/agent/reasoning_replay.dart';

/// `reasoning_replay`（思考回传精简）单元测试：分段规则、单段原样、空白行不计段、
/// 多段取首末、关掉精简时逐字节回传。
void main() {
  group('splitReasoningSegments（按段落切分，丢弃纯空白行）', () {
    test('空行 / 空白行不算段（`\\n\\n` 只是格式占位）', () {
      expect(
        splitReasoningSegments('第一段\n\n第二段\n   \n\n第三段'),
        ['第一段', '第二段', '第三段'],
      );
    });

    test('段内保留原文与缩进，只去首尾空白', () {
      expect(
        splitReasoningSegments('  1. 先读状态\n2. 再搜资料  '),
        ['1. 先读状态', '2. 再搜资料'],
      );
    });

    test('全空白文本 → 无段', () {
      expect(splitReasoningSegments('\n \n\t\n'), isEmpty);
    });
  });

  group('reduceReasoningText（单段原样 / 多段取首末）', () {
    test('只有一段 → 原样返回（不做任何改动）', () {
      const only = 'Need the world state first, then write the story.';
      expect(reduceReasoningText(only), only);
      expect(reduceReasoningText('  $only  '), only);
    });

    test('多段 → 首段 + 末段（中间过程丢弃）', () {
      const text = '先读世界状态确定地点。\n'
          '然后搜索洛天依与乐正绫的资料。\n'
          '再打开最相关的页面。\n'
          '最后按五区块写正文，时间沿用上轮格式。';
      expect(
        reduceReasoningText(text),
        '先读世界状态确定地点。\n\n最后按五区块写正文，时间沿用上轮格式。',
      );
    });

    test('恰好两段 → 两段都保留（等价于首末）', () {
      expect(reduceReasoningText('意图。\n结论。'), '意图。\n\n结论。');
    });

    test('多段但首末相同 → 只回传一段（不留重复）', () {
      expect(reduceReasoningText('同一段。\n中间段。\n同一段。'), '同一段。');
    });

    test('空文本 → 空串（调用方据此判定"无思考可回传"）', () {
      expect(reduceReasoningText(''), '');
      expect(reduceReasoningText('\n\n'), '');
    });
  });

  group('reasoningTextForReplay（按设置选择策略）', () {
    const multi = '第一段。\n第二段。\n第三段。';

    test('精简开 → 首段 + 末段', () {
      expect(
        reasoningTextForReplay(multi, reduce: true),
        '第一段。\n\n第三段。',
      );
    });

    test('精简关 → 逐字节回传原文（保留空行与首尾空白以外的原貌）', () {
      expect(reasoningTextForReplay(multi, reduce: false), multi);
      // 首尾空白仍会被裁掉（服务端要求非空块，不做无意义填充）。
      expect(
        reasoningTextForReplay('  $multi  ', reduce: false),
        multi,
      );
    });

    test('两种策略下空文本都返回空串', () {
      expect(reasoningTextForReplay('   ', reduce: true), '');
      expect(reasoningTextForReplay('   ', reduce: false), '');
    });
  });
}
