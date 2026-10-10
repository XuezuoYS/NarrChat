import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/round_stack.dart';
import 'package:narrchat/widgets/round_version_stepper.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

/// 对话页「删除此代」（单代删除）契约：扩展菜单入口 → 二次确认 → 自动回落相邻代。
///
/// 版本树服务用内存替身：入口显隐 / 确认与取消的编排 / 删除后的 UI 反馈
/// （左右箭头按剩余代置灰、「最新第 y 代」不因删除而重排）都在此断言；
/// 真实删除语义（后代子树、序号保留、回落规则）由 `round_stack_service_test.dart`
/// 的真库用例覆盖。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  Finder menuItem(String value) => find.byWidgetPredicate(
        (w) => w is PopupMenuItem<String> && w.value == value,
      );

  /// 点击气泡扩展菜单里的某一项。
  Future<void> tapMenuItem(
    WidgetTester tester,
    String value,
    String label,
  ) async {
    await tester.tap(
      find.descendant(of: menuItem(value), matching: find.text(label)),
    );
    await tester.pumpAndSettle();
  }

  /// 代次控件的箭头状态（false = 置灰不可点）。
  ({bool prev, bool next}) arrowState(WidgetTester tester) => (
        prev: tester
                .widget<IconButton>(find.byKey(RoundVersionStepper.prevKey))
                .onPressed !=
            null,
        next: tester
                .widget<IconButton>(find.byKey(RoundVersionStepper.nextKey))
                .onPressed !=
            null,
      );

  /// 预置：第 0 轮 + 第 1 轮（3 代 g1/g2/g3，当前 = g2「第 2 代正文」）。
  Future<({FakeRoundDao dao, FakeRoundStackService stack})> seedThreeGens() async {
    RoundStackMeta meta(String uuid, int serial, {bool use = false}) =>
        RoundStackMeta(
          uuid: uuid,
          bookUuid: kHarnessBookUuid,
          roundIndex: 1,
          roundSerialNum: serial,
          roundState: use ? 'use' : null,
        );
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(bookUuid: kHarnessBookUuid, roundIndex: 0, createdAt: DateTime.now()),
    );
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        userInput: '第一轮输入',
        aiNarrative: '第 2 代正文',
        createdAt: DateTime.now(),
        useStackUuid: 'g2',
      ),
    );
    final stack = FakeRoundStackService(roundDao: dao)
      ..metas = [meta('g1', 1), meta('g2', 2, use: true), meta('g3', 3)];
    return (dao: dao, stack: stack);
  }

  testWidgets('入口显隐：≥2 存活代时菜单含「删除此代」，唯一一代不显示', (tester) async {
    final seed = await seedThreeGens();
    final provider = await pumpChatScreen(
      tester,
      roundDao: seed.dao,
      roundStackService: seed.stack,
    );

    await tester.longPress(find.text('第 2 代正文'));
    await tester.pumpAndSettle();
    expect(menuItem('deleteGen'), findsOneWidget);
    expect(
      find.descendant(of: menuItem('deleteGen'), matching: find.text('删除此代')),
      findsOneWidget,
    );
    expect(menuItem('delete'), findsOneWidget, reason: '既有「删除本轮」不受影响');

    // 关掉菜单，把该轮收窄到唯一一代（当前代仍在）再看。
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    seed.stack.metas = [seed.stack.metas[1]];
    await provider.loadRounds(kHarnessBookUuid);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('第 2 代正文'));
    await tester.pumpAndSettle();
    expect(
      menuItem('deleteGen'),
      findsNothing,
      reason: '唯一一代没有可回落的相邻代 → 不显示入口',
    );
    expect(menuItem('delete'), findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
  });

  testWidgets('确认框：给出落点与剩余代；取消则不删除、不切换', (tester) async {
    final seed = await seedThreeGens();
    await pumpChatScreen(
      tester,
      roundDao: seed.dao,
      roundStackService: seed.stack,
    );
    expect(find.text('2/3'), findsOneWidget, reason: '夹具：当前第 2 代 / 最新第 3 代');

    await tester.longPress(find.text('第 2 代正文'));
    await tester.pumpAndSettle();
    await tapMenuItem(tester, 'deleteGen', '删除此代');

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('第 1 轮的第 2 代'), findsOneWidget);
    expect(find.textContaining('自动切换到第 1 代'), findsOneWidget);
    expect(find.textContaining('本轮剩余 2 代'), findsOneWidget);
    expect(find.textContaining('无法恢复'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(seed.stack.generationDeletes, isEmpty, reason: '取消不调用删除');
    expect(find.text('2/3'), findsOneWidget, reason: '代次与投影原样不动');
    expect(find.text('第 2 代正文'), findsOneWidget);
  });

  testWidgets('确认删除：删当前代 → 回落前一代，最大数不变、左右箭头按剩余代置灰', (tester) async {
    final seed = await seedThreeGens();
    final provider = await pumpChatScreen(
      tester,
      roundDao: seed.dao,
      roundStackService: seed.stack,
    );
    expect(arrowState(tester), (prev: true, next: true));

    // 「删除落地」的投影效果（真实语义由真库用例覆盖）：切到第 1 代。
    seed.stack.onDeleteGeneration = (bookUuid, roundIndex, _) {
      final index = seed.dao.rounds.indexWhere(
        (r) => r.bookUuid == bookUuid && r.roundIndex == roundIndex,
      );
      seed.dao.rounds[index] = seed.dao.rounds[index].copyWith(
        aiNarrative: '第 1 代正文',
        useStackUuid: 'g1',
      );
    };

    await tester.longPress(find.text('第 2 代正文'));
    await tester.pumpAndSettle();
    await tapMenuItem(tester, 'deleteGen', '删除此代');
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(seed.stack.generationDeletes, hasLength(1));
    expect(seed.stack.generationDeletes.single.generationUuid, 'g2');
    expect(seed.stack.generationDeletes.single.roundIndex, 1);
    expect(seed.stack.generationDeletes.single.bookUuid, kHarnessBookUuid);
    expect(find.text('第 1 代正文'), findsOneWidget, reason: '正文随回落代');
    expect(
      find.text('1/3'),
      findsOneWidget,
      reason: '删的不是最大号 → 「最新第 3 代」不变，序号不重排',
    );
    final arrows = arrowState(tester);
    expect(arrows.prev, isFalse, reason: '已在前一代 → 左箭头置灰');
    expect(arrows.next, isTrue, reason: '右侧仍有第 3 代可切');
    expect(provider.isSending, isFalse, reason: '删除不发起生成');
  });

  testWidgets('服务拒绝（唯一代 / 失败）：提示删除失败且不改动视图', (tester) async {
    final seed = await seedThreeGens();
    await pumpChatScreen(
      tester,
      roundDao: seed.dao,
      roundStackService: seed.stack,
    );
    seed.stack.deleteGenerationResult = false;

    await tester.longPress(find.text('第 2 代正文'));
    await tester.pumpAndSettle();
    await tapMenuItem(tester, 'deleteGen', '删除此代');
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await settleNoticeEnter(tester);

    expect(find.textContaining('删除失败'), findsOneWidget);
    expect(find.text('2/3'), findsOneWidget, reason: '失败不改动代次');
    await flushNotices(tester);
  });

  testWidgets('守卫：菜单已开出后缩到唯一一代 → 悬浮提示「请删除此轮」且不删除', (tester) async {
    final seed = await seedThreeGens();
    final provider = await pumpChatScreen(
      tester,
      roundDao: seed.dao,
      roundStackService: seed.stack,
    );

    await tester.longPress(find.text('第 2 代正文'));
    await tester.pumpAndSettle();
    expect(menuItem('deleteGen'), findsOneWidget);

    // 菜单开着的期间版本树变化（模拟特殊手段触发 / 竞态）。
    seed.stack.metas = [seed.stack.metas[1]];
    await provider.loadRounds(kHarnessBookUuid);
    await tester.pump();

    await tapMenuItem(tester, 'deleteGen', '删除此代');
    await settleNoticeEnter(tester);
    expect(find.textContaining('唯一代不可删除，请删除此轮。'), findsOneWidget);
    expect(seed.stack.generationDeletes, isEmpty, reason: '守卫拦截：不做任何删除');
    expect(find.byType(AlertDialog), findsNothing, reason: '不进入确认框');
    await flushNotices(tester);
  });

  testWidgets('守卫：正在生成中点击「删除此代」→ 提示暂不可删除', (tester) async {
    final seed = await seedThreeGens();
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      roundDao: seed.dao,
      roundStackService: seed.stack,
    );

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    expect(provider.isSending, isTrue);

    await tester.longPress(find.text('第 2 代正文'));
    // 生成中不能用 pumpAndSettle（转圈动画永不结束），手动推一帧让菜单弹出。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.descendant(
        of: menuItem('deleteGen'),
        matching: find.text('删除此代'),
      ),
    );
    await settleNoticeEnter(tester);

    expect(find.textContaining('正在生成中，暂不可删除此代。'), findsOneWidget);
    expect(seed.stack.generationDeletes, isEmpty);
    await flushNotices(tester);
    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });
}
