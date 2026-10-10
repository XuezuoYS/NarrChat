/// 探针（非回归测试；属 `.agents/perf/` 度量设施。文件名里的 `2026_10_11`
/// 标记「对话页 UI 性能优化」本轮收官日期，本轮之后不再更新）：
/// 定点跳转的**首帧落点**、**到达帧**与**单帧成本**。
///
/// 背景：楼层跳转早期是「偏移模型粗定位（`jumpTo`，无动画）→ 帧末用
/// `getOffsetToReveal` 精确对齐」两段式，已先后修掉两类缺陷（详见
/// `.agents/2026-10-11-chat-ui-perf-plan.md` 的 P0-③ 与「§13 跳转修复」小节）：
/// - 模型量（条目顶边坐标，视口顶为参照）被当 `pixels`（视口底边）用 → 首帧整体
///   偏大一个视口高（气泡落在窗口底部）；
/// - 一次 `jumpTo` 越界 → 框架单帧逐条构建几百个途经条目（曾 1043ms/帧），
///   且范围估算重排后偏移模型失效 → 远端目标根本到不了。
///
/// 现实现：`_stepJumpTowardItem` 按条目数限步分帧推进（方向取已构建条目的序号
/// 区间），`_alignedOffsetForTarget` 直接量目标在视口内的 y 做精确对齐。
///
/// 本探针测量（每个「冷」样本都在**独立 `testWidgets`** 里跑：对话页 State 在
/// 同一测试内多次 `pumpChatScreen` 会被复用，实测缓存会串味，故必须一测一页）：
/// - **首帧落点/到达帧**：目标轮 user 气泡顶相对消息视口顶的偏差（≈9px 已对齐；
///   ≈视口高 = 旧行为「气泡先落在窗口底部」；「未构建」= 该帧还没命中目标）；
/// - **单帧成本**：远端跳转每帧构建量有界（旧实现曾 1043ms/帧）。
///
/// 书形：
/// - 「均匀书」（6 轮 × 200 重复正文）：高度模型精确 → 首帧即应对齐，**硬断言**；
/// - 「长短混合书」（117 短 + 3 长、120 轮）：懒加载范围估算与均值高度模型误差
///   都被放大 → 断言「远端/过早轮次 40 帧内到达」且「单帧 < 600ms」（**硬断言**），
///   同时打印冷/热逐帧轨迹作诊断。
///
/// 运行：`flutter test .agents/perf/floor_jump_frame_probe_2026_10_11_test.dart`
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/widgets/floor_jump_bar.dart';

import '../../test/helpers/chat_harness.dart';
import '../../test/helpers/fakes.dart';

/// 各用例打印的汇总结论（`tearDownAll` 统一输出）。
final List<String> _summary = [];

/// 前短后长书籍：末 [longCount] 轮为超长正文（放大未构建条目的高度估算误差）。
Future<FakeRoundDao> _buildMixedRounds({
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

/// 悬浮条中间的数字输入框。
Finder _barNumberField() => find.descendant(
  of: find.byType(FloorJumpBar),
  matching: find.byType(TextField),
);

/// 触发一次定点跳转（走生产入口：打开悬浮条 → 输入数字 → 回车），只 pump 一帧。
Future<void> _jumpOnce(WidgetTester tester, int round) async {
  await tester.tap(find.byIcon(Icons.layers_outlined));
  await tester.pumpAndSettle();
  await tester.enterText(_barNumberField(), '$round');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

String _fmt(double? v) => v == null ? '未构建' : '${v.toStringAsFixed(1)}px';

/// 指定轮次 user 气泡文本顶相对消息视口顶的偏差（null = 该轮未被构建）。
double? _topGapOfRound(WidgetTester tester, int round) {
  final finder = find.text('第 $round 轮的用户输入');
  if (finder.evaluate().isEmpty) return null;
  return tester.getTopLeft(finder).dy -
      tester.getTopLeft(find.byType(ListView)).dy;
}

/// 一次跳转的首帧/收敛测量结果。
typedef _JumpSample = ({double? first, double? settled, double viewport});

/// 在**独立测试**里跑一个冷样本：全新页面 + 单次跳转 + 有界帧推进。
///
/// 有界推进（而不是 `pumpAndSettle`）是刻意的：冷跳远端目标时列表的范围估算与
/// 逐帧校准会持续请求新帧，`pumpAndSettle` 在该状态下不返回；这里固定推进
/// [frames] 帧再读落点，另外用 `hasScheduledFrame` 记录「第 [frames] 帧后是否
/// 仍被要求继续出帧」（= 是否还在动）。
Future<_JumpSample> _coldSample(
  WidgetTester tester,
  FakeRoundDao dao,
  int round, {
  int seedRounds = 0,
  int seedBodyRepeats = 40,
  int frames = 40,
  void Function(int frame, double? gap, bool scheduled)? onFrame,
}) async {
  await pumpChatScreen(
    tester,
    roundDao: dao,
    seedRounds: seedRounds,
    seedBodyRepeats: seedBodyRepeats,
  );
  final viewport = _chatPosition(tester).viewportDimension;
  await _jumpOnce(tester, round);
  final first = _topGapOfRound(tester, round);
  for (var i = 0; i < frames; i++) {
    onFrame?.call(i, _topGapOfRound(tester, round), tester.binding.hasScheduledFrame);
    await tester.pump(const Duration(milliseconds: 16));
  }
  return (
    first: first,
    settled: _topGapOfRound(tester, round),
    viewport: viewport,
  );
}

void main() {
  tearDownAll(() {
    // ignore: avoid_print
    print('--- L0-5 汇总 ---\n${_summary.join('\n')}');
  });

  // ---------------- 冷跳远端/过早/未加载轮次：到达帧与单帧成本 ----------------
  // 两个验收量：
  // ① **到达帧**：目标轮起点对齐视口顶（9px = 气泡内边距）发生在第几帧——
  //    限步分帧推进后，远端跳转不再「一帧构建几百条」，代价是若干帧；
  // ② **单帧成本**：最大单帧耗时（旧实现冷跳远端曾出现 **1043ms** 单帧）。
  for (final round in <int>[1, 2, 5, 30, 60, 90, 119, 120]) {
    testWidgets('混合书冷跳第 $round 轮：到达帧与单帧成本', (tester) async {
      final dao = await _buildMixedRounds(shortCount: 117, longCount: 3);
      await pumpChatScreen(tester, roundDao: dao);
      final pos = _chatPosition(tester);
      await _jumpOnce(tester, round);
      var arrived = -1;
      var worstMs = 0;
      var worstFrame = 0;
      final trail = <String>[];
      for (var f = 0; f < 40; f++) {
        final gap = _topGapOfRound(tester, round);
        if (arrived < 0 && gap != null && gap.abs() < 15) arrived = f + 1;
        if (f < 4 || f % 10 == 9) {
          trail.add(
            '${f + 1}:px=${pos.pixels.toStringAsFixed(0)}'
            '/目标=${_fmt(gap)}',
          );
        }
        final sw = Stopwatch()..start();
        await tester.pump(const Duration(milliseconds: 16));
        sw.stop();
        if (sw.elapsedMilliseconds > worstMs) {
          worstMs = sw.elapsedMilliseconds;
          worstFrame = f + 1;
        }
      }
      final finalGap = _topGapOfRound(tester, round);
      // ignore: avoid_print
      print(
        '--- L0-6 冷跳第 $round 轮：到达第 ${arrived < 0 ? '未到达' : '$arrived'} 帧'
        ' | 40 帧后=${_fmt(finalGap)}'
        ' | 最大单帧=${worstMs}ms(第 $worstFrame 帧)'
        ' | 轨迹=${trail.join(' ')}',
      );
      _summary.add(
        '冷跳第 $round 轮：到达第 ${arrived < 0 ? '—' : arrived} 帧、'
        '40 帧后=${_fmt(finalGap)}、最大单帧=${worstMs}ms',
      );
      expect(
        arrived,
        greaterThan(0),
        reason: '远端/过早/未加载轮次的跳转必须最终到达目标（旧实现冷跳第 1/30/60/90 轮永远到不了）',
      );
      expect(worstMs, lessThan(600), reason: '单帧构建量必须有界（旧实现曾 1043ms/帧）');
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  // ---------------- 均匀书（硬断言） ----------------
  for (final round in <int>[2, 4, 6]) {
    testWidgets('均匀书第 $round 轮：首帧即对齐视口顶且收敛后仍对齐', (tester) async {
      final s = await _coldSample(
        tester,
        FakeRoundDao(),
        round,
        seedRounds: 6,
        seedBodyRepeats: 200,
      );
      // ignore: avoid_print
      print(
        '--- L0-5 均匀书第 $round 轮：首帧气泡顶偏差=${_fmt(s.first)}'
        '（旧行为 ≈ 视口高 ${s.viewport.toStringAsFixed(0)}px）'
        ' | 收敛后=${_fmt(s.settled)}',
      );
      expect(s.first, isNotNull, reason: '首帧必须已构建目标轮');
      expect(
        s.first!,
        inInclusiveRange(-s.viewport * 0.3, s.viewport * 0.3),
        reason: '首帧就应落在视口顶部附近（旧行为 ≈ 偏下 1.0 屏）',
      );
      expect(s.settled!.abs(), lessThan(15), reason: '收敛后仍须对齐视口顶');
    });
  }

  // ---------------- 长短混合书（诊断） ----------------
  // 注意：DAO 必须在**测试体内**构造。在 `main()` 声明期先构造好（`await` 一个
  // 提前启动的 Future）会让 `pumpChatScreen` 卡住不出帧——疑似跨 zone 的异步
  // 收尾没有在 widget 测试的伪时钟 zone 内被排空。
  for (final round in <int>[2, 30, 60, 90, 119]) {
    testWidgets('混合书第 $round 轮：冷跳转诊断', (tester) async {
      final trace = <String>[];
      var stillScheduled = false;
      final s = await _coldSample(
        tester,
        await _buildMixedRounds(shortCount: 117, longCount: 3),
        round,
        onFrame: (frame, gap, scheduled) {
          if (frame < 4 || frame == 9 || frame == 19 || frame == 39) {
            trace.add('${frame + 1}:${_fmt(gap)}');
          }
          if (frame == 39) stillScheduled = scheduled;
        },
      );
      final firstOk = s.first != null && s.first!.abs() < 15;
      final settledOk = s.settled != null && s.settled!.abs() < 15;
      // ignore: avoid_print
      print(
        '--- L0-5 混合书第 $round 轮（冷）：首帧=${_fmt(s.first)}'
        ' | 40 帧后=${_fmt(s.settled)}'
        ' | 逐帧=${trace.join(' ')}'
        ' | 40 帧后仍需出帧=$stillScheduled'
        ' | 视口高=${s.viewport.toStringAsFixed(0)}px',
      );
      _summary.add(
        '混合书第 $round 轮（冷）：首帧${firstOk ? '已对齐' : _fmt(s.first)}、'
        '40 帧后${settledOk ? '已对齐' : _fmt(s.settled)}',
      );
    });
  }

  // ---------------- 热模型：同一页连续跳（真实使用） ----------------
  testWidgets('混合书热模型：同一页面连续跳转', (tester) async {
    final dao = await _buildMixedRounds(shortCount: 117, longCount: 3);
    await pumpChatScreen(tester, roundDao: dao);
    final pos = _chatPosition(tester);
    final bottom = pos.minScrollExtent;
    var firstOk = 0;
    var settledOk = 0;
    final out = <String>[];
    for (final round in <int>[2, 30, 60, 90, 119]) {
      pos.jumpTo(bottom);
      await tester.pump();
      await _jumpOnce(tester, round);
      final first = _topGapOfRound(tester, round);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final settled = _topGapOfRound(tester, round);
      if (first != null && first.abs() < 15) firstOk++;
      if (settled != null && settled.abs() < 15) settledOk++;
      out.add('第$round轮〔首帧=${_fmt(first)} 40帧后=${_fmt(settled)}〕');
    }
    // ignore: avoid_print
    print(
      '--- L0-5 混合书（热）：${out.join(' ')} | 首帧已对齐 $firstOk/5、'
      '40 帧后已对齐 $settledOk/5',
    );
    _summary.add('混合书（热）：首帧已对齐 $firstOk/5、40 帧后已对齐 $settledOk/5');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
