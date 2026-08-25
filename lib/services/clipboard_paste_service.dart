import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
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
  Future<bool> hasImage() async => (await Pasteboard.image) != null;

  @override
  Future<ClipboardImageResult> readImagePng({
    required int sizeLimitMb,
    required bool convertJpgToJpeg,
  }) async {
    final bytes = await Pasteboard.image;
    if (bytes == null) return const ClipboardImageResult();
    return savePastedBytes(
      bytes,
      sizeLimitMb: sizeLimitMb,
      convertJpgToJpeg: convertJpgToJpeg,
    );
  }

  /// 把剪贴板图片字节落盘：校验大小上限并以内容哈希去重保存。
  ///
  /// 拆为可见的纯逻辑（仅依赖 [ImageStore]），便于单独测试超限 / 落盘，
  /// 不触碰 `pasteboard` 平台通道。返回相对路径或超限/失败提示。
  @visibleForTesting
  static Future<ClipboardImageResult> savePastedBytes(
    Uint8List bytes, {
    required int sizeLimitMb,
    required bool convertJpgToJpeg,
  }) async {
    final maxBytes = sizeLimitMb * 1024 * 1024;
    if (bytes.length > maxBytes) {
      return ClipboardImageResult(
        warning: '剪贴板图片超过 ${sizeLimitMb}MB，请压缩后重试。',
      );
    }
    try {
      final rel = await ImageStore.saveBytes(
        bytes,
        filename: 'pasted.png',
        convertJpgToJpeg: convertJpgToJpeg,
      );
      return ClipboardImageResult(relPath: rel);
    } catch (e) {
      return ClipboardImageResult(warning: '剪贴板图片导入失败：$e');
    }
  }
}
