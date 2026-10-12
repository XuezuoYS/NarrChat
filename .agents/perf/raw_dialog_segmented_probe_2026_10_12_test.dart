/// 探针（非回归测试；属 `.agents/perf/` 度量设施）：**真实 RAW 对话框**在
/// 换用 `SelectionArea` + 分段 `RichText` 之后的端到端耗时。
///
/// 修前基线（同一台机器、同一 debug 口径，见 `.agents/2026-10-12-raw-perf.md`）：
/// 一块 20 万字符 / 12500 处命中的文本用 `SelectableText.rich` 整块渲染 ——
/// 首次展开冷排版 2239 ms，之后每点一次「下一处」（挪「当前定位」橙底）545 ms。
///
/// 这里跑的是用户真正会走的那条路：打开对话框 → 点标题展开 → 输关键词搜索 →
/// 连点「下一处」，逐段计时。视口保持 flutter_test 默认（800×600 / dpr 3），
/// 与修前那批数字同口径，可直接相减。
///
/// 运行：`flutter test .agents/perf/raw_dialog_segmented_probe_2026_10_12_test.dart`
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/raw_exchange.dart';
import 'package:narrchat/widgets/raw_dialog.dart';

int _seq = 0;

/// 20 万字符、每 16 字一处「青云」的冷文本（≈12500 处命中 / 25001 个 span）。
String _coldText({int chars = 200_000}) {
  const unit = r'青云宗是北域大派，弟子三千。\n';
  final sb = StringBuffer('#${_seq++}|');
  while (sb.length < chars) {
    sb.write(unit);
  }
  return expandEscapes(sb.toString());
}

double _msOf(Stopwatch sw) {
  sw.stop();
  return sw.elapsedMicroseconds / 1000;
}

void main() {
  testWidgets('真实对话框：展开 / 搜索 / 连点下一处（分段渲染后）', (tester) async {
    final text = _coldText();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RawDialog(
            exchanges: [
              RawExchange(
                requestBody: text,
                thinking: '无',
                toolCalls: '',
                content: '',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final hits = countMatches(text, '青云');
    print('文本 = ${text.length} 字符 · 命中「青云」= $hits 处');

    // 1) 点开请求体块：冷排版（分段后只有第一段真正付钱）。
    var sw = Stopwatch()..start();
    await tester.tap(find.text('【请求体 1】'));
    await tester.pumpAndSettle();
    print('展开请求体块 = ${_msOf(sw).toStringAsFixed(0)} ms');

    // 2) 搜索：扫描全部块 + 首处定位（含滚动动画）。
    sw = Stopwatch()..start();
    await tester.enterText(find.byKey(const Key('raw_search_field')), '青云');
    await tester.tap(find.byKey(const Key('raw_search_button')));
    await tester.pumpAndSettle();
    print('搜索「青云」= ${_msOf(sw).toStringAsFixed(0)} ms');
    expect(find.text('1/$hits'), findsOneWidget);

    // 3) 连点「下一处」：每次只挪橙底，分段后只重排命中所在的那一段。
    for (var i = 1; i <= 6; i++) {
      sw = Stopwatch()..start();
      await tester.tap(find.byKey(const Key('raw_match_next')));
      await tester.pumpAndSettle();
      print('第 $i 次下一处 = ${_msOf(sw).toStringAsFixed(0)} ms');
    }
  });

  testWidgets('对照：同一份文本用 SelectableText.rich 整块渲染（修前形状）', (tester) async {
    final text = _coldText();
    const base = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.5);
    final hl = base.copyWith(backgroundColor: const Color(0x80FFF176));
    final current = base.copyWith(backgroundColor: const Color(0x99FFB74D));
    var index = 0;

    Future<void> pumpSpan() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SelectableText.rich(
                TextSpan(
                  children: highlightSpans(
                    text,
                    '青云',
                    base,
                    hl,
                    currentIndex: index,
                    currentStyle: current,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    var sw = Stopwatch()..start();
    await pumpSpan();
    print('整块 SelectableText 首次排版 = ${_msOf(sw).toStringAsFixed(0)} ms');

    for (var i = 1; i <= 6; i++) {
      sw = Stopwatch()..start();
      index++;
      await pumpSpan();
      print('第 $i 次挪当前项（整块重排）= ${_msOf(sw).toStringAsFixed(0)} ms');
    }
  });
}
