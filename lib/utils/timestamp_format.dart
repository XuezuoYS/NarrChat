/// R3 全库统一的时间戳格式：`YYYY-MM-DDTHH:MM:SS.sssZ`（UTC、毫秒补零、带 `Z`）。
///
/// 为什么不用 `DateTime.toIso8601String()`：它在微秒非零时会写成
/// `...:54.123456Z`，定长与字典序都会被打乱。R3 约定时间戳**定长**，
/// 因此比较 / 排序直接走字符串字典序，禁止用 `datetime()` / `strftime()`。
library;

final RegExp _isoPattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{3})Z$',
);

/// 把 [time] 格式化成 R3 标准时间戳（内部先转 UTC）。
String formatTimestamp(DateTime time) {
  final u = time.toUtc();
  final buf = StringBuffer()
    ..write(u.year.toString().padLeft(4, '0'))
    ..write('-')
    ..write(u.month.toString().padLeft(2, '0'))
    ..write('-')
    ..write(u.day.toString().padLeft(2, '0'))
    ..write('T')
    ..write(u.hour.toString().padLeft(2, '0'))
    ..write(':')
    ..write(u.minute.toString().padLeft(2, '0'))
    ..write(':')
    ..write(u.second.toString().padLeft(2, '0'))
    ..write('.')
    ..write(u.millisecond.toString().padLeft(3, '0'))
    ..write('Z');
  return buf.toString();
}

/// 当前时间的 R3 标准时间戳。
String nowTimestamp() => formatTimestamp(DateTime.now());

/// 解析 R3 标准时间戳；格式不符或为空返回 `null`。
///
/// 刻意只接受定长格式（而不是 `DateTime.tryParse` 的宽松解析）：
/// 宽松解析会把语言环境相关的串也吞进来，读路径应当尽早暴露脏数据。
DateTime? parseTimestamp(Object? raw) {
  if (raw is! String) return null;
  final match = _isoPattern.firstMatch(raw);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  final milli = int.parse(match.group(7)!);
  return DateTime.utc(year, month, day, hour, minute, second, milli);
}

/// 解析时间戳；无效时返回 [fallback]（迁移 / 老数据兜底用）。
DateTime parseTimestampOr(Object? raw, DateTime fallback) =>
    parseTimestamp(raw) ?? fallback;
