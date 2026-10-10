/// 探针（非回归测试；属 `.agents/` 度量设施）：**离底阅读时的「内容漂移」**。
///
/// 背景：消息列改成 `reverse: true`（底部锚定）后，新内容插在滚动坐标系起点
/// （视觉底部）。贴底时这正是我们想要的（新内容把旧内容顶上去）；但用户已上翻
/// 阅读历史时，**视口下方已构建**的内容长高会把可视内容整体向上推 —— 合成宿主已
/// 测出该位移恰好等于长高的量（`.agents/perf/reverse_anchor_probe_test.dart` D2/D3）。
///
/// 度量口径：漂移量 = `maxScrollExtent` 的增量（视口下方内容长了多少，可视内容就被
/// 推走多少；pixels 不变）。本探针在真实对话页链路测两种配置：
/// - **A 场景（流式气泡已长高且被构建）**：预期持续漂移（Δmax > 0、pixels 不变）；
/// - **B 场景（气泡还很矮，被移出 cache 区）**：布局模型冻结（Δmax = 0、漂移 = 0）。
///
/// 运行：`flutter test .agents/perf/reading_drift_probe_test.dart`
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';

import '../../test/helpers/chat_harness.dart';
import '../../test/helpers/fakes.dart';

const Book _book = Book(uuid: kHarnessBookUuid, title: '测试书');

ScrollPosition _pos(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// 在 [batches] 次增量中测量「Δmax（= 漂移量）」与 pixels 变化。
///
/// [visualAnchor]（可选）用于交叉验证：被构建但可能在视口外的参考部件，
/// 其全局 y 应随内容增长而上移同样的量。
Future<void> _measureDrift(
  WidgetTester tester,
  FakeStreamingAiService ai, {
  required int batches,
  required String label,
  Finder? visualAnchor,
}) async {
  final pixelsBefore = _pos(tester).pixels;
  final maxBefore = _pos(tester).maxScrollExtent;
  double? anchorBefore;
  if (visualAnchor != null && visualAnchor.evaluate().isNotEmpty) {
    anchorBefore = tester.getTopLeft(visualAnchor).dy;
  }
  var anchorAfter = anchorBefore;

  for (var i = 0; i < batches; i++) {
    ai.emit('更多正文内容第 $i 段，用来撑高气泡并观察漂移。' * 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    if (visualAnchor != null && visualAnchor.evaluate().isNotEmpty) {
      anchorAfter = tester.getTopLeft(visualAnchor).dy;
    }
  }

  final dPixels = _pos(tester).pixels - pixelsBefore;
  final dMax = _pos(tester).maxScrollExtent - maxBefore;
  // ignore: avoid_print
  print(
    '--- $label（$batches 段增量）---\n'
    '  漂移量 Δmax=${dMax.toStringAsFixed(1)}px'
    '｜pixels Δ=${dPixels.toStringAsFixed(1)}（补偿成功时 ≈ 视口下方真实增长量）\n'
    '  参考部件全局 top：'
    '${anchorBefore == null ? '（无可用参考）' : '${anchorBefore.toStringAsFixed(1)} → ${anchorAfter!.toStringAsFixed(1)}'
        '（位移 ${(anchorAfter - anchorBefore).toStringAsFixed(1)}px）'}',
  );
}

void main() {
  testWidgets('A 场景：离底阅读时流式增长把可视内容推走', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 6,
      seedBodyRepeats: 200,
    );
    final sendFuture = provider.sendRound(userInput: '继续剧情', book: _book);
    await tester.pump();

    // 先贴底推一段，让流式气泡长到远高于视口（保证离开底部后仍然被构建）。
    for (var i = 0; i < 20; i++) {
      ai.emit('开篇正文第 $i 段，先把气泡撑高。' * 3);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_pos(tester).pixels, closeTo(0, 1), reason: '推流期间应始终贴底');

    // 离开底部：向下拖动 200px（揭示更旧内容）。
    // （生成中不能 pumpAndSettle：发送按钮有无限转圈动画。）
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_pos(tester).pixels, greaterThan(100), reason: '前提：已离开底部');

    await _measureDrift(
      tester,
      ai,
      batches: 20,
      label: 'A 场景 离底阅读漂移（气泡已长高、已构建）',
      // 待定用户气泡（在流式气泡**上方**）：被构建且在 cache 区内，可交叉验证漂移。
      visualAnchor: find.text('继续剧情'),
    );

    ai.complete();
    await waitSendDone(tester, provider);
    expect(await sendFuture, isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('B 场景：气泡仍矮、被移出 cache → 布局模型冻结（无漂移）', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 6,
      seedBodyRepeats: 200,
    );
    // 先离开底部，再开始生成（此时流式气泡刚出现、还很矮）。
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pumpAndSettle();

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: _book);
    await tester.pump();
    await _measureDrift(
      tester,
      ai,
      batches: 40,
      label: 'B 场景 离底阅读漂移（气泡仍矮、未构建）',
      visualAnchor: find.textContaining('第 6 轮的剧情正文'),
    );

    ai.complete();
    await waitSendDone(tester, provider);
    expect(await sendFuture, isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
