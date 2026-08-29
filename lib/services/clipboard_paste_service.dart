import 'dart:io' show File, Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pasteboard/pasteboard.dart';

import 'image_store.dart';

/// 剪贴板图片读取结果。
///
/// 成功返回落盘后的相对路径（`img/<hash>.<ext>`，可直接写入待发送附件）；
/// 超限或读取失败只写 [warning]（中文友好提示），二者互斥。
class ClipboardImageResult {
  final String? relPath;
  final String? warning;

  const ClipboardImageResult({this.relPath, this.warning});
}

/// 剪贴板读取服务（可注入替身）。
///
/// 抽象「读文本 / 判有无图片 / 读图片并校验大小 + 哈希去重落盘」，
/// 供测试注入假实现，避免触碰真实的 `pasteboard` 插件通道与真实文件系统。
/// 文本读取复用 Flutter 标准 [Clipboard]（仅支持纯文本）。
abstract class ClipboardPasteService {
  /// 剪贴板中的纯文本；无文本时返回 null。
  Future<String?> readText();

  /// 剪贴板是否包含图片（不做落盘，用于非识图场景的提示判定）。
  Future<bool> hasImage();

  /// 读取剪贴板 PNG 图片：超过 [sizeLimitMb] 跳过并给 [ClipboardImageResult.warning]；
  /// 否则经 [ImageStore.saveBytes] 以内容哈希去重落盘，返回相对路径。
  Future<ClipboardImageResult> readImagePng({
    required int sizeLimitMb,
    required bool convertJpgToJpeg,
  });
}

/// 真实实现：`pasteboard` 读 PNG 字节 + [ImageStore] 哈希去重保存。
class SystemClipboardPasteService implements ClipboardPasteService {
  const SystemClipboardPasteService();

  @override
  Future<String?> readText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  @override
  Future<bool> hasImage() async =>
      (await Pasteboard.image) != null || await _pickClipboardImageFile() != null;

  @override
  Future<ClipboardImageResult> readImagePng({
    required int sizeLimitMb,
    required bool convertJpgToJpeg,
  }) async {
    // 剪贴板为「文件复制」来源（查看器复制图片 / Explorer 复制图片文件）时，
    // 直接导入原始文件：保留原格式与字节（JPEG 复制后粘贴仍是 JPEG），
    // 不走「像素 → BMP → PNG」的读回链路（体积与格式均失真）。
    final file = await _pickClipboardImageFile();
    if (file != null) {
      return savePastedBytes(
        await file.readAsBytes(),
        sizeLimitMb: sizeLimitMb,
        convertJpgToJpeg: convertJpgToJpeg,
        fileName: p.basename(file.path),
      );
    }
    final bytes = await Pasteboard.image;
    if (bytes == null) return const ClipboardImageResult();
    return savePastedBytes(
      bytes,
      sizeLimitMb: sizeLimitMb,
      convertJpgToJpeg: convertJpgToJpeg,
    );
  }

  /// 剪贴板文件来源中的第一张图片文件（CF_HDROP，仅 Windows）。
  ///
  /// Android 的 `files()` 返回 content-uri（需 content resolver 读取），
  /// 不适合直接以文件读取，故仅 Windows 使用；找不到 / 读取失败返回 null。
  Future<File?> _pickClipboardImageFile() async {
    if (!Platform.isWindows) return null;
    try {
      final paths = await Pasteboard.files();
      for (final path in paths) {
        final file = File(path);
        if (file.existsSync() && _isImageFile(file.path)) return file;
      }
    } catch (_) {
      // 剪贴板通道不可用时忽略，退回像素读取。
    }
    return null;
  }

  bool _isImageFile(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return ImageStore.allowedExtensions.contains(ext);
  }

  /// 把剪贴板图片字节落盘：校验大小上限并以内容哈希去重保存。
  ///
  /// 拆为可见的纯逻辑（仅依赖 [ImageStore]），便于单独测试超限 / 落盘，
  /// 不触碰 `pasteboard` 平台通道。返回相对路径或超限/失败提示。
  ///
  /// Windows 上 `pasteboard` 读回的是**未压缩 32bpp BMP**（体积约为 PNG 的数倍，
  /// 会误触发「超过 N MB」限制），落盘前先经 [normalizeBmpToPng] 统一转为 PNG。
  @visibleForTesting
  static Future<ClipboardImageResult> savePastedBytes(
    Uint8List bytes, {
    required int sizeLimitMb,
    required bool convertJpgToJpeg,
    String fileName = 'pasted.png',
  }) async {
    final normalized = await normalizeBmpToPng(bytes);
    final maxBytes = sizeLimitMb * 1024 * 1024;
    if (normalized.length > maxBytes) {
      return ClipboardImageResult(
        warning: '剪贴板图片超过 ${sizeLimitMb}MB，请压缩后重试。',
      );
    }
    try {
      final rel = await ImageStore.saveBytes(
        normalized,
        filename: fileName,
        convertJpgToJpeg: convertJpgToJpeg,
      );
      return ClipboardImageResult(relPath: rel);
    } catch (e) {
      return ClipboardImageResult(warning: '剪贴板图片导入失败：$e');
    }
  }

  /// 把 BMP 魔数（`BM`）的字节重编码为 PNG；非 BMP 或解码失败原样返回。
  ///
  /// 目的：Windows 剪贴板读回（`pasteboard` 0.4.0）的图片是未压缩 32bpp BMP，
  /// 直接落盘不仅占空间数倍，还会让字节级大小限制误判；重编码后体积等价原图，
  /// 且落盘文件是真正的 PNG（识别接口按 `data:image/png` 上传时不会出错）。
  @visibleForTesting
  static Future<Uint8List> normalizeBmpToPng(Uint8List bytes) async {
    if (bytes.length < 2 || bytes[0] != 0x42 || bytes[1] != 0x4d) {
      return bytes; // 仅处理 BMP 魔数；PNG/JPEG 等原样使用。
    }
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) return bytes;
        return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
      } finally {
        image.dispose();
        codec.dispose();
      }
    } catch (_) {
      return bytes; // 解码失败回退原字节（大小校验行为与现状一致）。
    }
  }
}
