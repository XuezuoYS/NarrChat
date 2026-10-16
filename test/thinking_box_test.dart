import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 超长思考文本：首尾带唯一标记、每行独立成行，末尾混入 Markdown 结构
/// （用于验证思考框不走 Markdown 解析），总长超过末尾窗口上限。
String longReasoning() => '开头标记第一行\n'
    '${'中间推理内容行\n' * 200}'
    '## 末尾小标题\n**末尾粗体**';

/// 折叠面板所在的滚动视口（折叠态正文唯一的 `SingleChildScrollView` 祖先）。
Finder thinkingViewport(Finder text) =>
    find.ancestor(of: text, matching: find.byType(SingleChildScrollView));

/// 折叠面板的滚动位置（反向下锚：`pixels == 0` 即贴着内容末尾）。
ScrollPosition viewportPosition(WidgetTester tester, Finder viewport) =>
    tester
        .state<ScrollableState>(
          find.descendant(of: viewport, matching: find.byType(Scrollable)),
        )
        .position;

/// 展开块**可见部分**上的一个落点：正文矩形 ∩ 消息区矩形的中心。
///
/// 长思考链展开后正文远高于视口，整块 `Text` 的中心落在视口之外（那里收不到
/// 指针），所以落点必须按可见区域算。
Offset visiblePointOn(WidgetTester tester, Finder text) {
  final visible = tester.getRect(text).intersect(
    tester.getRect(find.byKey(const Key('chat_messages_area'))),
  );
  return visible.center;
}

/// 同一位置的两击（间隔在双击判定窗口内）。
///
/// 鼠标与触屏都覆盖：两条线路在选中区域里各有「双击选词」的识别器，收起手势
/// 必须同样抢得过它。
Future<void> doubleTapAt(
  WidgetTester tester,
  Offset point,
  PointerDeviceKind kind,
) async {
  await tester.tapAt(point, kind: kind);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(point, kind: kind);
  // 越过后一个双击判定窗口：让识别器计时器收敛（测试结束不得残留计时器）。
  await tester.pump(const Duration(milliseconds: 400));
}

/// 思考框交互与渲染策略：
/// - 折叠：只渲染末尾窗口（否则全文排版成本随思考链长度线性上升）、恒贴内容
///   末尾、**不允许手动滚动**（只读预览，读全文请展开）；
/// - 展开：渲染全文，**双击正文任意位置直接收起**（长链展开后头部已滚出视口，
///   点不到头部）；
/// - 一律按纯文本渲染（不做 Markdown 解析，保留模型原始分行）。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  testWidgets('生成中折叠态：只渲染末尾窗口，且思考文本不走 Markdown', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emitReasoning(longReasoning());
    await tester.pump();

    // 数据层完整：末尾窗口只影响渲染，不影响累积的思考原文。
    expect(provider.agentEvents.single.content, longReasoning());
    expect(provider.agentEvents.single.done, isFalse);

    final body = tester.widget<Text>(find.textContaining('**末尾粗体**'));
    // 窗口外的开头内容不参与渲染（这正是性能修复点）。
    expect(body.data, isNot(contains('开头标记第一行')));
    // 窗口贴住最新内容，且以完整行开头（不出现半行）。
    expect(body.data, startsWith('中间推理内容行\n'));
    expect(body.data, contains('\n'), reason: '纯文本保留模型原始换行');
    // 纯文本渲染：Markdown 标记原样保留，未被解析成标题/粗体。
    expect(body.data, contains('## 末尾小标题'));
    expect(find.text('末尾小标题'), findsNothing);
    expect(find.text('末尾粗体'), findsNothing);

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  testWidgets('折叠态恒贴内容末尾：首帧起就显示最新推理（不靠程序滚动）', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emitReasoning(longReasoning());
    await tester.pump();

    final tail = find.textContaining('末尾粗体');
    final viewport = thinkingViewport(tail);
    expect(viewport, findsOneWidget, reason: '折叠框内只有这一个滚动视口');
    final padding =
        tester.widget<SingleChildScrollView>(viewport).padding! as EdgeInsets;

    expect(
      viewportPosition(tester, viewport).pixels,
      0,
      reason: '反向下锚：偏移 0 即内容末尾',
    );
    expect(
      tester.getRect(tail).bottom,
      moreOrLessEquals(
        tester.getRect(viewport).bottom - padding.bottom,
        epsilon: 0.5,
      ),
      reason: '最新推理必须落在折叠框最下面几行（首帧即成立，无需等下一个增量）',
    );

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  testWidgets('折叠态不允许手动滚动：拖动动不了折叠框内容', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emitReasoning(longReasoning());
    await tester.pump();

    final tail = find.textContaining('末尾粗体');
    final viewport = thinkingViewport(tail);
    expect(
      tester.widget<SingleChildScrollView>(viewport).physics,
      isA<NeverScrollableScrollPhysics>(),
      reason: '折叠态是只读预览（读全文请展开），手势该留给外层消息列',
    );
    // 用例前提：框内本来有可滚动的余量——否则「拖不动」是假的（没得滚）。
    expect(
      viewportPosition(tester, viewport).maxScrollExtent,
      greaterThan(0),
      reason: '末尾窗口远高于折叠区，只是不给手滚',
    );

    await tester.drag(viewport, const Offset(0, 160));
    await tester.pump();

    expect(
      viewportPosition(tester, viewport).pixels,
      0,
      reason: '拖动后内部偏移仍为 0（内容一动没动）',
    );
    final padding =
        tester.widget<SingleChildScrollView>(viewport).padding! as EdgeInsets;
    expect(
      tester.getRect(tail).bottom,
      moreOrLessEquals(
        tester.getRect(viewport).bottom - padding.bottom,
        epsilon: 0.5,
      ),
      reason: '拖动后仍贴在末尾',
    );

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  testWidgets('折叠态始终只渲染末尾窗口：思考结束后也不放开全文', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emitReasoning(longReasoning());
    await tester.pump();
    expect(
      find.textContaining('开头标记第一行'),
      findsNothing,
      reason: '生成中只渲染末尾窗口',
    );

    // 首个正文增量到达 → 当前思考块标记完成（内容不再变化）。
    ai.emit('正文开始');
    await tester.pump();

    expect(provider.agentEvents.single.done, isTrue);
    expect(
      find.textContaining('开头标记第一行'),
      findsNothing,
      reason: '折叠态只露 4~5 行且不可手动滚动，渲染全文只多付一次排版成本',
    );
    expect(find.textContaining('**末尾粗体**'), findsOneWidget);

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  testWidgets('done 后仍续吐思考（少数线路）：仍只渲染末尾窗口并贴住新内容', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emitReasoning(longReasoning());
    await tester.pump();

    // 正文开始 → 思考标记完成。
    ai.emit('正文开始');
    await tester.pump();
    expect(find.textContaining('开头标记第一行'), findsNothing);

    // 已完成的思考块又被追加（异常线路）：仍按末尾窗口渲染。
    ai.emitReasoning('追加的思考');
    await tester.pump();

    expect(provider.agentEvents.first.content, endsWith('追加的思考'));
    expect(
      find.textContaining('追加的思考'),
      findsOneWidget,
      reason: '内容继续增长时窗口跟着往后滑',
    );
    expect(
      find.textContaining('开头标记第一行'),
      findsNothing,
      reason: '内容还在变也不退回全文渲染（每个增量重排全文没有收益）',
    );

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  testWidgets('生成中展开：立即渲染全文（不受末尾窗口限制）', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emitReasoning(longReasoning());
    await tester.pump();
    expect(find.textContaining('开头标记第一行'), findsNothing);

    await tester.tap(find.text('思考中'));
    await tester.pump();

    expect(find.textContaining('开头标记第一行'), findsOneWidget);
    expect(
      provider.agentEvents.single.done,
      isFalse,
      reason: '展开只是视图状态，不改变思考块完成状态',
    );

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  for (final kind in const [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets('双击展开块正文（${kind.name}）：直接收起，无需滚回头部', (tester) async {
      final ai = FakeStreamingAiService();
      final provider = await pumpChatScreen(tester, ai: ai);

      final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
      await tester.pump();
      ai.emitReasoning(longReasoning());
      await tester.pump();

      await tester.tap(find.text('思考中'));
      await tester.pump();
      final head = find.textContaining('开头标记第一行');
      expect(head, findsOneWidget, reason: '已展开：全文上屏');
      // 用例前提：长链展开后头部（即唯一的单击收起入口）远在视口之上，
      // 所以收起只能靠「就近双击正文」。
      expect(
        tester.getRect(find.text('思考中')).bottom,
        lessThan(tester.getRect(find.byKey(const Key('chat_messages_area'))).top),
        reason: '展开后头部已滚出视口',
      );
      final expandedBottom = tester.getRect(head).bottom;

      await doubleTapAt(tester, visiblePointOn(tester, head), kind);

      expect(
        find.textContaining('开头标记第一行'),
        findsNothing,
        reason: '双击正文即收起（不必滚回顶部的头部）',
      );
      expect(
        tester.getRect(find.textContaining('末尾粗体')).bottom,
        moreOrLessEquals(expandedBottom, epsilon: 0.5),
        reason: '收起锁底边：内容朝上收拢，视口不跳',
      );

      expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
    });
  }
}
