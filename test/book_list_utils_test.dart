import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/utils/book_list_utils.dart';

void main() {
  group('filterBooks', () {
    const books = [
      Book(id: 1, title: '剑来', category: '玄幻'),
      Book(id: 2, title: '三体', category: '科幻'),
      Book(id: 3, title: 'The Hobbit', category: 'Fantasy'),
    ];

    test('空查询返回全部', () {
      expect(filterBooks(books, ''), hasLength(3));
      expect(filterBooks(books, '   '), hasLength(3));
    });

    test('按标题过滤（大小写不敏感）', () {
      final r = filterBooks(books, '剑');
      expect(r.map((b) => b.id), [1]);
      final r2 = filterBooks(books, 'hobbit');
      expect(r2.map((b) => b.id), [3]);
    });

    test('按分类过滤', () {
      final r = filterBooks(books, '科幻');
      expect(r.map((b) => b.id), [2]);
    });

    test('无匹配返回空列表', () {
      expect(filterBooks(books, '不存在的书'), isEmpty);
    });
  });

  group('sortBooks A-Z', () {
    const books = [
      Book(id: 1, title: '张三'),
      Book(id: 2, title: '阿伟'),
      Book(id: 3, title: 'Book'),
      Book(id: 4, title: '张三'), // 标题相同按 id 升序
    ];

    test('汉字按拼音，非汉字原样', () {
      final r = sortBooks(books, BookSortMode.az, const {});
      expect(r.map((b) => b.id), [2, 3, 1, 4]); // 阿伟 < Book < 张三
    });

    test('标题相同按 id 升序', () {
      final r = sortBooks(books, BookSortMode.az, const {});
      expect(r[2].id, 1);
      expect(r[3].id, 4);
    });
  });

  group('sortBooks 时间', () {
    const books = [
      Book(id: 1, title: 'A'),
      Book(id: 2, title: 'B'),
      Book(id: 3, title: 'C'),
      Book(id: 4, title: 'D'),
    ];
    final times = {
      2: DateTime(2026, 8, 10),
      1: DateTime(2026, 8, 1),
    };

    test('最近对话在前，无对话排最后（按 id 倒序）', () {
      final r = sortBooks(books, BookSortMode.time, times);
      expect(r.map((b) => b.id), [2, 1, 4, 3]);
    });

    test('时间相同按 id 升序', () {
      final same = {1: DateTime(2026, 8, 1), 2: DateTime(2026, 8, 1)};
      final r = sortBooks(books, BookSortMode.time, same);
      expect(r.map((b) => b.id), [1, 2, 4, 3]);
    });

    test('全部无对话按 id 倒序', () {
      final r = sortBooks(books, BookSortMode.time, const {});
      expect(r.map((b) => b.id), [4, 3, 2, 1]);
    });
  });

  group('formatLastActivity', () {
    test('null 返回空串', () {
      expect(formatLastActivity(null), '');
    });

    test('今天显示 今天 HH:mm', () {
      final now = DateTime.now();
      final s = formatLastActivity(now);
      expect(s, startsWith('今天 '));
    });

    test('昨天显示 昨天', () {
      final y = DateTime.now().subtract(const Duration(days: 1));
      expect(formatLastActivity(y), '昨天');
    });

    test('今年显示 M-d', () {
      expect(formatLastActivity(DateTime(DateTime.now().year, 1, 1)), '1-1');
    });

    test('更早显示 yyyy-M-d', () {
      expect(formatLastActivity(DateTime(2000, 1, 2)), '2000-1-2');
    });
  });
}
