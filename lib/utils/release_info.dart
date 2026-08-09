import 'package:flutter/services.dart';

/// 从打包进应用的 `release.yaml` 读取版本信息。
///
/// `release.yaml` 已通过 `pubspec.yaml` 声明为资源（asset），
/// 运行时通过 [rootBundle] 加载，因此「关于」面板无需硬编码版本号。
class ReleaseInfo {
  ReleaseInfo._();

  /// 读取失败时的兜底版本号。
  static const String defaultVersion = '1.0.0';

  static String? _version;

  /// 读取应用版本号（异步，带缓存）。
  static Future<String> version() async {
    if (_version != null) return _version!;
    try {
      final raw = await rootBundle.loadString('release.yaml');
      _version = _parseVersion(raw) ?? defaultVersion;
    } catch (_) {
      _version = defaultVersion;
    }
    return _version!;
  }

  /// 从 YAML 文本中提取 `version` 字段（轻量解析，避免额外依赖）。
  static String? _parseVersion(String raw) {
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final match = RegExp(r'^version\s*:\s*(\S+)').firstMatch(trimmed);
      if (match != null) return match.group(1);
    }
    return null;
  }
}
