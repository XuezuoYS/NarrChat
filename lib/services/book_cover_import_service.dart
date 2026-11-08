import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/widgets.dart';

import '../screens/cover_crop_page.dart';
import 'image_store.dart';

/// 封面导入失败（中文友好提示，直接给用户看）。
class BookCoverImportException implements Exception {
  final String message;

  const BookCoverImportException(this.message);

  @override
  String toString() => message;
}

/// 「导入书籍封面」的一站式服务：选图 → 裁剪成 2 : 3 → 落盘（可注入替身）。
///
/// 之所以做成**一个动作**而不是拆成「选图 / 裁剪 / 保存」三步：
/// - 设置页只需拿一个可入库的相对路径，不必关心中间字节与文件系统；
/// - 用例注入替身时不用碰真实 `file_picker`、真实解码与真实磁盘 I/O。
///
/// 落盘复用 [ImageStore.saveBytes]：内容寻址（`img/<sha256>.png`）+ 天然去重，
/// 与剧情图片共用同一套存储与云备份口径。
abstract class BookCoverImportService {
  /// 导入一张封面；返回可写入 `book_meta.book_cover_img` 的相对路径。
  ///
  /// 用户取消（选图或裁剪）返回 null；格式不支持抛 `ImageFormatException`
  /// （来自 [ImageStore]），超过大小上限 / 解码失败抛 [BookCoverImportException]。
  Future<String?> importCover(BuildContext context);
}

/// 真实实现：`file_picker` 选图 + `dart:ui` 解码 + 裁剪页 + 渲染落盘。
class PlatformBookCoverImportService implements BookCoverImportService {
  const PlatformBookCoverImportService();

  /// 源图片大小上限：20MB（与聊天图片导入同量级，超大图解码很吃内存）。
  static const int maxSourceBytes = 20 * 1024 * 1024;

  /// 解码时最长边上限：最终输出 600×900，源图最长边 2400 已有 4 倍余量。
  static const int maxDecodeEdge = 2400;

  @override
  Future<String?> importCover(BuildContext context) async {
    final source = await _pick();
    if (source == null) return null;
    final image = await _decode(source.bytes);
    try {
      if (!context.mounted) return null;
      final cropped = await showCoverCropPage(context, image: image);
      if (cropped == null || cropped.isEmpty) return null;
      return await ImageStore.saveBytes(cropped, filename: 'cover.png');
    } finally {
      image.dispose();
    }
  }

  /// 打开文件选择器选一张图片；取消返回 null。
  Future<_CoverSource?> _pick() async {
    final result = await fp.FilePicker.platform.pickFiles(
      type: fp.FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final path = file.path;
    if (path == null || path.isEmpty) return null;
    // 先校验扩展名（与图片库同一份白名单），不合格直接给出中文提示。
    ImageStore.normalizeExt(file.name);
    if (file.size > maxSourceBytes) {
      throw const BookCoverImportException('图片超过 20MB，请压缩后重试');
    }
    return _CoverSource(bytes: await File(path).readAsBytes());
  }

  /// 把源字节解码成 `ui.Image`；过长边先限幅，避免超大图吃满内存。
  ///
  /// 解码失败统一转成 [BookCoverImportException]（例如扩展名对但内容不是图片）。
  Future<ui.Image> _decode(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 || height <= 0) {
        throw const BookCoverImportException('图片无法读取，请换一张试试');
      }
      final longest = math.max(width, height);
      if (longest > maxDecodeEdge) {
        final ratio = maxDecodeEdge / longest;
        codec = await descriptor.instantiateCodec(
          targetWidth: math.max(1, (width * ratio).round()),
          targetHeight: math.max(1, (height * ratio).round()),
        );
      } else {
        codec = await descriptor.instantiateCodec();
      }
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (error) {
      if (error is BookCoverImportException) rethrow;
      throw const BookCoverImportException('图片无法读取，请换一张试试');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

/// 候选封面图的原始字节（只在选图与解码之间传递）。
class _CoverSource {
  final Uint8List bytes;

  const _CoverSource({required this.bytes});
}
