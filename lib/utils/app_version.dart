/// 语义化版本号：轻量解析与比较（零依赖、零 IO）。
///
/// 用于「检查更新」：把本地 `release.yaml` 的 `version`（如 `1.3.1`）与
/// GitHub Release 的 `tag_name`（如 `v1.4.0`）归一化为数字段序列后逐段比较。
class AppVersion implements Comparable<AppVersion> {
  AppVersion._(this.segments);

  /// 数字段序列，如 `1.4.0` → `[1, 4, 0]`。
  final List<int> segments;

  /// 从任意字符串中提取版本号（容忍前导 `v`/`V` 与空白、前后缀文本）。
  ///
  /// 取首个形如 `\d+(\.\d+)*` 的片段；无法解析时返回 `null`。
  static AppVersion? tryParse(String raw) {
    final match = RegExp(r'\d+(\.\d+)*').firstMatch(raw);
    if (match == null) return null;
    final segments = match.group(0)!.split('.').map(int.parse).toList();
    if (segments.isEmpty) return null;
    return AppVersion._(segments);
  }

  /// 逐段数值比较：段数不同时缺失段按 0 计。
  ///
  /// 因此 `1.4` 与 `1.4.0` 相等，而 `1.4` > `1.3.9`。
  @override
  int compareTo(AppVersion other) {
    final len = segments.length > other.segments.length
        ? segments.length
        : other.segments.length;
    for (var i = 0; i < len; i++) {
      final a = i < segments.length ? segments[i] : 0;
      final b = i < other.segments.length ? other.segments[i] : 0;
      if (a != b) return a < b ? -1 : 1;
    }
    return 0;
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  bool operator <(AppVersion other) => compareTo(other) < 0;

  bool operator >=(AppVersion other) => compareTo(other) >= 0;

  bool operator <=(AppVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  /// 与 [==] 一致的哈希：先剥离末尾的 0 段（`1.3.0` 与 `1.3` 相等），
  /// 保证相等对象哈希相同（可安全用作 Set / Map 键）。
  @override
  int get hashCode {
    final canonical = [...segments];
    while (canonical.length > 1 && canonical.last == 0) {
      canonical.removeLast();
    }
    return Object.hashAll(canonical);
  }

  @override
  String toString() => segments.join('.');
}
