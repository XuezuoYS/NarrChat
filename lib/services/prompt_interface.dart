/// 发送给 AI 的**文本与工具**的唯一取用入口（分源接口套件）。
///
/// 定位：把「本轮要发给 AI 什么内容」从「怎么发」（报文 / 线路 / 参数 / 图片 /
/// 历史消息数组）里切出来，作为将来替换 v2 提示词的**唯一替换点**。
///
/// 【覆盖范围】只包含文本与其等价物：
/// - [SystemPromptSource.system]：**拼合后**的 system（instructions）；
/// - [UserPromptSource.user]：**拼合后**的本轮 user 消息；
/// - [StageDirectiveSource]：Agent 阶段帧指令（准备 / 记忆 / 正文 / 维护）；
/// - [AgentToolSource.tools]：工具集（工具定义即文本，故由接口构造）。
///
/// 【不覆盖】（仍由各自实现器负责，接口不参与）：
/// 历史 `messages` 数组的拼装、请求体 / 线路 / 采样参数、vision 图片 content、
/// 世界书关键词扫描与 Mod 解析、工具的执行与 UI 回调、报文字段拼装。
///
/// 【现状】[promptInterface] 绑定 [PromptInterfaceV1]：逐字转发到现有
/// `PromptSections` / `AgentStageDirectives` / `buildStateTools` /
/// `buildDefaultAgentTools`，**调用链与输出均未改变**（见 `prompt_interface_v1.dart`）。
///
/// 【切换 v2】把 [promptInterface] 的绑定改为 `prompt_v2_build.dart` 的实现即可；
/// 调用方只依赖本文件的接口，不感知实现。
///
/// 【接入约定】调用方**只调用** [PromptInterface] 上的方法，不得绕过接口直接调用
/// 被覆盖的实现器，否则 v2 切换时必然漏改。
library;

import '../models/agent_mode_level.dart';
import '../models/book.dart';
import '../models/mod.dart';
import '../models/round.dart';
import 'agent/agent_default_tools.dart';
import 'agent/fetch_page_tool.dart';
import 'agent/narr_agent_tool.dart';
import 'agent/state/agent_state_working_copy.dart';
import 'agent/web_search_tool.dart';
import 'html_search_service.dart';
import 'memory_merge_planner.dart';
import 'prompt_formats.dart';
import 'prompt_interface_v1.dart';

// -----------------------------------------------------------------------------
// 请求对象（只搬运已有数据，不负责取数）
// -----------------------------------------------------------------------------

/// 取用 system / user 文本所需的全部上下文。
///
/// 所有字段都是**已经取好的数据**：接口不查数据库、不扫世界书、不解析 Mod。
class PromptRequest {
  const PromptRequest({
    required this.book,
    required this.mode,
    this.lastRound,
    this.userInput = '',
    this.worldBookEntries = '',
    this.mods,
  });

  /// 本书（书籍名 / 分类 / 设定 / 文笔 / 角色类别 / 记忆合并档位等全在内）。
  final Book book;

  /// 提示词模式：Chat / Agent Lv.1 / Agent Lv.2。
  final PromptMode mode;

  /// 上一轮（首轮为 null）：上轮时间、状态快照与记忆总结的来源。
  final Round? lastRound;

  /// 本轮用户输入。
  final String userInput;

  /// 已按关键词命中筛好的世界书条目文本（扫描在调用方完成）。
  final String worldBookEntries;

  /// 本书启用的 Mod 束（system / 前置词 / 后置词 / 世界书）。
  final ModsBundle? mods;

  /// 同模式下的格式生成要求（由 [mode] 派生，便捷访问）。
  PromptFormatSpec get format => mode.format;
}

/// 取用 Agent 阶段帧指令所需的上下文（按阶段取用，未用到的字段忽略）。
class AgentStageRequest {
  const AgentStageRequest({
    required this.level,
    this.workingCopy,
    this.memoryMergePlan,
    this.first = true,
    this.problems = const [],
  });

  /// 档位（决定维护帧文案与工具名清单；准备 / 记忆 / 正文帧仅 Lv.1 使用）。
  final AgentModeLevel level;

  /// 本轮状态工作副本（记忆帧判定「本轮条目 / 合并是否落地」必需）。
  final AgentStateWorkingCopy? workingCopy;

  /// 本轮应执行的记忆合并动作（无动作时 null）。
  final MemoryMergePlan? memoryMergePlan;

  /// 主帧 = true，修复帧 = false。
  final bool first;

  /// 维护 / 修复帧的待修清单（应用侧缺口，未排序未截断）。
  final List<String> problems;
}

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

// -----------------------------------------------------------------------------
// 分源接口套件
// -----------------------------------------------------------------------------

/// **system**（instructions）文本源。
abstract interface class SystemPromptSource {
  /// 返回**拼合完成**的 system 文本：调用方不得再增删改写（线路层只负责把它
  /// 放进 `system` 消息或 `instructions` 字段）。
  String system(PromptRequest request);
}

/// **本轮 user 消息**文本源（历史 user / assistant 消息不在此列）。
abstract interface class UserPromptSource {
  /// 返回**拼合完成**的本轮 user 消息文本。
  String user(PromptRequest request);
}

/// **Agent 阶段帧指令**文本源。
///
/// 返回该帧 `role: user` 消息的正文（调用方包成消息条目）。各阶段帧指令是
/// 「同一轮内追加的指令」，不属于 system / 用户输入本身。
abstract interface class StageDirectiveSource {
  /// 准备回合（仅 Lv.1）：读史 + 按需联网 + 定下本轮大纲。
  String stagePrepare(AgentStageRequest request);

  /// 记忆回合（仅 Lv.1）：先落本轮记忆条目（只调工具、不输出文本）。
  String stageMemory(AgentStageRequest request);

  /// 正文回合：Lv.1 需要（Lv.2 的正文契约在 system 里，不追加帧指令）。
  String stageStory(AgentStageRequest request);

  /// 维护 / 修复回合（两档共用）：按缺口清单直接编辑。
  String stageState(AgentStageRequest request);
}

/// **工具集**源：按模式与档位决定本轮发给 AI 的工具清单。
abstract interface class AgentToolSource {
  /// 返回本轮工具清单，**顺序即请求体 `tools` 数组顺序**（任何差异都会改变
  /// 上下文前缀，必须保持稳定）。
  List<NarrAgentTool> tools(AgentToolsRequest request);
}

/// 聚合门面：本轮发送给 AI 的文本与工具的唯一入口。
///
/// 调用方只依赖本接口；实现可整体替换（v1 → v2），无需改动调用方。
abstract interface class PromptInterface
    implements
        SystemPromptSource,
        UserPromptSource,
        StageDirectiveSource,
        AgentToolSource {}

// -----------------------------------------------------------------------------
// 当前生效的实现（v2 接入时只改这一行）
// -----------------------------------------------------------------------------

/// 全局唯一的取用入口。
///
/// 替换 v2 时把这里改成 `prompt_v2_build.dart` 的实现即可——调用方代码与依赖
/// 都停留在本文件定义的接口上，不做任何选择 / 注册，只此一处绑定。
const PromptInterface promptInterface = PromptInterfaceV1();
