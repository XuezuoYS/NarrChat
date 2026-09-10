import '../models/book.dart';
import '../models/mod.dart';
import '../models/round.dart';
import 'ai_response_parser.dart';
import 'prompt_formats.dart';
import 'prompt_sections.dart';

/// Prompt 组装结果（Chat / AGENT 两模式通用）。
///
/// [systemPrompt] 在 Chat 模式即 `system` 消息文本；
/// 在 Agent 模式（[PromptMode.agentLv1] / [PromptMode.agentLv2]）即 Response API
/// 的 `instructions` 字段
/// （语义等价：协议侧直接发送该字段）。
class PromptBundle {
  final String systemPrompt;
  final String userPrompt;

  const PromptBundle({required this.systemPrompt, required this.userPrompt});
}

/// 历史轮次中 assistant 消息的**拼合形态**（模式唯一差异点，单一真源）。
///
/// 历史里的 assistant 消息是模型的**模仿对象**：一旦那里出现某个区块，模型
/// 就会照抄这个形状输出。因此每种模式的拼合形态必须与该模式的输出契约一致。
enum AssistantHistoryShape {
  /// Chat：最新一轮为完整 6 区块「原生返回」，更早轮次只带剧情正文
  /// （便于控制上下文篇幅）。
  chat,

  /// Agent Lv.1：最新一轮为 **5 区块**（排除 `## 记忆总结`），更早轮次只带
  /// 剧情正文；历史（记忆总结）改由 `narrchat_readHistory` 工具提供。
  chatWithoutMemory,

  /// Agent Lv.2：**每一轮**都只带正文三小节（剧情 / 行动 / 时间），
  /// 状态三栏一律由 `narrchat_read*` 工具提供。
  agentStoryOnly,
}

/// 按照需求文档组装发送给大模型的 System / User Prompt
/// （Chat / Agent 两种模式门面）。
///
/// 模式由 [mode] 指定（默认 [PromptMode.chat]）：
/// - **Chat**：[PromptMode.chat] —— 6 个二级标题区块（剧情演绎 / 推荐行动 /
///   当前时间 / 世界状态 / 角色状态 / 记忆总结），含状态快照规则、角色状态
///   输出格式与记忆总结格式；
/// - **Agent Lv.1**：[PromptMode.agentLv1] —— 5 个二级标题区块（排除
///   `## 记忆总结`）+ 历史工具契约（正文回合先读历史，编辑只在维护回合）；
/// - **Agent Lv.2**：[PromptMode.agentLv2] —— 全 Agent 流，仅 `## 剧情演绎`
///   与 `## 推荐行动`、`## 当前时间` 三个标题，世界状态 / 角色状态 / 记忆总结
///   一律通过六个 `narrchat_*` 工具按栏目读写（格式要求见
///   [AgentLv2PromptFormat]）。
///
/// 共享组装流程统一在 `PromptSections`（共享文案 + 共享组装单一真源）：
/// 修改共享文案时两种模式指令同步生效，无需多处维护；
/// 格式生成要求（[PromptFormatSpec]）是模式唯一差异化点。
///
/// 【System Prompt】
/// - 身份锁定（破甲）：解除助手式限制，明确本任务为虚构创作，直接顺从创作。
/// - 书籍名称、书籍类别、书籍设定、文笔要求（内置去 AI 味）、文笔参考（用户补充，**仅存在于 system**）、
///   角色层级、世界书条目、已启用 Mod 的系统提示词与 WorldBook。
/// - 上一轮状态快照（角色/世界状态、记忆总结、上轮时间）**不再注入 system**：
///   经 `messages` 中最后一条 assistant 消息（最后一轮的反解析「原生返回」，
///   见 [buildHistoryMessages]）原生传给模型。
///
/// 【User Prompt】
/// - 前置词（用户自定义 + Mod）→ 上轮时间 → 文笔要求 → 用户输入内容 →
///   后置词（用户自定义 + Mod）→ 模式【指令执行】→ 共性收尾【警告】；
///   Chat 额外在开头注入【格式要求】与记忆格式提醒（AGENT 无）。
/// - 历史轮次不写入 Prompt 文本，而是按 API 要求以 `messages` 数组中的
///   `user` / `assistant` 交替消息原生传入（见 [buildHistoryMessages]）。
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

  /// 将历史轮次组装为 OpenAI 兼容的 `messages` 数组片段：
  /// 每轮一条 `user`（用户输入）+ 一条 `assistant`，按时间顺序排列。
  /// 调用方应将其插入 `system` 消息之后、当前轮 `user` 消息之前。
  ///
  /// - **Chat**：最后一轮（最新一轮）的 assistant 为完整反解析的「原生返回」
  ///   格式（6 个 `##` 区块，见 [AiResponseParser.serialize]）：上一轮的角色状态 /
  ///   世界状态 / 记忆总结 / 当前时间经此原生传入，取代原先注入 system 的状态快照；
  ///   更早的历史轮次仅置入剧情正文（aiNarrative），控制上下文篇幅；
  /// - 整轮六字段全空时保留「（无正文）」占位（避免发送空 assistant 消息）。
  ///
  /// [imagePartsFor] 非空时，若某轮用户消息存在图片（该回调返回图片 parts），
  /// 其 `content` 变为「文本 + 图片数组」（OpenAI 兼容 vision 格式）；否则为纯文本。
  ///
  /// [shape] 决定 assistant 消息的拼合形态（见 [AssistantHistoryShape]）：
  /// - [AssistantHistoryShape.chat]：最新一轮完整 6 区块，更早轮次仅剧情正文；
  /// - [AssistantHistoryShape.chatWithoutMemory]（Lv.1）：最新一轮 5 区块
  ///   （排除记忆总结），更早轮次仅剧情正文；
  /// - [AssistantHistoryShape.agentStoryOnly]（Lv.2）：**每一轮**同一形状
  ///   （剧情 / 推荐行动 / 当前时间三小节），模型只模仿一种输出。
  static List<Map<String, dynamic>> buildHistoryMessages(
    List<Round> rounds, {
    List<Map<String, dynamic>> Function(Round round)? imagePartsFor,
    AssistantHistoryShape shape = AssistantHistoryShape.chat,
  }) {
    final result = <Map<String, dynamic>>[];
    for (var i = 0; i < rounds.length; i++) {
      final r = rounds[i];
      if (r.userInput.trim().isNotEmpty) {
        final imageParts = imagePartsFor?.call(r) ?? const [];
        result.add({
          'role': 'user',
          'content': _contentWithImages(r.userInput, imageParts),
        });
      }
      result.add({
        'role': 'assistant',
        'content': _assistantContent(
          r,
          isLatest: i == rounds.length - 1,
          shape: shape,
        ),
      });
    }
    return result;
  }

  /// 单轮 assistant 消息正文（按 [AssistantHistoryShape] 拼合）：
  /// - [AssistantHistoryShape.agentStoryOnly]：正文三个小节；
  /// - [AssistantHistoryShape.chatWithoutMemory]：**最新一轮**给出 5 区块
  ///   （排除记忆总结），更早轮次仅正文；
  /// - [AssistantHistoryShape.chat]：最新一轮完整 6 区块，更早轮次仅正文；
  ///
  /// 整轮全空时保留「（无正文）」占位（避免发送空 assistant 消息）。
  static String _assistantContent(
    Round r, {
    required bool isLatest,
    AssistantHistoryShape shape = AssistantHistoryShape.chat,
  }) {
    if (shape == AssistantHistoryShape.agentStoryOnly) {
      final story = r.aiNarrative.trim();
      final action = r.recommendedAction.trim();
      if (story.isEmpty && action.isEmpty) return '（无正文）';
      return AiResponseParser.serializeAgentBody(ParsedAiResponse(
        aiNarrative: r.aiNarrative,
        recommendedAction: r.recommendedAction,
        currentTime: r.currentTime,
      ));
    }
    if (!isLatest) {
      return r.aiNarrative.isEmpty ? '（无正文）' : r.aiNarrative;
    }
    final parsed = ParsedAiResponse(
      aiNarrative: r.aiNarrative,
      worldState: r.worldState,
      characterState: r.characterState,
      memorySummary: r.memorySummary,
      currentTime: r.currentTime,
      recommendedAction: r.recommendedAction,
    );
    if (parsed.isEmpty) return '（无正文）';
    return shape == AssistantHistoryShape.chatWithoutMemory
        ? AiResponseParser.serializeChatWithoutMemory(parsed)
        : AiResponseParser.serialize(parsed);
  }

  /// 组装单条用户消息的 `content`：无图片为纯文本字符串，有图片为
  /// `[{"type":"text",…},{"type":"image_url",…}]` 数组。
  static Object _contentWithImages(
    String text,
    List<Map<String, dynamic>> imageParts,
  ) {
    if (imageParts.isEmpty) return text;
    return [
      {'type': 'text', 'text': text},
      ...imageParts,
    ];
  }
}
