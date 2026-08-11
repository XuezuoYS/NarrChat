import '../models/book.dart';
import 'pinyin_sort.dart';

/// 书籍列表排序模式。
enum BookSortMode {
  /// 最近对话时间（新 → 旧）。
  time('时间'),

  /// 标题 A-Z（按拼音）。
  az('A-Z');

  const BookSortMode(this.label);

  final String label;
}

/// 按搜索词过滤书籍（标题 / 分类，大小写不敏感）。
List<Book> filterBooks(List<Book> books, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return books;
  return books
      .where(
        (b) =>
            b.title.toLowerCase().contains(q) ||
            b.category.toLowerCase().contains(q),
      )
      .toList();
}

/// 对书籍排序。
///
/// - [BookSortMode.time]：按 [lastRoundTimes] 倒序（最近对话在前）；
///   无轮次的书排最后，相互之间按 id 倒序（新创建在前）。
/// - [BookSortMode.az]：标题拼音 A-Z，标题相同按 id 升序。
List<Book> sortBooks(
  List<Book> books,
  BookSortMode mode,
  Map<int, DateTime> lastRoundTimes,
) {
  final list = List.of(books);
  switch (mode) {
    case BookSortMode.time:
      list.sort((a, b) {
        final ta = lastRoundTimes[a.id];
        final tb = lastRoundTimes[b.id];
        if (ta == null && tb == null) {
          return (b.id ?? 0).compareTo(a.id ?? 0);
        }
        if (ta == null) return 1;
        if (tb == null) return -1;
        final c = tb.compareTo(ta);
        if (c != 0) return c;
        return (a.id ?? 0).compareTo(b.id ?? 0);
      });
    case BookSortMode.az:
      list.sort((a, b) {
        final c = PinyinSort.compare(a.title, b.title);
        if (c != 0) return c;
        return (a.id ?? 0).compareTo(b.id ?? 0);
      });
  }
  return list;
}

/// 最近对话时间的简短展示（用于列表项副信息）。
///
/// - 今天 → `今天 HH:mm`；昨天 → `昨天`；
/// - 今年 → `M-d`；更早 → `yyyy-M-d`；null → 空串。
String formatLastActivity(DateTime? time) {
  if (time == null) return '';
  final local = time.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final days = today.difference(day).inDays;
  if (days == 0) {
    return '今天 ${local.hour}:${local.minute.toString().padLeft(2, '0')}';
  }
  if (days == 1) return '昨天';
  if (local.year == now.year) {
    return '${local.month}-${local.day}';
  }
  return '${local.year}-${local.month}-${local.day}';
}
