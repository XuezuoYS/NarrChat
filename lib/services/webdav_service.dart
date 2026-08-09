import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// WebDAV 文件条目（云端备份列表项）。
class WebDavFile {
  final String name;
  final DateTime? lastModified;
  final int size;

  const WebDavFile({required this.name, this.lastModified, this.size = 0});
}

/// WebDAV 请求异常（含 HTTP 状态码与响应片段，便于排查）。
class WebDavException implements Exception {
  final String message;
  final int? statusCode;
  final String body;

  const WebDavException(this.message, {this.statusCode, this.body = ''});

  @override
  String toString() {
    if (body.isNotEmpty) return '$message（HTTP $statusCode）：$body';
    if (statusCode != null) return '$message（HTTP $statusCode）';
    return message;
  }
}

/// 轻量 WebDAV 客户端（基于 `package:http`，Basic Auth）。
///
/// 仅实现云同步所需的最小操作集：
/// - `ensureCollection`：建目录（MKCOL，已存在则忽略）；
/// - `list`：列目录（PROPFIND Depth:1）；
/// - `put`：上传（PUT）；
/// - `get`：下载（GET）；
/// - `delete`：删除（DELETE，用于修剪历史版本）。
class WebDavService {
  WebDavService({
    required this.baseUrl,
    required this.username,
    required this.password,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String username;
  final String password;
  final http.Client _client;

  String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  Map<String, String> get _headers => {
        'Authorization': _authHeader,
        'User-Agent': 'NarrChat/1.0',
      };

  /// 拼接服务器地址与相对路径（自动处理首尾斜杠）。
  String _joinUrl(String path) {
    final base = baseUrl.trim().endsWith('/')
        ? baseUrl.trim()
        : '${baseUrl.trim()}/';
    final clean = path.replaceAll(RegExp(r'^/+'), '');
    return '$base$clean';
  }

  Uri _uri(String path) => Uri.parse(_joinUrl(path));

  /// 统一请求入口：手动跟随 3xx 重定向（保留方法与请求体）。
  ///
  /// `package:http` 默认客户端对 PROPFIND / MKCOL 等非标准方法不跟随重定向，
  /// 而不少 WebDAV 服务器（如 Apache mod_dav）会把无尾斜杠的目录地址
  /// 301 重定向到带尾斜杠地址——必须显式跟随，否则会拿到 301 原始响应。
  ///
  /// 安全：跨主机或跨协议跳转时移除 `Authorization`，避免凭据泄露。
  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    int maxRedirects = 5,
  }) async {
    var current = uri;
    var effectiveHeaders = headers ?? const <String, String>{};
    for (var i = 0; i <= maxRedirects; i++) {
      final request = http.Request(method, current);
      request.headers.addAll(effectiveHeaders);
      if (body is String) {
        request.body = body;
      } else if (body is List<int>) {
        request.bodyBytes = body;
      }
      final streamed = await _client.send(request);
      final response = await http.Response.fromStream(streamed);
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          return response;
        }
        final next = current.resolve(location);
        if (next.host != current.host || next.scheme != current.scheme) {
          effectiveHeaders = Map<String, String>.from(effectiveHeaders)
            ..remove('Authorization');
        }
        current = next;
        continue;
      }
      return response;
    }
    throw const WebDavException('重定向次数过多');
  }

  /// 确保集合（目录）存在；不存在则创建（MKCOL）。
  ///
  /// 已存在的目录服务器通常返回 405（方法不被允许），视为成功。
  Future<void> ensureCollection(String path) async {
    final res = await _send('MKCOL', _uri(path), headers: _headers);
    final ok = res.statusCode == 201 ||
        res.statusCode == 200 ||
        res.statusCode == 405;
    if (!ok) {
      throw WebDavException(
        '创建云端目录失败',
        statusCode: res.statusCode,
        body: res.body,
      );
    }
  }

  /// 列出集合内全部条目（PROPFIND，Depth:1）。
  Future<List<WebDavFile>> list(String path) async {
    final res = await _send(
      'PROPFIND',
      _uri(path),
      headers: {
        ..._headers,
        'Depth': '1',
        'Content-Type': 'application/xml; charset="utf-8"',
      },
      body: '''
<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getlastmodified/>
    <d:getcontentlength/>
  </d:prop>
</d:propfind>''',
    );
    if (res.statusCode != 207 && res.statusCode != 200) {
      throw WebDavException(
        '列出云端备份失败',
        statusCode: res.statusCode,
        body: res.body,
      );
    }
    return parseMultiStatus(res.body);
  }

  /// 上传文件（PUT）。
  Future<void> put(String path, String name, Uint8List bytes) async {
    final res = await _send(
      'PUT',
      _uri('$path/$name'),
      headers: {..._headers, 'Content-Type': 'application/octet-stream'},
      body: bytes,
    );
    final ok = res.statusCode == 201 ||
        res.statusCode == 204 ||
        res.statusCode == 200;
    if (!ok) {
      throw WebDavException(
        '上传失败',
        statusCode: res.statusCode,
        body: res.body,
      );
    }
  }

  /// 下载文件（GET），返回文件字节。
  Future<Uint8List> get(String path, String name) async {
    final res = await _send('GET', _uri('$path/$name'), headers: _headers);
    if (res.statusCode != 200) {
      throw WebDavException(
        '下载失败',
        statusCode: res.statusCode,
        body: res.body,
      );
    }
    return res.bodyBytes;
  }

  /// 删除文件（DELETE）；文件不存在（404）视为成功。
  Future<void> delete(String path, String name) async {
    final res = await _send('DELETE', _uri('$path/$name'), headers: _headers);
    final ok = res.statusCode == 204 ||
        res.statusCode == 200 ||
        res.statusCode == 404;
    if (!ok) {
      throw WebDavException(
        '删除失败',
        statusCode: res.statusCode,
        body: res.body,
      );
    }
  }

  void close() => _client.close();

  // ---------- PROPFIND 响应解析（multistatus XML） ----------

  static final RegExp _responseRegex = RegExp(
    r'<(?:\w+:)?response\b[^>]*>([\s\S]*?)</(?:\w+:)?response\b>',
    caseSensitive: false,
  );
  static final RegExp _hrefRegex = RegExp(
    r'<(?:\w+:)?href\b[^>]*>\s*([^<]*?)\s*</(?:\w+:)?href\b>',
    caseSensitive: false,
  );
  static final RegExp _modifiedRegex = RegExp(
    r'<(?:\w+:)?getlastmodified\b[^>]*>\s*([^<]*?)\s*</(?:\w+:)?getlastmodified\b>',
    caseSensitive: false,
  );
  static final RegExp _lengthRegex = RegExp(
    r'<(?:\w+:)?getcontentlength\b[^>]*>\s*([^<]*?)\s*</(?:\w+:)?getcontentlength\b>',
    caseSensitive: false,
  );

  /// 解析 PROPFIND 的 multistatus 响应，返回全部文件条目（跳过目录）。
  static List<WebDavFile> parseMultiStatus(String xml) {
    final files = <WebDavFile>[];
    for (final m in _responseRegex.allMatches(xml)) {
      final block = m.group(1)!;
      final hrefMatch = _hrefRegex.firstMatch(block);
      if (hrefMatch == null) continue;
      final href = Uri.decodeFull(hrefMatch.group(1)!.trim());
      if (href.endsWith('/')) continue; // 目录条目
      final name = href.split('/').last;
      if (name.isEmpty) continue;

      DateTime? modified;
      final modifiedMatch = _modifiedRegex.firstMatch(block);
      if (modifiedMatch != null) {
        try {
          modified = HttpDate.parse(modifiedMatch.group(1)!.trim());
        } catch (_) {
          // 非标准时间格式时忽略。
        }
      }
      final lengthMatch = _lengthRegex.firstMatch(block);
      final size = int.tryParse(lengthMatch?.group(1)?.trim() ?? '') ?? 0;
      files.add(
        WebDavFile(name: name, lastModified: modified, size: size),
      );
    }
    return files;
  }
}
