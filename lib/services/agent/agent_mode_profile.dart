import '../../models/agent_mode_level.dart';
import '../prompt_builder.dart';
import '../prompt_formats.dart';
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
        AgentModeLevel.lv2 => lv2,
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

  /// Lv.2：六个状态工具 + 联网；正文 3 小节，状态三栏全部由工具维护。
  static const AgentModeProfile lv2 = AgentModeProfile._(
    level: AgentModeLevel.lv2,
    promptMode: PromptMode.agentLv2,
    toolSections: <AgentStateSection>[
      AgentStateSection.worldState,
      AgentStateSection.characterState,
      AgentStateSection.memorySummary,
    ],
    historyShape: AssistantHistoryShape.agentStoryOnly,
  );

  final AgentModeLevel level;

  /// 本轮提示词的格式生成要求（[PromptBuilder] 的 `mode`）。
  final PromptMode promptMode;

  /// 本档位启用的状态工具栏目（读取器在前、编辑器在后的注册顺序由此决定）。
  final List<AgentStateSection> toolSections;

  /// 历史轮次 assistant 消息的拼合形态。
  final AssistantHistoryShape historyShape;

  /// 是否 Agent 流程（Lv.1 / Lv.2）。
  bool get isOn => level.isOn;

  /// 正文回合禁止输出的状态类二级标题（= 工具维护的栏目）。
  List<String> get bannedStoryHeadings =>
      [for (final section in toolSections) section.label];
}
