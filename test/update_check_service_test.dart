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

/// 发布列表接口（`releases`）响应：JSON 数组。
http.Response _jsonListResponse(
  List<Map<String, dynamic>> items, {
  int status = 200,
}) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(items)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
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

    test('本地是测试版：同主体正式版算更新，更早的正式版不算', () async {
      final stable = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonResponse(_releaseJson(tag: 'v3.0.0')),
        ),
      );
      expect(
        await stable.check(currentVersion: '3.0.0-beta.2'),
        isA<UpdateAvailable>(),
      );

      final older = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonResponse(_releaseJson(tag: 'v2.5.2')),
        ),
      );
      expect(
        await older.check(currentVersion: '3.0.0-beta.2'),
        isA<UpToDate>(),
      );
    });

    test('本地版本号不合规范 → UpToDate（不误报）', () async {
      final service = UpdateCheckService(
        client: MockClient((_) async => _jsonResponse(_releaseJson())),
      );
      expect(await service.check(currentVersion: 'dev-build'), isA<UpToDate>());
      expect(await service.check(currentVersion: '1.3'), isA<UpToDate>());
    });

    test('latest 的 tag 不合规范（缺段 / 夹带文字 / 规范外后缀）→ CheckFailed', () async {
      for (final tag in ['v1.4', 'release-1.3.1-tag', 'v1.4.0-hotfix.1']) {
        final service = UpdateCheckService(
          client: MockClient(
            (_) async => _jsonResponse(_releaseJson(tag: tag)),
          ),
        );
        expect(
          await service.check(currentVersion: '1.3.1'),
          isA<CheckFailed>(),
          reason: '应拒绝 "$tag"',
        );
      }
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

    test('本地版本无法解析也返回 UpdateAvailable', () async {
      final service = UpdateCheckService(
        client: MockClient((_) async => _jsonResponse(_releaseJson(tag: 'v1.3.0'))),
      );

      final result = await service.check(
        currentVersion: 'dev',
        forceShow: true,
      );

      expect(result, isA<UpdateAvailable>());
    });
  });

  group('check（latest 返回测试版时回退列表）', () {
    /// 路由式替身：`/releases/latest` 返回 [latest]，其它（列表）返回 [list]。
    UpdateCheckService buildService({
      required Map<String, dynamic> latest,
      required http.Response Function() list,
      List<String>? requests,
    }) {
      return UpdateCheckService(
        client: MockClient((request) async {
          requests?.add(request.url.toString());
          if (request.url.path.endsWith('/latest')) {
            return _jsonResponse(latest);
          }
          return list();
        }),
      );
    }

    test('回退列表后挑最高正式版，忽略测试版与草稿', () async {
      final requests = <String>[];
      final service = buildService(
        latest: _releaseJson(tag: 'v3.0.0-beta.1'),
        list: () => _jsonListResponse([
          _releaseJson(tag: 'v3.0.0-beta.2'),
          _releaseJson(tag: 'v2.5.2', name: 'NarrChat 2.5.2'),
          _releaseJson(tag: 'v2.4.0'),
          _releaseJson(tag: 'v9.0.0')..['draft'] = true,
        ]),
        requests: requests,
      );

      final result = await service.check(currentVersion: '2.5.1');

      expect(result, isA<UpdateAvailable>());
      expect((result as UpdateAvailable).release.tagVersion, 'v2.5.2');
      expect(requests, hasLength(2));
      expect(requests.first, endsWith('/releases/latest'));
      expect(requests.last, endsWith('/releases?per_page=30'));
    });

    test('latest 是正式版：不再请求列表', () async {
      final requests = <String>[];
      final service = buildService(
        latest: _releaseJson(tag: 'v1.4.0'),
        list: () => _jsonListResponse([_releaseJson(tag: 'v1.5.0')]),
        requests: requests,
      );

      final result = await service.check(currentVersion: '1.3.1');

      expect((result as UpdateAvailable).release.tagVersion, 'v1.4.0');
      expect(requests, hasLength(1));
    });

    test('回退列表里全是测试版 → UpToDate（当前渠道无更新）', () async {
      final service = buildService(
        latest: _releaseJson(tag: 'v3.0.0-beta.1'),
        list: () => _jsonListResponse([
          _releaseJson(tag: 'v3.0.0-beta.2'),
          _releaseJson(tag: 'v3.0.0-rc.1'),
        ]),
      );

      expect(await service.check(currentVersion: '2.5.2'), isA<UpToDate>());
    });

    test('回退列表为空 → NoRelease', () async {
      final service = buildService(
        latest: _releaseJson(tag: 'v3.0.0-beta.1'),
        list: () => _jsonListResponse([]),
      );

      expect(await service.check(currentVersion: '2.5.2'), isA<NoRelease>());
    });

    test('回退列表 tag 全不合规范 → CheckFailed', () async {
      final service = buildService(
        latest: _releaseJson(tag: 'v3.0.0-beta.1'),
        list: () => _jsonListResponse([
          _releaseJson(tag: 'release-alpha'),
          _releaseJson(tag: 'v2.5'),
        ]),
      );

      final result = await service.check(currentVersion: '2.5.2');
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).reason, contains('版本号无法解析'));
    });

    test('回退列表跳过不合规范的 tag，取最高合规正式版', () async {
      final service = buildService(
        latest: _releaseJson(tag: 'v3.0.0-beta.1'),
        list: () => _jsonListResponse([
          _releaseJson(tag: 'v2.5'),
          _releaseJson(tag: 'v2.4.9'),
          _releaseJson(tag: 'v2.5.0'),
        ]),
      );

      final result = await service.check(currentVersion: '2.4.9');
      expect((result as UpdateAvailable).release.tagVersion, 'v2.5.0');
    });

    test('回退请求失败（403）→ CheckFailed 含限流提示', () async {
      final service = buildService(
        latest: _releaseJson(tag: 'v3.0.0-beta.1'),
        list: () => http.Response('rate limited', 403),
      );

      final result = await service.check(currentVersion: '2.5.2');
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).reason, contains('限流'));
    });
  });

  group('check（includePrerelease：包含预发布版本）', () {
    test('改用发布列表接口，且按版本号取最高（含预发布）', () async {
      late http.Request captured;
      final service = UpdateCheckService(
        client: MockClient((request) async {
          captured = request;
          return _jsonListResponse([
            _releaseJson(tag: 'v1.3.0', name: 'NarrChat 1.3.0'),
            _releaseJson(tag: 'v1.4.0-beta.1', name: 'NarrChat 1.4.0 Beta 1'),
          ]);
        }),
      );

      final result = await service.check(
        currentVersion: '1.3.1',
        includePrerelease: true,
      );

      expect(result, isA<UpdateAvailable>());
      expect((result as UpdateAvailable).release.tagVersion, 'v1.4.0-beta.1');
      expect(
        captured.url.toString(),
        'https://api.github.com/repos/XuezuoYS/NarrChat/releases?per_page=30',
      );
      expect(_header(captured, 'User-Agent'), 'NarrChat');
      expect(_header(captured, 'Accept'), contains('vnd.github'));
    });

    test('默认（不传）仍走正式版 /releases/latest 接口', () async {
      late Uri url;
      final service = UpdateCheckService(
        client: MockClient((request) async {
          url = request.url;
          return _jsonResponse(_releaseJson());
        }),
      );
      await service.check(currentVersion: '1.3.1');
      expect(url.path, '/repos/XuezuoYS/NarrChat/releases/latest');
      expect(url.hasQuery, isFalse);
    });

    test('列表时间顺序与版本高低不一致：按版本号挑最高', () async {
      final service = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonListResponse([
            _releaseJson(tag: 'v1.9.0'),
            _releaseJson(tag: 'v1.10.0-beta.1'),
            _releaseJson(tag: 'v1.8.0'),
          ]),
        ),
      );
      final result = await service.check(
        currentVersion: '1.9.0',
        includePrerelease: true,
      );
      expect((result as UpdateAvailable).release.tagVersion, 'v1.10.0-beta.1');
    });

    test('本地跑 beta 构建：同号正式版优先于更高 beta，beta.2 也能提示', () async {
      final withStable = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonListResponse([
            _releaseJson(tag: 'v3.0.0-beta.2'),
            _releaseJson(tag: 'v3.0.0'),
          ]),
        ),
      );
      final stableResult = await withStable.check(
        currentVersion: '3.0.0-beta.1',
        includePrerelease: true,
      );
      expect((stableResult as UpdateAvailable).release.tagVersion, 'v3.0.0');

      final betaOnly = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonListResponse([_releaseJson(tag: 'v3.0.0-beta.2')]),
        ),
      );
      final betaResult = await betaOnly.check(
        currentVersion: '3.0.0-beta.1',
        includePrerelease: true,
      );
      expect(
        (betaResult as UpdateAvailable).release.tagVersion,
        'v3.0.0-beta.2',
      );
    });

    test('远端只是同号或更低预发布 → UpToDate', () async {
      final same = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonListResponse([
            _releaseJson(tag: 'v1.4.0'),
            _releaseJson(tag: 'v1.4.0-beta.2'),
          ]),
        ),
      );
      expect(
        await same.check(currentVersion: '1.4.0', includePrerelease: true),
        isA<UpToDate>(),
      );

      final lower = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonListResponse([_releaseJson(tag: 'v1.4.0-beta.1')]),
        ),
      );
      expect(
        await lower.check(
          currentVersion: '1.4.0-beta.2',
          includePrerelease: true,
        ),
        isA<UpToDate>(),
      );
    });

    test('跳过草稿（draft:true）', () async {
      final draft = _releaseJson(tag: 'v9.0.0')..['draft'] = true;
      final service = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonListResponse([draft, _releaseJson(tag: 'v1.4.0')]),
        ),
      );
      final result = await service.check(
        currentVersion: '1.3.1',
        includePrerelease: true,
      );
      expect((result as UpdateAvailable).release.tagVersion, 'v1.4.0');
    });

    test('列表内不合规范的 tag 被跳过', () async {
      final service = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonListResponse([
            _releaseJson(tag: 'v1.4'),
            _releaseJson(tag: 'v1.10.0-beta.1'),
          ]),
        ),
      );
      final result = await service.check(
        currentVersion: '1.3.1',
        includePrerelease: true,
      );
      expect((result as UpdateAvailable).release.tagVersion, 'v1.10.0-beta.1');
    });

    test('空列表 → NoRelease', () async {
      final service = UpdateCheckService(
        client: MockClient((_) async => _jsonListResponse([])),
      );
      expect(
        await service.check(currentVersion: '1.3.1', includePrerelease: true),
        isA<NoRelease>(),
      );
    });

    test('列表内 tag 全无法解析 → CheckFailed', () async {
      final service = UpdateCheckService(
        client: MockClient(
          (_) async => _jsonListResponse([_releaseJson(tag: 'release-alpha')]),
        ),
      );
      final result = await service.check(
        currentVersion: '1.3.1',
        includePrerelease: true,
      );
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).reason, contains('版本号无法解析'));
    });

    test('列表接口响应不是数组 → CheckFailed 响应格式异常', () async {
      final service = UpdateCheckService(
        client: MockClient((_) async => _jsonResponse(_releaseJson())),
      );
      final result = await service.check(
        currentVersion: '1.3.1',
        includePrerelease: true,
      );
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).reason, contains('响应格式异常'));
    });

    test('404 / 403 与正式版接口同口径', () async {
      final notFound = UpdateCheckService(
        client: MockClient((_) async => http.Response('Not Found', 404)),
      );
      expect(
        await notFound.check(currentVersion: '1.3.1', includePrerelease: true),
        isA<NoRelease>(),
      );

      final forbidden = UpdateCheckService(
        client: MockClient((_) async => http.Response('rate limited', 403)),
      );
      final result = await forbidden.check(
        currentVersion: '1.3.1',
        includePrerelease: true,
      );
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).reason, contains('限流'));
    });
  });
}
