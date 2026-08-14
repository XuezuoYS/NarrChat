import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/services/world_book_scanner.dart';

/// WorldBookScanner 关键词扫描逻辑单元测试（原 widget_test.dart 拆分而来）。
void main() {
  group('WorldBookScanner', () {
    test('命中关键词注入内容，未命中返回空', () {
      const scanner = WorldBookScanner();
      const entry = WorldBookEntry(
        id: 1,
        bookId: 1,
        keyword: '青云宗, 苏清月',
        content: '青云宗是北域的修仙大派。',
        isActive: true,
      );
      // 命中
      final hit = scanner.scan(
        userInput: '苏清月带我去了青云宗',
        historyRounds: const [],
        entries: const [entry],
      );
      expect(hit, contains('青云宗是北域的修仙大派。'));
      // 未命中
      final miss = scanner.scan(
        userInput: '我走在集市上',
        historyRounds: const [],
        entries: const [entry],
      );
      expect(miss, isEmpty);
    });

    test('停用条目不参与扫描', () {
      const scanner = WorldBookScanner();
      const entry = WorldBookEntry(
        id: 1,
        bookId: 1,
        keyword: '青云宗',
        content: '青云宗是北域的修仙大派。',
        isActive: false,
      );
      final result = scanner.scan(
        userInput: '青云宗',
        historyRounds: const [],
        entries: const [entry],
      );
      expect(result, isEmpty);
    });

    test('可从历史轮次中命中', () {
      const scanner = WorldBookScanner();
      const entry = WorldBookEntry(
        id: 1,
        bookId: 1,
        keyword: '青云宗',
        content: '青云宗是北域的修仙大派。',
        isActive: true,
      );
      final result = scanner.scan(
        userInput: '继续前行',
        historyRounds: const [
          Round(bookId: 1, roundIndex: 1, userInput: '我进入了青云宗'),
        ],
        entries: const [entry],
      );
      expect(result, contains('青云宗是北域的修仙大派。'));
    });
  });
}
