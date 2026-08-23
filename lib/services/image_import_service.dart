import 'dart:io';

import 'package:file_picker/file_picker.dart' as fp;

import 'image_store.dart';

/// 图片导入结果。
class ImageImportResult {
  /// 成功导入后应写入数据库的相对路径（`img/<hash>.<ext>`）。
  final List<String> paths;

  /// 跳过原因（大小超限 / 格式非法 / 读取失败等），中文友好提示。
  final List<String> warnings;

  const ImageImportResult({this.paths = const [], this.warnings = const []});
}

/// 图片导入服务（可注入替身）。
///
/// 抽象「平台文件选择 + 格式/大小校验 + 哈希去重落盘 + 进度」，
/// 供测试注入假实现，避免触碰真实 `file_picker` 插件与真实文件系统。
abstract class ImageImportService {
  /// 打开平台文件选择器导入更多图片。
  ///
  /// - 仅接受 `png / jpg / jpeg`；
  /// - 超过 [sizeLimitMb] 的图片跳过并写入 [ImageImportResult.warnings]；
  /// - [onProgress] 每处理完一张回调（`done / total`）。
  Future<ImageImportResult> importImages({
    required int sizeLimitMb,
    void Function(int done, int total)? onProgress,
  });
}

/// 真实实现：`file_picker` 选择 + [ImageStore] 哈希去重保存。
class PickerImageImportService implements ImageImportService {
  @override
  Future<ImageImportResult> importImages({
    required int sizeLimitMb,
    void Function(int done, int total)? onProgress,
  }) async {
    final result = await fp.FilePicker.platform.pickFiles(
      type: fp.FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg'],
      allowMultiple: true,
    );
    if (result == null) return const ImageImportResult();
    final files = result.files;
    final saved = <String>[];
    final warnings = <String>[];
    final maxBytes = sizeLimitMb * 1024 * 1024;
    var done = 0;
    for (final f in files) {
      done++;
      try {
        final path = f.path;
        if (path == null || path.isEmpty) continue;
        final file = File(path);
        final size = await file.length();
        if (size > maxBytes) {
          warnings.add(
            '「${f.name}」超过 ${sizeLimitMb}MB，请压缩后重试。'
            '应上传不超过 ${sizeLimitMb}MB 的图片。',
          );
          continue;
        }
        final bytes = await file.readAsBytes();
        saved.add(await ImageStore.saveBytes(bytes, filename: path));
      } catch (e) {
        warnings.add('「${f.name}」导入失败：$e');
      } finally {
        onProgress?.call(done, files.length);
      }
    }
    return ImageImportResult(paths: saved, warnings: warnings);
  }
}
