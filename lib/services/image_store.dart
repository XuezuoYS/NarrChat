import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 图片导入 / 管理服务。
///
/// 图片统一存于 `user_data/img/`（与 `narrchat.db` 同级），以**内容 SHA-256**
/// 命名去重：同内容的文件得到相同文件名，重复导入直接复用，天然去重。
///
/// 数据库记录的是相对路径（`img/<hash>.png`，相对 `user_data/`）；本服务负责
/// 「相对路径 ↔ 绝对路径」「存在性检查」「字节读取」与「删除」，供显存与请求发送使用。
class ImageStore {
  ImageStore._();

  /// 允许的扩展名（导入时归一化，img 目录内统一为小写扩展名）。
  static const Set<String> allowedExtensions = {'png', 'jpg', 'jpeg'};

  /// img 目录在 `user_data/` 下的相对路径前缀（DB 中以此为基）。
  static const String relativeDir = 'img';

  /// 测试用根目录覆盖（覆盖 `user_data/` 的基目录；null 走真实 [AppPaths.userData]）。
  @visibleForTesting
  static String? testUserDataRoot;

  /// 归一化并校验扩展名；非法抛 [ImageFormatException]，合法返回小写扩展名（不带点）。
  static String normalizeExt(String filename) {
    final ext = p.extension(filename).toLowerCase().replaceFirst('.', '');
    if (!allowedExtensions.contains(ext)) {
      throw ImageFormatException('仅支持 png / jpg / jpeg 格式');
    }
    return ext;
  }

  static Future<Directory> _imgDir() async {
    final userData = testUserDataRoot != null
        ? Directory(testUserDataRoot!)
        : await AppPaths.userData();
    final dir = Directory(p.join(userData.path, relativeDir));
    await dir.create(recursive: true);
    return dir;
  }

  /// img 目录（不存在则创建）。供「存储管理」列出 / 管理本地图片。
  static Future<Directory> imgDirectory() => _imgDir();

  static Future<File> _file(String relPath) async {
    // 仅允许 img 目录下的相对路径，防止路径逃逸。
    final normalized = relPath.replaceAll('\\', '/');
    if (!normalized.startsWith('$relativeDir/')) {
      throw ImageFormatException('非法图片路径');
    }
    final img = await _imgDir();
    return File(p.join(img.path, normalized.substring(relativeDir.length + 1)));
  }

  /// 保存图片字节，按内容哈希命名；同内容已存在则直接复用（去重）。
  ///
  /// 返回应写入数据库的相对路径（`img/<hash>.<ext>`）。
  ///
  /// [convertJpgToJpeg] 为 true 且源文件为 `.jpg` 时，落盘扩展名改写为 `.jpeg`
  /// （`.jpg` / `.jpeg` 同为 JPEG 编码，仅改扩展名以匹配 `data:image/jpeg`，
  /// 供不支持 `image/jpg` 的识别接口使用；无重编码、无质量损失）。
  static Future<String> saveBytes(
    Uint8List bytes, {
    required String filename,
    bool convertJpgToJpeg = false,
  }) async {
    final srcExt = normalizeExt(filename);
    final ext = (convertJpgToJpeg && srcExt == 'jpg') ? 'jpeg' : srcExt;
    final digest = sha256.convert(bytes).toString();
    final relPath = '$relativeDir/$digest.$ext';
    final file = await _file(relPath);
    if (!await file.exists()) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return relPath;
  }

  /// 相对路径对应的文件是否存在（路径为空 / 非法 / 缺失均返回 false）。
  static Future<bool> exists(String relPath) async {
    if (relPath.isEmpty) return false;
    try {
      return await (await _file(relPath)).exists();
    } catch (_) {
      return false;
    }
  }

  /// 相对路径 → 绝对路径（用于显示 FileImage / 读取字节）。
  /// 目录/路径非法时仍返回拼接结果，读取时按需容错。
  static Future<String> resolveAbsolute(String relPath) async {
    return (await _file(relPath)).path;
  }

  /// 读取图片字节（用于 base64 发送）。
  static Future<Uint8List> readBytes(String relPath) async {
    return (await _file(relPath)).readAsBytes();
  }

  /// 从相对路径取出原始文件名（占位图 / 展示用）。
  static String fileNameOf(String relPath) => p.basename(relPath);
}

/// 图片格式 / 路径异常（中文友好提示）。
class ImageFormatException implements Exception {
  final String message;

  const ImageFormatException(this.message);

  @override
  String toString() => message;
}
