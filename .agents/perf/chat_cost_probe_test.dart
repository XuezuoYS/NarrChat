/// 探针（非回归测试；属 `.agents/` 度量设施）：对话页 UI 成本基线。
///
/// 覆盖四件事：
/// 1. 「滚动到底部」链路：越界帧（= 用户看到的「往下多弹一段」）、
///    跳变帧数、收敛帧数与墙钟耗时；
/// 2. 流式生成：每批增量的单次 `pump` 耗时曲线（含 O(L²) 解析与
///    累计构树次数上升的叠加效应）；
/// 3. 单个 AI 气泡内的 `MarkdownBody` 数量（每次 = 一次全量解析 + 全量重排）
///    与**选中区域数量**；**P0-② / P0-④ 已落地**，此处断言的是修复后的期望
///    （选项不再各建一个 `MarkdownBody`；气泡内不再自建 `SelectionArea`，
///    整列只有列表外一个区域）；
/// 4. 滚动一屏（揭示新条目）的每帧耗时。
///
/// 运行：`flutter test .agents/perf/chat_cost_probe_test.dart`
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/widgets/chat_bubble.dart';
import 'package:narrchat/widgets/markdown_preview.dart';

import '../../test/helpers/chat_harness.dart';
import '../../test/helpers/fakes.dart';

const Book _book = Book(uuid: kHarnessBookUuid, title: '测试书');

/// 消息列的滚动位置（对话页只有一个纵向 `ListView`）。
ScrollPosition _chatPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// 造「前短后长」的多轮书籍（末 [longCount] 轮为超长正文，放大估算误差）。
Future<FakeRoundDao> _buildRounds({
  required int shortCount,
  required int longCount,
}) async {
  final dao = FakeRoundDao();
  for (var i = 1; i <= shortCount + longCount; i++) {
    final isLong = i > shortCount;
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: i,
        userInput: '第 $i 轮的用户输入',
        aiNarrative: isLong ? '尾部剧情正文。' * 260 : '第 $i 轮正文。' * 40,
        currentTime: '第一天 午时',
        createdAt: DateTime.now(),
      ),
    );
  }
  return dao;
}

void main() {
  testWidgets('落底链路 + 滚动成本基线（117 短 + 3 长 = 120 轮）', (tester) async {
    final dao = await _buildRounds(shortCount: 117, longCount: 3);
    await pumpChatScreen(tester, roundDao: dao);
    final pos = _chatPosition(tester);

    expect(pos.maxScrollExtent, greaterThan(0), reason: '内容必须溢出才有滚动意义');

    // 方向无关的「底部/顶部」：消息列已改 `reverse: true`（offset 0 = 底部），
    // `minScrollExtent` 即底部、`maxScrollExtent` 即顶部。
    final bottom = pos.minScrollExtent;
    final top = pos.maxScrollExtent;

    // 先回到顶部，再从生产入口（输入面板上方「滚动到底部」按钮）触发一次落底。
    pos.jumpTo(top);
    await tester.pump();
    expect(pos.pixels, closeTo(top, 1), reason: '已回到顶部');

    await tester.tap(find.byTooltip('滚动到底部'));

    final samples = <({double p, double m})>[];
    final sw = Stopwatch()..start();
    for (var i = 0; i < 80; i++) {
      // 采样点 = 该帧开始前（即上一帧动画/回调之后）的状态。
      samples.add((p: pos.pixels, m: pos.maxScrollExtent));
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(milliseconds: 16));
    }
    sw.stop();

    // 越界帧（越过底部 = 冲过头）与「到达底部之后是否还有位置变化（补滚残留）」。
    var overshootFrames = 0;
    var maxOvershoot = 0.0;
    for (final s in samples) {
      final o = bottom - s.p;
      if (o > 0.5) overshootFrames++;
      if (o > maxOvershoot) maxOvershoot = o;
    }
    var changedFrames = 0;
    var firstAtBottom = samples.length;
    for (var i = 0; i < samples.length; i++) {
      if (i > 0 && (samples[i].p - samples[i - 1].p).abs() > 0.5) changedFrames++;
      if (firstAtBottom == samples.length && (samples[i].p - bottom).abs() <= 1) {
        firstAtBottom = i;
      }
    }
    var postSettleChanges = 0;
    for (var i = firstAtBottom + 1; i < samples.length; i++) {
      if ((samples[i].p - samples[i - 1].p).abs() > 0.5) postSettleChanges++;
    }
    final finalGap = (samples.last.p - bottom).abs();

    // ignore: avoid_print
    print('--- L0-1 落底链路（120 轮，滚动到底部按钮）---');
    // ignore: avoid_print
    print(
      '越界帧(越过底部 >0.5px)=$overshootFrames/80 最大越界=${maxOvershoot.toStringAsFixed(1)}px '
      '| 位置变化帧=$changedFrames（含 300ms 动画） '
      '| 首次到底部于第 $firstAtBottom 帧 其后位置变化=$postSettleChanges '
      '| 耗时=${sw.elapsedMilliseconds}ms 最终误差=${finalGap.toStringAsFixed(2)}px',
    );

    expect(
      finalGap,
      lessThan(1.5),
      reason: '落底链路最终必须停在真实底部（既有不变量）',
    );
    // P0-③（reverse 底部锚定）落地后的期望：目标 offset 是**精确**边界
    // （minScrollExtent），不再有「jumpTo 懒加载估算值 → 冲过头 → 回弹 → 逐帧补滚」。
    expect(
      overshootFrames,
      0,
      reason: '不得越过底部（改造前：45/80 帧越界、最大 390.7px）',
    );
    expect(
      postSettleChanges,
      0,
      reason: '到达底部后不得再有补滚残留（改造前：68 帧后才稳定）',
    );

    // 滚动一屏（揭示新条目）的每帧耗时：手势逐步上移，每步一帧。
    // （向上拖动 = 揭示更新内容 = 朝底部；这里改为向下拖动，朝历史侧揭示。）
    final dragSw = Stopwatch()..start();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
    dragSw.stop();

    // ignore: avoid_print
    print(
      '--- L0-4 滚动 30 帧（向上揭示历史条目）--- '
      '总耗时=${dragSw.elapsedMilliseconds}ms '
      '每帧=${(dragSw.elapsedMicroseconds / 1000 / 30).toStringAsFixed(2)}ms',
    );
    expect(pos.pixels, greaterThan(0), reason: '手势应把列表滚离底部（揭示历史条目）');
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('流式增量成本曲线（60 轮底稿，约 8000 字正文）', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 60,
      seedBodyRepeats: 60,
    );
    for (var i = 0; i < 20; i++) {
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(milliseconds: 16));
    }

    // (0) 框架空转基线：什么都不改，只 pump → 得到 flutter_test 的每帧底噪。
    const idleBatches = 4;
    const idlePumps = 200;
    final idleMs = <double>[];
    for (var b = 0; b < idleBatches; b++) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < idlePumps; i++) {
        await tester.pump();
      }
      sw.stop();
      idleMs.add(sw.elapsedMicroseconds / 1000 / idlePumps);
    }
    final idleAvg = idleMs.reduce((a, b) => a + b) / idleMs.length;

    // (1)(2) 真实流式：每批推送固定字数，观察「每字成本」曲线。
    final sendFuture = provider.sendRound(userInput: '继续剧情', book: _book);
    await tester.pump();

    // (1) 空转但**有动画在跑**（生成中转圈）且无通知 → 一帧的固有开销。
    const framePumps = 200;
    final frameSw = Stopwatch()..start();
    for (var i = 0; i < framePumps; i++) {
      await tester.pump();
    }
    frameSw.stop();
    final frameMs = frameSw.elapsedMicroseconds / 1000 / framePumps;

    // (2) 通知路径基线：空增量（`contentDelta` 为空）仍会 `notifyListeners()`，
    //     但不改变正文 → 得到「通知 + 重建流式气泡」的固定成本。
    const notifyPumps = 200;
    final notifySw = Stopwatch()..start();
    for (var i = 0; i < notifyPumps; i++) {
      ai.emit('');
      await tester.pump();
    }
    notifySw.stop();
    final notifyMs = notifySw.elapsedMicroseconds / 1000 / notifyPumps;

    // (1b) 同一空增量、但**用户已手动上翻离开底部**（自动跟随短路，
    //      不再每帧 `jumpTo(maxScrollExtent)`）→ 分离「贴底跳转链路」与
    //      「重建路径」各自占多少。
    final pos = _chatPosition(tester);
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();
    // reverse：向下拖动 = 揭示更旧内容 = 离开底部。
    final awayFromBottom = pos.pixels > pos.minScrollExtent + 80;
    final notifyAwaySw = Stopwatch()..start();
    for (var i = 0; i < notifyPumps; i++) {
      ai.emit('');
      await tester.pump();
    }
    notifyAwaySw.stop();
    final notifyAwayMs = notifyAwaySw.elapsedMicroseconds / 1000 / notifyPumps;

    // 拉回底部（向上拖动 = 朝底部；越界被夹取 → 结束时的 idle 通知会把
    // 「用户已离开底部」复位），以便后面的增量曲线仍处于「贴底跟随」的真实语义下。
    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pump();
    expect(
      pos.pixels,
      lessThanOrEqualTo(pos.minScrollExtent + 1),
      reason: '探针前置条件：增量曲线必须在贴底状态下测量',
    );

    // (2) 真实增量：正文持续增长。
    const batches = 10;
    const perBatch = 100;
    const charsPerChunk = 8;
    final perChunkMs = <double>[];
    for (var b = 0; b < batches; b++) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < perBatch; i++) {
        ai.emit('字' * charsPerChunk);
        await tester.pump();
      }
      sw.stop();
      perChunkMs.add(sw.elapsedMicroseconds / 1000 / perBatch);
    }

    // ignore: avoid_print
    print(
      '--- L0-2 框架空转 pump 基线 = ${idleAvg.toStringAsFixed(3)} ms/帧'
      '（${idleMs.map((e) => e.toStringAsFixed(2)).join(', ')}）---',
    );
    // ignore: avoid_print
    print(
      '--- L0-2a 一帧固有开销（生成中转圈动画在跑、无通知）='
      '${frameMs.toStringAsFixed(3)} ms/帧---',
    );
    // ignore: avoid_print
    print(
      '--- L0-2 通知路径基线（空增量，不改正文，仍 notifyListeners）='
      '${notifyMs.toStringAsFixed(3)} ms/chunk'
      '（占首个增量成本的 '
      '${(notifyMs / perChunkMs.first * 100).toStringAsFixed(0)}%）---',
    );
    // ignore: avoid_print
    print(
      '--- L0-2b 同上但用户已上翻离开底部（自动跟随短路，无每帧 jumpTo）='
      '${notifyAwayMs.toStringAsFixed(3)} ms/chunk'
      '（离底成功=$awayFromBottom）'
      '→ 贴底跳转链路 ≈ ${(notifyMs - notifyAwayMs).toStringAsFixed(3)} ms/chunk---',
    );
    // ignore: avoid_print
    print('--- L0-2 流式增量：单次 pump 耗时（ms/chunk，每 chunk $charsPerChunk 字）---');
    for (var i = 0; i < batches; i++) {
      final chars = (i + 1) * perBatch * charsPerChunk;
      // ignore: avoid_print
      print(
        'batch ${i.toString().padLeft(2)}（累计 $chars 字）'
        ' = ${perChunkMs[i].toStringAsFixed(3)} ms'
        '（扣除空转底噪 ${(perChunkMs[i] - idleAvg).toStringAsFixed(3)} ms）',
      );
    }
    final netFirst = perChunkMs.first - idleAvg;
    final netLast = perChunkMs.last - idleAvg;
    // ignore: avoid_print
    print(
      '净增量成本 末/首 = ${(netLast / netFirst).toStringAsFixed(2)}x'
      '（首 ${netFirst.toStringAsFixed(3)} ms → 末 ${netLast.toStringAsFixed(3)} ms）；'
      '合计 ${perChunkMs.fold<double>(0, (a, b) => a + b * perBatch).toStringAsFixed(0)}ms',
    );

    expect(idleAvg, greaterThan(0), reason: '空转底噪必须被真实测量到');
    expect(
      perChunkMs.reduce((a, b) => a + b) / perChunkMs.length,
      greaterThan(idleAvg),
      reason: '流式增量（解析 + 重排 + 贴底）必须比空转帧更贵',
    );

    ai.complete();
    await waitSendDone(tester, provider);
    expect(await sendFuture, isTrue, reason: '流式轮次应正常收尾');
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('单个 AI 气泡内的 MarkdownBody / SelectionArea 数量', (tester) async {
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        userInput: '我沿着长街往南走',
        aiNarrative: '## 剧情演绎\n\n雨停了，**林昭**把斗笠往下压了压，朝南门走去。\n',
        recommendedAction:
            '- 直接去土地庙赴约\n'
            '- 先回客栈取那半张残图\n'
            '- 找船夫打听无名的货船\n'
            '- 在暗处观察庙祝的举动\n'
            '- 自定义行动',
        currentTime: '第一天 午时',
        createdAt: DateTime.now(),
      ),
    );
    await pumpChatScreen(tester, roundDao: dao);

    // 按 `isUser` 取气泡：`reverse: true` 下视图下标与逻辑序相反，
    // `find.byType(ChatBubble).first/last` 的先后不再对应「用户/AI」。
    final aiBubble = find.byWidgetPredicate(
      (w) => w is ChatBubble && !w.isUser,
    );
    final userBubble = find.byWidgetPredicate(
      (w) => w is ChatBubble && w.isUser,
    );
    final aiMarkdown = tester
        .widgetList(find.descendant(of: aiBubble, matching: find.byType(MarkdownBody)))
        .length;
    final aiSelectionAreas = tester
        .widgetList(find.descendant(of: aiBubble, matching: find.byType(SelectionArea)))
        .length;
    final userMarkdown = tester
        .widgetList(
          find.descendant(of: userBubble, matching: find.byType(MarkdownBody)),
        )
        .length;
    final totalMarkdown = tester.widgetList(find.byType(MarkdownBody)).length;
    final totalSelectionAreas =
        tester.widgetList(find.byType(SelectionArea)).length;
    final totalRegions = tester.widgetList(find.byType(SelectableRegion)).length;

    // ignore: avoid_print
    print(
      '--- L0-3 每气泡解析次数 / 选中容器（P0-② + P0-④ 落地后）--- '
      'AI 气泡 MarkdownBody=$aiMarkdown SelectionArea=$aiSelectionAreas | '
      '用户气泡 MarkdownBody=$userMarkdown | '
      '页面内 MarkdownBody 合计=$totalMarkdown '
      'SelectionArea 合计=$totalSelectionAreas '
      'SelectableRegion 合计=$totalRegions',
    );

    expect(
      aiMarkdown,
      lessThanOrEqualTo(2),
      reason: 'P0-② 验收：正文 1 次 + 选项 0 次（改造前 6 次：正文 + 5 选项）',
    );
    expect(
      aiMarkdown,
      greaterThanOrEqualTo(1),
      reason: '正文仍须走 Markdown 块级解析',
    );
    expect(
      aiSelectionAreas,
      0,
      reason: 'P0-④ 验收：气泡内不再自建选中区域（改造前 2 个：正文 + 推荐行动）',
    );
    expect(
      totalRegions,
      1,
      reason: '整列收敛为列表外一个区域（跨气泡连续选中的前提）',
    );
    expect(
      find.ancestor(
        of: aiBubble,
        matching: find.byType(SelectableRegion),
      ),
      findsOneWidget,
      reason: 'AI 气泡位于该区域内',
    );
    expect(
      find.ancestor(
        of: userBubble,
        matching: find.byType(SelectableRegion),
      ),
      findsOneWidget,
      reason: '用户气泡位于同一区域内',
    );
  });

  testWidgets('选中区域数量 → 平台文本处理查询次数（每区域一次往返）', (tester) async {
    // 每个 `SelectableRegion.initState` 都会查一次系统文本处理动作
    // （`SelectableRegionState._initProcessTextActions` →
    // `SystemChannels.processText`）。旧形态「每个气泡各自建区域」下，滚动到新
    // 条目、追加新气泡都会再付一次这个**平台往返**；收敛为列表外一个后整页一次。
    final queries = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.processText,
      (call) async {
        queries.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.processText, null),
    );

    // 5 轮 = 10 条气泡（AI 气泡带推荐行动），全部一次性构建（Column 非懒加载）。
    Widget page({required bool scope}) {
      final list = SingleChildScrollView(
        child: Column(
          children: [
            for (var round = 1; round <= 5; round++) ...[
              ChatBubble(isUser: true, text: '第 $round 轮的用户输入'),
              ChatBubble(
                isUser: false,
                text: '第 $round 轮的剧情正文。',
                recommendedAction: '- 选项一\n- 选项二',
              ),
            ],
          ],
        ),
      );
      return MaterialApp(
        home: Scaffold(
          body: scope ? SelectableTextScope(child: list) : list,
        ),
      );
    }

    await tester.pumpWidget(page(scope: false));
    await tester.pumpAndSettle();
    final perBubble = queries.length;
    final areasPerBubble =
        tester.widgetList(find.byType(SelectionArea)).length;

    queries.clear();
    await tester.pumpWidget(page(scope: true));
    await tester.pumpAndSettle();
    final scoped = queries.length;
    final areasScoped = tester.widgetList(find.byType(SelectionArea)).length;

    // ignore: avoid_print
    print(
      '--- L0-3b 平台文本处理查询（10 条气泡）--- 旧形态(各自区域)：'
      'SelectionArea=$areasPerBubble 查询=$perBubble 次 | '
      '作用域内：SelectionArea=$areasScoped 查询=$scoped 次',
    );

    expect(
      perBubble,
      areasPerBubble,
      reason: '每个区域各查一次系统文本处理动作（1:1）',
    );
    expect(scoped, 1, reason: '整块只有一个区域 → 只查一次');
  });
}
