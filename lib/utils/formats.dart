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

  /// 备份元信息：`时间 · 大小`（各自可缺省）。
  static String formatBackupMeta({DateTime? modified, int size = 0}) {
    final parts = <String>[];
    if (modified != null) parts.add(formatDateTime(modified));
    if (size > 0) parts.add(formatBytes(size));
    return parts.join(' · ');
  }
}
