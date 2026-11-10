import '../../models/agent_mode_level.dart';
import '../wire_messages.dart';
import '../prompt_text.dart';
import 'state/agent_state_working_copy.dart';

/// 单个 Agent 档位的**语义档案**（档位 → 提示词模式 / 工具栏目 / 正文契约的
/// 单一映射）。
///
/// 引入本类的目的：档位差异散落在提示词、工具集、执行器、缺口判定四处时，
/// 每加一个档位都要在四处加 `if`。现在各层只消费本档案：
/// - [promptMode]：本轮提示词的格式生成要求；
/// - [toolSections]：本档位启用的状态工具栏目（读取器与编辑器成对，顺序即
///   注册顺序）；
/// - [bannedStoryHeadings]：正文回合**禁止**出现的状态类二级标题
///   （= 工具维护的栏目，避免正文与工具双写）；
/// - [historyShape]：历史轮次 assistant 消息的拼合形态。
///
/// 历史上的完整 Agent（Lv.2：世界 / 角色 / 历史六工具 + 正文三小节）**已移除**；
/// 六工具实现与多栏目缺口框架仍留在 `state/` 下作为后续档位的基础设施，但当前
/// 没有任何档位把世界 / 角色栏目放进 [toolSections]。
class AgentModeProfile {
  const AgentModeProfile._({
    required this.level,
    required this.promptMode,
    required this.toolSections,
    required this.historyShape,
  });

  /// 档位 → 档案（档位语义的唯一入口）。
  static AgentModeProfile of(AgentModeLevel level) => switch (level) {
        AgentModeLevel.off => off,
        AgentModeLevel.lv1 => lv1,
      };

  /// 关闭：传统 Chat 流程（无工具、6 区块正文与历史形态）。
  static const AgentModeProfile off = AgentModeProfile._(
    level: AgentModeLevel.off,
    promptMode: PromptMode.chat,
    toolSections: <AgentStateSection>[],
    historyShape: AssistantHistoryShape.chat,
  );

  /// Lv.1：仅历史（记忆总结）工具 + 联网；正文 5 区块。
  static const AgentModeProfile lv1 = AgentModeProfile._(
    level: AgentModeLevel.lv1,
    promptMode: PromptMode.agentLv1,
    toolSections: <AgentStateSection>[AgentStateSection.memorySummary],
    historyShape: AssistantHistoryShape.chatWithoutMemory,
  );

  /// 完整 Agent（Lv.2）的「六工具 + 正文三小节」档案随该档位一起移除；六工具
  /// 实现与多栏目缺口框架保留在 `state/` 下，当前没有档位注册它们。
  final AgentModeLevel level;

  /// 本轮提示词的生成模式（[PromptMode]，分派到 v2 文本契约）。
  final PromptMode promptMode;

  /// 本档位启用的状态工具栏目（读取器在前、编辑器在后的注册顺序由此决定）。
  final List<AgentStateSection> toolSections;

  /// 历史轮次 assistant 消息的拼合形态。
  final AssistantHistoryShape historyShape;

  /// 是否 Agent 流程（当前仅 Lv.1；Lv.2 已移除）。
  bool get isOn => level.isOn;

  /// 正文回合禁止输出的状态类二级标题（= 工具维护的栏目）。
  List<String> get bannedStoryHeadings =>
      [for (final section in toolSections) section.label];
}
