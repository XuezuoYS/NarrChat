import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 「代级提示」与「失败轮次」的行为测试（R3）。
///
/// 覆盖：
/// - 生成警告随代落库（`message_status='warning'`）；
/// - 提示以库为唯一来源（重启仍在），**没有关闭入口**（常驻，只能随代变化）；
/// - 失败/中断 = 链上一条真轮次（`message_status='error'`），保留用户输入；
/// - 错误代不能衍生下一轮，恢复方式是「重新生成」；
/// - 提示随代而行（切版本 / 删轮次）；
/// - 对话页两种渲染：warning 黄框、error 红条。
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

  late TestStack stack;

  // R3 没有假 DAO：用真库 + 临时目录播种。
  setUp(() async {
    stack = await TestStack.create(prefix: 'round_messages_');
    await stack.repos.books.createBook(book);
  });

  tearDown(() async {
    await stack.dispose();
  });

  ({RoundProvider provider, FakeCloudSyncProvider cloud}) build({
    AiService? ai,
    FakeCloudSyncProvider? cloud,
  }) {
    final sync = cloud ?? FakeCloudSyncProvider();
    final rp = RoundProvider(
      rounds: stack.repos.rounds,
      books: stack.repos.books,
      aiService: ai ?? ToggleAiService(),
      aiSettingsProvider: AiSettingsProvider(),
      // Agent 模式与协议解耦：显式开启实验性开关（默认平台仍为 Response 线路）。
      experimentalSettings: AgentModeSettings(),
      cloudSyncProvider: sync,
      retryDelay: Duration.zero,
    );
    return (provider: rp, cloud: sync);
  }

  /// 成功一轮 AGENT（状态缺项 → 常驻提示）的公共夹具。
  Future<({RoundProvider provider, FakeCloudSyncProvider cloud})>
      runWarnedRound() async {
    var calls = 0;
    final env = build(
      ai: AiService(
        client: MockClient((request) async => sse(unappliedSse(++calls))),
      ),
    );
    await env.provider.loadRounds('b1');
    expect(await env.provider.sendRound(userInput: '开始', book: book), isTrue);
    return env;
  }

  test('生成警告 → 落到本轮那一代的 message（warning 级）', () async {
    final env = await runWarnedRound();

    expect(env.provider.roundWarningsFor(1), contains('世界状态本轮未更新'));

    final chain = await stack.repos.rounds.loadChain('b1');
    final round = chain.rounds.singleWhere((r) => r.roundIndex == 1);
    expect(round.message, contains('世界状态本轮未更新'));
    expect(round.messageStatus, 'warning');
    expect(round.isUsing, isTrue, reason: '提示挂在当前应用代上');
    expect(round.aiNarrative, contains('正文。'), reason: '提示不是内容');
    expect(round.isError, isFalse, reason: '警告不是失败');
  });

  test('「重启」后提示仍在（库是唯一来源，没有可以抹掉它的入口）', () async {
    final env = await runWarnedRound();
    expect(env.cloud.triggers, 1, reason: '生成结束只触发一次同步');

    // 冷启动：同一套库 + 新 Provider 重新加载即可看到提示。
    final restarted = build();
    await restarted.provider.loadRounds('b1');

    expect(restarted.provider.roundWarningsFor(1), contains('世界状态本轮未更新'));

    // 提示就挂在库里那一代上（不是本地副本），没有关闭动作能把它清掉。
    final chain = await stack.repos.rounds.loadChain('b1');
    final round = chain.rounds.singleWhere((r) => r.roundIndex == 1);
    expect(round.message, contains('世界状态本轮未更新'));
    expect(round.messageStatus, 'warning');
    expect(env.cloud.triggers, 1, reason: '提示没有关闭动作，不会再产生额外同步');
  });

  test('失败：落一条链上的 error 轮，保留用户输入；清除后消失并推送', () async {
    final env = build(ai: ToggleAiService()..fail = true);
    await env.provider.loadRounds('b1');

    expect(await env.provider.sendRound(userInput: '失败轮', book: book), isFalse);

    final failure = env.provider.rounds.single;
    expect(failure.isError, isTrue, reason: '失败就是链上一条真轮次');
    expect(failure.messageStatus, 'error');
    expect(failure.message.trim(), isNotEmpty, reason: '红条必须有文案');
    expect(failure.userInput, '失败轮', reason: '失败也要保留用户输入');
    expect(env.cloud.triggers, 1, reason: '错误代也是内容变更');

    await env.provider.clearFailedAttempt();

    expect(env.provider.rounds, isEmpty);
    expect(env.cloud.triggers, 2, reason: '清除同样要推送');
  });

  test('失败提示 = 失败原因 + 本轮过程警告，合并进同一条 message', () async {
    // 首次请求：AGENT 只回工具调用 → 整轮无正文 → 判失败（并带上「状态改动已作废」）。
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

    final failure = env.provider.rounds.single;
    expect(failure.message, contains('未产出正文'), reason: '失败原因');
    expect(failure.message, contains('状态改动已作废'), reason: '本轮过程警告并入同一条提示');

    // 错误代不能衍生下一轮：直接发新消息会被拒绝，提示用户先重新生成。
    expect(await env.provider.sendRound(userInput: '再来', book: book), isFalse);
    expect(env.provider.error, contains('上一轮生成失败'));

    // 正确恢复：对这条错误轮「重新生成」→ 同组新增一代并切过去。
    failFirst = false;
    await env.provider.refreshRound(failure, book: book);

    final recovered = env.provider.rounds.single;
    expect(recovered.isError, isFalse, reason: '重新生成后链上是成功代');
    expect(recovered.roundIndex, 1);
    expect(recovered.aiNarrative, contains('正文。'));
  });

  test('删除轮次 → 该轮的提示随行消失', () async {
    final env = await runWarnedRound();
    final round = env.provider.rounds.single;

    await env.provider.deleteRound(round, deleteFollowing: true);

    expect(env.provider.rounds, isEmpty);
    expect(env.provider.roundWarningsFor(1), isEmpty);
  });

  test('提示跟随「当前应用代」：换成另一代即换成那一代的提示', () async {
    // 第 1 轮两代：g-old 旧提示、g-new 当前代新提示（同组 = 同分支 + 同轮号 + 同父代）。
    await stack.seedRound(
      'b1',
      roundIndex: 1,
      uuid: 'g-old',
      serialNum: 1,
      isUsing: false,
      userInput: '问',
      aiNarrative: '答',
      message: '旧提示',
      messageStatus: 'warning',
    );
    await stack.seedRound(
      'b1',
      roundIndex: 1,
      uuid: 'g-new',
      serialNum: 2,
      isUsing: true,
      userInput: '问',
      aiNarrative: '答',
      message: '新提示',
      messageStatus: 'warning',
    );

    final env = build();
    await env.provider.loadRounds('b1');
    expect(env.provider.roundWarningsFor(1), ['新提示']);

    // 切回旧一代 → 看到的是那一代自己的提示。
    expect(await env.provider.switchRoundVersion(1, forward: false), isTrue);
    expect(env.provider.roundWarningsFor(1), ['旧提示']);
  });

  test('空提示不显示提示框（message 为空即无框，无论级别）', () async {
    await stack.seedRound(
      'b1',
      roundIndex: 1,
      userInput: '问',
      aiNarrative: '答',
      message: '   ',
      messageStatus: 'warning',
    );

    final env = build();
    await env.provider.loadRounds('b1');

    expect(env.provider.roundWarningsFor(1), isEmpty);
    expect(env.provider.roundMessageFor(1), isNull);
  });

  testWidgets('库内提示在对话页展示（warning 黄框），没有关闭入口', (tester) async {
    // 复用 setUp 里的 stack：testWidgets 的测试体跑在 fake-async 区域，
    // 这里再 `TestStack.create()` 会卡在真实文件 I/O 上（现象：10 分钟超时）。
    final provider = await pumpChatScreen(
      tester,
      stack: stack,
      seedRounds: 0,
    );
    // 真库 I/O 必须跑在真实事件循环里（见 chat_harness._resolveStack 的说明）。
    await tester.runAsync(() async {
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        userInput: '第一轮',
        aiNarrative: '正文',
        message: '世界状态本轮未更新',
        messageStatus: 'warning',
      );
      await provider.loadRounds(kHarnessBookUuid);
    });
    await settle(tester);

    expect(find.textContaining('世界状态本轮未更新'), findsOneWidget);
    // 提示常驻：旧版的「关闭提示」按钮已取消，重绘后它仍在。
    expect(find.byKey(const ValueKey('dismiss_round_warning')), findsNothing);
    await settle(tester);
    expect(find.textContaining('世界状态本轮未更新'), findsOneWidget);
    expect(provider.roundWarningsFor(1), isNotEmpty);
  });

  testWidgets('错误代在对话页渲染红条（文案取库内 message，用户输入保留）',
      (tester) async {
    final provider = await pumpChatScreen(
      tester,
      stack: stack,
      seedRounds: 0,
    );
    await tester.runAsync(() async {
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        userInput: '断线那一次',
        message: '连接超时（库内提示）',
        messageStatus: 'error',
      );
      await provider.loadRounds(kHarnessBookUuid);
    });
    await settle(tester);

    expect(provider.rounds.single.isError, isTrue);
    expect(find.textContaining('连接超时（库内提示）'), findsOneWidget);
    expect(find.textContaining('断线那一次'), findsOneWidget);
    // 错误代没有正文：不显示「AI 未返回剧情正文」的占位，避免盖住真正的失败原因。
    expect(find.textContaining('AI 未返回剧情正文'), findsNothing);
  });
}
