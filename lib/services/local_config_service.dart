import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 本地数据配置文件服务（明文 JSON，Dart 原生 `dart:convert`，零额外依赖）。
///
/// 对应 `<文档目录>/NarrChat/local_config/app_settings.json`，
/// 存放 AI 设置（除 API Key）、UI 设置等无需云同步的本地数据；
/// 文件以带缩进的 JSON 明文存储，便于用户直接查看与便捷配置。
///
/// ⚠️ API Key 不写入本文件，一律走 flutter_secure_storage（系统密钥库）。
///
/// 并发安全：启动阶段 AI / UI / 云同步多个 Provider 会同时读写该文件，
/// `update()` 属于「读-改-写」整体操作，若不加串行化会发生丢失更新
/// （后写者基于旧快照覆盖先写者的键），导致本地设置偶发被清。
/// 因此 [read] / [write] / [update] 全部经过同一把异步互斥锁，
/// 且写入采用「临时文件 + 原子替换」，避免进程被杀时留下截断的 JSON。
class LocalConfigService {
  LocalConfigService._();

  static const String fileName = 'app_settings.json';

  /// 测试用配置根目录覆盖（null 时走真实 [AppPaths.localConfig]）。
  @visibleForTesting
  static String? testRootOverride;

  /// 串行化所有文件操作的异步互斥链。
  static Future<void> _queue = Future<void>.value();

  /// 配置文件路径（local_config 目录不存在时自动创建）。
  static Future<File> file() async {
    final dir = testRootOverride != null
        ? Directory(p.join(testRootOverride!, 'local_config'))
        : await AppPaths.localConfig();
    await dir.create(recursive: true);
    return File(p.join(dir.path, fileName));
  }

  /// 将 [task] 排入互斥队列，保证同一时刻只有一个文件操作在执行。
  static Future<T> _runLocked<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    // 队列本身不吞掉异常：让调用方感知失败，同时保证后续任务不被卡死。
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// 读取整个配置（JSON Map）；文件不存在或解析失败时返回空 Map。
  static Future<Map<String, dynamic>> read() {
    return _runLocked(() async {
      try {
        final configFile = await file();
        if (!await configFile.exists()) return <String, dynamic>{};
        final decoded = jsonDecode(await configFile.readAsString());
        if (decoded is Map<String, dynamic>) return decoded;
        return <String, dynamic>{};
      } catch (_) {
        return <String, dynamic>{};
      }
    });
  }

  /// 读取单个配置项；不存在或类型不符时返回 [fallback]。
  static Future<T?> readValue<T>(String key, {T? fallback}) async {
    final map = await read();
    return (map[key] as T?) ?? fallback;
  }

  /// 整体覆盖写入（带缩进格式化，便于人工阅读与编辑）。
  static Future<void> write(Map<String, dynamic> data) {
    return _runLocked(() async {
      final configFile = await file();
      await _writeAtomic(configFile, data);
    });
  }

  /// 局部更新：读取现有配置后合并 [patch] 再写回。
  ///
  /// 「读-改-写」整体处于互斥区内，不会与其他 Provider 的写入交错，
  /// 因此不会基于过期快照覆盖掉刚写入的其他键。
  static Future<void> update(Map<String, dynamic> patch) {
    return _runLocked(() async {
      final configFile = await file();
      final map = await _readFile(configFile);
      map.addAll(patch);
      await _writeAtomic(configFile, map);
    });
  }

  static Future<Map<String, dynamic>> _readFile(File file) async {
    try {
      if (!await file.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// 原子替换写入：先写同目录临时文件，再 rename 覆盖目标文件，
  /// 避免进程在写入中途被杀时目标文件被截断（下次读取会当成空配置）。
  /// Dart 的 [File.rename] 会先移除已存在的目标文件，可直接覆盖。
  static Future<void> _writeAtomic(
    File target,
    Map<String, dynamic> data,
  ) async {
    final tempFile = File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await tempFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
        flush: true,
      );
      await tempFile.rename(target.path);
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }
}
