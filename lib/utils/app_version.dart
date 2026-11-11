/// 版本号：按 README「版本号规范」解析与比较（零依赖、零 IO）。
///
/// 规范（见 README）：
/// - 正式版：`a.b.c`；
/// - 测试版：`a.b.c-beta.d` / `a.b.c-rc.d`；
/// - 版本高低：先比 `a.b.c`；主体相同时 `beta < rc < 正式版`，同阶段再比 `d`。
///
/// GitHub tag 通常带 `v` 前缀（如 `v3.0.0-beta.2`），解析时允许；`+build`
/// 是构建元数据，不参与比较。除此之外的写法（缺段、多余段、规范外的阶段、
/// 前后夹带文字）一律视为无法解析并返回 `null`——宁可检查失败，也不按
/// 错误的版本号提示更新。
class AppVersion implements Comparable<AppVersion> {
  AppVersion._(
    this.major,
    this.minor,
    this.patch,
    this._stage,
    this.prereleaseNumber,
  );

  /// 只认规范里的两种形态（可带 `v` 前缀与 `+build` 元数据）。
  static final RegExp _pattern = RegExp(
    r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:-(beta|rc)\.(\d+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  /// 正式版第 1 段（`a.b.c` 的 `a`）。
  final int major;

  /// 正式版第 2 段（`a.b.c` 的 `b`）。
  final int minor;

  /// 正式版第 3 段（`a.b.c` 的 `c`）。
  final int patch;

  /// 测试阶段（`-beta.d` / `-rc.d`）；正式版为 `null`。
  final _ReleaseStage? _stage;

  /// 测试版序号 `d`（如 `-beta.4` 的 4）；正式版为 `null`。
  final int? prereleaseNumber;

  /// 是否为测试版（带 `-beta.d` / `-rc.d` 后缀）。
  bool get isPrerelease => _stage != null;

  /// 从 tag 或 `release.yaml` 的版本号解析；不合规范返回 `null`。
  static AppVersion? tryParse(String raw) {
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return null;
    return AppVersion._(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      switch (match.group(4)) {
        null => null,
        'beta' => _ReleaseStage.beta,
        _ => _ReleaseStage.rc,
      },
      match.group(5) == null ? null : int.parse(match.group(5)!),
    );
  }

  /// 按规范比较：先比 `a.b.c`；主体相同时 正式版 > rc > beta；同阶段比 `d`。
  @override
  int compareTo(AppVersion other) {
    var result = major.compareTo(other.major);
    if (result != 0) return result;
    result = minor.compareTo(other.minor);
    if (result != 0) return result;
    result = patch.compareTo(other.patch);
    if (result != 0) return result;
    final rank = _stage?.rank ?? _formalRank;
    final otherRank = other._stage?.rank ?? _formalRank;
    if (rank != otherRank) return rank.compareTo(otherRank);
    final number = prereleaseNumber;
    if (number == null) return 0; // 两边都是正式版
    return number.compareTo(other.prereleaseNumber!);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  bool operator <(AppVersion other) => compareTo(other) < 0;

  bool operator >=(AppVersion other) => compareTo(other) >= 0;

  bool operator <=(AppVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  /// 与 [==] 一致：解析时数字段已归一化（如 `beta.01` 与 `beta.1` 相同），
  /// 构建元数据不参与，因此相等对象哈希相同。
  @override
  int get hashCode =>
      Object.hash(major, minor, patch, _stage, prereleaseNumber);

  @override
  String toString() {
    final currentStage = _stage;
    if (currentStage == null) return '$major.$minor.$patch';
    return '$major.$minor.$patch-${currentStage.name}.$prereleaseNumber';
  }
}

/// 测试阶段，顺序与 README 示例一致（beta 早于 rc）。
enum _ReleaseStage {
  beta(0),
  rc(1);

  const _ReleaseStage(this.rank);

  /// 升序比较用的序号；正式版在 [AppVersion.compareTo] 里按 2 处理。
  final int rank;
}

/// 正式版的阶段序号（大于 beta / rc）。
const int _formalRank = 2;
