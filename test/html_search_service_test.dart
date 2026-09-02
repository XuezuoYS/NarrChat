import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fast_gbk/fast_gbk.dart';
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

    test('主内容区优先：剔除导航/页眉页脚/侧栏噪音', () {
      const html = '''
<html><body>
<nav><a>导航一</a><a>导航二</a></nav>
<header>网站标题与菜单</header>
<aside>侧栏推荐文章</aside>
<article>
<h1>正文标题</h1>
<p>这是文章正文第一段，包含关键信息。</p>
<p>第二段补充更多细节内容。</p>
</article>
<footer>版权与备案信息</footer>
</body></html>
''';
      final text = HtmlSearchService.extractPageText(html);
      expect(text, contains('正文标题'));
      expect(text, contains('关键信息'));
      expect(text, isNot(contains('导航')));
      expect(text, isNot(contains('网站标题')));
      expect(text, isNot(contains('侧栏')));
      expect(text, isNot(contains('版权')));
    });

    test('SPA 内嵌 JSON（ProseMirror）抽取正文', () {
      const html = '''
<html><body>
<div class="app">仅少量可见文字</div>
<script id="prefetch-data">var __x__ = null;
var __article__ = {"doc":{"type":"doc","content":[
  {"type":"heading","attrs":{"level":1},"children":[{"type":"text","text":"器灵·落星盏","node_id":"a"}],"node_id":"n1"},
  {"type":"paragraph","children":[{"type":"text","text":"这是文章正文第一段，包含关键信息。","node_id":"b"}],"node_id":"n2"}
]}};
</script>
</body></html>
''';
      final text = HtmlSearchService.extractPageText(html);
      expect(text, contains('器灵·落星盏'));
      expect(text, contains('这是文章正文第一段，包含关键信息。'));
    });

    test('SPA 内嵌 JSON（整段作为转义字符串，如抖音百科）抽取正文', () {
      const html = '''
<html><body>
<div class="app">少量</div>
<script id="prefetch-data">var __x__ = "{\\"doc\\":{\\"type\\":\\"doc\\",\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"背景故事第一段内容。\\",\\"node_id\\":\\"a\\"}]}}";
</script>
</body></html>
''';
      final text = HtmlSearchService.extractPageText(html);
      expect(text, contains('背景故事第一段内容。'));
    });

    test('application/ld+json 整段 JSON 抽取', () {
      const html = '''
<html><body><div>少量</div>
<script type="application/ld+json">{"name":"青云","description":"青云科技是一家企业级云服务商，成立于2012年，提供云计算与AI基础设施。"}</script>
</body></html>
''';
      final text = HtmlSearchService.extractPageText(html);
      expect(text, contains('青云科技是一家企业级云服务商'));
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

    test('2xx 状态码视为访问成功（如 206）', () async {
      final service = HtmlSearchService(
        client: MockClient(
          (request) async => _html(
            '<html><body><p>部分内容。</p></body></html>',
            status: 206,
          ),
        ),
      );
      final text = await service.fetchPageText('https://example.com/206');
      expect(text, contains('部分内容'));
    });

    test('非 2xx（如 403）抛 HttpStatusException', () async {
      final service = HtmlSearchService(
        client: MockClient((request) async => _html('forbidden', status: 403)),
      );
      expect(
        service.fetchPageText('https://example.com/403'),
        throwsA(
          isA<HttpStatusException>()
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
    });

    test('gzip 响应自动解压', () async {
      const body = '<html><body><p>压缩后的正文。</p></body></html>';
      final service = HtmlSearchService(
        client: MockClient(
          (request) async => http.Response.bytes(
            gzip.encode(utf8.encode(body)),
            200,
            headers: {
              'content-type': 'text/html; charset=utf-8',
              'content-encoding': 'gzip',
            },
          ),
        ),
      );
      final text = await service.fetchPageText('https://example.com/gzip');
      expect(text, contains('压缩后的正文'));
    });

    test('响应头标 gzip 但正文已被底层解压：不重复解压（模拟 dart:io）', () async {
      final service = HtmlSearchService(
        client: MockClient(
          (request) async => http.Response(
            '<html><body><p>已解压的正文。</p></body></html>',
            200,
            headers: {
              'content-type': 'text/html; charset=utf-8',
              'content-encoding': 'gzip',
            },
          ),
        ),
      );
      final text = await service.fetchPageText('https://example.com/gz');
      expect(text, contains('已解压的正文'));
    });

    test('百度百科 403 时回退 WAP 端点并记录跳转链', () async {
      final calls = <String>[];
      final hops = <FetchHop>[];
      final service = HtmlSearchService(
        client: MockClient((request) async {
          calls.add('${request.url.host}${request.url.path}');
          if (request.url.host == 'wapbaike.baidu.com') {
            return _html('<html><body><p>WAP 正文内容。</p></body></html>');
          }
          return http.Response('forbidden', 403);
        }),
      );

      final text = await service.fetchPageText(
        'https://baike.baidu.com/item/x',
        onHop: hops.add,
      );
      expect(text, contains('WAP 正文内容'));
      // 序列：桌面(403) → WAP(200)。
      expect(calls, [
        'baike.baidu.com/item/x',
        'wapbaike.baidu.com/item/x',
      ]);
      // 跳转链：应用重定向（无状态码）→ WAP 200。
      expect(hops.map((h) => '${h.url}|${h.statusCode}').toList(), [
        'https://baike.baidu.com/item/x|null',
        'https://wapbaike.baidu.com/item/x|200',
      ]);
    });

    test('回退目标仍失败：跳转链以失败终止点收尾（含目标 URL 与状态码）', () async {
      final hops = <FetchHop>[];
      final service = HtmlSearchService(
        client: MockClient(
          (request) async => http.Response('forbidden', 403),
        ),
      );

      await expectLater(
        service.fetchPageText(
          'https://baike.baidu.com/item/x',
          onHop: hops.add,
        ),
        throwsA(isA<HttpStatusException>()),
      );
      // 跳转链：应用重定向（无状态码）→ 最终失败（WAP 目标 + 403，failed=true）。
      expect(hops.map((h) => '${h.url}|${h.statusCode}|${h.failed}').toList(), [
        'https://baike.baidu.com/item/x|null|false',
        'https://wapbaike.baidu.com/item/x|403|true',
      ]);
    });

    test('手动跟随多级 3xx 重定向并回调每跳', () async {
      final hops = <FetchHop>[];
      final service = HtmlSearchService(
        client: MockClient((request) async {
          if (request.url.path == '/a') {
            return http.Response('', 302, headers: {'location': '/b'});
          }
          if (request.url.path == '/b') {
            return http.Response('', 302, headers: {'location': '/c'});
          }
          return _html('<html><body><p>最终内容。</p></body></html>');
        }),
      );

      final text = await service.fetchPageText(
        'https://example.com/a',
        onHop: hops.add,
      );
      expect(text, contains('最终内容'));
      expect(hops.map((h) => '${h.url}|${h.statusCode}').toList(), [
        'https://example.com/a|302',
        'https://example.com/b|302',
        'https://example.com/c|200',
      ]);
    });

    test('非百度站点 403 时先预热会话 Cookie 再重试一次', () async {
      final calls = <String>[];
      final service = HtmlSearchService(
        client: MockClient((request) async {
          calls.add('${request.url.host}${request.url.path}');
          if (request.url.path == '/') {
            return http.Response(
              'root',
              200,
              headers: {'set-cookie': 'SID=abc; path=/'},
            );
          }
          // 带上会话 Cookie 后返回 200，否则 403。
          if ((request.headers['Cookie'] ?? '').contains('SID')) {
            return _html('<html><body><p>预热后的正文。</p></body></html>');
          }
          return http.Response('forbidden', 403);
        }),
      );

      final text = await service.fetchPageText('https://example.com/item');
      expect(text, contains('预热后的正文'));
      // 序列：目标页(403) → 站点根(预热) → 目标页(200)。
      expect(calls, ['example.com/item', 'example.com/', 'example.com/item']);
    });

    test('GBK 编码页面按 <meta charset> 解码（修复乱码）', () async {
      final body = gbk.encode(
        '<html><head><meta charset="gbk"></head>'
        '<body><h1>王者荣耀</h1><p>嫦娥皮肤落星盏。</p></body></html>',
      );
      final service = HtmlSearchService(
        client: MockClient(
          (request) async => http.Response.bytes(
            body,
            200,
            headers: {'content-type': 'text/html'},
          ),
        ),
      );
      final text = await service.fetchPageText('https://pvp.qq.com/x');
      expect(text, contains('王者荣耀'));
      expect(text, contains('嫦娥皮肤落星盏。'));
    });
  });
}
