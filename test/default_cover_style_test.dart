import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/cover_illustration.dart';
import 'package:narrchat/models/default_cover_style.dart';

/// 默认封面样式与内置插画：关键词规则、样式解析、下拉顺序（纯逻辑，不渲染）。
void main() {
  group('插画适配关键词规则', () {
    for (final keyword in CoverIllustration.ancientKeywords) {
      test('命中古风关键词「$keyword」→ 插画2', () {
        expect(
          CoverIllustration.forCategory(keyword),
          CoverIllustration.illustration2,
        );
      });
    }

    for (final keyword in CoverIllustration.modernKeywords) {
      test('命中现代关键词「$keyword」→ 插画3', () {
        expect(
          CoverIllustration.forCategory(keyword),
          CoverIllustration.illustration3,
        );
      });
    }

    test('关键词出现在更长的分类文本里也算命中', () {
      expect(
        CoverIllustration.forCategory('东方玄幻 / 热血'),
        CoverIllustration.illustration2,
      );
      expect(
        CoverIllustration.forCategory('赛博都市 悬疑'),
        CoverIllustration.illustration3,
      );
    });

    test('两方关键词都有 → 插画1', () {
      for (final category in ['玄幻都市', '古风 + 科幻', '仙侠·魔幻']) {
        expect(
          CoverIllustration.forCategory(category),
          CoverIllustration.illustration1,
          reason: '分类「$category」两方都沾，应回退插画1',
        );
      }
    });

    test('两方都没有（含空分类）→ 插画1', () {
      for (final category in ['', '悬疑', '   ']) {
        expect(
          CoverIllustration.forCategory(category),
          CoverIllustration.illustration1,
          reason: '分类「$category」两方都不沾，应回退插画1',
        );
      }
    });

    test('三张插画资源互不相同且都是 png', () {
      final assets = [
        for (final illustration in CoverIllustration.values) illustration.asset,
      ];
      expect(assets, hasLength(3));
      expect(assets.toSet(), hasLength(3));
      expect(assets, everyElement(endsWith('.png')));
    });
  });

  group('默认封面样式', () {
    test('声明顺序即下拉顺序：无插画 → 插画适配 → 插画1 → 插画2 → 插画3', () {
      expect(
        [for (final style in DefaultCoverStyle.values) style.label],
        ['无插画', '插画适配', '插画1', '插画2', '插画3'],
      );
    });

    test('默认样式仍是插画1', () {
      expect(DefaultCoverStyle.defaultStyle, DefaultCoverStyle.illustration1);
    });

    test('每个样式的存储值都能原样解析回来', () {
      for (final style in DefaultCoverStyle.values) {
        expect(
          DefaultCoverStyle.fromStorageValue(style.storageValue),
          style,
          reason: '存储值「${style.storageValue}」应解析回 ${style.label}',
        );
      }
    });

    test('未配置 / 未知值回退插画1', () {
      for (final value in <String?>[null, '', 'bad', 'illustration4']) {
        expect(
          DefaultCoverStyle.fromStorageValue(value),
          DefaultCoverStyle.illustration1,
          reason: '非法存储值「$value」应回退插画1',
        );
      }
    });

    test('固定插画不随分类变化，无插画返回 null', () {
      for (final category in ['玄幻', '都市']) {
        expect(
          DefaultCoverStyle.illustration1.illustrationFor(category),
          CoverIllustration.illustration1,
        );
        expect(
          DefaultCoverStyle.illustration2.illustrationFor(category),
          CoverIllustration.illustration2,
        );
        expect(
          DefaultCoverStyle.illustration3.illustrationFor(category),
          CoverIllustration.illustration3,
        );
        expect(
          DefaultCoverStyle.noIllustration.illustrationFor(category),
          isNull,
        );
      }
    });

    test('插画适配按分类挑插画', () {
      expect(
        DefaultCoverStyle.adaptive.illustrationFor('玄幻'),
        CoverIllustration.illustration2,
      );
      expect(
        DefaultCoverStyle.adaptive.illustrationFor('都市'),
        CoverIllustration.illustration3,
      );
      expect(
        DefaultCoverStyle.adaptive.illustrationFor('玄幻都市'),
        CoverIllustration.illustration1,
      );
      expect(
        DefaultCoverStyle.adaptive.illustrationFor(''),
        CoverIllustration.illustration1,
      );
    });
  });
}
