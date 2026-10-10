import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';

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

/// 距**底部**的距离（0 = 贴底）。
///
/// 消息列 `reverse: true`（底部锚定）：offset 0 即底部
/// （[ScrollPosition.minScrollExtent]），因此该值就是 `pixels` 本身。
/// 旧实现是正向列表，底部为 `maxScrollExtent`，且 `maxScrollExtent` 在懒加载
/// 列表里是**估算值**——那时「滚到底部」要靠 `jumpTo(估算值)` 再逐帧补滚，
/// 估算偏大时会先冲过头再回弹（实测 45/80 帧越界、最大 390.7px）。
double chatBottomGap(WidgetTester tester) {
  final pos = chatScrollable(tester).position;
  return pos.pixels - pos.minScrollExtent;
}

/// 用慢速手势把对话列表滚动到底部（无惯性甩动，便于确定性断言）。
///
/// 手势方向与列表方向无关：向上拖动 = 揭示**更新**的内容（= 朝底部，
/// `pixels` 减小到 `minScrollExtent`）；向下拖动 = 揭示**更旧**的内容。
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

/// 自动跟随滚动：流式生成期间内容增长不得把正在上翻阅读的用户拉回底部。
///
/// 「结束流式并等待 sendRound 完成」用 `helpers/chat_harness.dart` 的
/// [finishStream]（发送按钮的无限转圈动画使 pumpAndSettle 无法直接使用）。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  /// 构造「前短后长」轮次：前 [shortCount] 轮短正文 + 末 [longCount] 轮长正文。
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

  testWidgets('打开内容不均的多轮次书籍：首帧即位于底部且稳定', (tester) async {
    final dao = await buildUnevenRounds();
    await pumpChatScreen(tester, roundDao: dao);

    expect(
      chatBottomGap(tester),
      closeTo(0, 1),
      reason: 'reverse 底部锚定：offset 0 就是真实底部，无需跳转与逐帧收敛',
    );
    // 稳定：继续泵几帧不漂移（旧实现要 68 帧 / 1306ms 才收敛）。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(chatBottomGap(tester), closeTo(0, 1));
  });

  testWidgets('打开单轮书籍：位于底部', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1);

    expect(chatBottomGap(tester), closeTo(0, 1));
  });

  testWidgets('贴底生成：连续增量不改变滚动偏移（无越界、无脚本补滚）', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 6,
      seedBodyRepeats: 200,
    );
    expect(chatBottomGap(tester), closeTo(0, 1), reason: '起始即底部');

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();

    final offsets = <double>[];
    for (var i = 0; i < 24; i++) {
      ai.emit('流式增量内容第 $i 段，用来让正文继续长高。');
      await tester.pump(const Duration(milliseconds: 16));
      final pos = chatScrollable(tester).position;
      offsets.add(pos.pixels);
      expect(
        pos.pixels,
        inInclusiveRange(pos.minScrollExtent - 0.5, pos.maxScrollExtent + 0.5),
        reason: '贴底生成期间不得越界（旧实现：越界帧 45/80、最大 390.7px）',
      );
    }

    expect(
      offsets.every((p) => p == 0),
      isTrue,
      reason: 'reverse 列表在坐标起点插入新内容不改变 pixels（无需任何脚本 jumpTo）：$offsets',
    );
    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  testWidgets('流式输出时触屏按住下滑（上翻阅读），不会被自动滚动拉回底部', (tester) async {
    final ai = FakeStreamingAiService();
    final roundProvider = await pumpChatScreen(tester, ai: ai, seedRounds: 6);

    // 滚动到底部。
    await scrollChatToBottom(tester);
    expect(chatBottomGap(tester), closeTo(0, 1));

    // 开始流式生成并推送首个增量（自动跟随已接管）。
    final sendFuture = roundProvider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emit('第一段内容');
    await tester.pump();
    expect(chatBottomGap(tester), closeTo(0, 1));

    // 用户触屏按住并向下滑动（内容下移、offset 增大 → 离开底部），手指不松开。
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    final posAfterDrag = chatOffset(tester);
    // 已离开底部（但仍在 80px 阈值内——旧实现正是此处被拉回）。
    expect(chatBottomGap(tester), greaterThan(0));

    // 流式继续输出新内容（触发 rebuild）：手指按住期间不得被拉回底部。
    ai.emit('第二段内容');
    await tester.pump();
    expect(chatOffset(tester), closeTo(posAfterDrag, 1));

    // 松手，结束流式。
    await gesture.up();
    await tester.pump();
    expect(await finishStream(tester, ai, roundProvider, sendFuture), isTrue);
  });

  testWidgets('上翻暂停自动跟随，回到底部后恢复跟随', (tester) async {
    final ai = FakeStreamingAiService();
    final roundProvider = await pumpChatScreen(tester, ai: ai, seedRounds: 6);

    await scrollChatToBottom(tester);
    expect(chatBottomGap(tester), closeTo(0, 1));

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
    final gapAway = chatBottomGap(tester);
    expect(gapAway, greaterThan(100));

    ai.emit('上翻后的内容');
    await tester.pump();
    // 不得被拉回底部（阅读位置补偿只会让它离底部更远，见
    // [ReadingAnchorScrollPhysics]；旧实现此处会被 jumpTo 拉回）。
    expect(chatBottomGap(tester), greaterThanOrEqualTo(gapAway - 1));

    // 用户拖回到底部并松手 → 自动跟随恢复。
    await scrollChatToBottom(tester);
    expect(chatBottomGap(tester), closeTo(0, 1));

    ai.emit('回到底部后的内容');
    await tester.pump();
    expect(chatBottomGap(tester), closeTo(0, 1));

    expect(await finishStream(tester, ai, roundProvider, sendFuture), isTrue);
  });

  testWidgets('离底阅读时流式新内容不推走已读内容（阅读位置保持）', (tester) async {
    final ai = FakeStreamingAiService();
    final roundProvider = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 6,
      seedBodyRepeats: 200,
    );
    final sendFuture = roundProvider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();

    // 先贴底推一段，让流式气泡长高（离开底部后它仍在视口下方/边缘并被构建）。
    for (var i = 0; i < 6; i++) {
      ai.emit('开篇正文第 $i 段，用来把气泡撑高。' * 3);
      await tester.pump();
    }

    // 离开底部（向下拖动 = 揭示更旧内容）。
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final gapBefore = chatBottomGap(tester);
    expect(gapBefore, greaterThan(100), reason: '前提：已离开底部');

    // 参考部件：待定用户气泡（在流式气泡**上方**，已构建）。它若被推走，
    // 说明「视口下方长高」把可视内容整体上移了 —— 正是要避免的现象。
    final reference = find.text('继续剧情');
    expect(reference, findsOneWidget, reason: '前提：参考条目已构建');
    final referenceTopBefore = tester.getTopLeft(reference).dy;

    for (var i = 0; i < 5; i++) {
      ai.emit('更多正文第 $i 段，继续撑高气泡。' * 4);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    final referenceTopAfter = tester.getTopLeft(reference).dy;
    expect(
      (referenceTopAfter - referenceTopBefore).abs(),
      lessThan(2),
      reason: '离底阅读时可视内容不得被推动（当前位移 '
          '${(referenceTopAfter - referenceTopBefore).toStringAsFixed(1)}px）',
    );
    expect(
      chatBottomGap(tester),
      greaterThan(gapBefore + 1),
      reason: '阅读位置由滚动偏移补偿：内容长高多少，就离底部远多少',
    );

    ai.complete();
    await waitSendDone(tester, roundProvider);
    expect(await sendFuture, isTrue);
  });

  testWidgets('长列表生成完成后仍贴在底部', (tester) async {
    final ai = FakeStreamingAiService();
    final dao = await buildUnevenRounds();
    final roundProvider = await pumpChatScreen(tester, ai: ai, roundDao: dao);
    expect(chatBottomGap(tester), closeTo(0, 1));

    // 通过 UI 发送（走生产 _send → _startGeneration / _endGeneration 收尾，
    // 而非直接调 provider，确保生成结束的底部滚动路径被覆盖）。
    await tester.enterText(find.byType(TextField).first, '继续剧情');
    await tester.pump(); // 让发送按钮随输入文本重建（空输入时按钮为禁用态）。
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    ai.emit('后续内容');
    await tester.pump();

    // 结束流式（isSending 期间不能 pumpAndSettle：发送按钮有无限转圈动画）。
    ai.complete();
    await waitSendDone(tester, roundProvider);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      chatBottomGap(tester),
      closeTo(0, 1),
      reason: '生成结束后应停在真实底部（reverse：offset 0 为精确边界）',
    );
  });
}
