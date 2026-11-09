import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/webdav_service.dart';

/// WebDAV 客户端（`WebDavService`）单元测试：
/// - `ensurePath` 逐级建目录（MKCOL 不会自动建父目录，父级缺失会 409）；
/// - PROPFIND 的 multistatus 解析（嵌套目录里的文件只取文件名）。
///
/// 云同步的目录改成 `<folder>/` 与 `<folder>/img/` 之后，这两个能力是
/// 「文件各进各的目录」的基础，之前完全没有覆盖。
void main() {
  group('ensurePath：逐级建目录', () {
    test('空路径只确保服务器根目录', () async {
      final dav = _RecordingDav();
      await dav.ensurePath('');
      expect(dav.ensured, ['']);
    });

    test('一级目录：先根、再文件夹', () async {
      final dav = _RecordingDav();
      await dav.ensurePath('narrchat');
      expect(dav.ensured, ['', 'narrchat']);
    });

    test('多级目录逐级建，首尾 / 重复斜杠的空段被忽略', () async {
      final dav = _RecordingDav();
      await dav.ensurePath('/a//b/');
      expect(dav.ensured, ['', 'a', 'a/b']);
    });
  });

  group('parseMultiStatus', () {
    test('嵌套目录里的文件只取文件名，目录条目跳过', () {
      final files = WebDavService.parseMultiStatus(multiStatusXml);

      expect(files, hasLength(1), reason: '目录自身那一条要跳过');
      final file = files.single;
      expect(file.name, 'abc123.png', reason: '只留文件名，不带目录');
      expect(file.size, 42);
      expect(file.lastModified, DateTime.utc(2025, 6, 11, 8, 30));
    });

    test('空响应返回空列表', () {
      expect(WebDavService.parseMultiStatus(''), isEmpty);
    });
  });
}

/// 只记录 MKCOL 路径的客户端（不发真实请求）。
class _RecordingDav extends WebDavService {
  _RecordingDav()
      : super(
          baseUrl: 'https://dav.example.invalid/',
          username: 'user',
          password: 'secret',
        );

  final List<String> ensured = [];

  @override
  Future<void> ensureCollection(String path) async => ensured.add(path);
}

/// 一份 PROPFIND 响应：目录条目 + 嵌套目录里的图片文件。
const String multiStatusXml = '''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/narrchat/img/</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>Wed, 11 Jun 2025 08:30:00 GMT</d:getlastmodified>
      </d:prop>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/narrchat/img/abc123.png</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>Wed, 11 Jun 2025 08:30:00 GMT</d:getlastmodified>
        <d:getcontentlength>42</d:getcontentlength>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>''';
