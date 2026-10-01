import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';

/// `books` 表 ↔ [Book] 的列映射（uuid 即主键）。
///
/// 重点覆盖 v18 新增配置项「记忆总结压缩轮次」（0 = 关闭，档位 5 / 10，无负数）：
/// 缺列 / 空值一律落到默认 0，且 `toMap` 必须带该列——否则保存设置会丢档位。
void main() {
  test('记忆总结压缩轮次：缺列 / 空值默认 0，fromMap 读取档位', () {
    expect(const Book(title: '书A').memorySummaryRounds, 0);
    expect(
      Book.fromMap(const {'uuid': 'u-1', 'title': '书A'}).memorySummaryRounds,
      0,
      reason: 'v18 之前的行没有该列，读作关闭',
    );
    expect(
      Book.fromMap(const {
        'uuid': 'u-1',
        'title': '书A',
        'memory_summary_rounds': null,
      }).memorySummaryRounds,
      0,
    );
    expect(
      Book.fromMap(const {
        'uuid': 'u-1',
        'title': '书A',
        'memory_summary_rounds': 5,
      }).memorySummaryRounds,
      5,
    );
    expect(
      Book.fromMap(const {
        'uuid': 'u-1',
        'title': '书A',
        'memory_summary_rounds': 10,
      }).memorySummaryRounds,
      10,
    );
  });

  test('记忆总结压缩轮次：toMap 回写该列，往返一致', () {
    const book = Book(title: '书A', memorySummaryRounds: 5);
    expect(book.toMap()['memory_summary_rounds'], 5);
    expect(Book.fromMap(book.toMap()).memorySummaryRounds, 5);
    const off = Book(title: '书A');
    expect(off.toMap()['memory_summary_rounds'], 0);
    expect(Book.fromMap(off.toMap()).memorySummaryRounds, 0);
  });

  test('copyWith：未指定时保留原档位，指定时更新（含回到 0 关闭）', () {
    const book = Book(title: '书A', memorySummaryRounds: 5);
    expect(book.copyWith().memorySummaryRounds, 5);
    expect(book.copyWith(title: '书B').memorySummaryRounds, 5);
    expect(book.copyWith(memorySummaryRounds: 10).memorySummaryRounds, 10);
    expect(book.copyWith(memorySummaryRounds: 0).memorySummaryRounds, 0);
  });
}
