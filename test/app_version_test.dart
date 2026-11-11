import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/utils/app_version.dart';

AppVersion parse(String raw) => AppVersion.tryParse(raw)!;

void main() {
  group('AppVersion.tryParse（严格按版本号规范）', () {
    test('正式版：三段数字，容忍 v 前缀、空白与构建元数据', () {
      final version = parse('v3.0.0');
      expect(version.major, 3);
      expect(version.minor, 0);
      expect(version.patch, 0);
      expect(version.isPrerelease, isFalse);
      expect(version.toString(), '3.0.0');

      expect(parse(' 2.10.1 '), parse('2.10.1'));
      expect(parse('V1.4.0'), parse('1.4.0'));
      // `+build` 是构建元数据，不参与比较。
      expect(parse('3.0.0+111'), parse('3.0.0'));
    });

    test('测试版：beta / rc 且必须带序号', () {
      final beta = parse('v3.0.0-beta.2');
      expect(beta.isPrerelease, isTrue);
      expect(beta.toString(), '3.0.0-beta.2');

      final rc = parse('3.0.0-rc.1+57');
      expect(rc.isPrerelease, isTrue);
      expect(rc.toString(), '3.0.0-rc.1');
      // 序号按数值比较，不会被当成字符串。
      expect(parse('3.0.0-beta.010'), parse('3.0.0-beta.10'));
    });

    test('不合规范的写法一律返回 null', () {
      const invalid = [
        '',
        'abc',
        'v',
        '..',
        '1.3', // 缺一段
        '1.4.0.1', // 多一段
        '1.4.0-1', // 测试版必须是 beta / rc
        '1.4.0-beta', // 缺序号
        '1.4.0-beta.x', // 序号不是数字
        '1.4.0-beta.1.2', // 序号后又多一段
        '1.4.0-alpha.1', // 规范外的阶段
        '1.4.0-BETA.1', // 规范写小写
        'release-1.4.0', // 前后夹带文字
        '1.4.0-hotfix.1',
        '1.4.0+', // 空的构建元数据
      ];
      for (final raw in invalid) {
        expect(AppVersion.tryParse(raw), isNull, reason: '应拒绝 "$raw"');
      }
    });
  });

  group('AppVersion 比较（README 版本号规范示例）', () {
    // 与 README「版本号规范」的顺序一致，越靠下越新。
    const ordered = [
      '2.9.4',
      '2.9.5',
      '2.10.0',
      '2.10.1',
      '3.0.0-beta.1',
      '3.0.0-beta.4',
      '3.0.0-rc.1',
      '3.0.0',
      '3.1.0-beta.1',
      '3.1.0',
    ];

    test('相邻版本严格递增', () {
      for (var i = 0; i < ordered.length - 1; i++) {
        final lower = parse(ordered[i]);
        final higher = parse(ordered[i + 1]);
        expect(
          lower < higher,
          isTrue,
          reason: '${ordered[i]} 应低于 ${ordered[i + 1]}',
        );
        expect(
          higher > lower,
          isTrue,
          reason: '${ordered[i + 1]} 应高于 ${ordered[i]}',
        );
      }
    });

    test('主体版本优先于测试版后缀', () {
      expect(parse('3.0.0-beta.4'), greaterThan(parse('2.99.99')));
      expect(parse('2.10.0'), greaterThan(parse('2.9.5')));
    });

    test('阶段顺序：beta < rc < 正式版', () {
      expect(parse('3.0.0-beta.9'), lessThan(parse('3.0.0-rc.1')));
      expect(parse('3.0.0-rc.9'), lessThan(parse('3.0.0')));
      expect(parse('3.0.0'), greaterThan(parse('3.0.0-rc.1')));
    });

    test('同阶段按序号数值比较', () {
      expect(parse('3.0.0-beta.10'), greaterThan(parse('3.0.0-beta.2')));
      expect(parse('3.0.0-rc.10'), greaterThan(parse('3.0.0-rc.9')));
      expect(parse('3.0.0-beta.02'), equals(parse('3.0.0-beta.2')));
    });

    test('相等与哈希忽略 v 前缀与构建元数据', () {
      final beta = parse('v3.0.0-beta.1');
      expect(parse('3.0.0-beta.1'), beta);
      expect(parse('3.0.0-beta.1+111'), beta);
      expect(parse('3.0.0-beta.1').hashCode, beta.hashCode);
      expect(parse('3.0.0-beta.1') == parse('3.0.0-beta.2'), isFalse);
      expect(parse('3.0.0') == parse('3.0.0+9'), isTrue);
      expect(parse('3.0.0').hashCode, parse('3.0.0+9').hashCode);
    });
  });
}
