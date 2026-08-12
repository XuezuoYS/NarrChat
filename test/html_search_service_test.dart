import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/services/html_search_service.dart';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

/// 构造 UTF-8 编码的 HTML 响应（MockClient 默认按 Latin-1 编码，中文会抛异常）。
http.Response _html(String body, {int status = 200}) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

void main() {
  group('parseBingHtml', () {
    test('解析真实结构样本：标题去 <strong>、摘要解实体、URL 解实体', () {
      final results = HtmlSearchService.parseBingHtml(
        _fixture('bing_sample.html'),
      );

      expect(results, hasLength(3));

      expect(
        results[0].title,
        '企业级AI基础设施与解决方案提供商 | 青云QingCloud',
      );
      expect(results[0].url, 'https://www.qingcloud.com/');
      expect(
        results[0].snippet,
        contains('青云科技（股票代码 688316）'),
      );
      // 实体解码：&ensp; 与 &#0183; 归一为空白 / ·
      expect(results[0].snippet, contains('2025年7月14日 · 青云科技'));

      // 第二个结果块顶部有 favicon 噪音 <a>，标题必须取自 <h2>。
      expect(results[1].title, '青云（汉语词汇）_百度百科');
      expect(
        results[1].url,
        'https://baike.baidu.com/item/%E9%9D%92%E4%BA%91/33077',
      );
      expect(results[1].snippet, contains('史记·范睢蔡泽列传'));

      // 无 b_caption 的结果摘要为空；&amp; 解码为 &。
      expect(results[2].title, '带参数链接示例');
      expect(results[2].url, 'https://example.com/a?x=1&y=2');
      expect(results[2].snippet, '');
    });

    test('无结果 / 非法输入返回空列表', () {
      expect(HtmlSearchService.parseBingHtml(''), isEmpty);
      expect(
        HtmlSearchService.parseBingHtml('<html><body>没有结果</body></html>'),
        isEmpty,
      );
    });
  });

  group('parseDuckDuckGoHtml', () {
    test('解析样本：跳转链接 uddg 还原为真实 URL', () {
      final results = HtmlSearchService.parseDuckDuckGoHtml(
        _fixture('ddg_sample.html'),
      );

      expect(results, hasLength(2));
      expect(results[0].title, '青云 QingCloud - 企业级AI基础设施');
      // //duckduckgo.com/l/?uddg=... 还原
      expect(results[0].url, 'https://www.qingcloud.com/');
      expect(results[0].snippet, contains('青云科技（688316）'));

      // 直接 URL 结果（保持原编码形式）
      expect(
        results[1].url,
        'https://baike.baidu.com/item/%E9%9D%92%E4%BA%91/33077',
      );
    });

    test('无结果返回空列表', () {
      expect(HtmlSearchService.parseDuckDuckGoHtml(''), isEmpty);
    });
  });

  group('extractPageText', () {
    test('去除 script/style/注释并保留段落结构', () {
      const html = '''
<html><head><title>标题</title>
<script>var x = 1;</script>
<style>.a { color: red; }</style>
</head><body>
<!-- 注释内容 -->
<h1>第一章</h1>
<p>第一段文字。</p>
<p>第二段&nbsp;文字。</p>
</body></html>
''';
      final text = HtmlSearchService.extractPageText(html);
      expect(text, isNot(contains('var x')));
      expect(text, isNot(contains('.a { color')));
      expect(text, isNot(contains('注释内容')));
      expect(text, isNot(contains('标题')));
      expect(text, contains('第一章'));
      expect(text, contains('第一段文字。'));
      expect(text, contains('第二段 文字。'));
      // 段落以换行分隔（\n 归一后保留单个换行）
      expect(text.contains('\n'), isTrue);
    });

    test('maxChars 截断', () {
      final html = '<p>${'很长的正文内容' * 100}</p>';
      final text = HtmlSearchService.extractPageText(html, maxChars: 20);
      expect(text.length, lessThanOrEqualTo(20));
    });
  });

  group('cleanText', () {
    test('去标签 + 解实体 + 空白归一', () {
      expect(
        HtmlSearchService.cleanText('<b>加粗</b> &amp; <i>斜体</i>'),
        '加粗 & 斜体',
      );
      expect(HtmlSearchService.cleanText('a\u00a0\u00a0\u00a0b'), 'a b');
      expect(HtmlSearchService.cleanText('青云&#183;词汇'), '青云·词汇');
    });
  });

  group('search（MockClient）', () {
    final bingHtml = _fixture('bing_sample.html');
    final ddgHtml = _fixture('ddg_sample.html');

    test('Bing 成功：解析结果并限制数量', () async {
      final service = HtmlSearchService(
        client: MockClient((request) async {
          expect(request.url.host, 'www.bing.com');
          expect(
            request.headers['User-Agent'],
            contains('Chrome'),
          );
          return _html(bingHtml);
        }),
      );

      final results = await service.search('青云宗', maxResults: 2);
      expect(results, hasLength(2));
      expect(results.first.url, 'https://www.qingcloud.com/');
    });

    test('Bing 失败（网络异常）时回退 DuckDuckGo', () async {
      var bingCalls = 0;
      final service = HtmlSearchService(
        client: MockClient((request) async {
          if (request.url.host == 'www.bing.com') {
            bingCalls++;
            throw http.ClientException('连接失败');
          }
          expect(request.url.host, 'html.duckduckgo.com');
          return _html(ddgHtml);
        }),
      );

      final results = await service.search('青云宗');
      expect(bingCalls, 1);
      expect(results, hasLength(2));
      expect(results.first.url, 'https://www.qingcloud.com/');
    });

    test('Bing 空结果时回退 DuckDuckGo', () async {
      final service = HtmlSearchService(
        client: MockClient((request) async {
          if (request.url.host == 'www.bing.com') {
            return _html('<html>无结果</html>');
          }
          return _html(ddgHtml);
        }),
      );

      final results = await service.search('青云宗');
      expect(results, hasLength(2));
    });

    test('两引擎均失败：抛 SearchException', () async {
      final service = HtmlSearchService(
        client: MockClient((request) async {
          throw http.ClientException('全挂');
        }),
      );

      expect(
        service.search('青云宗'),
        throwsA(isA<SearchException>()),
      );
    });

    test('非 200 视为失败并回退', () async {
      final service = HtmlSearchService(
        client: MockClient((request) async {
          if (request.url.host == 'www.bing.com') {
            return _html('error', status: 503);
          }
          return _html(ddgHtml);
        }),
      );

      final results = await service.search('青云宗');
      expect(results, hasLength(2));
    });

    test('翻页：maxResults=20 抓取 Bing 两页并合并去重', () async {
      const page2Html = '''
<html><body>
<li class="b_algo"><h2><a href="https://example.com/2a">结果2A</a></h2><div class="b_caption"><p>摘要2A。</p></div></li>
<li class="b_algo"><h2><a href="https://example.com/2b">结果2B</a></h2></li>
<li class="b_algo"><h2><a href="https://example.com/2c">结果2C</a></h2></li>
</body></html>
''';
      var bingCalls = 0;
      final service = HtmlSearchService(
        client: MockClient((request) async {
          expect(request.url.host, 'www.bing.com');
          bingCalls++;
          final first = request.url.queryParameters['first'];
          // 第二页 URL 应携带 first=11。
          if (first == '11') return _html(page2Html);
          return _html(bingHtml);
        }),
      );

      final results = await service.search('青云宗', maxResults: 20);

      expect(bingCalls, 2);
      // 第一页 3 条 + 第二页 3 条 = 6 条。
      expect(results, hasLength(6));
      expect(results[3].url, 'https://example.com/2a');
    });

    test('翻页：第二页失败时返回已收集的第一页结果', () async {
      var bingCalls = 0;
      final service = HtmlSearchService(
        client: MockClient((request) async {
          bingCalls++;
          if (request.url.queryParameters['first'] == '11') {
            throw http.ClientException('第二页失败');
          }
          return _html(bingHtml);
        }),
      );

      final results = await service.search('青云宗', maxResults: 20);

      expect(bingCalls, 2);
      expect(results, hasLength(3));
      expect(results.first.url, 'https://www.qingcloud.com/');
    });
  });

  group('fetchPageText（MockClient）', () {
    test('返回抽取后的可读正文', () async {
      const pageHtml =
          '<html><head><script>bad();</script></head>'
          '<body><h1>标题</h1><p>正文内容。</p></body></html>';
      final service = HtmlSearchService(
        client: MockClient((request) async {
          expect(request.url.toString(), 'https://example.com/page');
          return _html(pageHtml);
        }),
      );

      final text = await service.fetchPageText('https://example.com/page');
      expect(text, contains('标题'));
      expect(text, contains('正文内容。'));
      expect(text, isNot(contains('bad()')));
    });
  });
}
