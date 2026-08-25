import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narrchat/services/backup_image_service.dart';
import 'package:narrchat/services/cloud_sync_service.dart';
import 'package:narrchat/services/webdav_service.dart';

/// 供重定向测试使用的 PROPFIND 207 响应样例。
const String _multistatusXml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/narrchat/narrchat_user_2026-08-09_10-00-00.db</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Mon, 09 Aug 2026 10:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>2048</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>''';

void main() {
  group('WebDavService.parseMultiStatus', () {
    test('解析文件条目并跳过目录', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
  <d:response>
    <d:href>/dav/narrchat/</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Mon, 09 Aug 2026 10:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>0</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/narrchat/narrchat_user_2026-08-09_10-00-00.db</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Mon, 09 Aug 2026 10:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>2048</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/narrchat/other.txt</d:href>
    <d:propstat><d:prop>
      <d:getcontentlength>10</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>''';

      final files = WebDavService.parseMultiStatus(xml);
      expect(files, hasLength(2));
      expect(files[0].name, 'narrchat_user_2026-08-09_10-00-00.db');
      expect(files[0].size, 2048);
      expect(files[0].lastModified, isNotNull);
      expect(files[1].name, 'other.txt');
      expect(files[1].lastModified, isNull);
      expect(files[1].size, 10);
    });

    test('解码 URL 编码的 href 文件名', () {
      const xml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/narrchat/narrchat%20user_2026-08-09_11-00-00.db</d:href>
    <d:propstat><d:prop><d:getcontentlength>100</d:getcontentlength></d:prop></d:propstat>
  </d:response>
</d:multistatus>''';
      final files = WebDavService.parseMultiStatus(xml);
      expect(files.single.name, 'narrchat user_2026-08-09_11-00-00.db');
    });

    test('空响应返回空列表', () {
      expect(
        WebDavService.parseMultiStatus('<d:multistatus xmlns:d="DAV:"/>'),
        isEmpty,
      );
    });
  });

  group('WebDavService 重定向跟随', () {
    test('PROPFIND 收到 301 后跟随重定向成功列出', () async {
      var callCount = 0;
      String? lastMethod;
      String? lastAuth;
      final client = MockClient((request) async {
        callCount++;
        lastMethod = request.method;
        lastAuth = request.headers['Authorization'];
        if (request.url.path == '/dav/narrchat') {
          // 无尾斜杠目录 → 301 到带尾斜杠地址（Apache mod_dav 常见行为）。
          return http.Response(
            '<html>301 Moved</html>',
            301,
            headers: {
              'location': 'https://webdav.hk.xuezuo.xyz/dav/narrchat/',
            },
          );
        }
        return http.Response(_multistatusXml, 207);
      });
      final dav = WebDavService(
        baseUrl: 'https://webdav.hk.xuezuo.xyz/dav/',
        username: 'user',
        password: 'pass',
        client: client,
      );
      final files = await dav.list('narrchat');
      expect(callCount, 2);
      // 重定向后仍以 PROPFIND 发送，且同主机跳转保留 Authorization。
      expect(lastMethod, 'PROPFIND');
      expect(lastAuth, isNotNull);
      expect(files, hasLength(1));
      expect(files.single.name, 'narrchat_user_2026-08-09_10-00-00.db');
    });

    test('跨主机跳转时移除 Authorization', () async {
      String? lastAuth;
      final client = MockClient((request) async {
        lastAuth = request.headers['Authorization'];
        if (request.url.host == 'a.example.com') {
          return http.Response(
            'redirect',
            302,
            headers: {'location': 'https://b.example.com/dav/narrchat/'},
          );
        }
        return http.Response(_multistatusXml, 207);
      });
      final dav = WebDavService(
        baseUrl: 'https://a.example.com/dav/',
        username: 'user',
        password: 'pass',
        client: client,
      );
      final files = await dav.list('narrchat');
      expect(files, hasLength(1));
      expect(lastAuth, isNull); // 跨主机不携带凭据
    });

    test('重定向次数超过上限时抛错', () async {
      final client = MockClient((request) async {
        return http.Response(
          'redirect',
          302,
          headers: {'location': 'https://a.example.com/again'},
        );
      });
      final dav = WebDavService(
        baseUrl: 'https://a.example.com/',
        username: 'user',
        password: 'pass',
        client: client,
      );
      await expectLater(
        dav.list('narrchat'),
        throwsA(isA<WebDavException>()),
      );
    });
  });

  group('CloudSyncService.buildBackupFileName', () {
    test('生成标准格式文件名', () {
      final name = CloudSyncService.buildBackupFileName(
        'user',
        DateTime(2026, 8, 9, 10, 30, 5),
      );
      expect(name, 'narrchat_user_2026-08-09_10-30-05.db');
    });

    test('非法文件名与空白用户名被净化', () {
      final name = CloudSyncService.buildBackupFileName(
        'a/b:c',
        DateTime(2026, 8, 9, 10, 30, 5),
      );
      expect(name, 'narrchat_a_b_c_2026-08-09_10-30-05.db');
      final empty = CloudSyncService.buildBackupFileName(
        '   ',
        DateTime(2026, 1, 2, 3, 4, 5),
      );
      expect(empty, 'narrchat_user_2026-01-02_03-04-05.db');
    });
  });

  group('CloudSyncService.matchBackups / compareBackups', () {
    test('仅匹配本应用备份文件名', () {
      final files = [
        const WebDavFile(name: 'narrchat_user_2026-08-09_10-00-00.db'),
        const WebDavFile(name: 'other.db'),
        const WebDavFile(name: 'narrchat_user_bad.db'),
        const WebDavFile(name: 'narrchat_user_2026-08-09_10-00-00.db.bak'),
      ];
      final matched = CloudSyncService.matchBackups(files);
      expect(matched.map((f) => f.name), [
        'narrchat_user_2026-08-09_10-00-00.db',
      ]);
    });

    test('按修改时间新 → 旧排序', () {
      final files = [
        WebDavFile(
          name: 'a.db',
          lastModified: DateTime.utc(2026, 8, 1),
        ),
        WebDavFile(
          name: 'b.db',
          lastModified: DateTime.utc(2026, 8, 9),
        ),
        WebDavFile(name: 'c.db'),
      ];
      files.sort(CloudSyncService.compareBackups);
      expect(files.map((f) => f.name).toList(), ['b.db', 'a.db', 'c.db']);
    });
  });

  group('BackupImageService（图片 zip 备份命名 / 匹配）', () {
    test('文件名格式与时间戳、非法字符替换', () {
      final name = BackupImageService.buildImageBackupFileName(
        '张三/user',
        DateTime(2026, 8, 16, 10, 30, 5),
      );
      expect(name, 'img_张三_user_20260816_103005.zip');
      expect(BackupImageService.backupNameRegex.hasMatch(name), isTrue);
    });

    test('matchImageBackups：仅匹配本应用图片备份', () {
      final files = [
        const WebDavFile(name: 'narrchat_user_20260816_103005.db'),
        const WebDavFile(name: 'img_张三_user_20260816_103005.zip'),
        const WebDavFile(name: 'other.txt'),
      ];
      final matched = BackupImageService.matchImageBackups(files);
      expect(matched, hasLength(1));
      expect(matched.single.name, 'img_张三_user_20260816_103005.zip');
    });

    test('compareBackups：按修改时间新 → 旧，无时间按名字倒序', () {
      final a = const WebDavFile(name: 'img_u_20260816_100000.zip');
      final b = const WebDavFile(name: 'img_u_20260816_110000.zip');
      expect(BackupImageService.compareBackups(a, b), greaterThan(0));
      expect(BackupImageService.compareBackups(b, a), lessThan(0));
    });
  });
}
