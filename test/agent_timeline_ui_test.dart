import 'dart:async';

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

/// 脚本化 responses 服务：按序返回 [AiCallResult]（第 2 帧由 Completer 门控，
/// 便于在「调用间隙」断言 UI 时间线）。
class _ScriptResponsesService extends AiService {
  _ScriptResponsesService(this.gates);

  final List<Completer<AiCallResult>> gates;
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
    final index = calls++;
    return gates[index].future;
  }
}

/// 帧节目录：流式增量 + 最终结果。
typedef _ScriptedFrame = ({List<AiStreamChunk> chunks, AiCallResult result});

/// 两帧流式服务：帧 1 同步流式后返回（可定制）；帧 2 先流式增量、再等待
/// 门控完成。
///
/// 用于断言「帧 2（修复/补充轮）重复输出的正文增量被丢弃、不上屏」等
/// 帧级正文门控行为。
class _GatedStreamResponsesService extends AiService {
  _GatedStreamResponsesService(this.frame2, {this.frame1});

  /// 帧 2 门控：帧 2 的流式增量发出后阻塞，直到测试放行。
  final Completer<void> frame2Gate = Completer<void>();

  /// 帧 1（缺省 = 正文 + 记忆 noChange 校验失败场景）。
  final _ScriptedFrame? frame1;

  /// 帧 2 流式增量与最终结果。
  final _ScriptedFrame frame2;
  int calls = 0;

  /// 缺省帧 1：正文 + 记忆 noChange（必然校验失败 → 修复轮）。
  static const _ScriptedFrame _defaultFrame1 = (
    chunks: [
      AiStreamChunk(contentDelta: '## 剧情演绎\n正文初稿\n\n## 推荐行动\n行动'),
      AiStreamChunk(toolCallId: 'fc_1', toolName: 'narrchat_editSection'),
      AiStreamChunk(
        toolCallId: 'fc_1',
        toolArgsDelta: '{"section":"memorySummary","edits":[{"op":"noChange"}]}',
      ),
    ],
    result: AiCallResult(
      content: '## 剧情演绎\n正文初稿\n\n## 推荐行动\n行动',
      toolCalls: [
        AiToolCall(
          id: 'fc_1',
          name: 'narrchat_editSection',
          arguments: {
            'section': 'memorySummary',
            'edits': [
              {'op': 'noChange'},
            ],
          },
        ),
      ],
      promptTokens: 1,
      completionTokens: 1,
      responseId: 'r1',
    ),
  );

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
    final index = calls++;
    if (index == 0) {
      final f = frame1 ?? _defaultFrame1;
      for (final c in f.chunks) {
        onChunk?.call(c);
      }
      // 帧结束（与真实流式服务一致：结束前发出 done 增量）。
      onChunk?.call(const AiStreamChunk(done: true));
      return f.result;
    }
    // 帧 2：先流式发出（应被门控丢弃的正文 / 开场白之后），
    // 然后阻塞到门控放行，便于在流式期间断言正文块未被污染。
    for (final c in frame2.chunks) {
      onChunk?.call(c);
    }
    await frame2Gate.future;
    onChunk?.call(const AiStreamChunk(done: true));
    return frame2.result;
  }
}

/// AGENT 模式 UI：聊天页「AGENT」徽标与状态工具时间线框。
///
/// 工具事件框在「调用间隙」可见（工具轮完成 → 正文轮进行中），
/// 因此用例走两帧流程：第 1 帧仅状态工具；第 2 帧产出正文。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  testWidgets('AGENT（默认平台）：摘要显示 AGENT；块按 AI 返回顺序（工具先行帧在正文上方）', (
    tester,
  ) async {
    final gates = [Completer<AiCallResult>(), Completer<AiCallResult>()];
    final ai = _ScriptResponsesService(gates);
    final bookDao = FakeBookDao(books: [book]);
    final settings = AiSettingsProvider();
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      bookDao: bookDao,
      settings: settings,
      aiSettingsProvider: settings,
    );

    // 默认平台协议 = Response API 兼容 → AGENT 徽标出现在模式摘要。
    expect(find.textContaining('AGENT'), findsWidgets);

    final future = provider.sendRound(userInput: '测试', book: book);
    for (var i = 0; i < 60 && ai.calls < 1; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ai.calls, 1, reason: '第 1 帧（工具轮）请求应已发出');

    // 第 1 帧：仅状态工具调用（无正文）。
    gates[0].complete(
      AiCallResult(
        content: '',
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
    // 等待：第 1 帧完成 → 工具执行 → 第 2 帧请求发出（正文轮进行中）。
    for (var i = 0; i < 60 && ai.calls < 2; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ai.calls, 2, reason: '应已发出第 2 帧（正文轮）请求');

    // 正文未开始时：工具结果框按「返回顺序」显示在正文上方（工具先到）。
    expect(find.textContaining('Tool · narrchat_editSection'), findsWidgets);

    // 第 2 帧：产出正文 + 补齐剩余状态工具，本轮完整结束。
    gates[1].complete(
      const AiCallResult(
        content: '## 剧情演绎\n主角踏门而入。\n\n## 推荐行动\n叩见掌门。',
        toolCalls: [
          AiToolCall(
            id: 'fc_2',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'memorySummary',
              'edits': [
                {
                  'op': 'append',
                  'newLine': '- 第1轮｜日期：第二天 午时｜主角踏门而入',
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
                {'op': 'noChange'},
              ],
            },
          ),
          AiToolCall(
            id: 'fc_4',
            name: 'narrchat_advanceTime',
            arguments: {'time': '第二天 午时'},
          ),
        ],
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'r2',
      ),
    );
    await future;
    await waitSendDone(tester, provider);
  });

  testWidgets('修复轮重复输出的正文增量被丢弃：正文块始终只有首帧正文', (tester) async {
    final frame2 = (
      chunks: const [
        AiStreamChunk(contentDelta: '## 剧情演绎\n重复正文（修复轮复读）\n\n## 推荐行动\n行动'),
      ],
      result: const AiCallResult(
        content: '## 剧情演绎\n重复正文（修复轮复读）\n\n## 推荐行动\n行动',
        toolCalls: [
          AiToolCall(
            id: 'fc_2',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'memorySummary',
              'edits': [
                {
                  'op': 'append',
                  'newLine': '- 第1轮｜日期：第二天 申时｜主角见到掌门',
                },
              ],
            },
          ),
          AiToolCall(
            id: 'fc_3',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'noChange'},
              ],
            },
          ),
          AiToolCall(
            id: 'fc_4',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'characterState',
              'edits': [
                {'op': 'noChange'},
              ],
            },
          ),
          AiToolCall(
            id: 'fc_5',
            name: 'narrchat_advanceTime',
            arguments: {'time': '第二天 申时'},
          ),
        ],
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'r2',
      ),
    );
    final ai = _GatedStreamResponsesService(frame2);
    final settings = AiSettingsProvider();
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      bookDao: FakeBookDao(books: [book]),
      settings: settings,
      aiSettingsProvider: settings,
    );

    final future = provider.sendRound(userInput: '测试', book: book);
    // 等待第 1 帧完成 → 工具执行 → 第 2 帧（修复轮）请求发出。
    for (var i = 0; i < 60 && ai.calls < 2; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ai.calls, 2, reason: '应已发出第 2 帧（修复轮）请求');
    // 帧 2 的正文增量已（同步）发出：正文块应保持首帧正文，未拼入重复正文。
    await tester.pump();
    expect(provider.streamingContent, contains('正文初稿'));
    expect(provider.streamingContent, isNot(contains('重复正文')));
    expect(find.textContaining('重复正文'), findsNothing);
    // 执行失败的工具块保持展开：校验失败原因（原状态工具框语义）直接可见；
    // 成功的工具块则收起为一行状态栏。
    expect(find.textContaining('Tool · narrchat_editSection'), findsOneWidget);
    expect(find.textContaining('不能声明 noChange'), findsWidgets);

    // 放行帧 2 并完成本轮：落库正文 = 首帧正文。
    ai.frame2Gate.complete();
    await future;
    await waitSendDone(tester, provider);
    final round = provider.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('正文初稿'));
    expect(round.aiNarrative, isNot(contains('重复正文')));
    expect(round.memorySummary, contains('第1轮'));
    expect(round.currentTime, '第二天 申时');
  });

  testWidgets('搜索开场白（无标题帧）不上屏也不阻塞：正文块只展示标题帧正文', (tester) async {
    // 帧 1：说明性开场白（无 ## 剧情演绎 标题）+ 状态工具（世界状态追加）。
    final frame1 = (
      chunks: const [
        AiStreamChunk(
          contentDelta:
              'I\'ll search for information about the two characters before writing the story.',
        ),
        AiStreamChunk(toolCallId: 'fc_1', toolName: 'narrchat_editSection'),
        AiStreamChunk(
          toolCallId: 'fc_1',
          toolArgsDelta:
              '{"section":"worldState","edits":[{"op":"append","newLine":"- 地点：灯会"}]}',
        ),
      ],
      result: const AiCallResult(
        content:
            'I\'ll search for information about the two characters before writing the story.',
        toolCalls: [
          AiToolCall(
            id: 'fc_1',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'append', 'newLine': '- 地点：灯会'},
              ],
            },
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'r1',
      ),
    );
    // 帧 2：标题帧（真正的正文）+ 剩余状态工具（完整性补齐）。
    final frame2 = (
      chunks: const [
        AiStreamChunk(contentDelta: '## 剧情演绎\n真正的正文\n\n## 推荐行动\nx'),
      ],
      result: const AiCallResult(
        content: '## 剧情演绎\n真正的正文\n\n## 推荐行动\nx',
        toolCalls: [
          AiToolCall(
            id: 'fc_2',
            name: 'narrchat_advanceTime',
            arguments: {'time': '第一天 深夜'},
          ),
          AiToolCall(
            id: 'fc_3',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'memorySummary',
              'edits': [
                {
                  'op': 'append',
                  'newLine': '- 第1轮｜日期：第一天 深夜｜观察到两人走入小巷',
                },
              ],
            },
          ),
          AiToolCall(
            id: 'fc_4',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'characterState',
              'edits': [
                {'op': 'noChange'},
              ],
            },
          ),
        ],
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'r2',
      ),
    );
    final ai = _GatedStreamResponsesService(frame2, frame1: frame1);
    final settings = AiSettingsProvider();
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      bookDao: FakeBookDao(books: [book]),
      settings: settings,
      aiSettingsProvider: settings,
    );

    final future = provider.sendRound(userInput: '搜索两人资料', book: book);
    // 等待帧 1（开场白）完成 → 工具执行 → 帧 2（标题帧）请求发出。
    for (var i = 0; i < 60 && ai.calls < 2; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ai.calls, 2, reason: '应已发出第 2 帧（标题帧）请求');
    // 帧 2 正文已（同步）流式发出：正文块 = 标题帧正文，开场白从未上屏。
    await tester.pump();
    expect(provider.streamingContent, contains('真正的正文'));
    expect(provider.streamingContent, isNot(contains("I'll search")));
    expect(find.textContaining("I'll search"), findsNothing);

    // 放行帧 2 并完成本轮：落库正文 = 标题帧正文；开场白帧工具照常生效。
    ai.frame2Gate.complete();
    await future;
    await waitSendDone(tester, provider);
    final round = provider.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('真正的正文'));
    expect(round.aiNarrative, isNot(contains("I'll search")));
    expect(round.worldState, '- 地点：灯会');
    expect(round.currentTime, '第一天 深夜');
  });

  testWidgets('联网搜索一次调用只产生一个 Tool 框（不再并存「联网搜索」活动框）', (
    tester,
  ) async {
    final settings = AiSettingsProvider();
    // 不 await：setPerRoundOptions 的本地配置写入在 testWidgets 的
    // FakeAsync 下不会完成，而思考/流式/搜索字段在 await 前已同步生效。
    settings.setPerRoundOptions(thinking: true, streaming: true, search: true);
    // 帧 1：仅搜索工具调用（流式预览 + 执行）；帧 2：正文 + 状态工具（门控）。
    final frame1 = (
      chunks: const [
        AiStreamChunk(toolCallId: 'fc_1', toolName: 'narrchat_webSearch'),
        AiStreamChunk(toolCallId: 'fc_1', toolArgsDelta: '{"query":"洛天依"}'),
      ],
      result: const AiCallResult(
        content: '',
        toolCalls: [
          AiToolCall(
            id: 'fc_1',
            name: 'narrchat_webSearch',
            arguments: {'query': '洛天依'},
          ),
        ],
        promptTokens: 1,
        completionTokens: 1,
        responseId: 'r1',
      ),
    );
    final frame2 = (
      chunks: const [
        AiStreamChunk(contentDelta: '## 剧情演绎\n查完资料后的正文\n\n## 推荐行动\nx'),
      ],
      result: const AiCallResult(
        content: '## 剧情演绎\n查完资料后的正文\n\n## 推荐行动\nx',
        toolCalls: [
          AiToolCall(
            id: 'fc_2',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'worldState',
              'edits': [
                {'op': 'noChange'},
              ],
            },
          ),
          AiToolCall(
            id: 'fc_3',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'characterState',
              'edits': [
                {'op': 'noChange'},
              ],
            },
          ),
          AiToolCall(
            id: 'fc_4',
            name: 'narrchat_editSection',
            arguments: {
              'section': 'memorySummary',
              'edits': [
                {
                  'op': 'append',
                  'newLine': '- 第1轮｜日期：第一天 午时｜搜集两人资料',
                },
              ],
            },
          ),
          AiToolCall(
            id: 'fc_5',
            name: 'narrchat_advanceTime',
            arguments: {'time': '第一天 午时'},
          ),
        ],
        promptTokens: 2,
        completionTokens: 2,
        responseId: 'r2',
      ),
    );
    final ai = _GatedStreamResponsesService(frame2, frame1: frame1);
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      bookDao: FakeBookDao(books: [book]),
      settings: settings,
      aiSettingsProvider: settings,
      webSearchTool: _StubWebSearchTool(),
    );

    final future = provider.sendRound(userInput: '搜索两人资料', book: book);
    // 帧 1（搜索）执行完成 → 帧 2（正文）请求发出后断言时间线。
    for (var i = 0; i < 60 && ai.calls < 2; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ai.calls, 2, reason: '应已发出第 2 帧（正文轮）请求');
    await tester.pump();
    // 一次搜索调用 = 一个 Tool 框：不再并存「联网搜索」活动框与「Tool · …」框。
    expect(find.textContaining('Tool · narrchat_webSearch'), findsOneWidget);
    expect(find.textContaining('联网搜索'), findsNothing);
    expect(find.textContaining('Tool · narrchat_webFetchPage'), findsNothing);

    ai.frame2Gate.complete();
    await future;
    await waitSendDone(tester, provider);
  });
}
