/// **报文侧的消息组装**：历史轮次 messages（`user` / `assistant` 交替）+ 图片 content。
///
/// 解耦边界（重要）：**历史跟随报文**——历史消息与请求体组装同属「请求组装侧」，
/// 一起与提示词接口产出的 `system` / 本轮 user 输入 / 工具清单解耦：
/// - 本文件只依赖 `Round` 模型与反解析器，**不引用任何提示词模块**
///   （`prompt_text` / `prompt_v2_build` / `prompt_v2_sections` 都不引用）；
/// - 请求体由 `RoundProvider` + `wire_adapters` 拼装，历史消息在这一侧进入消息序列；
/// - 因此提示词换版（v1 ↔ v2）不需要改动本文件与报文层。
///
/// assistant 侧形态是模型的**模仿对象**：历史里一旦出现某个区块，模型就会照抄，
/// 所以形态必须与该模式的输出契约一致（见 [AssistantHistoryShape]）。
library;

import '../models/round.dart';
import 'ai_response_parser.dart';

/// 历史轮次中 assistant 消息的**拼合形态**（模式唯一差异点，单一真源）。
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

/// 将历史轮次组装为 OpenAI 兼容的 `messages` 数组片段：
/// 每轮一条 `user`（用户输入）+ 一条 `assistant`，按时间顺序排列。
/// 调用方应将其插入 `system` 消息之后、当前轮 `user` 消息之前。
///
/// - **Chat**：最新一轮（最新一轮）的 assistant 为完整反解析的「原生返回」
///   格式（6 个 `##` 区块，见 [AiResponseParser.serialize]）：上一轮的角色状态 /
///   世界状态 / 记忆总结 / 当前时间经此原生传入；
///   更早的历史轮次仅置入剧情正文（aiNarrative），控制上下文篇幅；
/// - 整轮六字段全空时保留「（无正文）」占位（避免发送空 assistant 消息）。
///
/// [imagePartsFor] 非空时，若某轮用户消息存在图片（该回调返回图片 parts），
/// 其 `content` 变为「文本 + 图片数组」（OpenAI 兼容 vision 格式）；否则为纯文本。
///
/// [shape] 决定 assistant 消息的拼合形态（见 [AssistantHistoryShape]）。
List<Map<String, dynamic>> buildHistoryMessages(
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
String _assistantContent(
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
Object _contentWithImages(
  String text,
  List<Map<String, dynamic>> imageParts,
) {
  if (imageParts.isEmpty) return text;
  return [
    {'type': 'text', 'text': text},
    ...imageParts,
  ];
}
