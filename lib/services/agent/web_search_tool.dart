import '../html_search_service.dart';
import 'narr_agent_tool.dart';

/// 联网搜索工具：通过 [HtmlSearchService] 自研抓取搜索引擎结果。
class WebSearchTool implements NarrAgentTool {
  WebSearchTool({
    HtmlSearchService? search,
    void Function(List<SearchResult> results)? onResults,
    void Function()? onFail,
  })  : _search = search ?? HtmlSearchService(),
        // ignore: prefer_initializing_formals
        _onResults = onResults,
        // ignore: prefer_initializing_formals
        _onFail = onFail;

  final HtmlSearchService _search;

  /// 搜索成功（有结果）回调（供 UI 展示结果明细）。
  final void Function(List<SearchResult> results)? _onResults;

  /// 搜索失败 / 无结果回调（供 UI 把搜索框标记为失败，显示 ✕）。
  final void Function()? _onFail;

  @override
  String get name => 'narrchat_webSearch';

  @override
  String get description =>
      '联网搜索获取最新或真实世界信息（如地名、历史、设定、专有名词等），'
      '返回最多 20 条结果的标题、链接与摘要。'
      '本工具启用后，涉及真实世界信息时应主动使用，不必等用户逐条点名；'
      '调用后必须紧接着用 narrchat_webFetchPage 打开最相关的 1~3 个结果页面阅读正文'
      '以获取准确细节，仅凭摘要不足以支撑创作。';

  @override
  Map<String, dynamic> get parameters => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': '要搜索的关键词，尽量简洁具体',
      },
    },
    'required': ['query'],
  };

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async {
    final query = (arguments['query'] as String? ?? '').trim();
    if (query.isEmpty) {
      _onFail?.call();
      return const AgentToolResult(success: false, content: '搜索关键词为空');
    }
    try {
      final results = await _search.search(query, maxResults: 20);
      if (results.isEmpty) {
        _onFail?.call();
        return AgentToolResult(
          success: false,
          content: '未找到与「$query」相关的搜索结果',
        );
      }
      _onResults?.call(results);
      final sb = StringBuffer('搜索「$query」的结果：\n');
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        sb.writeln('${i + 1}. ${r.title}');
        sb.writeln('   链接：${r.url}');
        if (r.snippet.isNotEmpty) sb.writeln('   摘要：${r.snippet}');
      }
      sb.writeln();
      sb.writeln('【接下来必须执行】请立即用 narrchat_webFetchPage 打开以上结果中最相关的'
          ' 1~3 个链接（优先百科/资料类页面）阅读完整正文，获取准确细节后'
          '再继续创作；不得在未打开任何页面的情况下直接结束搜索环节。');
      return AgentToolResult(success: true, content: sb.toString());
    } catch (e) {
      // 搜索失败：返回错误信息，由 Agent 循环回传模型继续执行。
      _onFail?.call();
      return AgentToolResult(success: false, content: '联网搜索失败：$e');
    }
  }
}
