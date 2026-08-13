import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:http/http.dart' as http;

/// 一条搜索结果。
class SearchResult {
  final String title;
  final String url;
  final String snippet;

  const SearchResult({
    required this.title,
    required this.url,
    this.snippet = '',
  });
}

/// 抓取网页过程中的一跳（HTTP 3xx 重定向或应用级回退）。
class FetchHop {
  /// 本跳访问的 URL。
  final String url;

  /// HTTP 状态码；为 null 表示应用级重定向（如百度百科回退 WAP 端点）。
  final int? statusCode;

  const FetchHop({required this.url, this.statusCode});
}

/// 抓取结果：最终 HTML 与跳转链。
class _FetchResult {
  final String html;
  final List<FetchHop> hops;
  const _FetchResult(this.html, this.hops);
}

/// 联网搜索失败异常（两个引擎均失败时抛出）。
class SearchException implements Exception {
  final String message;
  const SearchException(this.message);

  @override
  String toString() => message;
}

/// 目标页面拒绝访问异常（HTTP 3xx/4xx/5xx 等非 2xx）。
///
/// 区别于网络故障：[FetchPageTool] 据此把结果标记为 `refused`，
/// UI 显示黄色 ✕ 且不计入工具连续失败次数。
class HttpStatusException implements Exception {
  final int statusCode;
  final String url;
  const HttpStatusException(this.statusCode, this.url);

  @override
  String toString() => 'HTTP $statusCode：$url';
}

/// 自研 HTML 搜索引擎服务（不依赖第三方 API / 服务器）。
///
/// - **主引擎：Bing**（`www.bing.com/search`，自动跟随重定向到 cn.bing.com 等区域端点）；
/// - **备用引擎：DuckDuckGo HTML 端点**（`html.duckduckgo.com/html/`，部分网络可达）；
/// - 使用浏览器 User-Agent 与 Accept-Language，降低反爬命中；
/// - 解析器为**纯函数**（[parseBingHtml] / [parseDuckDuckGoHtml] / [extractPageText]），
///   可注入固定 HTML 样本测试，降低搜索引擎改版导致的维护风险。
class HtmlSearchService {
  HtmlSearchService({http.Client? client, String? userAgent})
    : _client = client ?? http.Client(),
      _userAgent = userAgent ?? _defaultUserAgent;

  final http.Client _client;
  final String _userAgent;

  /// 会话 Cookie（内存级，模拟浏览器会话；host → name → value）。
  final Map<String, Map<String, String>> _cookies = {};

  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static const Duration _timeout = Duration(seconds: 15);

  /// 搜索关键词，返回最多 [maxResults] 条结果。
  ///
  /// 主引擎 Bing 失败 / 空结果时回退 DuckDuckGo；两者均失败时抛 [SearchException]。
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 5,
  }) async {
    Object? bingError;
    try {
      final results = await _searchBing(query, maxResults);
      if (results.isNotEmpty) return results;
      bingError = 'Bing 未返回结果';
    } catch (e) {
      bingError = e;
    }
    try {
      return await _searchDuckDuckGo(query, maxResults);
    } catch (e) {
      throw SearchException('联网搜索失败（Bing：$bingError；备用引擎：$e）');
    }
  }

  Future<List<SearchResult>> _searchBing(
    String query,
    int maxResults,
  ) =>
      _paginate(
        maxResults: maxResults,
        buildUrl: (offset) => offset == 0
            ? 'https://www.bing.com/search?q=${Uri.encodeQueryComponent(query)}'
            : 'https://www.bing.com/search?q=${Uri.encodeQueryComponent(query)}'
                  '&first=${offset + 1}',
        parse: parseBingHtml,
      );

  Future<List<SearchResult>> _searchDuckDuckGo(
    String query,
    int maxResults,
  ) =>
      _paginate(
        maxResults: maxResults,
        buildUrl: (offset) =>
            'https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(query)}'
            '${offset == 0 ? '' : '&s=$offset'}',
        parse: parseDuckDuckGoHtml,
      );

  /// 翻页抓取搜索结果：每页约 10 条，逐页抓取直至凑齐 [maxResults]
  /// 或没有更多结果；按 URL 去重。
  ///
  /// - 第一页失败（网络 / 非 200）向上抛，由上层按「引擎错误」回退备用引擎；
  /// - 后续页失败时返回已收集的结果（不中断）；
  /// - 某页为空或全部重复时停止。
  Future<List<SearchResult>> _paginate({
    required int maxResults,
    required String Function(int offset) buildUrl,
    required List<SearchResult> Function(String html) parse,
  }) async {
    const perPage = 10;
    final all = <SearchResult>[];
    final seen = <String>{};
    for (var page = 0; page * perPage < maxResults; page++) {
      try {
        final fetched = await _get(buildUrl(page * perPage));
        final results = parse(fetched.html);
        if (results.isEmpty) break;
        var added = 0;
        for (final r in results) {
          if (seen.add(r.url)) {
            all.add(r);
            added++;
          }
        }
        if (added == 0) break; // 本页全部重复 → 无法继续翻页
        if (all.length >= maxResults) break; // 已凑齐
      } catch (e) {
        // 第一页失败：向上抛（上层按引擎错误回退）；后续页失败：保留已收集结果。
        if (all.isEmpty) rethrow;
        break;
      }
    }
    return all.take(maxResults).toList();
  }

  /// 抓取网页正文（去除 script/style/标签后的可读文本，截取前 [maxChars] 字符）。
  ///
  /// [onHop]：每完成一跳（HTTP 重定向 / 应用级回退 / 最终响应）回调一次，
  /// 供 UI 流式展示抓取跳转链。
  Future<String> fetchPageText(
    String url, {
    int maxChars = 30000,
    void Function(FetchHop hop)? onHop,
  }) async {
    final result = await _get(url, onHop: onHop);
    return extractPageText(result.html, maxChars: maxChars);
  }

  /// 抓取 URL：手动跟随 3xx 重定向并记录每一跳，返回最终 HTML 与跳转链。
  Future<_FetchResult> _get(
    String url, {
    void Function(FetchHop hop)? onHop,
  }) async {
    final hops = <FetchHop>[];
    void addHop(FetchHop hop) {
      hops.add(hop);
      onHop?.call(hop);
    }

    var uri = Uri.parse(url);
    var resp = await _send(uri);
    _storeCookies(resp, uri);
    // 手动跟随 3xx 重定向（记录每一跳；请求级已禁用自动跟随）。
    // ⚠️ 不依赖 resp.isRedirect（该字段可能为 false），直接按状态码区间判断。
    var redirectCount = 0;
    while (resp.statusCode >= 300 &&
        resp.statusCode < 400 &&
        redirectCount < 5) {
      addHop(FetchHop(url: uri.toString(), statusCode: resp.statusCode));
      final location = resp.headers['location'];
      if (location == null || location.isEmpty) break;
      uri = uri.resolve(location);
      resp = await _send(uri);
      _storeCookies(resp, uri);
      redirectCount++;
    }
    // 百度百科桌面端 403：WAP 应用级回退（同路径换主机）。
    if (resp.statusCode == 403 && uri.host == 'baike.baidu.com') {
      addHop(FetchHop(url: uri.toString())); // 应用重定向（无状态码）
      uri = uri.replace(host: 'wapbaike.baidu.com');
      resp = await _send(uri);
      _storeCookies(resp, uri);
    }
    // 一般 403：先访问站点根路径建立会话 Cookie 再重试一次。
    if (resp.statusCode == 403) {
      await _warmupSession(uri);
      resp = await _send(uri);
      _storeCookies(resp, uri);
    }
    // 2xx（含 206 等）视为访问成功；3xx/4xx/5xx 一律视为拒绝访问。
    if (resp.statusCode >= 300) {
      throw HttpStatusException(resp.statusCode, url);
    }
    addHop(FetchHop(url: uri.toString(), statusCode: resp.statusCode));
    return _FetchResult(_decodeBody(resp), hops);
  }

  /// 发送请求：请求级禁用自动跟随重定向，由 [_get] 手动跟随以记录每一跳。
  Future<http.Response> _send(Uri uri) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..maxRedirects = 0;
    request.headers.addAll(_headersFor(uri));
    final streamed = await _client.send(request).timeout(_timeout);
    return http.Response.fromStream(streamed);
  }

  /// 访问站点根路径以建立会话 Cookie（部分站点反爬要求先有 Cookie）。
  Future<void> _warmupSession(Uri uri) async {
    final root = Uri(scheme: uri.scheme, host: uri.host, path: '/');
    try {
      final resp = await _client
          .get(root, headers: _headersFor(root))
          .timeout(_timeout);
      _storeCookies(resp, root);
    } catch (_) {
      // 预热失败不阻断原请求。
    }
  }

  /// 组装浏览器风格请求头（降低反爬命中）并附加会话 Cookie。
  Map<String, String> _headersFor(Uri uri) {
    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,'
          'image/avif,image/webp,image/apng,*/*;q=0.8,'
          'application/signed-exchange;v=b3;q=0.7',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Accept-Encoding': 'gzip, deflate',
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
      'Upgrade-Insecure-Requests': '1',
      'Sec-Fetch-Dest': 'document',
      'Sec-Fetch-Mode': 'navigate',
      'Sec-Fetch-Site': 'none',
      'Sec-Fetch-User': '?1',
      'sec-ch-ua':
          '"Chromium";v="126", "Google Chrome";v="126", "Not.A/Brand";v="99"',
      'sec-ch-ua-mobile': '?0',
      'sec-ch-ua-platform': '"Windows"',
    };
    // 百度百科等对无来源的抓取更敏感，附加同站 Referer。
    if (uri.host == 'baike.baidu.com') {
      headers['Referer'] = 'https://baike.baidu.com/';
    }
    final cookie = _cookieFor(uri.host);
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    return headers;
  }

  /// 解析响应的 set-cookie 存入会话（按 host 隔离）。
  void _storeCookies(http.Response resp, Uri uri) {
    final setCookie = resp.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) return;
    final store = _cookies.putIfAbsent(uri.host, () => <String, String>{});
    for (final part in setCookie.split(',')) {
      final seg = part.split(';').first.trim();
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final name = seg.substring(0, eq).trim();
      final value = seg.substring(eq + 1).trim();
      // 删除标记（过期删除）或空值 → 移除该 cookie。
      if (value.isEmpty || value.toLowerCase() == 'deleted') {
        store.remove(name);
      } else {
        store[name] = value;
      }
    }
  }

  /// 组装指定 host 的 Cookie 头。
  String _cookieFor(String host) {
    final store = _cookies[host];
    if (store == null || store.isEmpty) return '';
    return store.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 按响应实际压缩格式解压后，按页面 charset 解码响应体。
  ///
  /// ⚠️ 不能只依赖 `content-encoding` 头：底层 client（dart:io 默认
  /// `autoUncompress=true`）可能已自动解压 gzip 却仍保留该头，此时再解压会抛
  /// `FormatException` 导致全部请求失败。因此用 gzip 魔数（0x1F 0x8B，RFC 1952）
  /// 判断是否仍为压缩数据；deflate 无魔数，按响应头尝试解压、失败则按原文处理。
  ///
  /// ⚠️ 中文站点常为 GBK/GB2312（如 pvp.qq.com），必须按 charset 解码，
  /// 不能一律 UTF-8，否则会产生乱码。
  String _decodeBody(http.Response resp) {
    List<int> bytes = resp.bodyBytes;
    final encoding = (resp.headers['content-encoding'] ?? '').toLowerCase();
    if (_isGzip(bytes)) {
      bytes = gzip.decode(bytes);
    } else if (encoding.contains('deflate')) {
      try {
        bytes = zlib.decode(bytes);
      } catch (_) {
        // 非有效 deflate 数据（可能已被底层解压），保留原文。
      }
    }
    return _decodeText(bytes, resp.headers['content-type']);
  }

  /// 按 charset 解码：优先 HTTP 头，其次页面 `<meta charset>`；
  /// GBK/GB2312/GB18030 用 GBK 码表，其余按 UTF-8（宽松）。
  String _decodeText(List<int> bytes, String? contentType) {
    final charset = _resolveCharset(bytes, contentType);
    if (charset == 'gbk' || charset == 'gb2312' || charset == 'gb18030') {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        // GBK 解码失败（可能是 GB18030 四字节扩展等），回退 UTF-8 宽松解码。
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 解析 charset：优先 HTTP `content-type`，其次扫描页面 `<meta charset>`。
  static String _resolveCharset(List<int> bytes, String? contentType) {
    final fromHeader = _charsetFrom(contentType);
    if (fromHeader != null) return fromHeader;
    // 部分站点（如 pvp.qq.com）只在 HTML 内声明 <meta charset="gbk">。
    final head = latin1.decode(bytes.take(4096).toList(), allowInvalid: true);
    final m = RegExp(
      '<meta[^>]+charset\\s*=\\s*["\']?\\s*([a-zA-Z0-9_\\-]+)',
      caseSensitive: false,
    ).firstMatch(head);
    return m?.group(1)?.toLowerCase() ?? 'utf-8';
  }

  static String? _charsetFrom(String? contentType) {
    if (contentType == null) return null;
    final m = RegExp(
      'charset\\s*=\\s*["\']?\\s*([a-zA-Z0-9_\\-]+)',
      caseSensitive: false,
    ).firstMatch(contentType);
    return m?.group(1)?.toLowerCase();
  }

  /// gzip 魔数（RFC 1952：0x1F 0x8B）。
  static bool _isGzip(List<int> bytes) =>
      bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

  // ---------------------------------------------------------------------------
  // 纯函数解析（可单测）
  // ---------------------------------------------------------------------------

  /// 解析 Bing 搜索结果页 HTML。
  ///
  /// 结构（实测 2026-08-12）：
  /// ```
  /// <li class="b_algo" ...>
  ///   ...(链接/图标等噪音)...
  ///   <h2 class=""><a ... href="URL" ...>标题（可含 <strong>）</a></h2>
  ///   <div class="b_caption"><p ...>摘要（含 HTML 实体）</p></div>
  /// </li>
  /// ```
  @visibleForTesting
  static List<SearchResult> parseBingHtml(String html) {
    final results = <SearchResult>[];
    final blocks = html.split('<li class="b_algo"');
    for (final block in blocks.skip(1)) {
      // 仅从 <h2> 内取链接，避开结果块顶部的 favicon/引用等噪音 <a>。
      final h2 = _between(block, '<h2', '</h2>');
      if (h2 == null) continue;
      final rawUrl = _firstAttr(h2, '<a', 'href');
      if (rawUrl == null || rawUrl.isEmpty) continue;
      final title = cleanText(h2);
      if (title.isEmpty) continue;
      final caption = _between(block, '<div class="b_caption"', '</div>');
      results.add(
        SearchResult(
          title: title,
          url: _normalizeUrl(_decodeEntities(rawUrl)),
          snippet: caption == null ? '' : cleanText(caption),
        ),
      );
    }
    return results;
  }

  /// 解析 DuckDuckGo HTML 端点搜索结果页。
  ///
  /// 结构：
  /// ```
  /// <div class="result ...">
  ///   <h2 class="result__title">
  ///     <a ... class="result__a" href="//duckduckgo.com/l/?uddg=<编码URL>&...">标题</a>
  ///   </h2>
  ///   <a class="result__snippet" ...>摘要</a>
  /// </div>
  /// ```
  @visibleForTesting
  static List<SearchResult> parseDuckDuckGoHtml(String html) {
    final results = <SearchResult>[];
    // 用「class="result 」+ 空格区分结果块，避免误匹配容器 class="results"。
    final blocks = html.split('<div class="result ');
    for (final block in blocks.skip(1)) {
      final h2 = _between(block, '<h2', '</h2>');
      if (h2 == null) continue;
      final rawUrl = _firstAttr(h2, '<a', 'href');
      if (rawUrl == null || rawUrl.isEmpty) continue;
      final title = cleanText(h2);
      if (title.isEmpty) continue;
      final snippet = cleanText(
        _between(block, 'class="result__snippet"', '</a>') ?? '',
      );
      results.add(
        SearchResult(
          title: title,
          url: _resolveDdgUrl(rawUrl),
          snippet: snippet,
        ),
      );
    }
    return results;
  }

  /// 从网页 HTML 中抽取可读正文文本。
  ///
  /// 先剔除导航/页眉页脚/表单等噪音区块，再优先定位主内容区
  /// （`<article>` → `<main>` → 内容容器 div）提高信息密度，
  /// 找不到时回退整页抽取；可见文本过少时从 `<script>` 内嵌 JSON
  /// （SPA 服务端渲染数据）兜底抽取；最终截取前 [maxChars] 字符。
  @visibleForTesting
  static String extractPageText(String html, {int maxChars = 30000}) {
    // 1) 先剔除明确的非正文区块（脚本/样式/导航/页眉页脚/表单等）。
    final noiseFree = _removeNoiseBlocks(html);
    // 2) 优先定位主内容区（article → main → 内容容器），提高信息密度。
    var s = _stripToText(_mainContentRegion(noiseFree) ?? noiseFree);
    // 3) SPA 站点（如抖音百科）正文常内嵌于 <script> JSON（ProseMirror 等）：
    //    可见文本过少时用内嵌 JSON 文本兜底，避免「只有标题没有正文」。
    if (s.length < 500) {
      final embedded = _stripToText(_extractEmbeddedJsonText(html));
      if (embedded.length > s.length) {
        s = embedded;
      }
    }
    // 4) 截断。
    if (s.length > maxChars) {
      s = s.substring(0, maxChars).trimRight();
    }
    return s;
  }

  /// 块级标签换行分隔 → 去标签 → 解码实体 → 归一空白。
  static String _stripToText(String html) {
    var s = html.replaceAll(
      RegExp(
        r'</(h1|h2|h3|h4|h5|p|li|div|tr|td|th|ul|ol|section|article|'
        r'blockquote|figure|figcaption|table)>',
        caseSensitive: false,
      ),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = _decodeEntities(s);
    s = s.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ');
    return s.replaceAll(RegExp(r'\n\s*\n+'), '\n').trim();
  }

  /// 从页面内嵌 `<script>` JSON（SPA 服务端渲染数据）中抽取文本。
  ///
  /// 覆盖两类：① `type="application/json"` / `application/ld+json` 整段 JSON；
  /// ② ProseMirror 等富文本 JSON（含 `"node_id"` / `"children"` 标记）中的
  /// `"text":"..."` 节点内容。
  static String _extractEmbeddedJsonText(String html) {
    final out = StringBuffer();
    final scriptRe = RegExp(
      r'<script\b([^>]*)>([\s\S]*?)</script>',
      caseSensitive: false,
    );
    for (final m in scriptRe.allMatches(html)) {
      final attrs = m.group(1)!;
      if (attrs.contains('src=')) continue; // 外部脚本无内联数据
      _collectEmbedded(attrs, m.group(2)!, out);
    }
    return out.toString();
  }

  static void _collectEmbedded(String attrs, String body, StringBuffer out) {
    final trimmed = body.trim();
    // ① application/ld+json、application/json 整段 JSON。
    if (attrs.contains('json')) {
      try {
        _collectStrings(jsonDecode(trimmed), out);
      } catch (_) {
        // 忽略解析失败。
      }
      return;
    }
    // ② ProseMirror 富文本：提取 "text":"..." 节点。
    // 部分站点（如抖音百科）会把整段 JSON 作为字符串内嵌（\" 转义），先还原。
    var probe = body;
    if (body.contains(r'\"')) {
      probe = body.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
    }
    if (probe.contains('"node_id"') || probe.contains('"children"')) {
      final re = RegExp(r'"text"\s*:\s*"((?:[^"\\]|\\.)*)"');
      for (final mm in re.allMatches(probe)) {
        final t = _decodeJsonString(mm.group(1)!).trim();
        if (t.length >= 2) out.writeln(t);
      }
    }
  }

  /// 递归收集 JSON 中的文本字符串（过滤 URL / 纯 ASCII ID 等噪音）。
  static void _collectStrings(Object? data, StringBuffer out) {
    if (data is String) {
      final t = data.trim();
      if (t.length >= 8 &&
          !t.startsWith('http') &&
          !t.startsWith('data:') &&
          !RegExp(r'^[a-zA-Z0-9_\-\.]{6,}$').hasMatch(t)) {
        out.writeln(t);
      }
      return;
    }
    if (data is Map) {
      // ProseMirror 文本节点优先。
      final textVal = data['text'];
      if (textVal is String && textVal.trim().length >= 8) {
        out.writeln(textVal.trim());
      }
      for (final v in data.values) {
        _collectStrings(v, out);
      }
    } else if (data is List) {
      for (final v in data) {
        _collectStrings(v, out);
      }
    }
  }

  /// 反转义 JSON 字符串（\" \\ \/ \n \uXXXX 等）。
  static String _decodeJsonString(String s) {
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == r'\' && i + 1 < s.length) {
        final n = s[i + 1];
        switch (n) {
          case 'n':
            b.write('\n');
            break;
          case 't':
            b.write('\t');
            break;
          case 'r':
            b.write('\r');
            break;
          case '"':
            b.write('"');
            break;
          case '\\':
            b.write('\\');
            break;
          case '/':
            b.write('/');
            break;
          case 'u':
            final hex = s.substring(
              i + 2,
              i + 6 > s.length ? s.length : i + 6,
            );
            final code = int.tryParse(hex, radix: 16);
            if (code != null) b.writeCharCode(code);
            i += 4;
            break;
          default:
            b.write(n);
        }
        i++;
      } else {
        b.write(c);
      }
    }
    return b.toString();
  }

  /// 剔除脚本/样式/注释/导航/页眉页脚/表单等非正文区块（大小写不敏感）。
  static String _removeNoiseBlocks(String html) {
    var s = html;
    s = s.replaceAll(
      RegExp(
        r'<(script|style|noscript|svg|template|head|title|iframe|form|'
        r'nav|header|footer|aside|button|select|option)[^>]*>'
        r'[\s\S]*?</\1>',
        caseSensitive: false,
      ),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '\n');
    return s;
  }

  /// 定位主内容区：按 `<article>` → `<main>` → 常见内容容器 div 的优先级，
  /// 返回对应 HTML 片段；候选过小（< 500 字符，可能只是部分小节或嵌套不完整）
  /// 时回退整页抽取，避免丢失正文（噪音区块此前已被剔除）。
  static String? _mainContentRegion(String html) {
    final article = _captureBlocks(html, 'article');
    if (article.isNotEmpty && _plainLength(article) >= 500) return article;
    final main = _captureBlocks(html, 'main');
    if (main.isNotEmpty && _plainLength(main) >= 500) return main;
    final container = _contentContainer(html);
    if (container != null && _plainLength(container) >= 500) return container;
    return null;
  }

  /// 提取指定标签（如 article/main）的全部非嵌套块并拼接。
  static String _captureBlocks(String html, String tag) {
    final re = RegExp(
      '<$tag[^>]*>[\\s\\S]*?</$tag>',
      caseSensitive: false,
    );
    return re.allMatches(html).map((m) => m.group(0)!).join('\n');
  }

  /// 在整页中查找 id/class 含 content/article/post/mw-parser-output/main
  /// 的 div 容器，深度匹配后返回纯文本最长者。
  static String? _contentContainer(String html) {
    final lower = html.toLowerCase();
    final re = RegExp(
      r'<div\b[^>]*\b(?:id|class)\s*=\s*[^>\s]*'
      r'(?:content|article|post|mw-parser-output|main)[^>\s]*',
    );
    String? best;
    var bestLen = 0;
    for (final m in re.allMatches(lower)) {
      final block = _extractDivBlock(lower, m.start);
      if (block == null) continue;
      final text = html.substring(m.start, m.start + block);
      final len = _plainLength(text);
      if (len > bestLen) {
        bestLen = len;
        best = text;
      }
    }
    return best;
  }

  /// 从开标签 [open]（lowercase 文本中的位置）按嵌套深度匹配 `</div>`，
  /// 返回块长度（含开标签）；匹配失败返回 null。
  static int? _extractDivBlock(String lowerHtml, int open) {
    var depth = 1;
    var i = open;
    final n = lowerHtml.length;
    while (i < n && depth > 0) {
      final nextOpen = lowerHtml.indexOf('<div', i + 1);
      final nextClose = lowerHtml.indexOf('</div>', i + 1);
      if (nextClose < 0) return null;
      if (nextOpen >= 0 && nextOpen < nextClose) {
        depth++;
        i = nextOpen + 1;
      } else {
        depth--;
        i = nextClose + 1;
      }
    }
    return depth == 0 ? i - open : null;
  }

  /// 计算 HTML 片段的纯文本长度（仅用于容器候选比较）。
  static int _plainLength(String html) {
    return _decodeEntities(html.replaceAll(RegExp(r'<[^>]+>'), '')).trim().length;
  }

  /// 去除 HTML 标签、解码实体并归一空白（用于标题 / 摘要等行内文本）。
  static String cleanText(String raw) {
    return _decodeEntities(raw.replaceAll(RegExp(r'<[^>]+>'), ''))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  /// 取 [start] 到 [end] 之间的内容（不含 [start] 所在标签）。
  static String? _between(String source, String start, String end) {
    final s = source.indexOf(start);
    if (s < 0) return null;
    final after = source.indexOf('>', s);
    if (after < 0) return null;
    final e = source.indexOf(end, after);
    if (e < 0) return null;
    return source.substring(after + 1, e);
  }

  /// 取 [source] 中第一个 [tagOpen]（如 `<a`）标签的 [attr] 属性值。
  ///
  /// 注意：raw string 中 `$` 不插值，故用拼接构造正则，避免转义陷阱。
  static String? _firstAttr(String source, String tagOpen, String attr) {
    final i = source.indexOf(tagOpen);
    if (i < 0) return null;
    final after = source.indexOf('>', i);
    if (after < 0) return null;
    final tag = source.substring(i, after + 1);
    final pattern = attr + r"""\s*=\s*["']([^"']*)["']""";
    final m = RegExp(pattern).firstMatch(tag);
    return m?.group(1);
  }

  /// DDG 跳转链接 `//duckduckgo.com/l/?uddg=<编码URL>` 还原为真实 URL。
  static String _resolveDdgUrl(String href) {
    var h = href.trim();
    if (h.startsWith('//')) h = 'https:$h';
    final uri = Uri.tryParse(h);
    if (uri == null) return '';
    final target = uri.queryParameters['uddg'];
    return (target ?? h).trim();
  }

  static String _normalizeUrl(String url) {
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('/')) return 'https://www.bing.com$url';
    return url;
  }

  /// HTML 实体解码（命名常用实体 + 数字实体）。
  static String _decodeEntities(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&ensp;', ' ')
        .replaceAll('&emsp;', ' ')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final code = int.tryParse(m.group(1)!);
          return (code != null && code > 0)
              ? String.fromCharCode(code)
              : m.group(0)!;
        });
  }
}
