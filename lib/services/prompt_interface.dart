/// 发送给 AI 的**文本与工具**的唯一取用入口（分源接口套件）。
///
/// 定位：把「本轮要发给 AI 什么内容」从「怎么发」（报文 / 线路 / 参数 / 图片 /
/// 历史消息数组）里切出来，作为提示词换版的**唯一替换点**。
///
/// 文件分工：
/// - `prompt_text.dart`：**纯文本**契约与请求对象（不依赖 Flutter）；
/// - 本文件：聚合门面 [PromptInterface]、**工具集**契约 [AgentToolSource]
///   （工具类型依赖抓取服务，故带 Flutter 依赖）、以及版本绑定；
/// - 实现：[PromptV2Build]（v2 文本）、`PromptInterfaceV1`（v1 回退）。
///
/// 【覆盖范围】只包含文本与其等价物：
/// - [SystemPromptSource.system]：**拼合后**的 system（instructions）；
/// - [UserPromptSource.user]：**拼合后**的本轮 user 消息；
/// - [StageDirectiveSource]：Agent 阶段帧指令（准备 / 记忆 / 正文 / 维护）；
/// - [AgentToolSource.tools]：工具集（工具定义即文本，故由接口构造）。
///
/// 【不覆盖】（仍由各自实现器负责，接口不参与）：
/// 历史 `messages` 数组（`wire_messages.dart`）、请求体 / 线路 / 采样参数、
/// vision 图片 content、世界书关键词扫描与 Mod 解析、工具的执行与 UI 回调。
///
/// 【现状】[promptInterface] 绑定 [PromptV2]（文本 = `prompt_v2_build.dart`，
/// 工具 = `prompt_v2_tools.dart`）；[PromptInterfaceV1] 保留为回退路径。
///
/// 【接入约定】调用方**只调用** [PromptInterface] 上的方法，不得绕过接口直接调用
/// 被覆盖的实现器，否则换版时必然漏改。
library;

import '../models/agent_mode_level.dart';
import 'agent/agent_default_tools.dart';
import 'agent/fetch_page_tool.dart';
import 'agent/narr_agent_tool.dart';
import 'agent/state/agent_state_working_copy.dart';
import 'agent/web_search_tool.dart';
import 'html_search_service.dart';
import 'prompt_text.dart';
import 'prompt_v2_build.dart';
import 'prompt_v2_tools.dart';

export 'prompt_text.dart';

/// 取用工具集所需的上下文。
///
/// 工具**实例**由接口构造（工具定义即文本），但依赖由调用方给：
/// 状态工具绑定 [workingCopy]，联网工具绑定 [search] 与 [handlers]。
class AgentToolsRequest {
  const AgentToolsRequest({
    required this.level,
    this.workingCopy,
    this.useSearch = false,
    this.search,
    this.webSearch,
    this.fetchPage,
    this.handlers,
  });

  /// 档位：`off` = 无状态工具（Chat 联网循环走这条），Lv.1 / Lv.2 决定状态栏目。
  final AgentModeLevel level;

  /// 状态工具绑定的工作副本；为 null 时不构造状态工具。
  final AgentStateWorkingCopy? workingCopy;

  /// 是否启用联网工具。
  final bool useSearch;

  /// 联网工具使用的抓取服务（[useSearch] 为 true 时必需）。
  final HtmlSearchService? search;

  /// 注入的搜索工具替身（非 null 时优先使用）。
  final WebSearchTool? webSearch;

  /// 注入的打开页工具替身（非 null 时优先使用）。
  final FetchPageTool? fetchPage;

  /// 联网工具的过程回调（UI 事件）；null = 预览路径，不要回调。
  final AgentToolEventHandlers? handlers;
}

/// **工具集**源：按模式与档位决定本轮发给 AI 的工具清单。
abstract interface class AgentToolSource {
  /// 返回本轮工具清单，**顺序即请求体 `tools` 数组顺序**（任何差异都会改变
  /// 上下文前缀，必须保持稳定）。
  List<NarrAgentTool> tools(AgentToolsRequest request);
}

/// 聚合门面：本轮发送给 AI 的文本与工具的唯一入口。
///
/// 调用方只依赖本接口；实现可整体替换（v1 ↔ v2），无需改动调用方。
abstract interface class PromptInterface
    implements
        SystemPromptSource,
        UserPromptSource,
        StageDirectiveSource,
        AgentToolSource {}

/// **v2 聚合实现**：文本 = [PromptV2Build]（总模板 / 新建轮模板 / 阶段帧），
/// 工具 = `prompt_v2_tools.listPromptTools`（与 v1 共用同一份清单路由）。
class PromptV2 extends PromptV2Build implements PromptInterface {
  const PromptV2();

  @override
  List<NarrAgentTool> tools(AgentToolsRequest request) => listPromptTools(
        level: request.level,
        workingCopy: request.workingCopy,
        useSearch: request.useSearch,
        search: request.search,
        webSearch: request.webSearch,
        fetchPage: request.fetchPage,
        handlers: request.handlers,
      );
}

// -----------------------------------------------------------------------------
// 当前生效的实现（换版只改这一行）
// -----------------------------------------------------------------------------

/// 全局唯一的取用入口（**当前绑定 v2**）。
///
/// 换实现只改这一行：`PromptV2()` ↔ `PromptInterfaceV1()`（v1 回退路径）；
/// 调用方代码与依赖都停留在本文件定义的接口上，不做任何选择 / 注册。
const PromptInterface promptInterface = PromptV2();
