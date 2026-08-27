import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/sync/sync_remote_store.dart';
import 'package:narrchat/services/webdav_service.dart';

/// `WebDavSyncStore` 测试：快照命名 + manifest 读写（用 MockClient 模拟 WebDAV）
/// + 云端软锁。
void main() {
  group('快照命名', () {
    test('生成标准代际快照名', () {
      final n = WebDavSyncStore.snapshotName(3, DateTime(2026, 8, 16, 10, 30, 5));
      expect(n, 'narrchat_snapshot_g3_20260816_103005.db');
      expect(WebDavSyncStore.isSnapshot(n), isTrue);
    });

    test('isSnapshot 只匹配本应用快照格式', () {
      expect(WebDavSyncStore.isSnapshot('narrchat_snapshot_g1_20260816_000000.db'), isTrue);
      expect(WebDavSyncStore.isSnapshot('other.db'), isFalse);
      expect(WebDavSyncStore.isSnapshot('narrchat_user_2026-08-16.db'), isFalse);
    });
  });

  group('manifest 读写', () {
    final manifest = SyncManifest(
      generation: 2,
      lastWriterDeviceId: 'dev-1',
      knownDevices: const ['dev-1', 'dev-2'],
      books: const [
        SyncBookEntry(
          title: '书A',
          deleted: false,
          settingsFp: 'S0',
          settingsUpdatedAt: 100,
          roundsFp: 'R1',
          roundsUpdatedAt: 200,
          worldBookFp: 'W0',
          bookModsFp: 'M0',
        ),
      ],
      images: const ['img/a.png'],
    );

    test('writeManifest → PUT；再用 GET 读回同构 manifest', () async {
      String? putBody;
      var got = false;
      final client = MockClient((request) async {
        if (request.method == 'PUT') {
          putBody = utf8.decode(request.bodyBytes);
          return http.Response('', 201);
        }
        if (request.method == 'GET') {
          got = true;
          return http.Response(
            manifest.toJsonString(),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      });
      final store = WebDavSyncStore(
        dav: WebDavService(
          baseUrl: 'https://dav.example.com/dav/',
          username: 'u',
          password: 'p',
          client: client,
        ),
        folder: 'narrchat',
      );

      await store.writeManifest(manifest);
      final readBack = await store.readManifest();
      expect(putBody, isNotNull);
      expect(readBack, isNotNull);
      expect(readBack!.generation, 2);
      expect(readBack.books.single.title, '书A');
      expect(readBack.books.single.settingsFp, 'S0');
      expect(readBack.books.single.roundsFp, 'R1');
      expect(readBack.images, ['img/a.png']);
      expect(got, isTrue);
    });

    test('云端无 manifest（GET 404）→ readManifest 返回 null', () async {
      final client = MockClient((request) async => http.Response('nf', 404));
      final store = WebDavSyncStore(
        dav: WebDavService(
          baseUrl: 'https://dav.example.com/dav/',
          username: 'u',
          password: 'p',
          client: client,
        ),
        folder: 'narrchat',
      );
      expect(await store.readManifest(), isNull);
    });

    test('uuid 身份随 manifest 读写往返', () async {
      var got = '';
      final client = MockClient((request) async {
        if (request.method == 'PUT') {
          got = utf8.decode(request.bodyBytes);
          return http.Response('', 201);
        }
        return http.Response('nf', 404);
      });
      final store = WebDavSyncStore(
        dav: WebDavService(
          baseUrl: 'https://dav.example.com/dav/',
          username: 'u',
          password: 'p',
          client: client,
        ),
        folder: 'narrchat',
      );
      final m = SyncManifest(
        generation: 3,
        lastWriterDeviceId: 'dev-1',
        knownDevices: const ['dev-1'],
        books: const [
          SyncBookEntry(
            uuid: 'u-uuid-1',
            title: '书A',
            deleted: false,
            settingsFp: 'S0',
            settingsUpdatedAt: 100,
            roundsFp: 'R1',
            roundsUpdatedAt: 200,
            worldBookFp: '',
            bookModsFp: '',
          ),
        ],
        mods: const [
          SyncModEntry(
            uuid: 'm-uuid-1',
            name: '风格',
            deleted: false,
            updatedAt: 0,
            fingerprint: 'F1',
          ),
        ],
      );
      await store.writeManifest(m);
      final parsed = SyncManifest.tryParse(got)!;
      expect(parsed.format, 2);
      expect(parsed.books.single.uuid, 'u-uuid-1');
      expect(parsed.mods.single.uuid, 'm-uuid-1');
      expect(parsed.books.single.title, '书A');
    });

    test('旧版清单（settingsFp 单值）→ 5 个子部件回退为同值（整书兼容）', () {
      final legacy =
          '{"format":1,"generation":2,"lastWriterDeviceId":"dev-1",'
          '"knownDevices":["dev-1"],'
          '"books":[{"title":"书A","deleted":false,"settingsFp":"S0",'
          '"settingsUpdatedAt":100,"roundsFp":"R1","roundsUpdatedAt":200,'
          '"worldBookFp":"","bookModsFp":""}],"mods":[],"images":[]}';
      final manifest = SyncManifest.tryParse(legacy)!;
      expect(manifest.format, 1);
      expect(manifest.books.single.uuid, '');
      expect(manifest.books.single.title, '书A');
      expect(manifest.books.single.settingsFp, 'S0');
    });
  });

  group('云端软锁', () {
    test('无锁 → acquire 成功并可在 release 后删除', () async {
      final requests = <String>[];
      String? lockBody;
      final client = MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.method == 'GET') {
          // 模拟锁文件：PUT 之后可被读到；未 PUT 前 404。
          if (lockBody == null) return http.Response('nf', 404);
          return http.Response(lockBody!, 200);
        }
        if (request.method == 'PUT') {
          lockBody = utf8.decode(request.bodyBytes);
          return http.Response('', 201);
        }
        if (request.method == 'DELETE') {
          lockBody = null;
          return http.Response('', 204);
        }
        return http.Response('', 404);
      });
      final store = WebDavSyncStore(
        dav: WebDavService(
          baseUrl: 'https://dav.example.com/dav/',
          username: 'u',
          password: 'p',
          client: client,
        ),
        folder: 'narrchat',
      );
      expect(await store.acquireLock(deviceId: 'dev-1'), isTrue);
      expect(requests, contains('PUT /dav/narrchat/sync.lock'));
      await store.releaseLock(deviceId: 'dev-1');
      expect(requests.last, 'DELETE /dav/narrchat/sync.lock');
    });

    test('有效且属于其它设备的锁 → 拒绝；过期锁 → 可抢占', () async {
      var body = jsonEncode({
        'deviceId': 'dev-2',
        'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
      });
      var getCalls = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          getCalls++;
          return http.Response(body, 200);
        }
        if (request.method == 'PUT') return http.Response('', 201);
        if (request.method == 'DELETE') return http.Response('', 204);
        return http.Response('', 404);
      });
      final store = WebDavSyncStore(
        dav: WebDavService(
          baseUrl: 'https://dav.example.com/dav/',
          username: 'u',
          password: 'p',
          client: client,
        ),
        folder: 'narrchat',
      );
      expect(await store.acquireLock(deviceId: 'dev-1'), isFalse,
          reason: '其它设备持有效锁');
      // 过期后被 dev-1 抢占。
      body = jsonEncode({
        'deviceId': 'dev-2',
        'expiresAt': DateTime.now().millisecondsSinceEpoch - 1000,
      });
      expect(getCalls, 1);
      expect(await store.acquireLock(deviceId: 'dev-1'), isTrue,
          reason: '过期锁可抢占');
    });
  });
}
