import '../models/book.dart';
import 'pinyin_sort.dart';
import 'search_utils.dart';

/// 书籍列表排列方式（首页方格 / 列表切换）。
enum BookLayoutMode {
  /// 方格排列（首页默认）。
  grid('方格排列'),

  /// 列表排列（沿用原书籍列表样式）。
  list('列表排列');

  const BookLayoutMode(this.label);

  /// 界面展示 / tooltip 文案。
  final String label;
}

/// 书籍列表排序模式。
enum BookSortMode {
  /// 更新时间（`book_meta.updated_at`，新 → 旧；首页默认）。
  time('更新时间'),

  /// 标题 A-Z（按拼音）。
  az('A-Z');

  const BookSortMode(this.label);

  final String label;
}

/// 首页方格排列的目标最小卡片宽度（px）。
const double kBookGridMinCardWidth = 160;

/// 首页方格排列的横向 / 纵向间距（px）。
const double kBookGridSpacing = 16;

/// 按可用宽度计算首页方格的每行书籍数。
///
/// 目标是让卡片宽度尽量接近 [kBookGridMinCardWidth]：
/// - 手机窄屏至少 2 列（卡片略缩小，而不是单列巨卡）；
/// - 宽屏按 `floor((可用宽 + 间距) / (最小宽 + 间距))` 扩展。
/// 非有限宽度 / 0 宽返回 1，交给布局层自行处理。
int bookGridColumns(double availableWidth) {
  if (!availableWidth.isFinite || availableWidth <= 0) return 1;
  final count =
      ((availableWidth + kBookGridSpacing) /
              (kBookGridMinCardWidth + kBookGridSpacing))
          .floor();
  return count < 2 ? 2 : count;
}

/// 按搜索词过滤书籍（标题 / 分类，大小写不敏感）。
///
/// 支持多关键词模糊搜索：以空格分隔关键词，所有关键词都必须命中
/// （每个关键词命中标题或分类即可），如 `"修仙 剑"`。
List<Book> filterBooks(List<Book> books, String query) {
  final keywords = splitKeywords(query);
  if (keywords.isEmpty) return books;
  return books
      .where((b) => matchesKeywords(keywords, [b.title, b.category]))
      .toList();
}

/// 对书籍排序。
///
/// [updatedTimes] 以书籍 uuid 为键，值为 `book_meta.updated_at`
/// （首页读取的缓存副本，见 `BookRepository.updatedTimes`）。
///
/// - [BookSortMode.time]：按更新时间倒序（新在前）；没有时间的书排最后，
///   相互之间按 uuid 稳定排序；时间相同也按 uuid 稳定排序。
/// - [BookSortMode.az]：标题拼音 A-Z，标题相同按 uuid 升序。
///
/// 一律以 uuid 决胜，不依赖创建先后 / 行序——那些是本地自增语义，跨设备不一致。
List<Book> sortBooks(
  List<Book> books,
  BookSortMode mode,
  Map<String, DateTime> updatedTimes,
) {
  final list = List.of(books);
  switch (mode) {
    case BookSortMode.time:
      list.sort((a, b) {
        final ta = updatedTimes[a.uuid];
        final tb = updatedTimes[b.uuid];
        if (ta == null && tb == null) {
          return b.uuid.compareTo(a.uuid); // 无时间：相互之间按 uuid 稳定排序
        }
        if (ta == null) return 1;
        if (tb == null) return -1;
        final c = tb.compareTo(ta);
        if (c != 0) return c;
        return a.uuid.compareTo(b.uuid);
      });
    case BookSortMode.az:
      list.sort((a, b) {
        final c = PinyinSort.compare(a.title, b.title);
        if (c != 0) return c;
        return a.uuid.compareTo(b.uuid);
      });
  }
  return list;
}

/// 更新时间的简短展示（用于列表项副信息）。
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
