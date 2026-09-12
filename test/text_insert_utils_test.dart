import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/utils/text_insert_utils.dart';

/// 「推荐下一步」双击选项写入输入框的落点规则（纯函数）。
void main() {
  /// 构造输入框当前值：[selection] 为 null 时模拟「无光标」（无效选择区，
  /// 如程序化赋值 / 草稿恢复后从未聚焦）。
  TextEditingValue value(String text, {TextSelection? selection}) =>
      TextEditingValue(
        text: text,
        selection: selection ?? const TextSelection.collapsed(offset: -1),
      );

  group('insertTextIntoValue 落点规则', () {
    test('空输入：直接置入，光标落在插入内容之后', () {
      final result = insertTextIntoValue(value(''), '上前行礼');
      expect(result.text, '上前行礼');
      expect(result.selection, const TextSelection.collapsed(offset: 4));
    });

    test('有文本但无光标：追加到已输入文本末尾', () {
      // 无效选择区 = 无光标（程序化赋值 / 从未聚焦）。
      final result = insertTextIntoValue(value('我走向主殿。'), '上前行礼');
      expect(result.text, '我走向主殿。上前行礼');
      expect(result.selection, const TextSelection.collapsed(offset: 10));
    });

    test('有文本且有光标：在光标处插入（不追加到末尾）', () {
      final result = insertTextIntoValue(
        value('我走向主殿。', selection: const TextSelection.collapsed(offset: 2)),
        '上前行礼',
      );
      expect(result.text, '我走上前行礼向主殿。');
      expect(result.selection, const TextSelection.collapsed(offset: 6));
    });

    test('光标处存在选中区：选中内容被插入文本替换', () {
      final result = insertTextIntoValue(
        value('我走向主殿。', selection: const TextSelection(baseOffset: 1, extentOffset: 5)),
        '行礼',
      );
      expect(result.text, '我行礼。');
      expect(result.selection, const TextSelection.collapsed(offset: 3));
    });

    test('光标越界（文本已被外部改短）：夹到文本范围内落点', () {
      final result = insertTextIntoValue(
        value('短', selection: const TextSelection.collapsed(offset: 9)),
        '加长',
      );
      expect(result.text, '短加长');
      expect(result.selection, const TextSelection.collapsed(offset: 3));
    });

    test('组合态（composing）被清空，不并入输入法未上屏内容', () {
      final result = insertTextIntoValue(
        TextEditingValue(
          text: '输入',
          selection: const TextSelection.collapsed(offset: 2),
          composing: const TextRange(start: 0, end: 2),
        ),
        '行动',
      );
      expect(result.text, '输入行动');
      expect(result.composing, TextRange.empty);
      expect(result.selection, const TextSelection.collapsed(offset: 4));
    });
  });
}
