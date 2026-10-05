import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/fakes.dart';

/// 「按意见修改」（修改轮）的 Provider 行为测试。
///
/// 覆盖：同轮号新增一代（旧代保留）/ 历史 = 被修改轮生成时收到的 n 轮 + 该轮自身
/// （n+1）/ Agent 工具读到的状态与记忆停在**上一轮** / 新版本沿用原输入与原图
/// （意见不落库）/ 后续轮次随旧代从视图隐藏 / 失败按「重新生成」规则写失败条目 /
/// 空意见拒绝。
void main() {
  /// 内存 Provider（fake 版本树，绝不触碰真实数据库）。
  (RoundProvider, FakeRoundDao, FakeRoundStackService) build({
    required Book book,
    AiService? ai,
    AiSettingsProvider? settings,
  }) {
    final dao = FakeRoundDao();
    final stack = FakeRoundStackService(roundDao: dao);
    final provider = RoundProvider(
      dao: dao,
      roundStackService: stack,
      bookDao: FakeBookDao(books: [book]),
      aiService: ai ?? ToggleAiService(),
      aiSettingsProvider: settings,
      retryDelay: Duration.zero,
    );
    return (provider, dao, stack);
  }

  /// 直接预置轮次（绕开生成，便于构造各异的历史 / 记忆内容）。
  Future<void> seed(FakeRoundDao dao, List<Round> rounds) async {
    for (final r in rounds) {
      await dao.insertRound(r);
    }
  }

  Round roundOf(FakeRoundDao dao, int roundIndex) =>
      dao.rounds.firstWhere((r) => r.roundIndex == roundIndex);

  /// Chat 线路请求体的 messages（RAW 记录 = 实发报文，与预览同源）。
  List<Map<String, dynamic>> messagesOf(
    RoundProvider provider,
    int roundId,
  ) {
    final raw = provider.rawExchangesFor(roundId)!.single.requestBody;
    final body = jsonDecode(raw) as Map<String, dynamic>;
    return (body['messages'] as List).cast<Map<String, dynamic>>();
  }

  String textOf(Map<String, dynamic> message) {
    final content = message['content'];
    if (content is String) return content;
    return jsonEncode(content);
  }

  group('Chat：同轮新增一代 + n+1 历史', () {
    // historyRounds = 2 → 修改第 4 轮应提交「第 2、3 轮 + 第 4 轮自身」，不含第 1 轮。
    const book = Book(uuid: 'b1', title: '测试书', historyRounds: 2);

    test('修改轮：历史 = n 轮 + 被修改轮自身；同轮号新增一代且沿用原输入 / 原图', () async {
      final (provider, dao, stack) = build(
        book: book,
        settings: ChatCompatibleSettings(),
      );
      await provider.loadRounds('b1');
      for (final input in const ['第 1 轮输入', '第 2 轮输入', '第 3 轮输入', '第 4 轮输入']) {
        expect(
          await provider.sendRound(
            userInput: input,
            book: book,
            userImages: const ['img/round.png'],
          ),
          isTrue,
        );
      }
      final target = roundOf(dao, 4);
      final attachesBefore = stack.attachCalls;

      final ok = await provider.modifyRoundByOpinion(
        target,
        '把第 4 轮写紧凑些',
        book: book,
        // 意见附图仅进本次请求，不落库。
        images: const ['img/opinion.png'],
      );

      expect(ok, isTrue);
      // 同轮号**新增一代**（版本树多一行），旧代保留可切回。
      expect(stack.attachCalls, attachesBefore + 1);
      expect(provider.rounds.map((r) => r.roundIndex).toList(), [0, 1, 2, 3, 4]);
      final updated = provider.rounds.last;
      expect(updated.roundIndex, 4);
      expect(updated.aiNarrative, contains('成功正文'));
      // 新版本与修改前一致：原输入 + 原图（意见不落库）。
      expect(updated.userInput, '第 4 轮输入');
      expect(updated.userImages, const ['img/round.png']);

      // —— 请求体：n+1 = 第 2、3 轮 + 第 4 轮自身 ——
      final messages = messagesOf(provider, updated.id!);
      final texts = [for (final m in messages) textOf(m)];
      final joined = texts.join('\n');
      expect(joined, contains('第 2 轮输入'));
      expect(joined, contains('第 3 轮输入'));
      expect(joined, contains('第 4 轮输入'), reason: '被修改轮自身也要作为历史提交');
      expect(joined, isNot(contains('第 1 轮输入')), reason: 'n = 2，更早的第 1 轮不进上下文');
      // 顺序：越晚的轮次越靠后，末条 = 修改轮注入。
      final last = texts.last;
      expect(last, contains('重写第 4 轮：'));
      expect(last, contains('- 此轮时间：第一天 午时'));
      expect(last, contains('把第 4 轮写紧凑些'));
      expect(last, isNot(contains('创作第')));
      expect(
        texts.indexWhere((t) => t.contains('第 2 轮输入')),
        lessThan(texts.indexWhere((t) => t.contains('第 3 轮输入'))),
      );
      expect(
        texts.indexWhere((t) => t.contains('第 3 轮输入')),
        lessThan(texts.indexWhere((t) => t.contains('第 4 轮输入'))),
      );
    });

    test('修改中间轮：该轮起的投影行被删（后续轮次随旧代一起隐藏）', () async {
      final (provider, dao, stack) = build(
        book: book,
        settings: ChatCompatibleSettings(),
      );
      await provider.loadRounds('b1');
      for (final input in const ['A', 'B', 'C']) {
        await provider.sendRound(userInput: input, book: book);
      }
      expect(provider.rounds.map((r) => r.roundIndex).toList(), [0, 1, 2, 3]);

      final ok = await provider.modifyRoundByOpinion(
        roundOf(dao, 2),
        '重写得更紧凑',
        book: book,
      );

      expect(ok, isTrue);
      // 第 3 轮从视图消失（内容仍在版本树：分支模型的既定语义，与「刷新本轮」一致）。
      expect(provider.rounds.map((r) => r.roundIndex).toList(), [0, 1, 2]);
      expect(stack.projectionDeletes.last.fromRoundIndex, 2);
      expect(roundOf(dao, 2).aiNarrative, contains('成功正文'));
    });

    test('意见为空：拒绝生成（不删投影行、不发请求、轮次不变）', () async {
      final (provider, dao, stack) = build(
        book: book,
        settings: ChatCompatibleSettings(),
      );
      await provider.loadRounds('b1');
      await provider.sendRound(userInput: '原输入', book: book);
      final target = roundOf(dao, 1);

      final ok = await provider.modifyRoundByOpinion(target, '   ', book: book);

      expect(ok, isFalse);
      expect(stack.projectionDeletes, isEmpty);
      expect(stack.attachCalls, 1, reason: '只有首次生成那一代');
      expect(provider.rounds.map((r) => r.roundIndex).toList(), [0, 1]);
      expect(roundOf(dao, 1).userInput, '原输入');
    });

    test('修改失败：按重新生成规则写失败条目（该轮原输入 + 原图）', () async {
      final ai = ToggleAiService()..fail = true;
      final (provider, dao, _) = build(
        book: book,
        ai: ai,
        settings: ChatCompatibleSettings(),
      );
      await seed(dao, [
        const Round(
          id: 1,
          bookUuid: 'b1',
          roundIndex: 1,
          userInput: '第 1 轮输入',
          aiNarrative: '第 1 轮正文',
          userImages: ['img/old.png'],
        ),
      ]);
      await provider.loadRounds('b1');

      final ok = await provider.modifyRoundByOpinion(
        roundOf(dao, 1),
        '改一下',
        book: book,
        images: const ['img/new.png'],
      );

      expect(ok, isFalse);
      expect(provider.hasFailureEntry, isTrue);
      // 失败条目与「刷新本轮 / 重新提问」同规则：保留该轮**原**输入与原图，
      // 重试即重刷该轮；意见只留在失败尝试的 RAW 里。
      expect(provider.failedAttempt.userInput, '第 1 轮输入');
      expect(provider.failedAttempt.userImages, const ['img/old.png']);
      expect(provider.nextRoundIndex, 1, reason: '投影已截断，失败条目「本该产生第 1 轮」');
    });
  });

  group('Agent：工具读取停在上一轮', () {
    const book = Book(
      uuid: 'b1',
      title: '测试书',
      historyRounds: 1,
      roleCategories: [RoleCategory(name: '主角', format: '- 气血：')],
    );

    http.Response sse(List<String> lines) => http.Response.bytes(
          utf8.encode(lines.join('\n')),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );

    String textDelta(String text) => 'data: ${jsonEncode({
          'type': 'response.output_text.delta',
          'delta': text,
        })}';

    String callAdded(String id, String name) => 'data: ${jsonEncode({
          'type': 'response.output_item.added',
          'item': {'type': 'function_call', 'id': id, 'name': name},
        })}';

    String callArgs(String id, Map<String, dynamic> arguments) =>
        'data: ${jsonEncode({
          'type': 'response.function_call_arguments.delta',
          'item_id': id,
          'delta': jsonEncode(arguments),
        })}';

    String completed(String id) => 'data: ${jsonEncode({
          'type': 'response.completed',
          'response': {
            'id': id,
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          },
        })}';

    List<String> editLines(
      String id,
      AgentStateSection section,
      List<Map<String, dynamic>> edits,
    ) =>
        [
          callAdded(id, agentEditToolName(section)),
          callArgs(id, {'edits': edits}),
        ];

    test('Lv.2 修改第 3 轮：历史 = 第 2 轮 + 第 3 轮，读史工具返回第 2 轮记忆，新条目记第 3 轮', () async {
      final dao = FakeRoundDao();
      await seed(dao, const [
        Round(
          id: 1,
          bookUuid: 'b1',
          roundIndex: 1,
          userInput: 'ROUND-ONE-INPUT',
          aiNarrative: '第一轮正文',
          worldState: '- 地点：山下',
          characterState: '# 主角\n## 林远\n- 气血：90',
          memorySummary: '- 1 | 第一天 | 事件一。',
          currentTime: '第一天',
        ),
        Round(
          id: 2,
          bookUuid: 'b1',
          roundIndex: 2,
          userInput: 'ROUND-TWO-INPUT',
          aiNarrative: '第二轮正文',
          worldState: '- 地点：山门',
          characterState: '# 主角\n## 林远\n- 气血：95',
          memorySummary: '- 1 | 第一天 | 事件一。\n- 2 | 第二天 | 事件二。',
          currentTime: '第二天 午时',
        ),
        Round(
          id: 3,
          bookUuid: 'b1',
          roundIndex: 3,
          userInput: 'ROUND-THREE-INPUT',
          aiNarrative: '第三轮正文',
          worldState: '- 地点：大殿',
          characterState: '# 主角\n## 林远\n- 气血：80',
          memorySummary: '- 1 | 第一天 | 事件一。\n- 2 | 第二天 | 事件二。\n'
              '- 3 | 第三天 | 事件三。',
          currentTime: '第三天 午时',
        ),
      ]);
      final bodies = <Map<String, dynamic>>[];
      final ai = AiService(
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          if (bodies.length == 1) {
            // 帧 1：只读史（读取器）——应用侧此刻只有「上一轮」的状态。
            return sse([
              callAdded('fc_read', 'narrchat_readHistory'),
              callArgs('fc_read', {'round': 3}),
              completed('resp_1'),
              '',
            ]);
          }
          // 帧 2：正文 + 三栏闭环（世界 / 角色声明无变化，历史追加本轮条目）。
          return sse([
            textDelta('## 剧情演绎\n重写后的正文。\n\n## 推荐行动\n继续。\n'
                '\n## 当前时间\n第三天 午时'),
            ...editLines('fc_1', AgentStateSection.worldState, [
              {'op': 'noChange', 'reason': '世界状态本轮未变化'},
            ]),
            ...editLines('fc_2', AgentStateSection.characterState, [
              {'op': 'noChange', 'reason': '角色状态本轮未变化'},
            ]),
            ...editLines('fc_3', AgentStateSection.memorySummary, [
              {'op': 'append', 'newLine': '- 3 | 第三天 午时 | 重写后的事件。'},
            ]),
            completed('resp_2'),
            '',
          ]);
        }),
      );
      final provider = RoundProvider(
        dao: dao,
        roundStackService: FakeRoundStackService(roundDao: dao),
        bookDao: FakeBookDao(books: [book]),
        aiService: ai,
        aiSettingsProvider: AiSettingsProvider(),
        experimentalSettings: AgentModeSettings(),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');

      final ok = await provider.modifyRoundByOpinion(
        roundOf(dao, 3),
        '按主人意见重写：节奏加快',
        book: book,
      );

      expect(ok, isTrue);
      expect(bodies, hasLength(2));

      // 首帧：n(=1) 轮历史 + 被修改轮自身（第 3 轮）——不含第 1 轮。
      final first = jsonEncode(bodies.first);
      expect(first, contains('ROUND-TWO-INPUT'));
      expect(first, contains('ROUND-THREE-INPUT'));
      expect(first, isNot(contains('ROUND-ONE-INPUT')));
      expect(first, contains('重写第 3 轮：'));
      expect(first, contains('按主人意见重写：节奏加快'));
      expect(first, contains('此轮时间：第三天 午时'));
      // Lv.2 历史每轮只带正文三小节：被修改轮的记忆**只能**来自工具。
      expect(first, isNot(contains('事件三')));

      // 第 2 帧：读史工具回传的 <memorySummary> = **上一轮（第 2 轮）**的内容。
      final outputs = [
        for (final item in (bodies[1]['input'] as List).cast<Map<String, dynamic>>())
          if (item['type'] == 'function_call_output') '${item['output']}',
      ];
      expect(outputs, hasLength(1));
      expect(outputs.single, contains('<memorySummary>'));
      expect(outputs.single, contains('- 2 | 第二天 | 事件二。'));
      expect(outputs.single, isNot(contains('- 3 |')));

      // 落库：同轮号第 3 轮新增一代，记忆条目按被修改轮号追加（基座 = 第 2 轮记忆）。
      final updated = roundOf(dao, 3);
      expect(updated.aiNarrative, contains('重写后的正文'));
      expect(updated.userInput, 'ROUND-THREE-INPUT');
      expect(updated.memorySummary, contains('- 2 | 第二天 | 事件二。'));
      expect(updated.memorySummary, contains('- 3 | 第三天 午时 | 重写后的事件。'));
      expect(updated.memorySummary, isNot(contains('事件三。')));
      expect(provider.agentWarnings, isEmpty);
      expect(provider.rounds.last.roundIndex, 3);
    });

    test('Lv.1 修改第 3 轮：调研读到的历史 = 上一轮；记忆条目按第 3 轮落地、正文 5 区块落该轮', () async {
      final dao = FakeRoundDao();
      await seed(dao, const [
        Round(
          id: 1,
          bookUuid: 'b1',
          roundIndex: 1,
          userInput: 'ROUND-ONE-INPUT',
          aiNarrative: '第一轮正文',
          memorySummary: '- 1 | 第一天 | 事件一。',
          currentTime: '第一天',
        ),
        Round(
          id: 2,
          bookUuid: 'b1',
          roundIndex: 2,
          userInput: 'ROUND-TWO-INPUT',
          aiNarrative: '第二轮正文',
          memorySummary: '- 1 | 第一天 | 事件一。\n- 2 | 第二天 | 事件二。',
          currentTime: '第二天 午时',
        ),
        Round(
          id: 3,
          bookUuid: 'b1',
          roundIndex: 3,
          userInput: 'ROUND-THREE-INPUT',
          aiNarrative: '第三轮正文',
          memorySummary: '- 1 | 第一天 | 事件一。\n- 2 | 第二天 | 事件二。\n'
              '- 3 | 第三天 | 事件三。',
          currentTime: '第三天 午时',
        ),
      ]);
      final bodies = <Map<String, dynamic>>[];
      final ai = AiService(
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          switch (bodies.length) {
            // 帧 1 = 调研：读史一次（返回值 = 上一轮 = 第 2 轮的记忆）。
            case 1:
              return sse([
                callAdded('r1', 'narrchat_readHistory'),
                callArgs('r1', {'round': 3}),
                completed('resp_r'),
                '',
              ]);
            // 帧 2 = 记忆：同回合推演 + 被重写轮（第 3 轮）条目落地。
            case 2:
              return sse([
                ...editLines('h1', AgentStateSection.memorySummary, [
                  {'op': 'append', 'newLine': '- 3 | 第三天 午时 | 重写后的事件。'},
                ]),
                completed('resp_h'),
                '',
              ]);
            // 帧 3 = 正文：Lv.1 的 5 区块（世界 / 角色 / 时间随正文携带）。
            default:
              return sse([
                textDelta('## 剧情演绎\n重写后的正文。\n\n## 推荐行动\n继续赶路\n\n'
                    '## 当前时间\n第三天 午时\n\n## 世界状态\n- 地点：大殿\n\n'
                    '## 角色状态\n# 主角\n## 林远\n- 气血：70'),
                completed('resp_s'),
                '',
              ]);
          }
        }),
      );
      final provider = RoundProvider(
        dao: dao,
        roundStackService: FakeRoundStackService(roundDao: dao),
        bookDao: FakeBookDao(books: [book]),
        aiService: ai,
        aiSettingsProvider: AiSettingsProvider(),
        experimentalSettings: AgentModeSettings(level: AgentModeLevel.lv1),
        retryDelay: Duration.zero,
      );
      await provider.loadRounds('b1');

      final ok = await provider.modifyRoundByOpinion(
        roundOf(dao, 3),
        '加大冲突',
        book: book,
      );

      expect(ok, isTrue);
      // 合规一轮仍是 3 帧（调研 → 记忆 → 正文，零额外请求）——轮号错位会多出补帧。
      expect(bodies, hasLength(3), reason: '被重写轮号必须喂对，否则记忆阶段不会闭环');

      final first = jsonEncode(bodies.first);
      expect(first, contains('ROUND-TWO-INPUT'));
      expect(first, contains('ROUND-THREE-INPUT'));
      expect(first, isNot(contains('ROUND-ONE-INPUT')));
      expect(first, contains('重写第 3 轮：'));
      expect(first, contains('加大冲突'));

      // 调研帧拿到的 <memorySummary> = 上一轮（第 2 轮）的内容。
      final outputs = [
        for (final item in (bodies[1]['input'] as List).cast<Map<String, dynamic>>())
          if (item['type'] == 'function_call_output') '${item['output']}',
      ];
      expect(outputs.single, contains('- 2 | 第二天 | 事件二。'));
      expect(outputs.single, isNot(contains('- 3 |')));

      final updated = roundOf(dao, 3);
      expect(updated.roundIndex, 3);
      expect(updated.userInput, 'ROUND-THREE-INPUT');
      expect(updated.aiNarrative, contains('重写后的正文'));
      expect(updated.worldState, '- 地点：大殿');
      expect(updated.characterState, contains('- 气血：70'));
      expect(updated.currentTime, '第三天 午时');
      expect(updated.memorySummary, contains('- 2 | 第二天 | 事件二。'));
      expect(updated.memorySummary, contains('- 3 | 第三天 午时 | 重写后的事件。'));
      expect(updated.memorySummary, isNot(contains('事件三。')));
      expect(provider.agentWarnings, isEmpty);
    });
  });
}
