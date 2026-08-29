import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/utils/book_list_utils.dart';

/// 首页书籍列表的搜索过滤与排序逻辑单元测试（纯函数，无需 widget）。
///
/// 书籍唯一身份是 uuid（TEXT 主键）：所有并列决胜都按 uuid 比较，
/// 与创建先后 / 列表入参顺序无关（那是旧的本地自增语义，跨设备不一致）。
void main() {
  group('filterBooks', () {
    const books = [
      Book(uuid: 'b1', title: '剑来', category: '玄幻'),
      Book(uuid: 'b2', title: '三体', category: '科幻'),
      Book(uuid: 'b3', title: 'The Hobbit', category: 'Fantasy'),
    ];

    test('空查询返回全部', () {
      expect(filterBooks(books, ''), hasLength(3));
      expect(filterBooks(books, '   '), hasLength(3));
    });

    test('按标题过滤（大小写不敏感）', () {
      final r = filterBooks(books, '剑');
      expect(r.map((b) => b.uuid), ['b1']);
      final r2 = filterBooks(books, 'hobbit');
      expect(r2.map((b) => b.uuid), ['b3']);
    });

    test('按分类过滤', () {
      final r = filterBooks(books, '科幻');
      expect(r.map((b) => b.uuid), ['b2']);
    });

    test('多关键词：全部命中才通过（标题或分类）', () {
      final r = filterBooks(books, '剑 玄幻');
      expect(r.map((b) => b.uuid), ['b1']);
    });

    test('多关键词：部分命中不通过', () {
      expect(filterBooks(books, '剑 科幻'), isEmpty);
    });

    test('多关键词：可跨字段命中（标题 + 分类）', () {
      final r = filterBooks(books, '三 科');
      expect(r.map((b) => b.uuid), ['b2']);
    });

    test('多关键词：大小写不敏感且忽略多余空格', () {
      final r = filterBooks(books, '  hobbit   fantasy  ');
      expect(r.map((b) => b.uuid), ['b3']);
    });

    test('无匹配返回空列表', () {
      expect(filterBooks(books, '不存在的书'), isEmpty);
    });
  });

  group('sortBooks A-Z', () {
    const books = [
      Book(uuid: 'b1', title: '张三'),
      Book(uuid: 'b2', title: '阿伟'),
      Book(uuid: 'b3', title: 'Book'),
      Book(uuid: 'b4', title: '张三'), // 标题相同按 uuid 升序
    ];

    test('汉字按拼音，非汉字原样', () {
      final r = sortBooks(books, BookSortMode.az, const {});
      expect(r.map((b) => b.uuid), ['b2', 'b3', 'b1', 'b4']); // 阿伟 < Book < 张三
    });

    test('标题相同按 uuid 升序', () {
      final r = sortBooks(books, BookSortMode.az, const {});
      expect(r[2].uuid, 'b1');
      expect(r[3].uuid, 'b4');
    });
  });

  group('sortBooks 时间', () {
    const books = [
      Book(uuid: 'b1', title: 'A'),
      Book(uuid: 'b2', title: 'B'),
      Book(uuid: 'b3', title: 'C'),
      Book(uuid: 'b4', title: 'D'),
    ];
    final times = {
      'b2': DateTime(2026, 8, 10),
      'b1': DateTime(2026, 8, 1),
    };

    test('最近对话在前，无对话排最后（无轮次之间按 uuid 倒序）', () {
      final r = sortBooks(books, BookSortMode.time, times);
      expect(r.map((b) => b.uuid), ['b2', 'b1', 'b4', 'b3']);
    });

    test('时间相同按 uuid 升序', () {
      final same = {
        'b1': DateTime(2026, 8, 1),
        'b2': DateTime(2026, 8, 1),
      };
      final r = sortBooks(books, BookSortMode.time, same);
      expect(r.map((b) => b.uuid), ['b1', 'b2', 'b4', 'b3']);
    });

    test('全部无对话按 uuid 倒序（不再暗示“新建在前”）', () {
      final r = sortBooks(books, BookSortMode.time, const {});
      expect(r.map((b) => b.uuid), ['b4', 'b3', 'b2', 'b1']);
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
