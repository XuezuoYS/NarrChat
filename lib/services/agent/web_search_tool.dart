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
  String get name => 'web_search';

  @override
  String get description =>
      '联网搜索获取最新或真实世界信息（如地名、历史、设定、专有名词等），'
      '返回标题、链接与摘要列表。需要核实或补充资料时使用。';

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
      final results = await _search.search(query, maxResults: 5);
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
      return AgentToolResult(success: true, content: sb.toString());
    } catch (e) {
      // 搜索失败：返回错误信息，由 Agent 循环回传模型继续执行。
      _onFail?.call();
      return AgentToolResult(success: false, content: '联网搜索失败：$e');
    }
  }
}
