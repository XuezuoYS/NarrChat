import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narrchat/services/update_check_service.dart';

/// 构造 UTF-8 的 GitHub Release JSON 响应（MockClient 默认按 Latin-1 解码，
/// 含中文的 body 必须用 bytes + charset 头，否则会抛编码异常）。
http.Response _jsonResponse(
  Map<String, dynamic> json, {
  int status = 200,
}) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(json)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> _releaseJson({
  String tag = 'v1.4.0',
  String name = 'NarrChat 1.4.0',
  String htmlUrl = 'https://github.com/XuezuoYS/NarrChat/releases/tag/v1.4.0',
  String body = '## 更新内容\n- 新功能',
  String publishedAt = '2026-01-01T00:00:00Z',
}) {
  return {
    'tag_name': tag,
    'name': name,
    'html_url': htmlUrl,
    'body': body,
    'published_at': publishedAt,
  };
}

/// 大小写不敏感地读取请求头（http 包内部可能归一化为小写键）。
String? _header(http.BaseRequest request, String name) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

void main() {
  group('check（MockClient）', () {
    test('200 且远端更高 → UpdateAvailable，字段解析正确', () async {
      late http.Request captured;
      final service = UpdateCheckService(
        client: MockClient((request) async {
          captured = request;
          return _jsonResponse(_releaseJson());
        }),
      );

      final result = await service.check(currentVersion: '1.3.1');

      expect(result, isA<UpdateAvailable>());
      final release = (result as UpdateAvailable).release;
      expect(release.tagVersion, 'v1.4.0');
      expect(release.displayName, 'NarrChat 1.4.0');
      expect(
        release.pageUrl,
        'https://github.com/XuezuoYS/NarrChat/releases/tag/v1.4.0',
      );
      expect(release.notes, contains('更新内容'));
      expect(release.publishedAt, '2026-01-01T00:00:00Z');
      expect(captured.url.toString(),
          'https://api.github.com/repos/XuezuoYS/NarrChat/releases/latest');
      expect(_header(captured, 'User-Agent'), 'NarrChat');
      expect(_header(captured, 'Accept'), contains('vnd.github'));
    });

    test('缺 html_url 时回退到仓库 Releases 页', () async {
      final json = _releaseJson()..['html_url'] = '';
      final service = UpdateCheckService(
        client: MockClient((_) async => _jsonResponse(json)),
      );
      final result = await service.check(currentVersion: '1.3.1');
      expect(
        (result as UpdateAvailable).release.pageUrl,
        'https://github.com/XuezuoYS/NarrChat/releases',
      );
    });

    test('200 且相同 / 更低 → UpToDate', () async {
      final same = UpdateCheckService(
        client: MockClient((_) async => _jsonResponse(_releaseJson(tag: 'v1.3.1'))),
      );
      expect(await same.check(currentVersion: '1.3.1'), isA<UpToDate>());

      final lower = UpdateCheckService(
        client: MockClient((_) async => _jsonResponse(_releaseJson(tag: 'v1.3.0'))),
      );
      expect(await lower.check(currentVersion: '1.3.1'), isA<UpToDate>());
    });

    test('404 → NoRelease', () async {
      final service = UpdateCheckService(
        client: MockClient((_) async => http.Response('Not Found', 404)),
      );
      expect(await service.check(currentVersion: '1.3.1'), isA<NoRelease>());
    });

    test('403 → CheckFailed 且文案含限流提示', () async {
      final service = UpdateCheckService(
        client: MockClient((_) async => http.Response('rate limited', 403)),
      );
      final result = await service.check(currentVersion: '1.3.1');
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).reason, contains('403'));
      expect(result.reason, contains('限流'));
    });

    test('非 200 其它状态码 → CheckFailed 含状态码', () async {
      final service = UpdateCheckService(
        client: MockClient((_) async => http.Response('server error', 500)),
      );
      final result = await service.check(currentVersion: '1.3.1');
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).reason, contains('500'));
    });

    test('响应非 JSON / 非对象 → CheckFailed 响应格式异常', () async {
      final notJson = UpdateCheckService(
        client: MockClient((_) async => http.Response('not-json', 200)),
      );
      final failed1 = await notJson.check(currentVersion: '1.3.1');
      expect(failed1, isA<CheckFailed>());
      expect((failed1 as CheckFailed).reason, contains('响应格式异常'));

      final notObject = UpdateCheckService(
        client: MockClient((_) async => http.Response('[1,2]', 200)),
      );
      final failed2 = await notObject.check(currentVersion: '1.3.1');
      expect(failed2, isA<CheckFailed>());
    });

    test('tag 无法解析 → CheckFailed', () async {
      final service = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonResponse(_releaseJson(tag: 'release-alpha')),
        ),
      );
      final result = await service.check(currentVersion: '1.3.1');
      expect(result, isA<CheckFailed>());
    });

    test('ClientException → CheckFailed 网络请求失败', () async {
      final service = UpdateCheckService(
        client: MockClient((_) async => throw http.ClientException('连接失败')),
      );
      final result = await service.check(currentVersion: '1.3.1');
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).reason, contains('网络请求失败'));
      expect(result.reason, contains('连接失败'));
    });

    test('超过 8 秒超时 → CheckFailed 网络请求超时', () {
      fakeAsync((async) {
        final service = UpdateCheckService(
          client: MockClient((_) async {
            await Future<void>.delayed(const Duration(seconds: 20));
            return _jsonResponse(_releaseJson());
          }),
        );
        UpdateCheckResult? result;
        service.check(currentVersion: '1.3.1').then((r) => result = r);

        async.elapse(const Duration(seconds: 7));
        expect(result, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(result, isA<CheckFailed>());
        expect((result as CheckFailed).reason, contains('超时'));
      });
    });
  });

  group('check（forceShow 调试强制演示）', () {
    test('版本相同也返回 UpdateAvailable', () async {
      final service = UpdateCheckService(
        client: MockClient((_) async => _jsonResponse(_releaseJson(tag: 'v1.3.1'))),
      );

      final result = await service.check(currentVersion: '1.3.1', forceShow: true);

      expect(result, isA<UpdateAvailable>());
      expect((result as UpdateAvailable).release.tagVersion, 'v1.3.1');
    });

    test('版本更旧也返回 UpdateAvailable', () async {
      final service = UpdateCheckService(
        client: MockClient((_) async => _jsonResponse(_releaseJson(tag: 'v1.3.0'))),
      );

      final result = await service.check(currentVersion: '1.3.1', forceShow: true);

      expect(result, isA<UpdateAvailable>());
      expect((result as UpdateAvailable).release.tagVersion, 'v1.3.0');
    });

    test('默认 false 时保持原行为：相同 / 更旧 → UpToDate', () async {
      final same = UpdateCheckService(
        client: MockClient((_) async => _jsonResponse(_releaseJson(tag: 'v1.3.1'))),
      );
      expect(await same.check(currentVersion: '1.3.1'), isA<UpToDate>());

      final lower = UpdateCheckService(
        client: MockClient((_) async => _jsonResponse(_releaseJson(tag: 'v1.3.0'))),
      );
      expect(await lower.check(currentVersion: '1.3.1'), isA<UpToDate>());
    });
  });
}
