import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../utils/formats.dart';
import 'app_repositories.dart';
import 'app_stores.dart';

/// 调试文件浏览里一个文件的阅读器类型。
enum DebugFileKind {
  directory,
  sqlite,
  json,
  image,
  text,

  /// 没有可用阅读器：只展示文件信息。
  binary,
}

/// 调试文件浏览里的一个目录项（文件或文件夹）。
///
/// 所有路径都相对应用数据根目录（`NarrChat/`），统一用 `/` 分隔，避免
/// Windows / Android 的路径差异传进 UI。绝对路径由 [DebugFileService] 按需拼。
class DebugFileEntry {
  const DebugFileEntry({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modified,
    required this.kind,
  });

  final String name;
  final String relativePath;
  final bool isDirectory;
  final int sizeBytes;
  final DateTime? modified;
  final DebugFileKind kind;

  static final RegExp _bookFilePattern = RegExp(
    r'^narrbook_.+\.db$',
    caseSensitive: false,
  );

  /// 是否是书籍库文件：`user_data/books/narrbook_<uuid>.db`。
  ///
  /// 只按文件名识别（不看所在目录），这样 `.import-backup-*` 等备份目录里的
  /// 书库副本也能显示书名。
  bool get isBookDatabase =>
      !isDirectory &&
      kind == DebugFileKind.sqlite &&
      _bookFilePattern.hasMatch(name);
}

/// 调试文件浏览的路径 / 读取错误（中文友好提示）。
class DebugFileException implements Exception {
  const DebugFileException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 调试页的文件访问抽象（可注入替身，避免测试碰真实用户目录）。
///
/// 只负责"列目录 / 读文本 / 拼路径"，不关心具体阅读器；数据库查看与书名
/// 读取由 `DebugDatabaseService` 负责。
abstract class DebugFileService {
  /// 应用数据根目录（`user_data/` 与 `local_config/` 的父目录）。
  String get rootPath;

  /// 相对路径 → 绝对路径；非法路径（绝对路径 / `..` 逃逸）直接抛错。
  String absolutePathOf(String relativePath);

  /// 列出 [relativePath] 目录下的全部条目；空字符串表示根目录。
  Future<List<DebugFileEntry>> listDirectory(String relativePath);

  /// 读取文本文件（UTF-8 宽容解码）；超过大小上限时抛 [DebugFileException]。
  Future<String> readTextFile(String relativePath);
}

/// 真实实现：直接读文件系统，全程只读。
class LocalDebugFileService implements DebugFileService {
  LocalDebugFileService({String? rootPath, AppStores? stores})
    : rootPath = _normalizeRoot(
        rootPath ??
            p.dirname(
              (stores ?? AppRepositories.instance.stores).paths.userDataDir,
            ),
      );

  /// 文本预览上限：超过这个大小的文件不读进 UI，避免调试页被大日志卡住。
  static const int maxTextBytes = 4 * 1024 * 1024;

  @override
  final String rootPath;

  static String _normalizeRoot(String path) => p.normalize(p.absolute(path));

  static const Set<String> _imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
    'bmp',
  };

  static const Set<String> _sqliteExtensions = {'db', 'sqlite', 'sqlite3'};

  static const Set<String> _textExtensions = {
    'txt',
    'md',
    'log',
    'csv',
    'tsv',
    'ini',
    'yaml',
    'yml',
    'xml',
    'html',
    'htm',
  };

  static const String _sqliteHeader = 'SQLite format 3\u0000';

  @override
  String absolutePathOf(String relativePath) {
    if (relativePath.isEmpty) return rootPath;
    // 只拒绝真正会跳出数据目录的路径；Android 上文件名本身可以带冒号，
    // 不能见到冒号就判非法。
    if (p.isAbsolute(relativePath) || p.rootPrefix(relativePath).isNotEmpty) {
      throw DebugFileException('非法路径：$relativePath');
    }
    final segments = relativePath.split(RegExp(r'[\\/]'));
    if (segments.any((segment) => segment == '..')) {
      throw DebugFileException('非法路径：$relativePath');
    }
    final abs = p.normalize(
      p.joinAll([rootPath, ...segments.where((segment) => segment.isNotEmpty)]),
    );
    if (!p.equals(abs, rootPath) && !p.isWithin(rootPath, abs)) {
      throw DebugFileException('非法路径：$relativePath');
    }
    return abs;
  }

  @override
  Future<List<DebugFileEntry>> listDirectory(String relativePath) async {
    final path = absolutePathOf(relativePath);
    final dir = Directory(path);
    if (!await dir.exists()) {
      throw DebugFileException('目录不存在：$path');
    }

    final entries = <DebugFileEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final childRelativePath = relativePath.isEmpty
          ? name
          : '$relativePath/$name';
      try {
        if (entity is Directory) {
          final stat = await entity.stat();
          entries.add(
            DebugFileEntry(
              name: name,
              relativePath: childRelativePath,
              isDirectory: true,
              sizeBytes: 0,
              modified: stat.modified,
              kind: DebugFileKind.directory,
            ),
          );
        } else if (entity is File) {
          final stat = await entity.stat();
          entries.add(
            DebugFileEntry(
              name: name,
              relativePath: childRelativePath,
              isDirectory: false,
              sizeBytes: stat.size,
              modified: stat.modified,
              kind: await _kindOf(entity, name),
            ),
          );
        }
        // Link / socket 等直接跳过：调试页不跟进，避免跳出数据目录。
      } on FileSystemException {
        // 列目录的过程中文件被删掉：跳过这一项，不让整页失败。
      }
    }
    entries.sort(_compareEntries);
    return entries;
  }

  @override
  Future<String> readTextFile(String relativePath) async {
    final path = absolutePathOf(relativePath);
    final file = File(path);
    if (!await file.exists()) {
      throw DebugFileException('文件不存在：$path');
    }
    final size = await file.length();
    if (size > maxTextBytes) {
      throw DebugFileException('文件过大（${Formats.formatBytes(size)}），暂不预览');
    }
    final bytes = await file.readAsBytes();
    return utf8.decode(bytes, allowMalformed: true);
  }

  static int _compareEntries(DebugFileEntry a, DebugFileEntry b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.name.compareTo(b.name);
  }

  Future<DebugFileKind> _kindOf(File file, String name) async {
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    if (ext == 'json') return DebugFileKind.json;
    if (_imageExtensions.contains(ext)) return DebugFileKind.image;
    if (_sqliteExtensions.contains(ext)) return DebugFileKind.sqlite;
    if (_textExtensions.contains(ext)) return DebugFileKind.text;

    // 未知后缀（含 `.bak`）：看文件头。旧版 R2 备份是 SQLite 库，但没有 `.db`
    // 后缀，不能只靠扩展名丢掉它的阅读器。
    final head = await _readHead(file, 512);
    if (_looksLikeSqlite(head)) return DebugFileKind.sqlite;
    if (head.contains(0)) return DebugFileKind.binary;
    if (_looksLikeUtf8Text(head)) return DebugFileKind.text;
    return DebugFileKind.binary;
  }

  Future<Uint8List> _readHead(File file, int maxBytes) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      return await handle.read(maxBytes);
    } catch (_) {
      return Uint8List(0);
    } finally {
      await handle?.close();
    }
  }

  bool _looksLikeSqlite(Uint8List bytes) {
    if (bytes.length < _sqliteHeader.length) return false;
    for (var i = 0; i < _sqliteHeader.length; i++) {
      if (bytes[i] != _sqliteHeader.codeUnitAt(i)) return false;
    }
    return true;
  }

  bool _looksLikeUtf8Text(Uint8List bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }
}
