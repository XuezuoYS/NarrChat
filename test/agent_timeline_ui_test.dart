import 'dart:async';

import 'package:flutter/foundation.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 联网搜索工具替身：固定成功结果，不发网络请求
/// （testWidgets 的 FakeAsync 下真实 HTTP 不会完成）。
class _StubWebSearchTool extends WebSearchTool {
  _StubWebSearchTool();

  @override
  Future<AgentToolResult> run(Map<String, dynamic> arguments) async =>
      const AgentToolResult(success: true, content: '搜索「洛天依」的结果：\n- 萌娘百科');
}

/// 单帧脚本：流式增量 + 最终结果 + 可选门控。
///
/// 门控用于在两种时机断言 UI 时间线：
/// - [startGate]：帧请求已发出、流式增量之前（断言上一阶段的工具块）；
/// - [endGate]：流式增量已发出、帧结果返回之前（断言正文流式内容）。
class _ScriptedFrame {
  _ScriptedFrame({
    this.chunks = const [],
    required this.result,
    this.startGate,
    this.endGate,
  });

  final List<AiStreamChunk> chunks;
  final AiCallResult result;
  final Completer<void>? startGate;
  final Completer<void>? endGate;
}

/// 脚本化 responses 服务：按序返回 [_ScriptedFrame]（Lv.1 三段帧脚本）。
class _ScriptedStreamResponsesService extends AiService {
  _ScriptedStreamResponsesService(this.frames);

  final List<_ScriptedFrame> frames;
  int calls = 0;

  @override
  Future<AiCallResult> responses({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    final frame = frames[calls++];
    if (frame.startGate != null) await frame.startGate!.future;
    for (final chunk in frame.chunks) {
      onChunk?.call(chunk);
    }
    if (frame.endGate != null) await frame.endGate!.future;
    onChunk?.call(const AiStreamChunk(done: true));
    return frame.result;
  }
}

/// 等待条件成立（驱动 FakeAsync 下的微任务 / 定时器）。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  int max = 80,
}) async {
  for (var i = 0; i < max && !cond(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(cond(), isTrue, reason: '等待条件超时未成立');
}

// ---------------------------------------------------------------------------
// Lv.1 帧脚本辅助
// ---------------------------------------------------------------------------

/// 准备帧：只读一次历史（读完即结束调研阶段，无联网时整轮恰好三段）。
_ScriptedFrame _prepareReadFrame({String id = 'fc_read'}) => _ScriptedFrame(
  result: AiCallResult(
    content: '',
    toolCalls: [
      AiToolCall(id: id, name: 'narrchat_readHistory', arguments: const {}),
    ],
    promptTokens: 1,
    completionTokens: 1,
    responseId: 'r_read',
  ),
);

/// 记忆帧：`op=append` 追加恰好一条本轮条目（记忆先于正文落地）。
_ScriptedFrame _memoryAppendFrame({
  required String entry,
  String id = 'fc_memory',
}) => _ScriptedFrame(
  result: AiCallResult(
    content: '',
    toolCalls: [
      AiToolCall(
        id: id,
        name: 'narrchat_editHistory',
        arguments: {
          'edits': [
            {'op': 'append', 'newLine': entry},
          ],
        },
      ),
    ],
    promptTokens: 1,
    completionTokens: 1,
    responseId: 'r_memory',
  ),
);

/// 空手帧：只回文本、不调工具（记忆 / 维护阶段走到帧数上限用）。
_ScriptedFrame _emptyFrame(String text) => _ScriptedFrame(
  result: AiCallResult(
    content: text,
    promptTokens: 1,
    completionTokens: 1,
    responseId: 'r_empty',
  ),
);

/// 正文帧：标题帧正文（唯一上屏阶段），流式增量与最终结果一致。
_ScriptedFrame _storyFrame(
  String story, {
  Completer<void>? startGate,
  Completer<void>? endGate,
}) => _ScriptedFrame(
  chunks: [AiStreamChunk(contentDelta: story)],
  result: AiCallResult(
    content: story,
    promptTokens: 1,
    completionTokens: 1,
    responseId: 'r_story',
  ),
  startGate: startGate,
  endGate: endGate,
);

/// AGENT Lv.1 模式 UI：聊天页「AGENT」徽标与状态工具时间线框。
///
/// 帧语义：准备（读史 / 联网）→ 记忆（编辑历史）→ 正文（唯一上屏）→
/// 维护轮（仅在记忆未落地时兜底）。工具块在「调用间隙」可见，因此用例
/// 用多帧脚本 + 门控在帧间断言：工具先行的块排在正文上方。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  testWidgets('AGENT Lv.1（默认平台）：徽标为 Lv.1；准备/记忆工具块在正文上方', (tester) async {
    final storyStartGate = Completer<void>();
    final storyEndGate = Completer<void>();
    const story = '## 剧情演绎\n主角踏门而入。\n\n## 推荐行动\n叩见掌门。\n\n'
        '## 当前时间\n第二天 午时\n\n## 世界状态\n- 地点：青云宗\n\n'
        '## 角色状态\n# 主角\n## 林远\n- 气血：70';
    final ai = _ScriptedStreamResponsesService([
      _prepareReadFrame(),
      _memoryAppendFrame(entry: '- 第1轮｜日期：第二天 午时｜主角踏门而入'),
      _storyFrame(story, startGate: storyStartGate, endGate: storyEndGate),
    ]);
    final settings = AiSettingsProvider();
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      settings: settings,
      aiSettingsProvider: settings,
      // AGENT 模式由实验性档位驱动（默认平台协议 = Response 线路）。
      experimentalSettings: AgentModeSettings(),
    );

    // Lv.1 档位开启 → 左下角徽标为联网同款黄色 `Agent Lv.1 On (BETA)`。
    expect(find.textContaining('Agent Lv.1 On (BETA)'), findsWidgets);

    final future = provider.sendRound(userInput: '测试', book: book);
    await _pumpUntil(tester, () => ai.calls == 3);

    // 准备帧读史 + 记忆帧编辑历史：两个工具块都已结束且排在正文上方；
    // 正文帧已发出请求但尚未流出任何正文。
    expect(find.textContaining('Tool · narrchat_readHistory'), findsOneWidget);
    expect(find.textContaining('Tool · narrchat_editHistory'), findsOneWidget);
    expect(provider.streamingContent, isEmpty);
    expect(provider.contentBoundaryIndex, -1);

    // 放行正文帧：正文起点边界落在两个工具块之后（块下标 0/1 → 边界 2），
    // 即工具块严格位于正文上方。
    storyStartGate.complete();
    await _pumpUntil(tester, () => provider.streamingContent.isNotEmpty);
    expect(provider.streamingContent, contains('主角踏门而入'));
    expect(provider.contentBoundaryIndex, 2);

    storyEndGate.complete();
    await future;
    await waitSendDone(tester, provider);

    // 正文按正文帧落库；记忆条目由记忆帧先于正文写入。
    final round = provider.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('主角踏门而入'));
    expect(round.memorySummary, contains('第1轮'));
    expect(round.currentTime, '第二天 午时');
    expect(round.worldState, '- 地点：青云宗');
  });

  testWidgets('搜索开场白（准备帧无标题文本）不上屏也不阻塞：正文块只展示正文帧', (tester) async {
    final storyEndGate = Completer<void>();
    final settings = AiSettingsProvider();
    // 不 await：本地配置写入在 testWidgets 的 FakeAsync 下不会完成，而
    // 思考 / 流式 / 搜索字段在 await 前已同步生效。
    settings.setPerRoundOptions(thinking: true, streaming: true, search: true);
    const opener =
        "I'll search for information about the two characters before writing the story.";
    const story = '## 剧情演绎\n真正的正文\n\n## 推荐行动\nx\n\n'
        '## 当前时间\n第一天 深夜\n\n## 世界状态\n- 地点：灯会';
    final ai = _ScriptedStreamResponsesService([
      // 准备帧 1：说明性开场白（无标题）+ 联网搜索（搜索不是读取器，调研继续）。
      _ScriptedFrame(
        chunks: const [
          AiStreamChunk(contentDelta: opener),
          AiStreamChunk(toolCallId: 'fc_search', toolName: 'narrchat_webSearch'),
          AiStreamChunk(
            toolCallId: 'fc_search',
            toolArgsDelta: '{"query":"洛天依"}',
          ),
        ],
        result: const AiCallResult(
          content: opener,
          toolCalls: [
            AiToolCall(
              id: 'fc_search',
              name: 'narrchat_webSearch',
              arguments: {'query': '洛天依'},
            ),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'r1',
        ),
      ),
      // 准备帧 2：读史结束调研 → 记忆帧编辑历史 → 正文帧标题正文。
      _prepareReadFrame(id: 'fc_read'),
      _memoryAppendFrame(entry: '- 第1轮｜日期：第一天 深夜｜观察到两人走入小巷'),
      _storyFrame(story, endGate: storyEndGate),
    ]);
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      settings: settings,
      aiSettingsProvider: settings,
      // AGENT 模式由实验性档位驱动（与平台协议正交）。
      experimentalSettings: AgentModeSettings(),
      webSearchTool: _StubWebSearchTool(),
    );

    final future = provider.sendRound(userInput: '搜索两人资料', book: book);
    await _pumpUntil(tester, () => ai.calls == 4);
    await tester.pump();

    // 正文帧已（同步）流式发出：正文块 = 正文帧正文，开场白从未上屏。
    expect(provider.streamingContent, contains('真正的正文'));
    expect(provider.streamingContent, isNot(contains("I'll search")));
    expect(find.textContaining("I'll search"), findsNothing);

    // 放行正文帧并完成本轮：落库正文 = 正文帧正文；搜索工具照常生效。
    storyEndGate.complete();
    await future;
    await waitSendDone(tester, provider);
    final round = provider.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('真正的正文'));
    expect(round.aiNarrative, isNot(contains("I'll search")));
    expect(round.memorySummary, contains('第1轮'));
    expect(round.worldState, '- 地点：灯会');
    expect(round.currentTime, '第一天 深夜');
  });

  testWidgets('联网搜索一次调用只产生一个 Tool 框（不再并存「联网搜索」活动框）', (
    tester,
  ) async {
    final settings = AiSettingsProvider();
    // 不 await：同上，思考 / 流式 / 搜索字段在 await 前已同步生效。
    settings.setPerRoundOptions(thinking: true, streaming: true, search: true);
    final storyEndGate = Completer<void>();
    const story = '## 剧情演绎\n查完资料后的正文\n\n## 推荐行动\nx\n\n'
        '## 当前时间\n第一天 午时';
    final ai = _ScriptedStreamResponsesService([
      // 准备帧：仅搜索工具调用（流式预览 + 执行）；正文在最后一段。
      _ScriptedFrame(
        chunks: const [
          AiStreamChunk(toolCallId: 'fc_search', toolName: 'narrchat_webSearch'),
          AiStreamChunk(
            toolCallId: 'fc_search',
            toolArgsDelta: '{"query":"洛天依"}',
          ),
        ],
        result: const AiCallResult(
          content: '',
          toolCalls: [
            AiToolCall(
              id: 'fc_search',
              name: 'narrchat_webSearch',
              arguments: {'query': '洛天依'},
            ),
          ],
          promptTokens: 1,
          completionTokens: 1,
          responseId: 'r1',
        ),
      ),
      _prepareReadFrame(id: 'fc_read'),
      _memoryAppendFrame(entry: '- 第1轮｜日期：第一天 午时｜搜集两人资料'),
      _storyFrame(story, endGate: storyEndGate),
    ]);
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      settings: settings,
      aiSettingsProvider: settings,
      // AGENT 模式由实验性档位驱动（与平台协议正交）。
      experimentalSettings: AgentModeSettings(),
      webSearchTool: _StubWebSearchTool(),
    );

    final future = provider.sendRound(userInput: '搜索两人资料', book: book);
    await _pumpUntil(tester, () => ai.calls == 4);
    await tester.pump();

    // 一次搜索调用 = 一个 Tool 框：不再并存「联网搜索」活动框与「Tool · …」框。
    expect(find.textContaining('Tool · narrchat_webSearch'), findsOneWidget);
    expect(find.textContaining('联网搜索'), findsNothing);
    expect(find.textContaining('Tool · narrchat_webFetchPage'), findsNothing);

    storyEndGate.complete();
    await future;
    await waitSendDone(tester, provider);
  });

  testWidgets('轮次常驻黄框：结束后警告仍挂在正文轮上，没有关闭入口', (tester) async {
    // Lv.1 兜底流程：准备读史 → 3 次记忆空手（记忆阶段帧数上限）→ 正文 →
    // 4 次维护空手（维护阶段帧数上限）→ 记忆总结缺项转常驻警告。
    // 世界 / 角色不再由工具维护，不会再出现「世界状态本轮未更新」。
    const story = '## 剧情演绎\n正文初稿\n\n## 推荐行动\n行动';
    final ai = _ScriptedStreamResponsesService([
      _prepareReadFrame(),
      for (var i = 0; i < 3; i++) _emptyFrame('记忆阶段空手：没有调用编辑器。'),
      _storyFrame(story),
      for (var i = 0; i < 4; i++) _emptyFrame('维护阶段空手：没有调用编辑器。'),
    ]);
    final settings = AiSettingsProvider();
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      settings: settings,
      aiSettingsProvider: settings,
      // AGENT 模式由实验性档位驱动（与平台协议正交）。
      experimentalSettings: AgentModeSettings(),
    );

    final future = provider.sendRound(userInput: '测试', book: book);
    await future;
    await waitSendDone(tester, provider);
    expect(ai.calls, 9, reason: '1 准备 + 3 记忆 + 1 正文 + 4 维护');

    final idx = provider.rounds.last.roundIndex;
    expect(provider.roundWarningsFor(idx), ['记忆总结本轮未更新']);
    // 生成已结束（顶部流式提示框随之消失），警告改挂在正文轮上。
    expect(find.textContaining('记忆总结本轮未更新'), findsOneWidget);
    expect(find.textContaining('世界状态本轮未更新'), findsNothing);
    expect(find.textContaining('角色状态本轮未更新'), findsNothing);
    expect(provider.roundWarningsFor(idx), isNot(contains('当前时间')));

    // 提示常驻：没有关闭按钮，重新布局后它仍在。
    expect(find.byKey(const ValueKey('dismiss_round_warning')), findsNothing);
    await tester.pump();
    expect(find.textContaining('记忆总结本轮未更新'), findsOneWidget);
  });
}
