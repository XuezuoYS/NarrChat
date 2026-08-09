import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/system_fonts_service.dart';

void main() {
  group('SystemFontsService 解析', () {
    test('解析 TTF 的 family name（nameID 1，Windows UTF-16BE）', () {
      final bytes = _buildMinimalSfnt('TestFont');
      expect(SystemFontsService.parseFamilyNamesFromBytes(bytes), ['TestFont']);
    });

    test('typographic family（nameID 16）优先于 family（nameID 1）', () {
      final bytes = _buildMinimalSfnt(
        'LegacyName',
        typographicFamily: 'NiceName',
      );
      expect(SystemFontsService.parseFamilyNamesFromBytes(bytes), ['NiceName']);
    });

    test('中英双语 name 表提取简体中文名（如 微软雅黑）', () {
      final bytes = _buildMinimalSfnt('Microsoft YaHei', localizedName: '微软雅黑');
      final parsed = SystemFontsService.parseFontNamesFromBytes(bytes);
      expect(parsed, hasLength(1));
      expect(parsed.first.familyName, 'Microsoft YaHei');
      expect(parsed.first.localizedName, '微软雅黑');
      expect(parsed.first.localizedName, isNot(parsed.first.familyName));
    });

    test('中文 family name 的 UTF-16BE 解码', () {
      final bytes = _buildMinimalSfnt('微软雅黑');
      expect(SystemFontsService.parseFamilyNamesFromBytes(bytes), ['微软雅黑']);
    });

    test('解析 TTC 集合中的多个字面（含本地化名）', () {
      final ttc = _buildTtc([
        _buildMinimalSfnt('FontA', localizedName: '字体A'),
        _buildMinimalSfnt('FontB'),
      ]);
      final parsed = SystemFontsService.parseFontNamesFromBytes(ttc);
      expect(parsed, hasLength(2));
      expect(parsed[0].familyName, 'FontA');
      expect(parsed[0].localizedName, '字体A');
      expect(parsed[1].familyName, 'FontB');
      expect(parsed[1].localizedName, isNull);
    });

    test('非法/过短输入返回空列表', () {
      expect(
        SystemFontsService.parseFamilyNamesFromBytes(Uint8List(0)),
        isEmpty,
      );
      expect(
        SystemFontsService.parseFamilyNamesFromBytes(
          Uint8List.fromList([1, 2, 3]),
        ),
        isEmpty,
      );
    });
  });

  group('SystemFontsService.scan', () {
    test('扫描系统字体目录并解析真实名称（Windows）', () async {
      if (!Platform.isWindows) {
        markTestSkipped('非 Windows 平台跳过真实目录扫描');
        return;
      }
      final service = SystemFontsService.instance;
      await service.scan();
      expect(service.isScanned, isTrue);
      expect(service.fonts, isNotEmpty);
      // 名称非空且去重。
      final names = service.fonts.map((f) => f.familyName).toSet();
      expect(names.length, service.fonts.length);
      expect(service.fonts.every((f) => f.familyName.isNotEmpty), isTrue);
      // 中文系统应能识别微软雅黑，并提取其简体中文名。
      final yahei = service.fonts.firstWhere(
        (f) => f.familyName == 'Microsoft YaHei',
        orElse: () => const SystemFont(familyName: '', filePath: ''),
      );
      expect(yahei.familyName, 'Microsoft YaHei');
      expect(yahei.localizedName, '微软雅黑');
      expect(yahei.displayName, '微软雅黑');
    });
  });
}

// —— 测试用字体字节构造 ——

List<int> _utf16beBytes(String value) {
  final bytes = <int>[];
  for (final code in value.codeUnits) {
    bytes.add(code >> 8);
    bytes.add(code & 0xFF);
  }
  return bytes;
}

void _writeTag(ByteData data, int offset, String tag) {
  for (var i = 0; i < tag.length; i++) {
    data.setUint8(offset + i, tag.codeUnitAt(i));
  }
}

/// 构造一个仅含 name 表的最小 TTF/sfnt 字节。
///
/// 记录结构：(nameID, languageID, 值)，全部用 Windows 平台（3, encoding 1, UTF-16BE）。
/// - [localizedName] 会以简体中文（languageID 0x0804）的 nameID 1 写入。
Uint8List _buildMinimalSfnt(
  String familyName, {
  String? typographicFamily,
  String? localizedName,
}) {
  final records = <(int, int, String)>[
    if (typographicFamily != null) (16, 0x0409, typographicFamily),
    (1, 0x0409, familyName),
    if (localizedName != null) (1, 0x0804, localizedName),
  ];
  final stringBytes = <int>[];
  final recordBytes = <List<int>>[];
  for (final (_, _, value) in records) {
    final bytes = _utf16beBytes(value);
    recordBytes.add(bytes);
    stringBytes.addAll(bytes);
  }
  final stringOffset = 6 + records.length * 12;
  final nameTable = ByteData(stringOffset + stringBytes.length);
  nameTable.setUint16(0, 0); // format
  nameTable.setUint16(2, records.length); // count
  nameTable.setUint16(4, stringOffset); // stringOffset
  var strPos = 0;
  for (var i = 0; i < records.length; i++) {
    final rec = 6 + i * 12;
    nameTable.setUint16(rec, 3); // platformID = Windows
    nameTable.setUint16(rec + 2, 1); // encodingID
    nameTable.setUint16(rec + 4, records[i].$2); // languageID
    nameTable.setUint16(rec + 6, records[i].$1); // nameID
    nameTable.setUint16(rec + 8, recordBytes[i].length); // length
    nameTable.setUint16(rec + 10, strPos); // string offset
    for (var j = 0; j < recordBytes[i].length; j++) {
      nameTable.setUint8(stringOffset + strPos + j, recordBytes[i][j]);
    }
    strPos += recordBytes[i].length;
  }
  final nameTableBytes = nameTable.buffer.asUint8List();

  final sfnt = ByteData(12 + 16 + nameTableBytes.length);
  sfnt.setUint32(0, 0x00010000); // sfnt version
  sfnt.setUint16(4, 1); // numTables
  _writeTag(sfnt, 12, 'name');
  sfnt.setUint32(16, 0); // checksum（忽略）
  sfnt.setUint32(20, 28); // table offset（12 + 16，相对 sfnt）
  sfnt.setUint32(24, nameTableBytes.length); // table length
  for (var i = 0; i < nameTableBytes.length; i++) {
    sfnt.setUint8(28 + i, nameTableBytes[i]);
  }
  return sfnt.buffer.asUint8List();
}

/// 将多个 sfnt 拼装为 TTC 集合。
///
/// 按 OpenType 规范，TTC 内每个字体的表偏移是相对整个文件开头的绝对偏移，
/// 因此把各 sfnt 中相对自身的 name 表偏移（28）改写为其绝对位置。
Uint8List _buildTtc(List<Uint8List> sfnts) {
  final headerLen = 12 + sfnts.length * 4;
  final total = headerLen + sfnts.fold<int>(0, (sum, s) => sum + s.length);
  final data = ByteData(total);
  _writeTag(data, 0, 'ttcf');
  data.setUint32(4, 0x00010000); // TTC version 1.0
  data.setUint32(8, sfnts.length); // numFonts
  var offset = headerLen;
  for (var i = 0; i < sfnts.length; i++) {
    final base = offset;
    data.setUint32(12 + i * 4, base);
    final modified = Uint8List.fromList(sfnts[i]);
    // sfnt 中 name 表 offset 字段位于 12（sfnt 头）+ 8（记录内偏移）= 20。
    ByteData.sublistView(modified).setUint32(20, base + 28);
    for (var j = 0; j < modified.length; j++) {
      data.setUint8(base + j, modified[j]);
    }
    offset += sfnts[i].length;
  }
  return data.buffer.asUint8List();
}
