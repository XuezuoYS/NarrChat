import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/manual_license.dart';

/// 手动补充的开放源代码许可证服务。
///
/// 打包资源 `assets/manual_licenses.json`（开发者维护）收录非 pub 依赖方式置入的
/// 开放源代码（复制的代码片段、内置字体/图标、打包的二进制等），避免许可证页遗漏。
///
/// 结构：
/// ```json
/// {
///   "licenses": [
///     {
///       "name": "SomeLibrary",
///       "version": "1.0.0",
///       "copyright": "Copyright (c) 2024 xxx",
///       "license": "MIT License\n\n...（多行，段落以空行分隔）"
///     }
///   ]
/// }
/// ```
class ManualLicensesService {
  ManualLicensesService._();

  /// 打包资源路径（已通过 `pubspec.yaml` 声明为 asset）。
  static const String assetPath = 'assets/manual_licenses.json';

  static bool _registered = false;

  static List<ManualLicense>? _cache;

  /// 将手动补充的许可证注册进 [LicenseRegistry]（幂等）。
  ///
  /// collector 为懒加载闭包：仅当访问 `LicenseRegistry.licenses`（即打开许可证页）时
  /// 才解析资源并产出条目，因此启动时调用零开销，且与 Flutter 自动收集的依赖许可证
  /// 在同一个数据源中无缝合并。
  static void register() {
    if (_registered) return;
    _registered = true;
    LicenseRegistry.addLicense(() async* {
      for (final entry in await load()) {
        yield LicenseEntryWithLineBreaks([entry.name], entry.license);
      }
    });
  }

  /// 读取并解析手动许可证清单（带缓存）。
  ///
  /// [raw] 仅供测试注入原始 JSON 文本；正常调用传 null，从打包资源读取。
  /// 解析失败时打印错误并返回空列表（不阻塞启动、不崩溃）。
  static Future<List<ManualLicense>> load({String? raw}) async {
    if (raw == null && _cache != null) return _cache!;
    try {
      final source = raw ?? await rootBundle.loadString(assetPath);
      final list = parse(source);
      if (raw == null) _cache = list;
      return list;
    } catch (e) {
      debugPrint('手动许可证清单解析失败: $e');
      if (raw == null) _cache = const [];
      return const [];
    }
  }

  /// 解析清单 JSON 文本为条目列表。
  ///
  /// - 非法 JSON / 结构不符：抛出 [FormatException]（由 [load] 兜底）；
  /// - `name` 或 `license` 为空 / 缺失的条目会被过滤掉。
  static List<ManualLicense> parse(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('manual_licenses.json 顶层结构应为对象');
    }
    final list = json['licenses'];
    if (list is! List<dynamic>) {
      throw const FormatException('manual_licenses.json 缺少 licenses 数组');
    }
    return list
        .whereType<Map<String, dynamic>>()
        .map(ManualLicense.fromJson)
        .where((e) => e.name.isNotEmpty && e.license.isNotEmpty)
        .toList();
  }
}
