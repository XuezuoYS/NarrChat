/// 语义化版本号：轻量解析与比较（零依赖、零 IO）。
///
/// 用于「检查更新」：把本地 `release.yaml` 的 `version`（如 `1.3.1`）与
/// GitHub Release 的 `tag_name`（如 `v1.4.0`）归一化为数字段序列后逐段比较。
///
/// 预发布后缀（`-beta.1` / `-rc.2`）按语义化版本规则参与比较，因此本地
/// 自己跑 beta 构建时，也能正确判断远端 beta 与正式版谁更新：
/// `1.4.0-beta.1 < 1.4.0-beta.2 < 1.4.0`。
class AppVersion implements Comparable<AppVersion> {
  AppVersion._(this.segments, this.prerelease);

  /// 版本主体（数字段 + 预发布后缀）的匹配：`1.4.0` / `v1.4.0-beta.1`。
  ///
  /// 第 1 组为数字段，第 2 组为可选的预发布后缀（`-` 之后、`+` 之前）。
  static final RegExp _pattern = RegExp(
    r'(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?',
  );

  /// 数字段序列，如 `1.4.0` → `[1, 4, 0]`。
  final List<int> segments;

  /// 预发布标识符，如 `-beta.1` → `['beta', '1']`；空列表表示正式版。
  final List<String> prerelease;

  /// 从任意字符串中提取版本号（容忍前导 `v`/`V` 与空白、前后缀文本）。
  ///
  /// 取首个形如 `\d+(.\d+)*` 的片段；紧跟的 `-xxx` 视为预发布后缀
  /// （`beta.1` / `rc.2` 等），构建元数据（如 `+build.5`）忽略。
  /// 无法解析时返回 `null`。
  static AppVersion? tryParse(String raw) {
    final match = _pattern.firstMatch(raw);
    if (match == null) return null;
    final segments = match.group(1)!.split('.').map(int.parse).toList();
    if (segments.isEmpty) return null;
    final suffix = match.group(2);
    return AppVersion._(
      segments,
      suffix == null ? const [] : suffix.split('.'),
    );
  }

  /// 逐段数值比较：段数不同时缺失段按 0 计。
  ///
  /// 因此 `1.4` 与 `1.4.0` 相等，而 `1.4` > `1.3.9`；主体相同时再比预发布
  /// 后缀（同号正式版高于预发布版，`beta.2` 高于 `beta.1`）。
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
    return _comparePrerelease(prerelease, other.prerelease);
  }

  /// 预发布后缀比较（语义化版本 11 条）：正式版 > 预发布版；标识符逐位比较，
  /// 数字标识符按数值且恒小于字母标识符；前缀相同则标识符更多者更高。
  static int _comparePrerelease(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) {
      if (a.isEmpty && b.isEmpty) return 0;
      return a.isEmpty ? 1 : -1;
    }
    final len = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final cmp = _compareIdentifier(a[i], b[i]);
      if (cmp != 0) return cmp;
    }
    return a.length.compareTo(b.length);
  }

  static int _compareIdentifier(String a, String b) {
    final aNumber = int.tryParse(a);
    final bNumber = int.tryParse(b);
    if (aNumber != null && bNumber != null) return aNumber.compareTo(bNumber);
    if (aNumber != null) return -1;
    if (bNumber != null) return 1;
    return a.compareTo(b);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  bool operator <(AppVersion other) => compareTo(other) < 0;

  bool operator >=(AppVersion other) => compareTo(other) >= 0;

  bool operator <=(AppVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  /// 与 [==] 一致的哈希：先剥离末尾的 0 段（`1.3.0` 与 `1.3` 相等），
  /// 再并入预发布后缀，保证相等对象哈希相同（可安全用作 Set / Map 键）。
  @override
  int get hashCode {
    final canonical = [...segments];
    while (canonical.length > 1 && canonical.last == 0) {
      canonical.removeLast();
    }
    return Object.hash(
      Object.hashAll(canonical),
      prerelease.isEmpty ? null : Object.hashAll(prerelease),
    );
  }

  @override
  String toString() => prerelease.isEmpty
      ? segments.join('.')
      : '${segments.join('.')}-${prerelease.join('.')}';
}
