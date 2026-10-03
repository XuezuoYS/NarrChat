import '../html_search_service.dart';
import 'fetch_page_tool.dart';
import 'narr_agent_tool.dart';
import 'web_search_tool.dart';

/// 联网工具（搜索 / 打开页）构造时的**过程回调**集合（供 UI 展示）。
///
/// 一次生成过程里的事件（搜索结果 / 搜索失败 / 打开成功 / 打开失败 / 页面拒绝 /
/// 跳转）全部由此转发；整体为 `null` 表示「只要工具定义、不要过程回调」
/// （预览请求体路径：只读 `name` / `description` / `parameters`，绝不执行 `run`）。
class AgentToolEventHandlers {
  const AgentToolEventHandlers({
    this.onResults,
    this.onSearchFail,
    this.onFetchDone,
    this.onFetchFail,
    this.onFetchRefused,
    this.onFetchHop,
  });

  /// 搜索成功（有结果）。
  final void Function(List<SearchResult> results)? onResults;

  /// 搜索失败 / 无结果。
  final void Function()? onSearchFail;

  /// 打开页面成功。
  final void Function()? onFetchDone;

  /// 打开页面失败（网络 / 超时 / 无正文）。
  final void Function()? onFetchFail;

  /// 页面拒绝访问（HTTP 4xx/5xx，不计入工具连续失败次数）。
  final void Function()? onFetchRefused;

  /// 重定向跳转（跳转链 UI）。
  final void Function(FetchHop hop)? onFetchHop;
}

/// 默认联网工具（`narrchat_webSearch` → `narrchat_webFetchPage`）的**公共工厂**。
///
/// **单一真源**：`RoundProvider`（实际生成与「预览请求体」两条路径）与
/// `prompt_interface.dart` 的实现共用本函数，避免两处各写一份构造与回调接线。
///
/// - [webSearch] / [fetchPage] 非空时**优先使用**（测试或调用方注入的替身）；
///   两个都注入时 [search] 不会被使用（可为 null）；
/// - [search] 为 null 时由工具自身回落 `HtmlSearchService()`（调用方应避免这种
///   静默回落：`prompt_interface` 的实现会显式校验）；
/// - [handlers] 为 `null` 时两个工具都不接过程回调（预览路径语义）。
///
/// 返回顺序固定为「搜索 → 打开页」（请求体 `tools` 数组顺序即前缀顺序，
/// 不得随意调整）。
List<NarrAgentTool> buildDefaultAgentTools({
  HtmlSearchService? search,
  WebSearchTool? webSearch,
  FetchPageTool? fetchPage,
  AgentToolEventHandlers? handlers,
}) =>
    [
      webSearch ??
          WebSearchTool(
            search: search,
            onResults: handlers?.onResults,
            onFail: handlers?.onSearchFail,
          ),
      fetchPage ??
          FetchPageTool(
            search: search,
            onDone: handlers?.onFetchDone,
            onFail: handlers?.onFetchFail,
            onRefused: handlers?.onFetchRefused,
            onHop: handlers?.onFetchHop,
          ),
    ];
