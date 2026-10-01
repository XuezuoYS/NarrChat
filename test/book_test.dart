import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';

/// `books` 表 ↔ [Book] 的列映射（uuid 即主键）与「记忆总结轮次合并」档位收敛。
///
/// 档位单一真源为 [Book.memorySummaryRoundTiers]（0 / 5 / 10）；库内出现不属于
/// 这三者的数值（脏数据 / 已移除的档位）一律按 0 读取与回写。
void main() {
  group('记忆总结轮次合并档位', () {
    test('受支持档位就是 0 / 5 / 10', () {
      expect(Book.memorySummaryRoundTiers, [0, 5, 10]);
    });

    test('缺列 / 空值默认 0，受支持档位原样读取', () {
      expect(const Book(title: '书A').memorySummaryRounds, 0);
      expect(
        Book.fromMap(const {'uuid': 'u-1', 'title': '书A'}).memorySummaryRounds,
        0,
        reason: 'v18 之前的行没有该列，读作不开启',
      );
      for (final tier in Book.memorySummaryRoundTiers) {
        expect(
          Book.fromMap({
            'uuid': 'u-1',
            'title': '书A',
            'memory_summary_rounds': tier,
          }).memorySummaryRounds,
          tier,
        );
      }
      expect(
        Book.fromMap(const {
          'uuid': 'u-1',
          'title': '书A',
          'memory_summary_rounds': null,
        }).memorySummaryRounds,
        0,
      );
    });

    test('库内不支持的值（7 / 11 / -5 等）读出一律按 0 执行', () {
      for (final dirty in const [1, 4, 6, 7, 11, 100, -5]) {
        expect(
          Book.fromMap({
            'uuid': 'u-1',
            'title': '书A',
            'memory_summary_rounds': dirty,
          }).memorySummaryRounds,
          0,
          reason: '$dirty 不属于 0 / 5 / 10，必须按 0 执行',
        );
      }
    });

    test('写库一律落受支持档位：越界值 toMap 收敛为 0', () {
      expect(
        const Book(title: '书A', memorySummaryRounds: 7)
            .toMap()['memory_summary_rounds'],
        0,
        reason: '构造入参越界时也不得把脏值写进库',
      );
    });

    test('toMap 回写收敛后的档位（脏数据保存即自愈为 0）', () {
      expect(
        Book.fromMap(
          const {'uuid': 'u-1', 'title': '书A', 'memory_summary_rounds': 7},
        ).toMap()['memory_summary_rounds'],
        0,
        reason: '库内脏数据下次保存必须被改写为 0',
      );
      expect(
        const Book(title: '书A', memorySummaryRounds: 5).toMap()[
            'memory_summary_rounds'],
        5,
      );
      expect(
        Book.fromMap(
          const {'uuid': 'u-1', 'title': '书A', 'memory_summary_rounds': 10},
        ).toMap()['memory_summary_rounds'],
        10,
      );
    });

    test('copyWith：未指定时保留原档位，指定时更新', () {
      const book = Book(title: '书A', memorySummaryRounds: 5);
      expect(book.copyWith().memorySummaryRounds, 5);
      expect(book.copyWith(title: '书B').memorySummaryRounds, 5);
      expect(book.copyWith(memorySummaryRounds: 10).memorySummaryRounds, 10);
      expect(book.copyWith(memorySummaryRounds: 0).memorySummaryRounds, 0);
    });
  });
}
