/// 通用格式化工具（时间、字节数等）。
///
/// 集中管理补零、日期时间、文件大小等格式化逻辑，
/// 供云同步面板、侧边栏等多处复用，避免重复实现。
class Formats {
  Formats._();

  /// 两位补零（如 `3` → `03`）。
  static String two(int n) => n.toString().padLeft(2, '0');

  /// 字节数的人类可读格式（B / KB / MB）。
  static String formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  /// 本地时间格式化：`yyyy-MM-dd HH:mm:ss`。
  static String formatDateTime(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  /// 仅时间部分：`HH:mm:ss`。
  static String formatTimeOfDay(DateTime t) {
    final l = t.toLocal();
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  /// 「无数据」占位文本（模型未返回该字段 / 数据库无该列值）。
  static const String noData = '（无）';

  /// Token 数量展示：无数据（null）→ [noData]，否则原样十进制数字。
  static String formatTokenCount(int? count) =>
      count == null ? noData : '$count';

  /// 缓存命中率（如 `49.4%`）：缓存命中输入 token / 输入 token。
  ///
  /// 任一侧无数据（null）或输入为 0 → null（调用方显示 [noData]）。
  /// 保留一位小数；末位 `.0` 省略；**未真正全命中时绝不四舍五入成 100%**
  /// （逐位增加精度直到小于 100，最多 4 位）。
  static String? formatCacheHitRate(int? cachedTokensIn, int? tokensIn) {
    if (cachedTokensIn == null || tokensIn == null || tokensIn <= 0) return null;
    if (cachedTokensIn >= tokensIn) return '100%';
    final percent = cachedTokensIn * 100 / tokensIn;
    for (var digits = 1; digits <= 4; digits++) {
      final text = percent.toStringAsFixed(digits);
      if (double.parse(text) < 100) {
        return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}%';
      }
    }
    return '<100%';
  }
}
