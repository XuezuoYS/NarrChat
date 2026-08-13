import '../html_search_service.dart';
import 'narr_agent_tool.dart';

/// 打开网页工具：从搜索结果中选定页面，抓取正文回传模型深入阅读。
///
/// 通过 [HtmlSearchService.fetchPageText] 抓取可读正文（截取前 [maxChars]
/// 字符），供模型在 `web_search` 之后选定最有价值的页面深入。
///
/// 页面拒绝访问（HTTP 4xx/5xx）返回 `refused:true` 的结果（非工具故障，
/// 不计入连续失败次数、UI 显示黄色 ✕）；网络/超时等其它失败走 `onFail`。
class FetchPageTool implements NarrAgentTool {
  FetchPageTool({
    HtmlSearchService? search,
    void Function()? onDone,
    void Function()? onFail,
    void Function()? onRefused,
    int maxChars = 30000,
  })  : _search = search ?? HtmlSearchService(),
        // ignore: prefer_initializing_formals
        _onDone = onDone,
        // ignore: prefer_initializing_formals
        _onFail = onFail,
        // ignore: prefer_initializing_formals
        _onRefused = onRefused,
        // ignore: prefer_initializing_formals
        _maxChars = maxChars;

  final HtmlSearchService _search;

  /// 打开成功回调（供 UI 把 fetch 事件标记完成）。
  final void Function()? _onDone;

  /// 打开失败 / 无内容回调（供 UI 把 fetch 事件标记失败，显示 ✕）。
  final void Function()? _onFail;

  /// 页面拒绝访问（HTTP 4xx/5xx）回调（供 UI 标记黄色 ✕，不计入失败次数）。
  final void Function()? _onRefused;

  /// 抓取正文截取长度。
  final int _maxChars;

  @override
  String get name => 'fetch_page';

  @override
  String get description =>
      '打开网页链接并返回页面正文（截取前 $_maxChars 字符）。'
      '用于在 web_search 之后深入阅读最相关的页面获取准确细节：'
      '创作任何涉及真实世界信息的内容前，必须主动打开页面阅读正文后再动笔，'
      '不要跳过；若页面拒绝访问（HTTP 4xx/5xx），请换用其它结果页面。'
      'url 需为完整 http(s) 链接（取自搜索结果）。';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'url': {
        'type': 'string',
        'description': '要打开的网页完整链接（来自搜索结果）',
      },
    },
    'required': ['url'],
  };

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async {
    final url = (arguments['url'] as String? ?? '').trim();
    if (url.isEmpty) {
      _onFail?.call();
      return const AgentToolResult(success: false, content: '打开的链接为空');
    }
    try {
      final text = await _search.fetchPageText(url, maxChars: _maxChars);
      if (text.trim().isEmpty) {
        _onFail?.call();
        return AgentToolResult(success: false, content: '页面无有效内容：$url');
      }
      _onDone?.call();
      return AgentToolResult(
        success: true,
        content: '页面「$url」正文：\n$text',
      );
    } on HttpStatusException catch (e) {
      // 页面拒绝访问（HTTP 4xx/5xx）：非工具故障，UI 黄色 ✕、
      // 不计入工具连续失败次数；错误信息回传模型，并提示换用其它页面。
      _onRefused?.call();
      return AgentToolResult(
        success: false,
        content: '页面拒绝访问（HTTP ${e.statusCode}）：$url。'
            '请改用 fetch_page 打开 web_search 结果中的其它相关链接继续获取资料。',
        refused: true,
      );
    } catch (e) {
      // 打开失败（网络/超时等工具故障）：错误信息回传模型继续执行。
      _onFail?.call();
      return AgentToolResult(success: false, content: '打开页面失败：$e');
    }
  }
}
