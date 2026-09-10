import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/utils/text_stats.dart';

void main() {
  group('TextStats.charCount：中英文字 / 标点 / 空格 / 表情各计 1', () {
    test('空串为 0', () {
      expect(TextStats.charCount(''), 0);
    });

    test('中英混排逐字符计数（含全角标点）', () {
      expect(TextStats.charCount('你好，world!'), 9);
    });

    test('空格与换行同样计入', () {
      expect(TextStats.charCount('a b\nc'), 5);
    });

    test('表情按字素簇计 1（不按码位 / 码元拆开）', () {
      // 单个表情：UTF-16 下是代理对（length == 2），码位为 1，字素簇为 1。
      expect(TextStats.charCount('👍'), 1);
      // ZWJ 组合家庭：5 个码位合成 1 个可见字符。
      expect(TextStats.charCount('👨‍👩‍👧'), 1);
      // 旗帜：两个区域指示符合成 1 个可见字符。
      expect(TextStats.charCount('🇨🇳'), 1);
    });

    test('中文与表情混排', () {
      expect(TextStats.charCount('好的👍，收到'), 6);
    });
  });

  group('TextStats.groupThousands：千分位分组', () {
    test('不足四位不加分隔符', () {
      expect(TextStats.groupThousands(0), '0');
      expect(TextStats.groupThousands(9), '9');
      expect(TextStats.groupThousands(999), '999');
    });

    test('四位及以上按三位一组', () {
      expect(TextStats.groupThousands(1000), '1,000');
      expect(TextStats.groupThousands(12345), '12,345');
      expect(TextStats.groupThousands(1234567), '1,234,567');
    });
  });
}
