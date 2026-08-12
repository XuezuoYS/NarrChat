import 'dart:async';

import 'package:flutter/foundation.dart';
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

/// 联网搜索失败异常（两个引擎均失败时抛出）。
class SearchException implements Exception {
  final String message;
  const SearchException(this.message);

  @override
  String toString() => message;
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
  ) async {
    final html = await _get(
      'https://www.bing.com/search?q=${Uri.encodeQueryComponent(query)}',
    );
    final results = parseBingHtml(html);
    return results.take(maxResults).toList();
  }

  Future<List<SearchResult>> _searchDuckDuckGo(
    String query,
    int maxResults,
  ) async {
    final html = await _get(
      'https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(query)}',
    );
    final results = parseDuckDuckGoHtml(html);
    return results.take(maxResults).toList();
  }

  /// 抓取网页正文（去除 script/style/标签后的可读文本，截取前 [maxChars] 字符）。
  Future<String> fetchPageText(String url, {int maxChars = 6000}) async {
    final html = await _get(url);
    return extractPageText(html, maxChars: maxChars);
  }

  Future<String> _get(String url) async {
    final resp = await _client
        .get(
          Uri.parse(url),
          headers: {
            'User-Agent': _userAgent,
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          },
        )
        .timeout(_timeout);
    if (resp.statusCode != 200) {
      throw http.ClientException('HTTP ${resp.statusCode}', Uri.parse(url));
    }
    return resp.body;
  }

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
  @visibleForTesting
  static String extractPageText(String html, {int maxChars = 6000}) {
    var s = html;
    // 丢弃脚本/样式/模板/头部等非正文区块（大小写不敏感）。
    s = s.replaceAll(
      RegExp(
        r'<(script|style|noscript|svg|template|head|title)[^>]*>[\s\S]*?</\1>',
        caseSensitive: false,
      ),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '\n');
    // 块级标签换行分隔，保留段落结构。
    s = s.replaceAll(
      RegExp(
        r'</(h1|h2|h3|h4|h5|p|li|div|tr|section|article)>',
        caseSensitive: false,
      ),
      '\n',
    );
    s = s.replaceAll(
      RegExp(r'<br\s*/?>', caseSensitive: false),
      '\n',
    );
    // 去标签 → 解码实体 → 归一空白。
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = _decodeEntities(s);
    s = s.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ');
    s = s.replaceAll(RegExp(r'\n\s*\n+'), '\n').trim();
    if (s.length > maxChars) {
      s = s.substring(0, maxChars).trimRight();
    }
    return s;
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
