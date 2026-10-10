/// 探针（非回归测试；属 `.agents/` 度量设施）：
/// P0-②「推荐行动改为一次解析」的收益（一个 AI 气泡 = 正文 + 5 条选项）。
///
/// 微基准：交替渲染两组内容，逼出「从零构建一个旧气泡」的成本（= 滚动时首次
/// 揭示该气泡要付的钱），对比两条渲染路径：
/// - **现状（重建）**：正文 `MarkdownPreview` + 逐选项 `_OptionRow`（符号 +
///   每项一个 `MarkdownPreview`）——即 P0-② 改造前的实现，为对照在本探针内
///   按原样重建（`MarkdownBody` 合计 6 次）；
/// - **P0-②（一次解析）**：正文 `MarkdownPreview` + `RecommendedActionView`
///   （选项走内联 span，`MarkdownBody` 合计 1 次）。
///
/// 运行：`flutter test .agents/perf/recommended_action_probe_test.dart`
/// ⚠️ 必须**单独运行**（与其他测试并发会污染耗时比值）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/recommended_action_parser.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_preview.dart';
import 'package:narrchat/widgets/recommended_action_view.dart';

const TextStyle _base = TextStyle(fontSize: 15, height: 1.65);

const String _narrativeA = '## 剧情演绎\n\n雨停了，**林昭**把斗笠往下压了压，朝南门走去。\n';
const String _narrativeB = '## 剧情演绎\n\n街市上只剩几盏残灯，**林昭**在桥头停住脚。\n';
const String _actionA = '1. 直接去土地庙赴约\n'
    '2. 先回客栈取那半张残图\n'
    '3. 找船夫打听无名的货船\n'
    '4. 在暗处观察庙祝的举动\n'
    '5. 自定义行动';
const String _actionB = '1. 沿南门长街再走一段\n'
    '2. 向卖炭翁打听昨夜的事\n'
    '3. 回客栈翻那半张残图的背面\n'
    '4. 站在桥头等庙祝出现\n'
    '5. 自定义行动';

/// P0-② 改造前的推荐行动区块（对照重建）。
Widget _legacyAction(BuildContext context, String data) {
  final options = splitRecommendedAction(data).whereType<RecommendedActionOption>();
  return SelectableTextArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final option in options)
          Row(
            mainAxisSize: MainAxisSize.min,
            textBaseline: TextBaseline.alphabetic,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            children: [
              SizedBox(
                width: GitHubMarkdownStyle.listBulletWidth,
                child: Padding(
                  padding: GitHubMarkdownStyle.listBulletPadding,
                  child: MarkdownPreview.buildListBullet(
                    context,
                    MarkdownBulletParameters(
                      index: option.ordered ? option.number - 1 : 0,
                      style: option.ordered
                          ? BulletStyle.orderedList
                          : BulletStyle.unorderedList,
                      nestLevel: 0,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: MarkdownPreview(
                  data: option.content,
                  base: _base,
                  selectable: false,
                ),
              ),
            ],
          ),
      ],
    ),
  );
}

/// 一个 AI 气泡的推荐下一步区块：现状（重建）或 P0-②（一次解析）。
Widget _bubbleAction({required bool optimized, required bool variantB}) {
  final narrative = variantB ? _narrativeB : _narrativeA;
  final action = variantB ? _actionB : _actionA;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      MarkdownPreview(data: narrative, base: _base, selectable: false),
      const SizedBox(height: 10),
      Builder(
        builder: (context) => optimized
            ? RecommendedActionView(
                data: action,
                base: _base,
                onInsert: (_) {},
              )
            : _legacyAction(context, action),
      ),
    ],
  );
}

void main() {
  testWidgets('微基准：揭示一个旧气泡（正文 + 5 选项）的构建成本', (tester) async {
    const updatesPerBatch = 200;
    const batches = 4;
    final perUpdate = <List<double>>[];

    for (final optimized in [false, true]) {
      final variant = ValueNotifier<bool>(false);
      addTearDown(variant.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: NarrChatTheme.light,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ValueListenableBuilder<bool>(
                valueListenable: variant,
                builder: (context, v, _) =>
                    _bubbleAction(optimized: optimized, variantB: v),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 空转底噪（不换内容、只 pump）。
      const idlePumps = 200;
      final idleSw = Stopwatch()..start();
      for (var i = 0; i < idlePumps; i++) {
        await tester.pump();
      }
      idleSw.stop();
      final idle = idleSw.elapsedMicroseconds / 1000 / idlePumps;

      final ms = <double>[];
      for (var b = 0; b < batches; b++) {
        final sw = Stopwatch()..start();
        for (var i = 0; i < updatesPerBatch; i++) {
          variant.value = i.isEven;
          await tester.pump();
        }
        sw.stop();
        ms.add(sw.elapsedMicroseconds / 1000 / updatesPerBatch - idle);
      }
      perUpdate.add(ms);

      final totalBodies = tester.widgetList(find.byType(MarkdownBody)).length;
      // ignore: avoid_print
      print(
        '--- P0-② 探针｜${optimized ? 'P0-②一次解析' : '现状（每项一个 MarkdownBody）'} --- '
        '页面 MarkdownBody=$totalBodies',
      );
      expect(
        find.text('自定义行动', findRichText: true),
        findsOneWidget,
        reason: '选项确实渲染在屏上',
      );
      if (optimized) {
        expect(totalBodies, 1, reason: '正文 1 + 选项 0');
      } else {
        expect(totalBodies, 6, reason: '正文 1 + 选项 5（P0-② 改造前）');
      }
    }

    final legacy = perUpdate[0];
    final optimized = perUpdate[1];
    // ignore: avoid_print
    print('batch        现状（每项一个 MarkdownBody）   P0-②一次解析   倍数');
    for (var b = 0; b < batches; b++) {
      // ignore: avoid_print
      print(
        'batch $b   ${legacy[b].toStringAsFixed(3).padLeft(12)} ms'
        '   ${optimized[b].toStringAsFixed(3).padLeft(14)} ms'
        '   ${(legacy[b] / optimized[b]).toStringAsFixed(2).padLeft(6)}x',
      );
    }
    final legacyAvg = legacy.reduce((a, b) => a + b) / batches;
    final optimizedAvg = optimized.reduce((a, b) => a + b) / batches;
    // ignore: avoid_print
    print(
      '平均 ${legacyAvg.toStringAsFixed(3)} ms → ${optimizedAvg.toStringAsFixed(3)} ms/次'
      '（${(legacyAvg / optimizedAvg).toStringAsFixed(2)}x）',
    );

    expect(optimizedAvg, lessThan(legacyAvg), reason: '选项不再各建 MarkdownBody 应更快');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
