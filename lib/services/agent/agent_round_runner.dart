import 'dart:convert';

import '../ai_response_parser.dart';
import '../ai_service.dart';
import 'agent_activity.dart';
import 'narr_agent_tool.dart';

/// 单次修复轮可用的状态修改次数上限（超过即钳制）。
const int kAgentMaxFixups = 2;

/// 单个工具调用的执行结果（UI 事件 + 回传模型依据）。
class AgentToolOutcome {
  final String name;

  /// 工具调用 id（与流式预览事件匹配）。
  final String callId;

  /// 参数短摘要（UI 展示）。
  final String argsSummary;

  /// 事件主体（UI 展示用，语义化）：搜索工具 = query、打开页面 = url、
  /// 其余 = [argsSummary]。保证同一工具调用只产生一个语义正确的事件框。
  final String subject;

  /// 是否应用成功（状态工具校验失败 → 修复轮反馈）。
  final bool applied;

  /// 结果消息（成功说明或错误原因）。
  final String message;

  /// 是否状态类工具（校验失败走修复轮语义）。
  final bool isStateTool;

  const AgentToolOutcome({
    required this.name,
    this.callId = '',
    required this.argsSummary,
    this.subject = '',
    required this.applied,
    required this.message,
    required this.isStateTool,
  });
}

/// AGENT 轮运行的聚合结果。
class AgentRoundResult {
  /// 本轮正文：首个**标题帧**（内容含 `## 剧情演绎` 标题）的原始内容；
  /// 整轮无标题帧时以「无标题 + 无工具」帧兜底。
  final String content;

  /// 全部帧正文的拼接（含修复 / 补充帧）：供「未使用工具时按文本状态兜底」
  /// 解析状态区块（状态文本可能出现在任意帧）；正文采纳不受其影响。
  final String fullContent;

  /// 聚合思考内容。
  final String reasoningContent;

  /// 聚合 Token 用量。
  final int promptTokens;
  final int completionTokens;

  /// 全部工具调用结果（按执行顺序）。
  final List<AgentToolOutcome> outcomes;

  /// 修复 2 次后仍被跳过（钳制）的修改项说明。
  final List<String> warnings;

  /// 最后一次响应的 responseId（无状态平台为空）。
  final String responseId;

  const AgentRoundResult({
    required this.content,
    required this.fullContent,
    required this.reasoningContent,
    required this.promptTokens,
    required this.completionTokens,
    required this.outcomes,
    required this.warnings,
    required this.responseId,
  });
}

/// AGENT 单轮执行器（Response API 协议 + 锚定式状态工具）。
///
/// 循环语义（与 Chat 搜索循环不同）：
/// 1. 主响应：模型可同时输出正文（剧情演绎/推荐行动）与并行工具调用；
///    执行全部工具后：
///    - 正文已产出且全部状态工具校验通过 → **本轮结束**（不再发起后续调用）；
///    - 存在未通过校验的状态工具 → 反馈错误进入修复轮（≤ [kAgentMaxFixups] 次）；
/// 2. 未产出正文（模型先搜索后写作）时按搜索循环继续（结果=正文 + 状态工具）；
/// 3. 修复轮仍失败 → 应用已通过部分 + [AgentRoundResult.warnings] 钳制跳过。
///
/// 【正文采纳】按「帧级格式分类」判定，而非「首个含文字帧」：
/// - **标题帧**（内容含 `## 剧情演绎` / `## 正文` 标题）→ 采纳为本轮正文
///   （首个标题帧；后续帧的正文按契约丢弃——修复轮只允许工具调用）；
/// - **无标题 + 带工具调用**的帧 = 搜索开场白 / 说明性文字
///   （如「我先搜索一下…」）→ **不作为正文**、不阻塞后续真正正文
///   （继续搜索循环），仅作为兜底暂存；
/// - **无标题 + 无工具**的帧 = 模型未按格式输出正文 → 兜底采纳
///   （仅在无标题帧中最后出现的一个作为正文，防止故事因格式问题丢失）；
/// - 整轮从未产出标题帧时，以「无标题帧」兜底内容作为正文。
///
/// 完整性检查（时间/记忆等状态项）只在**正文已采纳**后触发，搜索阶段的
/// 开场白帧不会触发「状态维护反馈」。
///
/// 续接策略：`previous_response_id` 仅在平台开启有状态链式（[chaining] 为真）
/// 时使用（后续帧只发新增 item）；无状态平台每次全量重发输入。
class AgentRoundRunner {
  AgentRoundRunner({
    required this.buildBody,
    required this.call,
    required this.tools,
    this.chaining = false,
    this.maxIterations = 30,
    this.onActivity,
    this.onToolStarted,
    this.onToolFinished,
    this.completenessCheck,
  });

  /// 组装一次调用的请求体：
  /// [inputItems] 为本次要发送的 input 内容（无状态 = 全量累积；
  /// 有状态 = 仅新增 item）；[previousResponseId] 非空表示链式续接帧。
  final Map<String, dynamic> Function(
    List<Map<String, dynamic>> inputItems,
    String? previousResponseId,
  ) buildBody;

  /// 执行一次 LLM 调用（responses 通道）。
  final Future<AiCallResult> Function(
    Map<String, dynamic> requestBody,
    bool stream,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  ) call;

  final List<NarrAgentTool> tools;
  final bool chaining;
  final int maxIterations;
  final void Function(AgentActivity activity)? onActivity;
  final void Function(AgentToolOutcome outcome)? onToolStarted;
  final void Function(AgentToolOutcome outcome)? onToolFinished;

  /// 状态完整性检查（由调用方按轮次语义提供）。
  ///
  /// 主响应（已产出正文）的工具执行完成后调用：返回非空列表表示本轮缺失
  /// 必须维护的状态项（如「时间未推进」「未添加记忆条目」），将进入补充
  /// 修复轮（与校验失败同一补救通道，≤ [kAgentMaxFixups] 次，超限钳制并警告）。
  final List<String> Function(List<AgentToolOutcome> outcomes)? completenessCheck;

  /// 运行一轮 AGENT 生成。
  ///
  /// [initialInputItems]：本轮 input（历史消息 + 用户消息）；
  /// [stream] / [onChunk] / [onRequestBody] / [isCancelled] 与既有通道一致。
  Future<AgentRoundResult> run({
    required List<Map<String, dynamic>> initialInputItems,
    required bool stream,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    // 会话累积：全量 item 列表（无状态重发 / 有状态新增均从中派生）。
    final allItems = List<Map<String, dynamic>>.from(initialInputItems);
    String? previousResponseId;
    var totalPrompt = 0;
    var totalCompletion = 0;
    // 采纳的正文（首个标题帧 / 无标题兜底帧）。
    final narrativeSb = StringBuffer();
    // 全部帧正文拼接（文本状态兜底解析用）。
    final fullContentSb = StringBuffer();
    final reasoningSb = StringBuffer();
    final outcomes = <AgentToolOutcome>[];
    final warnings = <String>[];
    // 正文采纳：首个**标题帧**（内容含 ## 剧情演绎）采纳为正文；无标题 +
    // 带工具调用的帧 = 搜索开场白（如「我先搜索一下…」），不采纳、不阻塞
    // 后续真正正文；无标题 + 无工具的帧兜底采纳（防格式不合规时丢失故事）。
    var narrativeTaken = false;
    var lastPreamble = '';
    var fixups = 0;
    String lastResponseId = '';

    for (var i = 0; i < maxIterations; i++) {
      onActivity?.call(
        AgentActivity(type: AgentActivityType.turn, query: '', iteration: i),
      );
      // 无状态重发全量；有状态链式只发新增 item（上一个响应的 id 作为挂接点）。
      final sendItems = chaining && previousResponseId != null
          ? allItems.sublist(initialInputItems.length)
          : allItems;
      final requestBody = buildBody(sendItems, previousResponseId);
      final result = await call(
        requestBody,
        stream,
        onChunk,
        onRequestBody,
        isCancelled,
      );
      totalPrompt += result.promptTokens;
      totalCompletion += result.completionTokens;
      reasoningSb.write(result.reasoningContent);
      // 帧级正文分类（见类文档「正文采纳」）：
      // - 标题帧：首个被采纳；后续标题帧（修复轮复读）按契约丢弃；
      // - 无标题 + 带工具：搜索开场白，仅暂存兜底，不阻塞真正正文；
      // - 无标题 + 无工具：格式不合规正文兜底采纳。
      if (result.content.trim().isNotEmpty) {
        if (fullContentSb.isNotEmpty) fullContentSb.write('\n');
        fullContentSb.write(result.content);
        if (!narrativeTaken) {
          final hasStoryHeading =
              AiResponseParser.storyHeadingStart(result.content) != null;
          if (hasStoryHeading || result.toolCalls.isEmpty) {
            narrativeTaken = true;
            narrativeSb.write(result.content);
          } else {
            lastPreamble = result.content;
          }
        }
      }
      if (result.responseId.isNotEmpty) {
        lastResponseId = result.responseId;
      }

      if (result.toolCalls.isEmpty) {
        // 无任何工具调用：正文已采纳时仍需完整性检查（时间/记忆等必需项
        // 缺失 → 进入补充修复轮；这是「模型只输出正文不用工具」的核心兜底）。
        // 同样以整轮累计判定（此前帧已调用过的工具计入）。
        final problems = narrativeTaken
            ? completenessCheck?.call(outcomes) ?? const <String>[]
            : const <String>[];
        if (problems.isNotEmpty) {
          if (fixups >= kAgentMaxFixups) {
            warnings.addAll(problems);
            break;
          }
          fixups++;
          allItems.add(_fixupFeedbackItem(problems));
          previousResponseId = lastResponseId;
          continue;
        }
        break;
      }

      // 执行工具批（并行语义：逐个执行、结果全部回传）。
      final turnOutcomes = <AgentToolOutcome>[];
      final newItems = <Map<String, dynamic>>[];
      final stateFailures = <String>[];      for (final tc in result.toolCalls) {
        if (isCancelled?.call() ?? false) {
          throw const AiCancelledException();
        }
        final tool = _byName(tc.name);
        final summary = _argsSummary(tc.name, tc.arguments);
        final outcome = await _execute(
          i,
          tc,
          tool,
          summary,
          onFailed: (message) {
            stateFailures.add('${tc.name}：$message');
          },
        );
        turnOutcomes.add(outcome);
        // 续接帧的输入项：
        // - 无状态平台必须**重放**本轮的 function_call 条目（服务端无会话，
        //   需凭 call_id 匹配工具输出），再加 function_call_output；
        // - 有状态链式只发 function_call_output（调用条目已存于服务端会话）。
        if (!chaining) {
          newItems.add({
            'type': 'function_call',
            'call_id': tc.id,
            'name': tc.name,
            'arguments': jsonEncode(tc.arguments),
          });
        }
        newItems.add({
          'type': 'function_call_output',
          'call_id': tc.id,
          'output': outcome.message,
        });
      }
      outcomes.addAll(turnOutcomes);

      // 正文已采纳 → 完整性检查（时间/记忆等必需状态项缺失也进入补充轮）。
      // 注意：以**整轮累计**的工具调用判定（工具状态跨帧持久，时间在第 1 帧
      // 推进过、后续帧不再调用不应误判缺失）。
      final completeness = narrativeTaken
          ? completenessCheck?.call(outcomes) ?? const <String>[]
          : const <String>[];
      final problems = [...stateFailures, ...completeness];

      // 正文已产出：状态全部通过 → 结束；否则修复轮。
      if (narrativeTaken) {
        if (problems.isEmpty) break;
        if (fixups >= kAgentMaxFixups) {
          warnings.addAll(problems);
          break;
        }
      } else if (stateFailures.isEmpty) {
        // 搜索型回合：无状态错误，继续循环（与 Chat 搜索语义一致）。
      }

      // 组织修复轮 / 续接输入。
      fixups++;
      if (problems.isNotEmpty) {
        newItems.add(_fixupFeedbackItem(problems));
      }
      previousResponseId = lastResponseId;
      allItems.addAll(newItems);
    }

    // 整轮从未出现标题帧：以「无标题 + 无工具」帧 / 最后开场白兜底，
    // 避免模型的正文（格式不合规）或失败轮内容彻底丢失。
    final narrative = narrativeSb.isNotEmpty
        ? narrativeSb.toString()
        : (lastPreamble.isEmpty ? '' : lastPreamble);
    return AgentRoundResult(
      content: narrative,
      fullContent: fullContentSb.toString(),
      reasoningContent: reasoningSb.toString(),
      promptTokens: totalPrompt,
      completionTokens: totalCompletion,
      outcomes: outcomes,
      warnings: warnings,
      responseId: lastResponseId,
    );
  }

  /// 修复 / 补充反馈消息（校验失败或缺项提示，中英双语强化约束）。
  ///
  /// 修复轮仅允许工具调用：正文已完整，重复输出会被丢弃——反馈文本显式
  /// 声明，避免模型在修复轮复读正文造成「两个请求各输出一遍正文」。
  static Map<String, dynamic> _fixupFeedbackItem(List<String> problems) => {
        'role': 'user',
        'content': '【状态维护反馈】正文已完整：**不要再输出 ## 剧情演绎 / '
            '## 推荐行动**（重复正文会被丢弃，不计入本轮正文）。'
            '本修复轮只调用工具修正以下项（同一项最多再尝试 '
            '$kAgentMaxFixups 次，超时将跳过）：\n'
            '- ${problems.join('\n- ')}\n'
            '[State feedback] The story is complete: DO NOT output '
            '## 剧情演绎 / ## 推荐行动 again (repeated story is discarded). '
            'In this fixup turn only call the tools to fix the items below '
            '(max $kAgentMaxFixups tries per item, then it will be skipped):\n'
            '- ${problems.join('\n- ')}',
      };

  Future<AgentToolOutcome> _execute(
    int iteration,
    AiToolCall tc,
    NarrAgentTool? tool,
    String summary, {
    required void Function(String message) onFailed,
  }) async {
    final isStateTool = tool?.activityType == AgentActivityType.tooling;
    // 事件主体：语义化提取（搜索 query / 打开页面 url），否则用参数摘要。
    final subject = _subject(tc, summary);

    onActivity?.call(
      AgentActivity(
        type: tool?.activityType ?? AgentActivityType.searching,
        query: summary,
        iteration: iteration,
      ),
    );
    onToolStarted?.call(
      AgentToolOutcome(
        name: tc.name,
        callId: tc.id,
        argsSummary: summary,
        subject: subject,
        applied: false,
        message: '',
        isStateTool: isStateTool,
      ),
    );

    if (tool == null) {
      final outcome = AgentToolOutcome(
        name: tc.name,
        callId: tc.id,
        argsSummary: summary,
        subject: subject,
        applied: false,
        message: '未知工具：${tc.name}',
        isStateTool: isStateTool,
      );
      onToolFinished?.call(outcome);
      return outcome;
    }
    final toolResult = await tool.run(tc.arguments);
    final outcome = AgentToolOutcome(
      name: tc.name,
      callId: tc.id,
      argsSummary: summary,
      subject: subject,
      applied: toolResult.success,
      message: toolResult.content,
      isStateTool: isStateTool,
    );
    if (!toolResult.success && isStateTool) {
      onFailed(toolResult.content);
    }
    onToolFinished?.call(outcome);
    return outcome;
  }

  /// 事件主体：搜索工具取 query、打开页面取 url，其余回退参数摘要。
  static String _subject(AiToolCall tc, String fallback) {
    final query = tc.arguments['query'];
    if (query is String && query.trim().isNotEmpty) return query.trim();
    final url = tc.arguments['url'];
    if (url is String && url.trim().isNotEmpty) return url.trim();
    return fallback;
  }

  NarrAgentTool? _byName(String name) {
    for (final t in tools) {
      if (t.name == name) return t;
    }
    return null;
  }

  static String _argsSummary(String name, Map<String, dynamic> arguments) {
    if (arguments.isEmpty) return name;
    final parts = arguments.entries
        .map((e) => '${e.key}=${_short(e.value)}')
        .take(3)
        .join('；');
    return '$name（$parts）';
  }

  static String _short(Object? v) {
    final s = v is String ? v : v.toString();
    return s.length <= 20 ? s : '${s.substring(0, 20)}…';
  }
}
