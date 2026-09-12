import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/utils/thinking_window.dart';

/// 折叠态思考框的末尾窗口：折叠区只露 4~5 行，单次渲染成本必须与思考链
/// 总长解耦（否则「思考链越长越卡」）。
void main() {
  test('未超过上限：返回 null（无需截断）', () {
    expect(thinkingTailWindow(''), isNull);
    expect(thinkingTailWindow('短文'), isNull);
    expect(
      thinkingTailWindow('甲' * kThinkingTailMaxChars),
      isNull,
      reason: '恰好等于上限时不截断',
    );
  });

  test('超长单行：硬切到上限，窗口始终以文本末尾结束', () {
    final text = '甲' * (kThinkingTailMaxChars + 600);

    final tail = thinkingTailWindow(text);

    expect(tail, '甲' * kThinkingTailMaxChars);
    expect(text.endsWith(tail!), isTrue, reason: '窗口必须贴着最新内容');
  });

  test('多行文本：切点回看对齐行首，窗口长度有界且保留末尾', () {
    const line = '中间推理内容行\n';
    final text = '开头标记\n${line * 300}结尾标记';

    final tail = thinkingTailWindow(text)!;
    final startInText = text.length - tail.length;

    expect(text.endsWith(tail), isTrue);
    // 起点前一位是换行 → 窗口以完整行开头，不会出现半行。
    expect(text[startInText - 1], '\n');
    expect(tail, startsWith('中间推理内容行\n'));
    expect(tail, contains('结尾标记'));
    expect(tail, isNot(contains('开头标记')));
    expect(
      tail.length,
      inInclusiveRange(
        kThinkingTailMaxChars - 1,
        kThinkingTailMaxChars + 200,
      ),
      reason: '窗口长度须有界（上限 + 回看上限）',
    );
  });

  test('最近的行首超出回看范围：硬切而非把超长行整体吞掉', () {
    final text = '${'甲' * 3000}\n${'乙' * 2000}';

    final tail = thinkingTailWindow(text)!;
    final startInText = text.length - tail.length;

    expect(tail.length, kThinkingTailMaxChars, reason: '硬切恰好等于上限');
    expect(text[startInText - 1], '乙', reason: '未回看到行首');
    expect(text.endsWith(tail), isTrue);
  });

  test('硬切不产生半个码点（emoji 代理对）', () {
    // 前缀 'a' 使硬切位置恰好落在低代理位（UTF-16 码元 202 为低代理）。
    final text = 'a${'🙂' * 800}b';
    expect(text.length, 1602, reason: '用例前提：1 + 1600 + 1');

    final tail = thinkingTailWindow(text)!;

    expect(tail.runes.first, 0x1F642, reason: '窗口应以完整 emoji 开头');
    expect(tail.endsWith('b'), isTrue);
  });

  test('文本以换行结尾：不越界、仍贴着末尾', () {
    final text = '${'甲' * 10}\n${'乙' * 2000}\n';

    final tail = thinkingTailWindow(text)!;

    expect(text.endsWith(tail), isTrue);
    expect(tail.length, lessThanOrEqualTo(kThinkingTailMaxChars + 200));
  });

  test('自定义上限：窗口随参数收敛（含退化取值）', () {
    final text = '甲' * 100;

    expect(thinkingTailWindow(text, maxChars: 100), isNull);
    expect(thinkingTailWindow(text, maxChars: 40), '甲' * 40);
    expect(thinkingTailWindow(text, maxChars: 0), isNull);
    expect(thinkingTailWindow(text, maxChars: -1), isNull);
  });
}
