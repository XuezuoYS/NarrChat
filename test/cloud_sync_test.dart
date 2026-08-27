import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/sync/sync_remote_store.dart';
import 'package:narrchat/services/webdav_service.dart';

/// WebDAV 服务 / 云端快照命名测试。
///
/// 覆盖：
/// - `WebDavService.parseMultiStatus` 与 3xx 重定向跟随；
/// - 新版快照命名 `narrchat_snapshot_g<gen>_<yyyyMMdd_HHmmss>.db` 的
///   匹配 / 代际 / 时间解析（旧版 `narrchat_<user>_*.db` 不再支持）。
const String _multistatusXml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/narrchat/narrchat_snapshot_g5_20260809_100000.db</d:href>
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
    <d:href>/dav/narrchat/narrchat_snapshot_g5_20260809_100000.db</d:href>
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
      expect(files[0].name, 'narrchat_snapshot_g5_20260809_100000.db');
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
    <d:href>/dav/narrchat/narrchat%20snapshot_g5_20260809_110000.db</d:href>
    <d:propstat><d:prop><d:getcontentlength>100</d:getcontentlength></d:prop></d:propstat>
  </d:response>
</d:multistatus>''';
      final files = WebDavService.parseMultiStatus(xml);
      expect(files.single.name, 'narrchat snapshot_g5_20260809_110000.db');
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
      expect(files.single.name, 'narrchat_snapshot_g5_20260809_100000.db');
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

  group('WebDavSyncStore 快照命名（新版备份规则）', () {
    test('生成标准格式快照名', () {
      final name = WebDavSyncStore.snapshotName(3, DateTime(2026, 8, 16, 10, 30, 5));
      expect(name, 'narrchat_snapshot_g3_20260816_103005.db');
      expect(WebDavSyncStore.isSnapshot(name), isTrue);
    });

    test('isSnapshot：匹配新版快照，不再匹配旧版命名', () {
      expect(
        WebDavSyncStore.isSnapshot('narrchat_snapshot_g1_20260816_000000.db'),
        isTrue,
      );
      expect(WebDavSyncStore.isSnapshot('other.db'), isFalse);
      // 旧版命名（narrchat_<user>_<yyyy-MM-dd_HH-mm-ss>.db）不再支持。
      expect(
        WebDavSyncStore.isSnapshot('narrchat_user_2026-08-16_10-30-05.db'),
        isFalse,
      );
      expect(WebDavSyncStore.isSnapshot('manifest.json'), isFalse);
    });

    test('generationOf / snapshotTimeOf：解析代际与内嵌时间戳', () {
      const name = 'narrchat_snapshot_g12_20260816_103005.db';
      expect(WebDavSyncStore.generationOf(name), 12);
      expect(
        WebDavSyncStore.snapshotTimeOf(name),
        DateTime(2026, 8, 16, 10, 30, 5),
      );
      expect(WebDavSyncStore.generationOf('other.db'), isNull);
      expect(WebDavSyncStore.snapshotTimeOf('other.db'), isNull);
    });

    test('latestSnapshotName：按代际新 → 旧，可指定代际', () async {
      final store = _MemorySnapshotStore({
        'narrchat_snapshot_g3_20260816_100000.db',
        'narrchat_snapshot_g5_20260816_120000.db',
        'narrchat_snapshot_g7_20260816_110000.db',
        'manifest.json', // 非快照名忽略
      });
      expect(await store.latestSnapshotName(), 'narrchat_snapshot_g7_20260816_110000.db');
      expect(
        await store.latestSnapshotName(generation: 5),
        'narrchat_snapshot_g5_20260816_120000.db',
      );
      expect(await store.latestSnapshotName(generation: 99), isNull);
    });
  });
}

/// 纯内存快照名列表替身（只实现 [SyncRemoteStore] 的最小面，供命名测试用）。
class _MemorySnapshotStore extends SyncRemoteStore {
  _MemorySnapshotStore(this.names);

  final Set<String> names;

  @override
  Future<List<String>> listSnapshotNames() async => names.toList();

  @override
  Future<SyncManifest?> readManifest() async => null;

  @override
  Future<void> writeManifest(SyncManifest manifest) async {}

  @override
  Future<Uint8List?> readSnapshot(String name) async => null;

  @override
  Future<void> writeSnapshot(String name, Uint8List bytes) async {}

  @override
  Future<void> deleteSnapshot(String name) async {}

  @override
  Future<List<String>> listImages() async => const [];

  @override
  Future<Uint8List?> readImage(String path) async => null;

  @override
  Future<void> writeImage(String path, Uint8List bytes) async {}

  @override
  Future<void> deleteImage(String path) async {}

  @override
  void close() {}
}
