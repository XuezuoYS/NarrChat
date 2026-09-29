import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';

/// [FontScaleLevel] 档位表：偏移量 0 = 0% = 默认，负数为更小档位。
void main() {
  group('字体缩放档位表', () {
    test('偏移量依次为 -2..3，且与百分比、标签、倍率精确对应', () {
      const expected = <(int, int, String, double)>[
        (-2, -30, '-30%', 0.70),
        (-1, -15, '-15%', 0.85),
        (0, 0, '0%', 1.00),
        (1, 15, '+15%', 1.15),
        (2, 30, '+30%', 1.30),
        (3, 45, '+45%', 1.45),
      ];
      expect(FontScaleLevel.values.length, expected.length);
      for (var i = 0; i < expected.length; i++) {
        final level = FontScaleLevel.values[i];
        expect(level.offset, expected[i].$1, reason: '第 $i 档偏移量');
        expect(level.percent, expected[i].$2, reason: '第 $i 档百分比');
        expect(level.label, expected[i].$3, reason: '第 $i 档标签');
        expect(level.scale, expected[i].$4, reason: '第 $i 档倍率');
      }
    });

    test('零档标签为 0% 而非 +0%', () {
      expect(FontScaleLevel.zero.label, '0%');
    });

    test('默认档为 0%（零偏移）', () {
      expect(FontScaleLevel.defaultLevel, FontScaleLevel.zero);
      expect(FontScaleLevel.defaultLevel.offset, 0);
      expect(FontScaleLevel.defaultLevel.scale, 1.0);
    });

    test('minOffset / maxOffset 与实际档位边界一致', () {
      // 顺序枚举：values.first 为最负档，values.last 为最正档。
      expect(FontScaleLevel.minOffset, FontScaleLevel.values.first.offset);
      expect(FontScaleLevel.maxOffset, FontScaleLevel.values.last.offset);
    });

    test('offsets 按档位顺序给出全部偏移量', () {
      expect(FontScaleLevel.offsets, [-2, -1, 0, 1, 2, 3]);
    });

    test('fromOffset：合法偏移量精确映射', () {
      for (final level in FontScaleLevel.values) {
        expect(
          FontScaleLevel.fromOffset(level.offset).label,
          level.label,
          reason: 'offset ${level.offset}',
        );
      }
    });

    test('fromOffset：null / 越界偏移量回退默认档', () {
      for (final invalid in <int?>[null, -3, -99, 4, 99]) {
        expect(
          FontScaleLevel.fromOffset(invalid),
          FontScaleLevel.defaultLevel,
          reason: '非法偏移量 $invalid',
        );
      }
    });
  });
}
