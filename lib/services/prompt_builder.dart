import '../models/book.dart';
import '../models/mod.dart';
import '../models/round.dart';
import 'prompt_formats.dart';
import 'prompt_sections.dart';

/// Prompt 组装结果（Chat / AGENT 两模式通用）。
///
/// [systemPrompt] 在 Chat 模式即 `system` 消息文本；
/// 在 Agent 模式（[PromptMode.agentLv1] / [PromptMode.agentLv2]）即 Response API
/// 的 `instructions` 字段（语义等价：协议侧直接发送该字段）。
class PromptBundle {
  final String systemPrompt;
  final String userPrompt;

  const PromptBundle({required this.systemPrompt, required this.userPrompt});
}

/// **v1 文案**的 System / User Prompt 门面（组装流程转发 `PromptSections`）。
///
/// 现状与去向：
/// - 生产路径已切到 `prompt_interface.dart`（当前绑定 `PromptV2Build`）；
///   本类保留为 **v1 回退路径**与既有单测入口，`PromptInterfaceV1` 与它同源；
/// - **历史 messages 数组的拼装已迁出本文件**（`wire_messages.dart`）：
///   报文与历史不再依赖提示词模块；
/// - 模式由 [build] 的 `mode` 指定（默认 [PromptMode.chat]）：
///   Chat = 6 个二级标题区块；Lv.1 = 5 区块（排除 `## 记忆总结`）+ 历史工具契约；
///   Lv.2 = 全 Agent 流（正文三小节 + 六个状态工具按栏目读写）。
///
/// 【System Prompt】身份锁定（破甲）→ 模式格式要求 → Markdown 兼容 / 推荐行动 /
/// 角色状态格式 → Mod 系统提示词 → 书籍 / 角色类别 / 世界书 / 文笔 →
/// 模式尾部（记忆格式或工具契约）→ 记忆合并策略 → 收尾【警告】。
///
/// 【User Prompt】模式头部（Chat 的【格式要求】）→ 前置词 → 上轮时间 → 文笔要求 →
/// 用户输入 → 后置词 → 记忆合并指令（Chat）→ 模式【指令执行】→ 收尾【警告】。
class PromptBuilder {
  const PromptBuilder();

  /// 6 个二级标题区块及其固定顺序（真源见 [ChatPromptFormat.sectionOrder]；
  /// 仅 Chat 模式使用）。
  static const List<String> sectionOrder = ChatPromptFormat.sectionOrder;

  PromptBundle build({
    required Book book,
    Round? lastRound,
    required String userInput,
    String worldBookEntries = '',
    ModsBundle? mods,
    PromptMode mode = PromptMode.chat,
  }) {
    const sections = PromptSections();
    return PromptBundle(
      systemPrompt: sections.buildSystemPrompt(
        book: book,
        worldBookEntries: worldBookEntries,
        mods: mods,
        format: mode.format,
      ),
      userPrompt: sections.buildUserPrompt(
        book: book,
        lastRound: lastRound,
        userInput: userInput,
        mods: mods,
        format: mode.format,
      ),
    );
  }
}
