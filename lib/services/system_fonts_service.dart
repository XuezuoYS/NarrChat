import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show loadFontFromList;

import 'package:path/path.dart' as p;

/// 从字体 name 表解析出的名称信息。
class ParsedFontName {
  /// 字体族名（默认/英文，如 "Microsoft YaHei"）。
  final String familyName;

  /// 简体中文本地化名称（如 "微软雅黑"）；字体无中文记录时为 null。
  final String? localizedName;

  const ParsedFontName({required this.familyName, this.localizedName});
}

/// 系统字体（族）信息。
class SystemFont {
  /// 真实字体族名（解析自字体 name 表，如 "Microsoft YaHei"、"SimSun"）。
  final String familyName;

  /// 简体中文本地化名称（如 "微软雅黑"）；无中文记录时为 null。
  final String? localizedName;

  /// 字体文件绝对路径。
  final String filePath;

  /// 是否为字体集合（.ttc，通常含多个字面）。
  final bool isCollection;

  const SystemFont({
    required this.familyName,
    this.localizedName,
    required this.filePath,
    this.isCollection = false,
  });

  /// 展示名称：优先简体中文名（如 "微软雅黑"），否则回退英文族名。
  String get displayName {
    final zh = localizedName;
    if (zh != null && zh.isNotEmpty && zh != familyName) return zh;
    return familyName;
  }
}

/// 系统字体服务：
/// - [scan]：扫描系统字体目录（Windows / macOS / Linux / Android），
///   解析 TTF / OTF / TTC 的 name 表以获取真实字体族名（仅读取必要字节，开销小）；
/// - [loadFont]：用 `dart:ui` 的 [FontLoader] 按需加载所选字体，
///   加载成功后即可通过 `TextStyle(fontFamily: ...)` 全局使用。
///
/// 字体数据来自操作系统，不随应用分发；仅缓存扫描与加载结果，不落盘。
class SystemFontsService {
  SystemFontsService._();

  static final SystemFontsService instance = SystemFontsService._();

  final List<SystemFont> _fonts = [];
  final Set<String> _loadedFamilies = {};
  bool _scanned = false;

  /// 已扫描到的系统字体（按名称排序，只读）。
  List<SystemFont> get fonts => List.unmodifiable(_fonts);

  /// 是否已完成扫描。
  bool get isScanned => _scanned;

  /// 已成功加载（注册到引擎）的字体族名。
  Set<String> get loadedFamilies => Set.unmodifiable(_loadedFamilies);

  /// 扫描系统字体（幂等：仅首次真正扫描）。
  Future<void> scan() async {
    if (_scanned) return;
    final files = await _collectFontFiles();
    for (final file in files) {
      try {
        final names = await _readFamilyNames(file);
        final isCollection = file.path.toLowerCase().endsWith('.ttc');
        for (final name in names) {
          if (name.familyName.isEmpty) continue;
          if (_fonts.any((f) => f.familyName == name.familyName)) continue;
          _fonts.add(
            SystemFont(
              familyName: name.familyName,
              localizedName: name.localizedName,
              filePath: file.path,
              isCollection: isCollection,
            ),
          );
        }
      } catch (_) {
        // 单个字体解析失败不影响整体扫描。
      }
    }
    _fonts.sort(
      (a, b) =>
          a.familyName.toLowerCase().compareTo(b.familyName.toLowerCase()),
    );
    _scanned = true;
  }

  /// 按需加载字体并注册到 Flutter 引擎（幂等，失败返回 false）。
  Future<bool> loadFont(String familyName) async {
    if (_loadedFamilies.contains(familyName)) return true;
    final font = _findFont(familyName);
    if (font == null) return false;
    try {
      final bytes = await File(font.filePath).readAsBytes();
      await loadFontFromList(bytes, fontFamily: font.familyName);
      _loadedFamilies.add(font.familyName);
      return true;
    } catch (_) {
      return false;
    }
  }

  SystemFont? _findFont(String familyName) {
    for (final f in _fonts) {
      if (f.familyName == familyName) return f;
    }
    return null;
  }

  // —— 字体目录收集 ——

  Future<List<File>> _collectFontFiles() async {
    final files = <File>[];
    for (final dir in _fontDirectories()) {
      try {
        final d = Directory(dir);
        if (!await d.exists()) continue;
        await for (final entity in d.list(followLinks: false)) {
          if (entity is File && _isFontFile(entity.path)) {
            files.add(entity);
          }
        }
      } catch (_) {
        // 目录不可读时跳过。
      }
    }
    return files;
  }

  List<String> _fontDirectories() {
    if (Platform.isWindows) {
      final windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      return [
        p.join(windir, 'Fonts'),
        if (localAppData.isNotEmpty)
          p.join(localAppData, r'Microsoft\Windows\Fonts'),
      ];
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      return [
        '/System/Library/Fonts',
        '/Library/Fonts',
        if (home.isNotEmpty) p.join(home, 'Library', 'Fonts'),
      ];
    }
    if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '';
      return [
        '/usr/share/fonts',
        '/usr/local/share/fonts',
        if (home.isNotEmpty) p.join(home, '.fonts'),
        if (home.isNotEmpty) p.join(home, '.local', 'share', 'fonts'),
      ];
    }
    if (Platform.isAndroid) {
      return ['/system/fonts', '/data/fonts'];
    }
    return const [];
  }

  bool _isFontFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.ttf') ||
        lower.endsWith('.otf') ||
        lower.endsWith('.ttc');
  }

  // —— 字体 name 表解析（仅读取必要字节） ——

  /// 解析字体文件中的全部字体名称信息（TTC 可能含多个字面）。
  Future<List<ParsedFontName>> _readFamilyNames(File file) async {
    final raf = await file.open();
    try {
      final header = await raf.read(12);
      if (header.length < 12) return const [];
      final tag = String.fromCharCodes(header.sublist(0, 4));
      final sfntOffsets = <int>[];
      if (tag == 'ttcf') {
        final numFonts = _readU32(header, 8);
        if (numFonts <= 0 || numFonts > 64) return const [];
        final offs = await raf.read(numFonts * 4);
        for (var i = 0; i < numFonts; i++) {
          sfntOffsets.add(_readU32(offs, i * 4));
        }
      } else {
        sfntOffsets.add(0);
      }
      final names = <ParsedFontName>[];
      for (final base in sfntOffsets) {
        try {
          final name = await _readSfntFamilyName(raf, base);
          if (name != null && name.familyName.isNotEmpty) names.add(name);
        } catch (_) {
          // 单个字面解析失败不影响整体。
        }
      }
      return names;
    } finally {
      await raf.close();
    }
  }

  Future<ParsedFontName?> _readSfntFamilyName(
    RandomAccessFile raf,
    int base,
  ) async {
    await raf.setPosition(base);
    final sfnt = await raf.read(12);
    if (sfnt.length < 12) return null;
    final numTables = _readU16(sfnt, 4);
    if (numTables <= 0 || numTables > 256) return null;
    await raf.setPosition(base + 12);
    final dir = await raf.read(numTables * 16);
    if (dir.length < numTables * 16) return null;
    int? nameOffset;
    int? nameLength;
    for (var i = 0; i < numTables; i++) {
      final rec = i * 16;
      if (String.fromCharCodes(dir.sublist(rec, rec + 4)) == 'name') {
        nameOffset = _readU32(dir, rec + 8);
        nameLength = _readU32(dir, rec + 12);
        break;
      }
    }
    if (nameOffset == null || nameLength == null || nameLength <= 0) {
      return null;
    }
    if (nameLength > 1 << 20) return null; // 防御性上限（1MB）。
    // TTC 中表偏移为相对文件开头的绝对偏移（见 _parseSfntFamilyName 注释）。
    await raf.setPosition(nameOffset);
    final nameData = await raf.read(nameLength);
    if (nameData.length < 6) return null;
    final parsed = _parseNameTable(nameData);
    if (parsed.$1 == null) return null;
    return ParsedFontName(familyName: parsed.$1!, localizedName: parsed.$2);
  }

  /// 从内存字节（TTF / OTF / TTC）解析全部字体名称信息；解析失败返回空列表。
  /// 供文件扫描复用与单元测试使用。
  static List<ParsedFontName> parseFontNamesFromBytes(Uint8List bytes) {
    if (bytes.length < 12) return const [];
    final tag = String.fromCharCodes(bytes.sublist(0, 4));
    final sfntOffsets = <int>[];
    if (tag == 'ttcf') {
      final numFonts = _readU32(bytes, 8);
      if (numFonts <= 0 || numFonts > 64) return const [];
      for (var i = 0; i < numFonts; i++) {
        sfntOffsets.add(_readU32(bytes, 12 + i * 4));
      }
    } else {
      sfntOffsets.add(0);
    }
    final names = <ParsedFontName>[];
    for (final base in sfntOffsets) {
      final name = _parseSfntFamilyName(bytes, base);
      if (name != null && name.familyName.isNotEmpty) names.add(name);
    }
    return names;
  }

  /// 兼容接口：仅返回字体族名列表。
  static List<String> parseFamilyNamesFromBytes(Uint8List bytes) =>
      parseFontNamesFromBytes(bytes).map((n) => n.familyName).toList();

  static ParsedFontName? _parseSfntFamilyName(Uint8List bytes, int base) {
    if (base + 12 > bytes.length) return null;
    final numTables = _readU16(bytes, base + 4);
    if (numTables <= 0 || numTables > 256) return null;
    int? nameOffset;
    int? nameLength;
    for (var i = 0; i < numTables; i++) {
      final rec = base + 12 + i * 16;
      if (rec + 16 > bytes.length) break;
      if (String.fromCharCodes(bytes.sublist(rec, rec + 4)) == 'name') {
        nameOffset = _readU32(bytes, rec + 8);
        nameLength = _readU32(bytes, rec + 12);
        break;
      }
    }
    if (nameOffset == null || nameLength == null || nameLength <= 0) {
      return null;
    }
    // 注意：OpenType 规范中，TTC 内每个字体的表偏移是相对整个文件开头的
    // 绝对偏移（而非相对该 sfnt 开头）；单字体 TTF/OTF 时 base 为 0，同样成立。
    // 因此这里直接使用 nameOffset，不再叠加 base。
    final absOffset = nameOffset;
    if (absOffset + nameLength > bytes.length) return null;
    final parsed = _parseNameTable(
      Uint8List.sublistView(bytes, absOffset, absOffset + nameLength),
    );
    if (parsed.$1 == null) return null;
    return ParsedFontName(familyName: parsed.$1!, localizedName: parsed.$2);
  }

  /// 解析 name 表：返回 (族名, 简体中文名)，二者都可能为 null。
  static (String?, String?) _parseNameTable(Uint8List data) {
    final count = _readU16(data, 2);
    if (count <= 0 || count > 4096) return (null, null);
    final stringOffset = _readU16(data, 4);
    String? family;
    String? typographic;
    String? localizedFamily;
    String? localizedTypographic;
    for (var i = 0; i < count; i++) {
      final rec = 6 + i * 12;
      if (rec + 12 > data.length) break;
      final platformId = _readU16(data, rec);
      final languageId = _readU16(data, rec + 4);
      final nameId = _readU16(data, rec + 6);
      final len = _readU16(data, rec + 8);
      final strOff = _readU16(data, rec + 10);
      if (nameId != 1 && nameId != 16) continue;
      final abs = stringOffset + strOff;
      if (abs + len > data.length) continue;
      final value = _decodeNameString(data, abs, len, platformId);
      if (value == null || value.trim().isEmpty) continue;
      // 简体中文：Windows/Unicode 平台的 zh-CN（0x0804）记录。
      final isZhCn =
          languageId == 0x0804 && (platformId == 3 || platformId == 0);
      if (nameId == 16) {
        // typographic family 优先。
        typographic ??= value;
        if (isZhCn) localizedTypographic ??= value;
      } else {
        family ??= value;
        if (isZhCn) localizedFamily ??= value;
      }
    }
    return (typographic ?? family, localizedTypographic ?? localizedFamily);
  }

  static String? _decodeNameString(
    Uint8List data,
    int offset,
    int length,
    int platformId,
  ) {
    // Windows（3）/ Unicode（0、2）平台：UTF-16BE。
    if (platformId == 3 || platformId == 0 || platformId == 2) {
      return _decodeUtf16Be(data, offset, length);
    }
    // Macintosh（1）：Mac Roman，latin1 近似（中文场景走 Windows 记录）。
    return _decodeLatin1(data, offset, length);
  }

  static String _decodeUtf16Be(Uint8List data, int offset, int length) {
    final sb = StringBuffer();
    for (var i = 0; i + 1 < length; i += 2) {
      sb.writeCharCode((data[offset + i] << 8) | data[offset + i + 1]);
    }
    return sb.toString();
  }

  static String _decodeLatin1(Uint8List data, int offset, int length) {
    return String.fromCharCodes(data.sublist(offset, offset + length));
  }

  static int _readU16(Uint8List data, int offset) =>
      (data[offset] << 8) | data[offset + 1];

  static int _readU32(Uint8List data, int offset) =>
      (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];
}
