import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/failed_attempt.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/round_stack.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 「代级提示」（`round_stack.message` / `message_status`）的行为测试。
///
/// 覆盖：生成警告随代入库（warning）、失败占位代（error）与 `books.failed_*` 双写、
/// 关闭提示触发同步、提示随代（切换 / 删除）而行、UI 三态展示。
void main() {
  const book = Book(
    uuid: 'b1',
    title: '测试书',
    category: '玄幻',
    baseSetting: '北域修仙世界。',
    historyRounds: 2,
    roleCategories: [RoleCategory(name: '主角', format: '- 气血：')],
  );

  http.Response sse(List<String> lines) => http.Response.bytes(
        utf8.encode(lines.join('\n')),
        200,
        headers: {'content-type': 'text/event-stream; charset=utf-8'},
      );

  /// 每帧只回文本 + 完成：状态轮空手帧不再止损 → 直到帧数上限，
  /// 缺项转常驻提示（与 agent_round_test 同夹具思路）。
  List<String> unappliedSse(int calls) => [
        'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n正文。\\n\\n## 推荐行动\\n行动"}',
        'data: {"type":"response.completed","response":{"id":"r$calls","usage":{"input_tokens":1,"output_tokens":1}}}',
        '',
      ];

  ({RoundProvider provider, FakeRoundDao dao, FakeRoundStackService stack,
    FakeCloudSyncProvider cloud, FakeBookDao bookDao}) build({
    AiService? ai,
    FakeRoundDao? roundDao,
    FakeBookDao? bookDao,
  }) {
    final dao = roundDao ?? FakeRoundDao();
    final stack = FakeRoundStackService(roundDao: dao);
    final books = bookDao ?? FakeBookDao();
    final cloud = FakeCloudSyncProvider();
    final rp = RoundProvider(
      dao: dao,
      roundStackService: stack,
      bookDao: books,
      aiService: ai ?? ToggleAiService(),
      aiSettingsProvider: AiSettingsProvider(),
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      cloudSyncProvider: cloud,
      retryDelay: Duration.zero,
    );
    return (
      provider: rp,
      dao: dao,
      stack: stack,
      cloud: cloud,
      bookDao: books,
    );
  }

  /// 该书的「真代」行（不含失败占位代）。
  List<RoundStackRow> aliveRows(FakeRoundStackService stack) =>
      [for (final row in stack.rows['b1'] ?? const []) if (!row.isFailed) row];

  /// 成功一轮 AGENT（状态缺项 → 常驻提示）的公共夹具。
  Future<
      ({
        RoundProvider provider,
        FakeRoundDao dao,
        FakeRoundStackService stack,
        FakeCloudSyncProvider cloud,
        FakeBookDao bookDao,
      })> runWarnedRound() async {
    var calls = 0;
    final env = build(
      ai: AiService(client: MockClient((request) async => sse(unappliedSse(++calls)))),
    );
    await env.provider.loadRounds('b1');
    expect(await env.provider.sendRound(userInput: '开始', book: book), isTrue);
    return env;
  }

  test('生成警告 → 落到本轮那一代的 message（warning 级）', () async {
    final env = await runWarnedRound();

    expect(env.provider.roundWarningsFor(1), contains('世界状态本轮未更新'));
    final row = aliveRows(env.stack).singleWhere((r) => r.roundIndex == 1);
    expect(row.message, contains('世界状态本轮未更新'));
    expect(row.messageStatus, 'warning');
    expect(row.isUse, isTrue, reason: '提示挂在当前应用代上');
    // 提示不是内容：`rounds` 投影行与 round_stack 的内容列保持同构（无提示字段）。
    final round = env.dao.rounds.singleWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('正文。'));
    expect(round.useStackUuid, row.uuid);
  });

  test('「重启」后提示仍在（库是唯一来源，无本地副本）', () async {
    final env = await runWarnedRound();

    // 冷启动：同一内存版本树 + 同一轮次表，新 Provider 重新加载。
    final restarted = build(
      roundDao: env.dao,
      bookDao: env.bookDao,
      ai: AiService(client: MockClient((request) async => sse(unappliedSse(1)))),
    );
    restarted.stack.rows['b1'] = env.stack.rows['b1']!;
    await restarted.provider.loadRounds('b1');
    expect(restarted.provider.roundWarningsFor(1), contains('世界状态本轮未更新'));
  });

  test('手动关闭 → 该代 message 清空，并触发一次自动同步', () async {
    final env = await runWarnedRound();
    expect(env.cloud.triggers, 1, reason: '生成结束已触发一次');

    await env.provider.dismissRoundWarnings(1);

    expect(env.provider.roundWarningsFor(1), isEmpty);
    final row = aliveRows(env.stack).singleWhere((r) => r.roundIndex == 1);
    expect(row.message, isEmpty);
    expect(row.messageStatus, isNull);
    expect(env.cloud.triggers, 2, reason: '关闭提示是轮次部件的真实变化，必须推送');

    // 关闭后重启不复活（库里已经没有了）。
    final restarted = build(roundDao: env.dao, bookDao: env.bookDao);
    restarted.stack.rows['b1'] = env.stack.rows['b1']!;
    await restarted.provider.loadRounds('b1');
    expect(restarted.provider.roundWarningsFor(1), isEmpty);
  });

  test('失败：失败占位代（error 级）与 books.failed_* 双写，清除后两处一起消失', () async {
    final env = build(ai: ToggleAiService()..fail = true);
    await env.provider.loadRounds('b1');

    expect(await env.provider.sendRound(userInput: '失败轮', book: book), isFalse);

    // 双写①：books.failed_*（旧语义 + 老版本兼容）。
    expect(env.provider.hasFailureEntry, isTrue);
    expect(env.bookDao.failed.userInput, '失败轮');
    // 双写②：round_stack 的失败占位代（提示的新版权威载体）。
    final failure = (env.stack.rows['b1'] ?? const [])
        .singleWhere((row) => row.isFailed);
    expect(failure.roundIndex, 1);
    expect(failure.messageStatus, 'error');
    expect(failure.message, isNotEmpty);
    expect(failure.isUse, isFalse, reason: '失败占位代绝不参与活动链');
    // 失败占位代不进代次索引（不显示为可切换的一代）。
    final index = await env.stack.loadIndex('b1');
    expect(index.infoFor(1, fatherUuid: null, currentUuid: null), isNull);

    await env.provider.clearFailedAttempt();

    expect(env.provider.hasFailureEntry, isFalse);
    expect(env.provider.failureMessageLines, isEmpty);
    expect(
      (env.stack.rows['b1'] ?? const []).any((row) => row.isFailed),
      isFalse,
    );
    expect(env.cloud.triggers, 2, reason: '清除失败条目同样要推送（生成一次 + 清除一次）');
  });

  test('失败占位代的提示 = 失败原因 + 本轮过程警告（合并为一条 error 提示）', () async {
    // 首次请求：AGENT 只回工具调用 → 整轮无正文 → 判失败（并带上「状态改动已作废」）；
    // 第二次请求：正常回正文 → 成功（用于验证「新请求开始即清除失败态」）。
    var failFirst = true;
    final env = build(
      ai: AiService(
        client: MockClient((request) async {
          if (!failFirst) return sse(unappliedSse(1));
          return sse([
            'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","name":"narrchat_editWorldState"}}',
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 地点：荒原\\"}]}"}',
            'data: {"type":"response.completed","response":{"id":"r1","usage":{"input_tokens":1,"output_tokens":1}}}',
            '',
          ]);
        }),
      ),
    );
    await env.provider.loadRounds('b1');

    expect(await env.provider.sendRound(userInput: '只调工具', book: book), isFalse);

    final lines = env.provider.failureMessageLines;
    expect(lines.any((l) => l.contains('未产出正文')), isTrue, reason: '失败原因');
    expect(lines.any((l) => l.contains('状态改动已作废')), isTrue,
        reason: '本轮过程警告并入同一条提示');
    final failure = (env.stack.rows['b1'] ?? const [])
        .singleWhere((row) => row.isFailed);
    expect(failure.message, env.provider.failureMessageLines.join('\n'));

    // 新请求开始即清除失败态（与 books.failed_* 同一时机，符合原版行为）。
    failFirst = false;
    expect(await env.provider.sendRound(userInput: '再来', book: book), isTrue);
    expect(
      (env.stack.rows['b1'] ?? const []).any((row) => row.isFailed),
      isFalse,
    );
    expect(env.provider.hasFailureEntry, isFalse);
  });

  test('删除轮次 → 该轮的提示随行消失', () async {
    final env = await runWarnedRound();
    final round = env.dao.rounds.singleWhere((r) => r.roundIndex == 1);

    await env.provider.deleteRound(round, deleteFollowing: true);

    expect(env.provider.roundWarningsFor(1), isEmpty);
    expect(aliveRows(env.stack).where((r) => r.roundIndex == 1), isEmpty);
  });

  test('提示跟随「当前应用代」：换成另一代即换成那一代的提示', () async {
    final dao = FakeRoundDao();
    final stack = FakeRoundStackService(roundDao: dao);
    // 第 1 轮两代：g-old 是旧一代（带旧提示），g-new 是当前代（带新提示）。
    stack.rows['b1'] = [
      const RoundStackRow(
        uuid: 'g-old',
        bookUuid: 'b1',
        roundIndex: 1,
        roundSerialNum: 1,
        message: '旧提示',
        messageStatus: 'warning',
      ),
      const RoundStackRow(
        uuid: 'g-new',
        bookUuid: 'b1',
        roundIndex: 1,
        roundSerialNum: 2,
        roundState: 'use',
        message: '新提示',
        messageStatus: 'warning',
      ),
    ];
    final inserted = await dao.insertRound(
      Round(
        bookUuid: 'b1',
        roundIndex: 1,
        aiNarrative: '正文',
        useStackUuid: 'g-new',
        createdAt: DateTime.now(),
      ),
    );
    final env = build(roundDao: dao);
    env.stack.rows['b1'] = stack.rows['b1']!;
    await env.provider.loadRounds('b1');
    expect(env.provider.roundWarningsFor(1), ['新提示']);

    // 切回旧一代（投影锚点改指 g-old）→ 看到的是那一代自己的提示。
    await dao.updateRoundFields(inserted, {'use_stack_uuid': 'g-old'});
    await env.provider.loadRounds('b1');
    expect(env.provider.roundWarningsFor(1), ['旧提示']);
  });

  test('提示写入归一化：超长截断、无提示不写键（老库 / 老备份兼容）', () {
    final long = '提' * (RoundStackRow.maxMessageLength + 50);
    final map = RoundStackRow(
      uuid: 'g1',
      bookUuid: 'b1',
      roundIndex: 1,
      roundSerialNum: 1,
      message: long,
      messageStatus: 'warning',
    ).toMap();
    final written = map['message']! as String;
    expect(written.length, RoundStackRow.maxMessageLength + 1, reason: '截断后带省略号');
    expect(written.endsWith('…'), isTrue);
    expect(map['message_status'], 'warning');

    // 无提示时不写这两个键：对「没有这两列」的老库 / 老备份写入不会报 no column，
    // 而先清后插 / INSERT OR REPLACE 时缺列取默认值 = 提示被清空（期望语义）。
    final empty = RoundStackRow(
      uuid: 'g2',
      bookUuid: 'b1',
      roundIndex: 1,
      roundSerialNum: 1,
    ).toMap();
    expect(empty.containsKey('message'), isFalse);
    expect(empty.containsKey('message_status'), isFalse);

    // 只有文本没有级别：按「无级别」写（读时渲染为中性）。
    final noStatus = RoundStackRow(
      uuid: 'g3',
      bookUuid: 'b1',
      roundIndex: 1,
      roundSerialNum: 1,
      message: '提示',
    ).toMap();
    expect(noStatus['message'], '提示');
    expect(noStatus.containsKey('message_status'), isFalse);
  });

  testWidgets('库内提示在对话页展示（warning 黄色框），可手动关闭', (tester) async {
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        userInput: '第一轮',
        aiNarrative: '正文',
        useStackUuid: 'g1',
        createdAt: DateTime.now(),
      ),
    );
    final stack = FakeRoundStackService(roundDao: dao);
    stack.rows[kHarnessBookUuid] = [
      const RoundStackRow(
        uuid: 'g1',
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        roundSerialNum: 1,
        roundState: 'use',
        message: '世界状态本轮未更新',
        messageStatus: 'warning',
      ),
    ];

    final provider = await pumpChatScreen(
      tester,
      seedRounds: 0,
      roundDao: dao,
      roundStackService: stack,
    );

    expect(find.textContaining('世界状态本轮未更新'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dismiss_round_warning')));
    await tester.pump();
    expect(provider.roundWarningsFor(1), isEmpty);
    expect(find.textContaining('世界状态本轮未更新'), findsNothing);
    await tester.pump();
    expect(stack.rows[kHarnessBookUuid]!.single.message, isEmpty);
  });

  testWidgets('红条以失败占位代的提示为准（缺位时回落 books.failed_*）',
      (tester) async {
    final dao = FakeRoundDao();
    final bookDao = FakeBookDao(
      books: const [Book(uuid: kHarnessBookUuid, title: '测试书')],
    )..failed = const FailedAttempt(userInput: '断线那一次');
    final stack = FakeRoundStackService(roundDao: dao);
    stack.rows[kHarnessBookUuid] = [
      const RoundStackRow(
        uuid: 'f1',
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        roundSerialNum: 1,
        roundState: 'failed',
        message: '连接超时（库内提示）',
        messageStatus: 'error',
      ),
    ];

    await pumpChatScreen(
      tester,
      seedRounds: 0,
      roundDao: dao,
      bookDao: bookDao,
      roundStackService: stack,
    );

    expect(find.textContaining('连接超时（库内提示）'), findsOneWidget);
  });
}
