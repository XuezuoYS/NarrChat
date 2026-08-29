import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/round_provider.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 对话消息列表最外层（ListView 自带）的滚动状态。
ScrollableState chatScrollable(WidgetTester tester) {
  return tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
}

/// 对话消息列表的滚动偏移。
double chatOffset(WidgetTester tester) => chatScrollable(tester).position.pixels;

/// 对话消息列表的最大滚动偏移。
double chatMax(WidgetTester tester) =>
    chatScrollable(tester).position.maxScrollExtent;

/// 用慢速手势把对话列表滚动到底部（无惯性甩动，便于确定性断言）。
Future<void> scrollChatToBottom(WidgetTester tester) async {
  final start = tester.getCenter(find.byType(ListView));
  final gesture = await tester.startGesture(start);
  for (var i = 0; i < 8; i++) {
    await gesture.moveBy(const Offset(0, -300));
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 结束流式并等待 sendRound 完成（期间 isSending 为 true 时发送按钮
/// 有无限转圈动画，不能用 pumpAndSettle，须等 isSending 变 false）。
Future<void> finishStream(
  WidgetTester tester,
  FakeStreamingAiService ai,
  RoundProvider provider,
  Future<bool> sendFuture,
) async {
  ai.complete();
  for (var i = 0; i < 20 && provider.isSending; i++) {
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(await sendFuture, isTrue);
}

void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  testWidgets('流式输出时触屏按住上滑，不会被自动滚动拉回底部', (tester) async {
    final ai = FakeStreamingAiService();
    final roundProvider = await pumpChatScreen(tester, ai: ai, seedRounds: 6);

    // 滚动到底部。
    await scrollChatToBottom(tester);
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    // 开始流式生成并推送首个增量（自动跟随已接管）。
    final sendFuture = roundProvider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emit('第一段内容');
    await tester.pump();
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    // 用户触屏按住并向上滑动（内容向下移动、offset 减小），手指不松开。
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    final posAfterDrag = chatOffset(tester);
    // 已离开底部（但仍在 80px 阈值内——旧实现正是此处被拉回）。
    expect(posAfterDrag, lessThan(chatMax(tester)));

    // 流式继续输出新内容（触发 rebuild）：手指按住期间不得被拉回底部。
    ai.emit('第二段内容');
    await tester.pump();
    expect(chatOffset(tester), closeTo(posAfterDrag, 1));

    // 松手，结束流式。
    await gesture.up();
    await tester.pump();
    await finishStream(tester, ai, roundProvider, sendFuture);
  });

  testWidgets('上翻暂停自动跟随，回到底部后恢复跟随', (tester) async {
    final ai = FakeStreamingAiService();
    final roundProvider = await pumpChatScreen(tester, ai: ai, seedRounds: 6);

    await scrollChatToBottom(tester);
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    final sendFuture = roundProvider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emit('第一段内容');
    await tester.pump();

    // 用户上翻一段距离后松手：之后流式内容不得再把它拉回底部。
    final up = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await up.moveBy(const Offset(0, 150));
    await tester.pump();
    await up.moveBy(const Offset(0, 300));
    await tester.pump();
    await up.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final posAway = chatOffset(tester);
    expect(posAway, lessThan(chatMax(tester) - 100));

    ai.emit('上翻后的内容');
    await tester.pump();
    expect(chatOffset(tester), closeTo(posAway, 1));

    // 用户拖回到底部并松手 → 自动跟随恢复。
    await scrollChatToBottom(tester);
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    ai.emit('回到底部后的内容');
    await tester.pump();
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    await finishStream(tester, ai, roundProvider, sendFuture);
  });

  /// 驱动「打开书籍 → 跳转到底部 → 帧末收敛」的 postFrame 帧链。
  ///
  /// 测试环境没有自持续帧：pumpAndSettle 不会泵「未调度」的帧，而
  /// 生产代码的跳底（入口 postFrame）与逐帧收敛都排队在帧末回调上；
  /// 这里显式调度帧并逐帧推进（16ms/帧，40 帧 > 收敛上限 + 动画 300ms）。
  Future<void> pumpScrollBottomChain(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// 构造「前短后长」轮次：前 [shortCount] 轮短正文 + 末 [longCount] 轮长正文。
  /// 懒加载列表的估算 maxScrollExtent 远小于真实值（复现「滚到一半停住」的根因）。
  Future<FakeRoundDao> buildUnevenRounds({
    int shortCount = 24,
    int longCount = 3,
  }) async {
    final dao = FakeRoundDao();
    for (var i = 1; i <= shortCount + longCount; i++) {
      final isLong = i > shortCount;
      await dao.insertRound(
        Round(
          bookUuid: kHarnessBookUuid,
          roundIndex: i,
          userInput: '第 $i 轮的用户输入',
          aiNarrative: isLong ? '尾部剧情。' * 200 : '好。',
          currentTime: '第一天 午时',
          createdAt: DateTime.now(),
        ),
      );
    }
    return dao;
  }

  testWidgets('打开内容不均的多轮次书籍：直接位于真实底部且稳定', (tester) async {
    final dao = await buildUnevenRounds();
    await pumpChatScreen(tester, roundDao: dao);
    await pumpScrollBottomChain(tester);

    expect(
      chatOffset(tester),
      closeTo(chatMax(tester), 1),
      reason: '打开书籍后应位于真实底部，而非懒加载估算位置（修复前停在半路）',
    );
    // 收敛已完成且稳定：继续泵几帧不漂移、maxScrollExtent 不再增长。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));
  });

  testWidgets('打开单轮书籍：位于底部', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1);
    await pumpScrollBottomChain(tester);

    expect(chatOffset(tester), closeTo(chatMax(tester), 1));
  });

  testWidgets('长列表生成完成后自动跟随贴底（动画路径收敛）', (tester) async {
    final ai = FakeStreamingAiService();
    final dao = await buildUnevenRounds();
    final roundProvider = await pumpChatScreen(tester, ai: ai, roundDao: dao);
    await pumpScrollBottomChain(tester);
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    // 通过 UI 发送（走生产 _send → _startGeneration / _endGeneration 收尾，
    // 而非直接调 provider，确保生成结束的底部滚动路径被覆盖）。
    await tester.enterText(find.byType(TextField).first, '继续剧情');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    ai.emit('后续内容');
    await tester.pump();

    // 结束流式（isSending 期间不能 pumpAndSettle：发送按钮有无限转圈动画）。
    ai.complete();
    for (var i = 0; i < 20 && roundProvider.isSending; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await pumpScrollBottomChain(tester);

    expect(
      chatOffset(tester),
      closeTo(chatMax(tester), 1),
      reason: '生成结束的动画滚动完成后应收敛到真实底部',
    );
  });
}
