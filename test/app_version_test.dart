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

  group('AppVersion 预发布后缀', () {
    AppVersion parse(String raw) => AppVersion.tryParse(raw)!;

    test('解析 -beta.1 为预发布标识符；构建元数据忽略', () {
      final beta = parse('v3.0.0-beta.1');
      expect(beta.segments, [3, 0, 0]);
      expect(beta.prerelease, ['beta', '1']);
      expect(beta.toString(), '3.0.0-beta.1');

      expect(parse('1.4.0').prerelease, isEmpty);
      expect(parse('1.4.0').toString(), '1.4.0');
      // `+build` 属于构建元数据，不参与比较。
      expect(parse('1.4.0+build.5'), parse('1.4.0'));
    });

    test('同号正式版高于预发布版', () {
      final stable = parse('1.4.0');
      final beta = parse('v1.4.0-beta.1');
      expect(stable > beta, isTrue);
      expect(beta < stable, isTrue);
      expect(beta, isNot(equals(stable)));
      expect(beta.hashCode, isNot(stable.hashCode));
    });

    test('预发布标识符按语义化规则比较', () {
      expect(parse('1.4.0-beta.2'), greaterThan(parse('1.4.0-beta.1')));
      expect(parse('1.4.0-beta.10'), greaterThan(parse('1.4.0-beta.2')));
      expect(parse('1.4.0-rc.1'), greaterThan(parse('1.4.0-beta.9')));
      // 前缀相同时标识符更多者更高；数字标识符恒小于字母标识符。
      expect(parse('1.4.0-beta'), lessThan(parse('1.4.0-beta.1')));
      expect(parse('1.4.0-1'), lessThan(parse('1.4.0-beta')));
    });

    test('预发布相同即相等（忽略 v 前缀与多余 0 段）', () {
      final beta = parse('3.0.0-beta.1');
      expect(parse('v3.0.0-beta.1'), beta);
      expect(parse('3.0-beta.1'), beta);
      expect(parse('3.0-beta.1').hashCode, beta.hashCode);
    });

    test('主体版本高低优先于预发布后缀', () {
      expect(parse('2.0.0'), greaterThan(parse('1.9.9-beta.5')));
      expect(parse('2.0.0-beta.1'), greaterThan(parse('1.9.9')));
    });
  });
}
