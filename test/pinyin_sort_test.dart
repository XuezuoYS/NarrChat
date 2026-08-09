import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/utils/pinyin_sort.dart';

void main() {
  group('PinyinSort', () {
    test('中文按拼音 a~z 排序', () {
      final names = ['陈', '白', '安', '赵'];
      final sorted = List.of(names)..sort(PinyinSort.compare);
      expect(sorted, ['安', '白', '陈', '赵']);
    });

    test('中文词组按拼音首字排序', () {
      final names = ['宗门世界', '人物志', '炼丹术', '境界体系'];
      final sorted = List.of(names)..sort(PinyinSort.compare);
      // 境界(jìng) < 炼丹(liàn) < 人物(rén) < 宗门(zōng)
      expect(sorted, ['境界体系', '炼丹术', '人物志', '宗门世界']);
    });

    test('非汉字字符原样保留并按字典序比较', () {
      expect(PinyinSort.compare('abc', 'abd'), isNegative);
      expect(PinyinSort.compare('ABC', 'abc'), 0);
      expect(PinyinSort.key('ABC'), 'abc');
    });

    test('混合中英文排序（英文在前按字母序，中文按拼音）', () {
      final names = ['修仙', 'apple', '炼丹', 'Banana'];
      final sorted = List.of(names)..sort(PinyinSort.compare);
      // apple / banana（字母序）在前，随后是 炼丹 / 修仙（拼音序）
      expect(sorted.take(2), ['apple', 'Banana']);
      expect(sorted.skip(2), ['炼丹', '修仙']);
    });

    test('空串与空内容排序稳定', () {
      expect(PinyinSort.key(''), '');
      final names = ['', 'a', '安'];
      final sorted = List.of(names)..sort(PinyinSort.compare);
      expect(sorted.first, '');
    });
  });
}
