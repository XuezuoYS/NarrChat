import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/utils/formats.dart';

/// Token 展示格式化：无数据占位、Token 计数与缓存命中率。
void main() {
  group('Formats.formatTokenCount', () {
    test('有数据：十进制原样（0 也是数据，不是「无」）', () {
      expect(Formats.formatTokenCount(0), '0');
      expect(Formats.formatTokenCount(3395), '3395');
    });

    test('无数据（null）：占位（无）', () {
      expect(Formats.noData, '（无）');
      expect(Formats.formatTokenCount(null), Formats.noData);
    });
  });

  group('Formats.formatCacheHitRate', () {
    test('正常比例：一位小数，末位 .0 省略', () {
      expect(Formats.formatCacheHitRate(4940, 10000), '49.4%');
      expect(Formats.formatCacheHitRate(4949, 10000), '49.5%');
      expect(Formats.formatCacheHitRate(300, 1000), '30%');
      expect(Formats.formatCacheHitRate(0, 1000), '0%');
    });

    test('缓存或输入任一侧无数据 → null（调用方显示「（无）」）', () {
      expect(Formats.formatCacheHitRate(null, 100), isNull);
      expect(Formats.formatCacheHitRate(10, null), isNull);
      expect(Formats.formatCacheHitRate(null, null), isNull);
    });

    test('输入为 0（分母无效）→ null，不谎报 0%', () {
      expect(Formats.formatCacheHitRate(0, 0), isNull);
    });

    test('全部命中 → 100%', () {
      expect(Formats.formatCacheHitRate(1000, 1000), '100%');
      expect(Formats.formatCacheHitRate(1200, 1000), '100%', reason: '异常超报按满命中收敛');
    });

    test('未真正全命中不得四舍五入成 100%', () {
      // 9999/10000 = 99.99%：一位小数会变 100.0 → 自动降到两位显示真值。
      expect(Formats.formatCacheHitRate(9999, 10000), '99.99%');
      expect(Formats.formatCacheHitRate(999999, 1000000), '99.9999%');
    });
  });
}
