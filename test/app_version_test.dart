import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/utils/app_version.dart';

void main() {
  group('AppVersion.tryParse', () {
    test('解析 v 前缀、纯数字与带前后缀文本', () {
      expect(AppVersion.tryParse('v1.4.0')!.segments, [1, 4, 0]);
      expect(AppVersion.tryParse('1.4.0')!.segments, [1, 4, 0]);
      expect(AppVersion.tryParse('V1.4')!.segments, [1, 4]);
      expect(AppVersion.tryParse('v2.10.1-beta')!.segments, [2, 10, 1]);
      expect(AppVersion.tryParse('release-1.3.1-tag')!.segments, [1, 3, 1]);
      expect(AppVersion.tryParse(' 1.3.1 '), AppVersion.tryParse('1.3.1'));
    });

    test('无法解析时返回 null', () {
      expect(AppVersion.tryParse(''), isNull);
      expect(AppVersion.tryParse('abc'), isNull);
      expect(AppVersion.tryParse('v'), isNull);
      expect(AppVersion.tryParse('..'), isNull);
    });
  });

  group('AppVersion 比较', () {
    test('数值逐段比较（非字符串序）', () {
      expect(AppVersion.tryParse('1.4')!, greaterThan(AppVersion.tryParse('1.3.9')!));
      expect(AppVersion.tryParse('1.10')!, greaterThan(AppVersion.tryParse('1.9')!));
      expect(AppVersion.tryParse('2.0.0')!, greaterThan(AppVersion.tryParse('1.99.99')!));
      expect(AppVersion.tryParse('1.3.1')!, lessThan(AppVersion.tryParse('1.4.0')!));
    });

    test('缺失段按 0 计：1.3 与 1.3.0 相等', () {
      expect(AppVersion.tryParse('1.3'), AppVersion.tryParse('1.3.0'));
      expect(AppVersion.tryParse('1.3')!.compareTo(AppVersion.tryParse('1.3.0')!), 0);
      expect(AppVersion.tryParse('1.3.0')!.hashCode,
          AppVersion.tryParse('1.3')!.hashCode);
    });

    test('compareTo 反对称', () {
      final a = AppVersion.tryParse('1.4.0')!;
      final b = AppVersion.tryParse('1.3.9')!;
      expect(a.compareTo(b), -b.compareTo(a));
      expect(a, isNot(equals(b)));
    });
  });
}
