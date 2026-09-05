import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 常驻黄框警告的**本地持久化**集成测试（RoundProvider × RoundWarningsStore）。
///
/// 目标：警告只进本地数据层（store 替身）——不入用户库、不云同步；
/// 重启 / 换书后未关闭的警告恢复，关闭、重生成、删除随轮次清除。
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

  /// 每帧只回文本+完成：正文轮一帧收工，状态轮空手帧不再止损 →
  /// 直到帧数上限，缺项转常驻警告（与 agent_round_test 同夹具思路）。
  List<String> unappliedSse(int calls) => [
        'data: {"type":"response.output_text.delta","delta":"## 剧情演绎\\n正文。\\n\\n## 推荐行动\\n行动"}',
        'data: {"type":"response.completed","response":{"id":"r$calls","usage":{"input_tokens":1,"output_tokens":1}}}',
        '',
      ];

  RoundProvider buildProvider(
    FakeRoundDao dao,
    FakeBookDao bookDao,
    FakeRoundWarningsStore store,
    AiService ai,
  ) {
    return RoundProvider(
      dao: dao,
      bookDao: bookDao,
      aiService: ai,
      aiSettingsProvider: AiSettingsProvider(),
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      warningsStore: store,
      retryDelay: Duration.zero,
    );
  }

  /// 成功一轮 AGENT（状态缺项→警告常驻）的公共夹具，返回 (dao, store)。
  Future<(FakeRoundDao, FakeRoundWarningsStore)> runWarnedRound() async {
    final dao = FakeRoundDao();
    final store = FakeRoundWarningsStore();
    var calls = 0;
    final ai = AiService(
      client: MockClient((request) async => sse(unappliedSse(++calls))),
    );
    final provider = buildProvider(dao, FakeBookDao(), store, ai);
    await provider.loadRounds('b1');
    expect(await provider.sendRound(userInput: '开始', book: book), isTrue);
    expect(provider.roundWarningsFor(1), contains('世界状态本轮未更新'));
    return (dao, store);
  }

  test('生成产生警告 → 写入本地存储；未关闭时「重启」后恢复展示', () async {
    final (dao, store) = await runWarnedRound();
    expect(store.data['b1']?[1], contains('世界状态本轮未更新'));

    // 模拟冷启动：同一本地存储 + 同一数据库，新 Provider 重新加载。
    final restarted = buildProvider(
      dao,
      FakeBookDao(),
      store,
      AiService(client: MockClient((request) async => sse(unappliedSse(1)))),
    );
    await restarted.loadRounds('b1');
    expect(restarted.roundWarningsFor(1), contains('世界状态本轮未更新'));
    // 警告只存本地数据层：round 表本身不带任何警告字段（同构轮次）。
    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    expect(round.aiNarrative, contains('正文。'));
  });

  test('手动关闭 → 本地存储同步移除；「重启」后不复活', () async {
    final (dao, store) = await runWarnedRound();

    final provider = buildProvider(
      dao,
      FakeBookDao(),
      store,
      AiService(client: MockClient((request) async => sse(unappliedSse(1)))),
    );
    await provider.loadRounds('b1');
    provider.dismissRoundWarnings(1);
    await pumpEventQueue();
    expect(provider.roundWarningsFor(1), isEmpty);
    expect(store.data['b1']?[1], isNull);

    final restarted = buildProvider(
      dao,
      FakeBookDao(),
      store,
      AiService(client: MockClient((request) async => sse(unappliedSse(1)))),
    );
    await restarted.loadRounds('b1');
    expect(restarted.roundWarningsFor(1), isEmpty);
  });

  test('AGENT 空正文轮失败：黄框随失败条目落本地存储，重启恢复，清除失败条目后消失',
      () async {
    final dao = FakeRoundDao();
    final bookDao = FakeBookDao(books: [book]);
    final store = FakeRoundWarningsStore();
    final ai = AiService(
      client: MockClient((request) async => sse([
            'data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","name":"narrchat_editSection"}}',
            'data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"section\\":\\"worldState\\",\\"edits\\":[{\\"op\\":\\"append\\",\\"newLine\\":\\"- 地点：荒原\\"}]}"}',
            'data: {"type":"response.completed","response":{"id":"r1","usage":{"input_tokens":1,"output_tokens":1}}}',
            '',
          ])),
    );
    final provider = buildProvider(dao, bookDao, store, ai);
    await provider.loadRounds('b1');

    expect(await provider.sendRound(userInput: '只调工具', book: book), isFalse);
    expect(provider.failedAttempt.userInput, '只调工具');
    final pending = provider.nextRoundIndex;
    expect(provider.roundWarningsFor(pending), isNotEmpty);
    expect(store.data['b1']?[pending], isNotEmpty);

    // 重启：失败条目仍在（bookDao 同实例），黄框恢复在「本该产生的那一轮」。
    final restarted = buildProvider(dao, bookDao, store, ai);
    await restarted.loadRounds('b1');
    expect(restarted.nextRoundIndex, pending);
    expect(restarted.roundWarningsFor(pending), isNotEmpty);
    expect(restarted.failedAttempt.userInput, '只调工具');

    // 清除失败条目 → 黄框一并清除并落盘。
    await restarted.clearFailedAttempt();
    await pumpEventQueue();
    expect(restarted.roundWarningsFor(pending), isEmpty);
    expect(store.data['b1']?[pending], isNull);
  });

  test('删除轮次（重生成 / 改提问的前置删除）→ 本地存储一并清除', () async {
    final (dao, store) = await runWarnedRound();
    final provider = buildProvider(
      dao,
      FakeBookDao(),
      store,
      AiService(client: MockClient((request) async => sse(unappliedSse(1)))),
    );
    await provider.loadRounds('b1');

    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);
    await provider.deleteRound(round, deleteFollowing: true);
    await pumpEventQueue();

    expect(provider.roundWarningsFor(1), isEmpty);
    expect(store.data['b1']?[1], isNull);
  });

  test('水合时校验清理：本地存储中不存在的轮次残留被清除（含回写）', () async {
    final dao = FakeRoundDao();
    for (var i = 1; i <= 2; i++) {
      await dao.insertRound(
        Round(bookUuid: 'b1', roundIndex: i, createdAt: DateTime.now()),
      );
    }
    final store = FakeRoundWarningsStore();
    store.data['b1'] = {
      1: ['世界状态本轮未更新'],
      99: ['无效残留：没有第 99 轮'],
    };

    final provider = buildProvider(
      dao,
      FakeBookDao(),
      store,
      AiService(client: MockClient((request) async => sse(unappliedSse(1)))),
    );
    await provider.loadRounds('b1');
    await pumpEventQueue();

    expect(provider.roundWarningsFor(1), ['世界状态本轮未更新']);
    expect(provider.roundWarningsFor(99), isEmpty);
    expect(store.data['b1']?.keys, [1]);
    // 校验清理后的状态已回写存储（而非仅在内存丢弃）。
    expect(store.saveCalls, greaterThan(0));
  });

  test('水合读取失败：视为无缓存，不抛异常、不影响轮次加载', () async {
    final dao = FakeRoundDao();
    final store = FakeRoundWarningsStore()..nextLoadError = Exception('损坏');
    final provider = buildProvider(
      dao,
      FakeBookDao(),
      store,
      AiService(client: MockClient((request) async => sse(unappliedSse(1)))),
    );

    await provider.loadRounds('b1');
    expect(provider.error, isNull);
    expect(provider.roundWarningsFor(0), isEmpty);
  });

  testWidgets('由本地存储恢复的黄框在 chat 页展示，可手动关闭',
      (tester) async {
    final store = FakeRoundWarningsStore();
    store.data[kHarnessBookUuid] = {
      1: ['世界状态本轮未更新'],
    };
    final provider = await pumpChatScreen(
      tester,
      seedRounds: 1,
      warningsStore: store,
    );

    expect(find.textContaining('世界状态本轮未更新'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dismiss_round_warning')));
    await tester.pump();
    expect(provider.roundWarningsFor(1), isEmpty);
    expect(find.textContaining('世界状态本轮未更新'), findsNothing);
    // testWidgets 内禁止 pumpEventQueue（FakeAsync 下零时长 Timer 不会自燃）：
    // 用 pump 冲刷微任务，落盘（内存替身）与 UI 同步完成。
    await tester.pump();
    expect(store.data[kHarnessBookUuid]?[1], isNull);
  });
}
