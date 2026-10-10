/// 探针（非回归测试；属 `.agents/` 度量设施）：对话页 UI 成本基线。
///
/// 覆盖四件事：
/// 1. 「滚动到底部」链路：越界帧（= 用户看到的「往下多弹一段」）、
///    跳变帧数、收敛帧数与墙钟耗时；
/// 2. 流式生成：每批增量的单次 `pump` 耗时曲线（含 O(L²) 解析与
///    累计构树次数上升的叠加效应）；
/// 3. 单个 AI 气泡内的 `MarkdownBody` 数量（每次 = 一次全量解析 + 全量重排）
///    与 `SelectionArea` 数量；
/// 4. 滚动一屏（揭示新条目）的每帧耗时。
///
/// 运行：`flutter test .agents/perf/chat_cost_probe_test.dart`
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/widgets/chat_bubble.dart';

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

    // 先回到顶部，再从生产入口（输入面板上方「滚动到底部」按钮）触发一次落底。
    pos.jumpTo(0);
    await tester.pump();
    expect(pos.pixels, 0, reason: '已回到顶部');

    await tester.tap(find.byTooltip('滚动到底部'));

    final samples = <({double p, double m})>[];
    final sw = Stopwatch()..start();
    for (var i = 0; i < 80; i++) {
      // 采样点 = 该帧开始前（即上一帧 postFrame 里的 jumpTo 之后）的状态。
      samples.add((p: pos.pixels, m: pos.maxScrollExtent));
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(milliseconds: 16));
    }
    sw.stop();

    var overshootFrames = 0;
    var maxOvershoot = 0.0;
    for (final s in samples) {
      final o = s.p - s.m;
      if (o > 0.5) overshootFrames++;
      if (o > maxOvershoot) maxOvershoot = o;
    }
    var changedFrames = 0;
    for (var i = 1; i < samples.length; i++) {
      if ((samples[i].p - samples[i - 1].p).abs() > 0.5) changedFrames++;
    }
    var firstStable = samples.length;
    for (var i = samples.length - 1; i >= 0; i--) {
      if ((samples[i].p - samples[i].m).abs() > 1) {
        firstStable = i + 1;
        break;
      }
    }
    final finalGap = (samples.last.p - samples.last.m).abs();

    // ignore: avoid_print
    print('--- L0-1 落底链路（120 轮，滚动到底部按钮）---');
    // ignore: avoid_print
    print(
      '越界帧(>0.5px)=$overshootFrames/80 最大越界=${maxOvershoot.toStringAsFixed(1)}px '
      '| 位置变化帧=$changedFrames $firstStable 帧后稳定 '
      '| 收敛耗时=${sw.elapsedMilliseconds}ms 最终误差=${finalGap.toStringAsFixed(2)}px',
    );

    expect(
      finalGap,
      lessThan(1.5),
      reason: '落底链路最终必须停在真实底部（既有不变量）',
    );
    // 探针断言：复现「多弹一段 / 多次跳变」这一缺陷；修复后应改为
    // changedFrames <= 2 且 overshootFrames == 0。
    expect(
      changedFrames,
      greaterThan(2),
      reason: '落底当前经由多帧 jumpTo 收敛（L0 待优化点）',
    );

    // 滚动一屏（揭示新条目）的每帧耗时：手势逐步上移，每步一帧。
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
    expect(pos.pixels, greaterThan(0), reason: '手势应把列表向上滚动离开底部');
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
    final awayFromBottom = pos.pixels < pos.maxScrollExtent - 80;
    final notifyAwaySw = Stopwatch()..start();
    for (var i = 0; i < notifyPumps; i++) {
      ai.emit('');
      await tester.pump();
    }
    notifyAwaySw.stop();
    final notifyAwayMs = notifyAwaySw.elapsedMicroseconds / 1000 / notifyPumps;

    // 拉回底部（越界被夹取 → 结束时的 idle 通知会把「用户已离开底部」复位），
    // 以便后面的增量曲线仍处于「贴底跟随」的真实语义下。
    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pump();
    expect(
      pos.pixels,
      greaterThanOrEqualTo(pos.maxScrollExtent - 1),
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

    final aiBubble = find.byType(ChatBubble).last;
    final userBubble = find.byType(ChatBubble).first;
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

    // ignore: avoid_print
    print(
      '--- L0-3 每气泡解析次数 --- AI 气泡 MarkdownBody=$aiMarkdown '
      'SelectionArea=$aiSelectionAreas | 用户气泡 MarkdownBody=$userMarkdown '
      '| 页面内 MarkdownBody 合计=$totalMarkdown',
    );

    expect(
      aiMarkdown,
      greaterThanOrEqualTo(5),
      reason: '推荐行动逐项各建一个 MarkdownBody（每项一次全量解析）',
    );
    expect(
      aiSelectionAreas,
      greaterThanOrEqualTo(2),
      reason: '正文与推荐行动各自建一个 SelectionArea',
    );
  });
}
