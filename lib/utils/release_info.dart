import 'package:flutter/services.dart';

/// 从打包进应用的 `release.yaml` 读取版本信息。
///
/// `release.yaml` 已通过 `pubspec.yaml` 声明为资源（asset），
/// 运行时通过 [rootBundle] 加载，因此「关于」面板无需硬编码版本号。
class ReleaseInfo {
  ReleaseInfo._();

  /// 读取失败时的兜底版本号。
  static const String defaultVersion = '1.0.0';

  /// 读取失败时的兜底构建号。
  static const String defaultBuild = '0';

  static Map<String, String>? _info;

  /// 读取 `release.yaml` 中的版本信息（异步，带缓存）。
  static Future<Map<String, String>> _load() async {
    if (_info != null) return _info!;
    try {
      final raw = await rootBundle.loadString('release.yaml');
      _info = {
        'version': _parseField(raw, 'version') ?? defaultVersion,
        'build': _parseField(raw, 'build') ?? defaultBuild,
      };
    } catch (_) {
      _info = {'version': defaultVersion, 'build': defaultBuild};
    }
    return _info!;
  }

  /// 读取应用版本号，如 `1.2.3`。
  static Future<String> version() async => (await _load())['version']!;

  /// 组合显示文本，如 `1.2.3 (build.28)`。
  static Future<String> versionLabel() async {
    final info = await _load();
    return '${info['version']} (build.${info['build']})';
  }

  /// 从 YAML 文本中提取指定字段（轻量解析，避免额外依赖）。
  static String? _parseField(String raw, String field) {
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final match = RegExp('^$field\\s*:\\s*(\\S+)').firstMatch(trimmed);
      if (match != null) return match.group(1);
    }
    return null;
  }
}
