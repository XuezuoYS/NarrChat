import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/agent_event.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/html_search_service.dart';
import 'package:narrchat/services/non_stream_replay.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 按序返回门控结果的 responses 服务（AGENT 模式替身）：非流式请求。
class _GatedResponsesService extends AiService {
  _GatedResponsesService(this.gates);

  final List<Completer<AiCallResult>> gates;
  final List<bool> streams = [];
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
  }) {
    streams.add(stream);
    final index = calls++;
    return gates[index].future;
  }
}

/// 按序返回门控结果的 chat 服务（Chat 协议替身）：非流式请求。
class _GatedChatService extends AiService {
  _GatedChatService(this.gates);

  final List<Completer<AiCallResult>> gates;
  final List<bool> streams = [];
  int calls = 0;

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) {
    streams.add(stream);
    final index = calls++;
    return gates[index].future;
  }
}

/// 门控搜索替身：结果与完成时机由测试控制（不发网络请求）。
class _GatedSearchService extends HtmlSearchService {
  _GatedSearchService(this.gate);

  final Completer<void> gate;
  bool started = false;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 20,
  }) async {
    started = true;
    await gate.future;
    return const [SearchResult(title: '洛天依 - 萌娘百科', url: 'https://x.example')];
  }
}

/// 非流式多轮（AGENT / 联网搜索）的块时间线展示：
/// 每次 AI 轮次完成即展示其思考 / 工具 / 正文块，工具执行过程 → 结果实时可见。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  /// 等待条件成立（驱动 FakeAsync 下的定时器推进）。
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() cond, {
    int max = 150,
  }) async {
    for (var i = 0; i < max && !cond(); i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(cond(), isTrue, reason: '等待条件超时未成立');
  }

  testWidgets('AGENT 非流式：思考与工具块按轮次展示，工具结果可见，正文渐进出现', (
    tester,
  ) async {
    final gates = [Completer<AiCallResult>(), Completer<AiCallResult>()];
    final ai = _GatedResponsesService(gates);
    final settings = AiSettingsProvider();
    // 非流式（记忆值同步生效，持久化在 FakeAsync 下不等待）。
    settings.setPerRoundOptions(thinking: true, streaming: false);
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      bookDao: FakeBookDao(books: [book]),
      settings: settings,
      aiSettingsProvider: settings,
      // AGENT 模式由实验性开关驱动（与平台协议正交）。
      experimentalSettings: AgentModeSettings(),
      nonStreamReplayer: const NonStreamReplayer(
        tickInterval: Duration(milliseconds: 20),
        charsPerTick: 4,
      ),
    );

    final future = provider.sendRound(userInput: '测试', book: book);
    await pumpUntil(tester, () => ai.calls == 1);
    // 请求体确为非流式；生成期间处于块时间线展示模式。
    expect(ai.streams, [false]);
    expect(provider.showTimeline, isTrue);

    // 第 1 帧：思考 + 状态工具（世界状态追加），无正文。
    gates[0].complete(
      AiCallResult(
        content: '',
        reasoningContent: '需要先维护世界状态。',
        toolCalls: const [
          AiToolCall(
            id: 'fc_1',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'append', 'newLine': '- 地点：青云宗'},
              ],
            },
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'r1',
      ),
    );
    // 第 1 帧回放 + 工具执行 → 第 2 帧（正文轮）请求发出。
    await pumpUntil(tester, () => ai.calls == 2);
    expect(ai.streams, [false, false]);
    // 思考块已上屏（按轮次展示，而不是等全部生成完）。
    final firstThinking = provider.agentEvents
        .where((e) => e.type == AgentEventType.thinking)
        .toList();
    expect(firstThinking, hasLength(1));
    expect(firstThinking.single.content, '需要先维护世界状态。');
    // 工具框执行过程中可见（工具轮已执行完，正文轮进行中）。
    expect(find.textContaining('Tool · narrchat_editSection'), findsWidgets);
    expect(provider.streamingContent, isEmpty, reason: '正文轮尚未返回');

    // 第 2 帧：正文 + 当前时间 + 补齐剩余状态工具（完整性通过，无修复轮）。
    gates[1].complete(
      const AiCallResult(
        content: '## 剧情演绎\n非流式正文\n\n## 推荐行动\n行动\n\n## 当前时间\n第一天 午时',
        reasoningContent: '根据世界状态写正文。',
        toolCalls: [
          AiToolCall(
            id: 'fc_2',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'memorySummary',
              'edits': [
                {
                  'op': 'append',
                  'newLine': '- 第1轮｜日期：第一天 午时｜主角登场',
                },
              ],
            },
          ),
          AiToolCall(
            id: 'fc_3',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'characterState',
              'edits': [
                {'op': 'noChange', 'reason': '主角状态本轮无变化'},
              ],
            },
          ),
        ],
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'r2',
      ),
    );
    // 回放仍在进行中：正文块应渐进出现（内容已开始上屏，尚未全部完成时
    // 结束状态也未恢复）。逐步推进定时器直至生成结束。
    await pumpUntil(
      tester,
      () => provider.streamingContent.isNotEmpty,
    );
    await pumpUntil(tester, () => !provider.isSending);
    expect(await future, isTrue);
    await waitSendDone(tester, provider);

    // 生成的第二轮：正文按「采纳帧」落库，未被复用正文污染；时间线复位。
    final round = provider.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('非流式正文'));
    expect(round.aiNarrative, isNot(contains('根据世界状态写正文')));
    expect(round.worldState, '- 地点：青云宗');
    expect(round.currentTime, '第一天 午时');
    expect(provider.showTimeline, isFalse);
  });

  testWidgets('联网搜索（Chat 协议）非流式：搜索过程 → 结果实时展示，正文按轮次出现', (
    tester,
  ) async {
    final gates = [Completer<AiCallResult>(), Completer<AiCallResult>()];
    final ai = _GatedChatService(gates);
    final searchGate = Completer<void>();
    final searchService = _GatedSearchService(searchGate);
    final settings = ChatCompatibleSettings();
    // 非流式 + 联网搜索（记忆值同步生效，持久化在 FakeAsync 下不等待）。
    settings.setPerRoundOptions(thinking: true, streaming: false, search: true);
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      bookDao: FakeBookDao(books: [book]),
      settings: settings,
      aiSettingsProvider: settings,
      searchService: searchService,
      nonStreamReplayer: const NonStreamReplayer(
        tickInterval: Duration(milliseconds: 10),
        charsPerTick: 100,
      ),
    );

    final future = provider.sendRound(userInput: '搜索洛天依资料', book: book);
    await pumpUntil(tester, () => ai.calls == 1);

    // 第 1 帧：思考 + 搜索工具调用（无正文）。
    gates[0].complete(
      AiCallResult(
        content: '',
        reasoningContent: '需要先搜索洛天依的资料。',
        toolCalls: const [
          AiToolCall(
            id: 'fc_1',
            name: 'narrchat_webSearch',
            arguments: {'query': '洛天依'},
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
      ),
    );
    // 回放完成 → 搜索工具开始执行（被门控挂起）→ 搜索框实时展示「进行中」。
    await pumpUntil(tester, () => searchService.started);
    await tester.pump();
    expect(find.textContaining('正在搜索'), findsWidgets);
    expect(provider.streamingContent, isEmpty);

    // 搜索完成：结果（1 条）实时展示。
    searchGate.complete();
    await pumpUntil(tester, () => ai.calls == 2);
    expect(ai.streams, [false, false]);
    await tester.pump();
    expect(find.textContaining('1 条结果'), findsWidgets);

    // 第 2 帧：最终正文（无工具调用）。
    gates[1].complete(
      const AiCallResult(
        content: '## 剧情演绎\n搜索后的正文\n\n## 推荐行动\nx',
        reasoningContent: '根据搜索结果写正文。',
        promptTokens: 2,
        completionTokens: 2,
      ),
    );
    await pumpUntil(tester, () => !provider.isSending);
    expect(await future, isTrue);
    await waitSendDone(tester, provider);

    final round = provider.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('搜索后的正文'));
    expect(round.aiNarrative, isNot(contains('根据搜索结果写正文')));
  });

  testWidgets('AGENT 非流式：回放期间取消，立即终止并保留失败条目', (tester) async {
    final gates = [Completer<AiCallResult>()];
    final ai = _GatedResponsesService(gates);
    final settings = AiSettingsProvider();
    settings.setPerRoundOptions(thinking: true, streaming: false);
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      bookDao: FakeBookDao(books: [book]),
      settings: settings,
      aiSettingsProvider: settings,
      // AGENT 模式由实验性开关驱动（与平台协议正交）。
      experimentalSettings: AgentModeSettings(),
      nonStreamReplayer: const NonStreamReplayer(
        tickInterval: Duration(milliseconds: 20),
        charsPerTick: 2,
      ),
    );

    final future = provider.sendRound(userInput: '测试', book: book);
    await pumpUntil(tester, () => ai.calls == 1);

    // 返回一大段思考（回放需要多个 tick），完成门控后立即取消。
    gates[0].complete(
      AiCallResult(
        content: '',
        reasoningContent: '这是一个很长的思考过程。' * 10,
        toolCalls: const [
          AiToolCall(
            id: 'fc_1',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'noChange', 'reason': '本轮未涉及世界设定'},
              ],
            },
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'r1',
      ),
    );
    await pumpUntil(tester, () => provider.agentEvents.isNotEmpty);
    provider.cancelGeneration();
    await pumpUntil(tester, () => !provider.isSending);

    expect(await future, isFalse);
    expect(provider.failedAttempt.isEmpty, isFalse, reason: '取消应保留失败条目');
    expect(provider.rounds.where((r) => r.roundIndex == 1), isEmpty);
    await waitSendDone(tester, provider);
  });
}
