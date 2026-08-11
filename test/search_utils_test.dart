import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/utils/search_utils.dart';

void main() {
  group('splitKeywords', () {
    test('空串 / 纯空白返回空列表', () {
      expect(splitKeywords(''), isEmpty);
      expect(splitKeywords('   '), isEmpty);
      expect(splitKeywords('\t\n '), isEmpty);
    });

    test('单关键词', () {
      expect(splitKeywords('修仙'), ['修仙']);
    });

    test('空格分隔多关键词并转小写', () {
      expect(splitKeywords('AI 写作'), ['ai', '写作']);
    });

    test('忽略连续空格与首尾空白', () {
      expect(splitKeywords('  剑  玄幻  '), ['剑', '玄幻']);
    });
  });

  group('matchesKeywords', () {
    test('无关键词恒为 true', () {
      expect(matchesKeywords(const [], ['任意']), isTrue);
    });

    test('单关键词任一字段命中', () {
      expect(matchesKeywords(const ['剑'], ['剑来', '玄幻']), isTrue);
      expect(matchesKeywords(const ['剑'], ['三体', '科幻']), isFalse);
    });

    test('多关键词全部命中才通过', () {
      expect(
        matchesKeywords(const ['剑', '玄幻'], ['剑来', '玄幻']),
        isTrue,
      );
      expect(
        matchesKeywords(const ['剑', '科幻'], ['剑来', '玄幻']),
        isFalse,
      );
    });

    test('大小写不敏感', () {
      expect(matchesKeywords(const ['hobbit'], ['The Hobbit']), isTrue);
      expect(matchesKeywords(const ['THE'], ['the hobbit']), isTrue);
    });
  });

  group('modMatchesKeywords', () {
    const mod = Mod(
      name: '网文语感强化',
      description: '增强文笔的网文风格，适合修仙题材',
    );

    test('名称命中', () {
      expect(modMatchesKeywords(const ['语感'], mod), isTrue);
    });

    test('简介命中', () {
      expect(modMatchesKeywords(const ['修仙'], mod), isTrue);
    });

    test('多关键词跨名称与简介', () {
      expect(modMatchesKeywords(const ['网文', '修仙'], mod), isTrue);
      expect(modMatchesKeywords(const ['网文', '科幻'], mod), isFalse);
    });

    test('空关键词命中一切', () {
      expect(modMatchesKeywords(const [], mod), isTrue);
    });

    test('mod 为 null 不命中', () {
      expect(modMatchesKeywords(const ['任意'], null), isFalse);
    });
  });
}
