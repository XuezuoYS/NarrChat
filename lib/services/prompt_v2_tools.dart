/// **v2 工具清单**：列出并返回本轮发给 AI 的工具（工具定义即文本）。
///
/// 工具集与提示词版本**无关**——v1 回退路径与 v2 用同一份清单路由：状态工具按档位
/// 栏目现构（绑定本轮工作副本），联网工具按需叠加（搜索 → 打开页）。
/// 因此本函数是唯一实现，`PromptInterfaceV1` 与 `PromptV2` 都调用它。
///
/// 工具定义（名字 / schema / description / 参数说明）**已按 v2 口径迁移**：
/// 简明中文，英文只保留工具名 / 状态块标签 / `op` 取值（见 `docs/agent_tools.md`）；
/// v1 回退路径复用同一份文案，工具类不再维护双语。
///
/// 顺序即请求体 `tools` 数组顺序：状态工具在前（读取器 → 编辑器），联网工具在后；
/// 任何顺序变化都会改动请求前缀、使服务商上下文缓存失效，不得随意调整。
library;

import '../models/agent_mode_level.dart';
import 'agent/agent_default_tools.dart';
import 'agent/agent_mode_profile.dart';
import 'agent/fetch_page_tool.dart';
import 'agent/narr_agent_tool.dart';
import 'agent/state/agent_state_working_copy.dart';
import 'agent/state/state_tools.dart';
import 'agent/web_search_tool.dart';
import 'html_search_service.dart';

/// 列出本轮工具：`…状态工具, …联网工具`。
///
/// - [workingCopy] 为 null 时不构造状态工具（Chat 联网循环、预览请求体路径）；
/// - [useSearch] 为 true 时必须给出 [search]，或同时注入 [webSearch] 与
///   [fetchPage] 两个替身，否则抛 [ArgumentError]（不静默回落真实抓取服务）；
/// - [handlers] 为 null 表示「只要工具定义、不要过程回调」（预览路径）。
List<NarrAgentTool> listPromptTools({
  required AgentModeLevel level,
  AgentStateWorkingCopy? workingCopy,
  bool useSearch = false,
  HtmlSearchService? search,
  WebSearchTool? webSearch,
  FetchPageTool? fetchPage,
  AgentToolEventHandlers? handlers,
}) {
  final sections = AgentModeProfile.of(level).toolSections;
  return [
    if (workingCopy != null)
      ...buildStateTools(workingCopy, sections: sections),
    if (useSearch)
      ..._searchTools(
        search: search,
        webSearch: webSearch,
        fetchPage: fetchPage,
        handlers: handlers,
      ),
  ];
}

/// 联网工具（搜索 → 打开页）及其依赖校验。
List<NarrAgentTool> _searchTools({
  HtmlSearchService? search,
  WebSearchTool? webSearch,
  FetchPageTool? fetchPage,
  AgentToolEventHandlers? handlers,
}) {
  final needsService = webSearch == null || fetchPage == null;
  if (needsService && search == null) {
    throw ArgumentError.notNull(
      'search（启用联网工具时需要抓取服务；已注入两个联网工具替身时可省略）',
    );
  }
  return buildDefaultAgentTools(
    search: search,
    webSearch: webSearch,
    fetchPage: fetchPage,
    handlers: handlers,
  );
}
