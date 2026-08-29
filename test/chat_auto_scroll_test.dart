import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
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
}
