import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 本地数据配置文件服务（明文 JSON，Dart 原生 `dart:convert`，零额外依赖）。
///
/// 对应 `<文档目录>/NarrChat/local_config/app_settings.json`，
/// 存放 AI 设置（除 API Key）、UI 设置等无需云同步的本地数据；
/// 文件以带缩进的 JSON 明文存储，便于用户直接查看与便捷配置。
///
/// ⚠️ API Key 不写入本文件，一律走 flutter_secure_storage（系统密钥库）。
class LocalConfigService {
  LocalConfigService._();

  static const String fileName = 'app_settings.json';

  /// 配置文件路径（local_config 目录不存在时自动创建）。
  static Future<File> file() async {
    final dir = await AppPaths.localConfig();
    return File(p.join(dir.path, fileName));
  }

  /// 读取整个配置（JSON Map）；文件不存在或解析失败时返回空 Map。
  static Future<Map<String, dynamic>> read() async {
    try {
      final configFile = await file();
      if (!await configFile.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await configFile.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// 读取单个配置项；不存在或类型不符时返回 [fallback]。
  static Future<T?> readValue<T>(String key, {T? fallback}) async {
    final map = await read();
    return (map[key] as T?) ?? fallback;
  }

  /// 整体覆盖写入（带缩进格式化，便于人工阅读与编辑）。
  static Future<void> write(Map<String, dynamic> data) async {
    final configFile = await file();
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
  }

  /// 局部更新：读取现有配置后合并 [patch] 再写回。
  static Future<void> update(Map<String, dynamic> patch) async {
    final map = await read();
    map.addAll(patch);
    await write(map);
  }
}
