/// **文本取用契约**（不依赖 Flutter）：system / user / Agent 阶段帧指令。
///
/// 与 `prompt_interface.dart` 的分工：
/// - 本文件 = 只产出**文本**的契约与请求对象（纯 Dart，任何工具 / 脚本可直接引用）；
/// - `prompt_interface.dart` = 聚合门面 + **工具集**契约（工具类型依赖抓取服务，
///   因此那一半带 Flutter 依赖）+ 版本绑定。
///
/// 库使用方（如 `tool/preview_prompt.dart`、未来的 CLI）可以只引用本文件 +
/// 某个文本实现，避免把 Flutter 依赖带进纯 Dart 环境。
library;

import '../models/agent_mode_level.dart';
import '../models/book.dart';
import '../models/mod.dart';
import '../models/round.dart';
import 'agent/state/agent_state_working_copy.dart';
import 'memory_merge_planner.dart';

/// 生成模式：决定取用哪一份文本契约。
///
/// v1 提示词已移除后，本枚举是**唯一真源**：`prompt_v2_sections` /
/// `prompt_v2_build` / `AgentModeProfile` 都由它分派（不再有格式规格对象）。
enum PromptMode {
  /// 聊天模式：6 个二级标题区块（剧情演绎 → … → 记忆总结）。
  chat,

  /// Agent **Lv.1**：5 个区块（排除 `## 记忆总结`）+ 历史工具契约。
  agentLv1,

  /// Agent **Lv.2**：正文三小节 + 六个状态工具按栏目读写。
  agentLv2,
}

/// 修改轮（按意见重写某一轮）的目标描述（见 `docs/ai_prompt_v2.md` 修改轮模板）。
///
/// 与 [PromptRequest.lastRound] 的分工：
/// - [PromptRequest.lastRound] = **生成基座**，即被重写轮的**上一轮**——上轮时间、
///   状态快照与记忆总结都取自它（工具读取到的信息也停在上一轮）；
/// - 本对象 = **被重写的是哪一轮**，只提供头部「重写第 {轮次} 轮」与「此轮时间」。
class RewriteTarget {
  const RewriteTarget({required this.roundIndex, this.roundTime = ''});

  /// 被重写的轮号（裸数字）。
  final int roundIndex;

  /// 被重写轮的「此轮时间」= 该轮**当前代**的 `## 当前时间`（空则整行不注入）。
  final String roundTime;
}

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
    this.rewrite,
  });

  /// 本书（书籍名 / 分类 / 设定 / 文笔 / 角色类别 / 记忆合并档位等全在内）。
  final Book book;

  /// 提示词模式：Chat / Agent Lv.1 / Agent Lv.2。
  final PromptMode mode;

  /// 生成基座轮（首轮为 null）：上轮时间、状态快照与记忆总结的来源。
  /// 修改轮下 = 被重写轮的上一轮（工具读取到的信息也停在上一轮）。
  final Round? lastRound;

  /// 本轮用户输入（修改轮下 = 用户填写的修改意见）。
  final String userInput;

  /// 已按关键词命中筛好的世界书条目文本（扫描在调用方完成）。
  final String worldBookEntries;

  /// 本书启用的 Mod 束（system / 前置词 / 后置词 / 世界书）。
  final ModsBundle? mods;

  /// 修改轮目标（null = 新建轮）。
  ///
  /// 非 null 时 [lastRound] 是**被重写轮的上一轮**（生成基座），[userInput] 是用户
  /// 填写的修改意见；`user()` 因此走「重写第 {轮次} 轮」模板，其余与新建轮同构。
  final RewriteTarget? rewrite;
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
  /// 调研回合（仅 Lv.1）：读史一次 + 按需联网；不写大纲 / 记忆 / 正文，文本零输出。
  String stagePrepare(AgentStageRequest request);

  /// 记忆回合（仅 Lv.1）：同一回合内推演剧情（思考通道定大纲）+ 落本轮记忆条目。
  String stageMemory(AgentStageRequest request);

  /// 正文回合：Lv.1 需要（Lv.2 的正文契约在 system 里，不追加帧指令）。
  String stageStory(AgentStageRequest request);

  /// 维护 / 修复回合（两档共用）：按缺口清单直接编辑。
  String stageState(AgentStageRequest request);
}
