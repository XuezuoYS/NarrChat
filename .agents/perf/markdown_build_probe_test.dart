/// 探针（非回归测试；属 `.agents/` 度量设施）：
/// 判定 `flutter_markdown` 的 `MarkdownBuilder.build()` 每次调用都向
/// **库级全局** `_kBlockTags` 追加一条 `'div'`（无去重，
/// `flutter_markdown-0.7.7+1/lib/src/builder.dart:253-257`）、而块标签判定
/// `_isBlockTag` 走 `List.contains`（`builder.dart:36, 287, 447, 811`）
/// 这一「随累计构树次数增长」的隐性劣化到底有多大。
///
/// 做法：**递增扫描**而不是单次前后对比——每一步只用极小文档灌入
/// [inflateStep] 次构树，然后在同一步内测量「大文档 Markdown」与
/// 「大文档纯文本（对照组）」的耗时中位数，取比值。
/// 比值曲线若随灌入量单调上升即为效应本身；JIT/机器抖动由对照组抵消。
///
/// ⚠️ 请**单独**运行本文件（与其他测试并发时资源争抢会污染比值）：
/// `flutter test .agents/perf/markdown_build_probe_test.dart`
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/markdown_preview.dart';

/// 接近真实 AI 输出的正文（含标题 / 列表 / 粗体 / 引用 / 行内代码），约 1.6k 字符。
const String _narrative = '''
## 剧情演绎

雨到了傍晚才停，青石长街上积着一层薄水，倒映着檐角**昏黄的灯**。
林昭把斗笠往下压了压，目光扫过茶馆二层那扇半开的窗——那里坐着的人，正是三日前
在渡口递给他半张残图的陌生人。

> 「你若真想知道那批货去了哪儿，」那人当时说，「今晚三更，到城南的土地庙等我。」

### 需要注意的三件事

- 那半张残图的边角有明显的**火燎痕迹**，说明原件曾被烧过；
- 渡口的船夫提到过一艘没有名字的货船，凌晨出发，吃水比寻常船深得多；
- 城南土地庙的香火三年前就断了，如今只有一个跛脚庙祝守着。

林昭在檐下站了一会儿，把手里的铜钱翻来覆去地摩挲。他知道这一步迈出去，
就不再是替人跑腿的小角色了——`江湖` 这两个字，从来都是用命换来的。

雨后的空气里混着潮湿的草木气，远处更夫敲了三下梆子。他整了整衣襟，转身
朝南门走去。巷口的灯笼在风里晃了晃，把他的影子拉得很长。
''';

/// 每一步灌入的构树次数（只增长全局列表，几乎不付大文档成本）。
const int _inflateStep = 500;

/// 扫描步数（总灌入量 = `_inflateStep * _steps`）。
const int _steps = 40;

/// 每步内「大文档」的采样次数。
const int _samples = 30;

void main() {
  testWidgets('P0-1：单次 Markdown 构树耗时 vs 累计构树次数（递增扫描）', (tester) async {
    // 充分预热，压掉 JIT 上升段。
    await _measure(tester, 'warm-md', _narrative, markdown: true, count: 120);
    await _measure(tester, 'warm-txt', _narrative, markdown: false, count: 120);

    final ratios = <double>[];
    final mdMs = <double>[];
    final txtMs = <double>[];

    for (var step = 0; step < _steps; step++) {
      final md = await _measure(
        tester,
        'md-$step',
        _narrative,
        markdown: true,
        count: _samples,
        warmup: 5,
      );
      final txt = await _measure(
        tester,
        'txt-$step',
        _narrative,
        markdown: false,
        count: _samples,
        warmup: 5,
      );
      mdMs.add(md);
      txtMs.add(txt);
      ratios.add(md / txt);

      // 灌入：只用极小文档把全局 `_kBlockTags` 推长。
      await _measure(
        tester,
        'inflate-$step',
        'a',
        markdown: true,
        count: _inflateStep,
        warmup: 0,
      );
    }

    // ignore: avoid_print
    print('--- P0-1 递增扫描（每步灌入 $_inflateStep 次构树）---');
    for (var i = 0; i < _steps; i++) {
      // ignore: avoid_print
      print(
        '累计构造 ${((i + 1) * _inflateStep).toString().padLeft(6)} | '
        'markdown ${mdMs[i].toStringAsFixed(3)} ms | '
        'control ${txtMs[i].toStringAsFixed(3)} ms | '
        'ratio ${ratios[i].toStringAsFixed(2)}',
      );
    }

    double mean(List<double> xs, int from) {
      final slice = xs.sublist(from);
      return slice.reduce((a, b) => a + b) / slice.length;
    }

    final head = mean(ratios, 0);
    final head5 = ratios.take(5).reduce((a, b) => a + b) / 5;
    final tail5 = ratios.skip(_steps - 5).reduce((a, b) => a + b) / 5;
    // ignore: avoid_print
    print(
      'ratio 首 5 步均值=${head5.toStringAsFixed(2)} '
      '末 5 步均值=${tail5.toStringAsFixed(2)} '
      '（末/首=${(tail5 / head5).toStringAsFixed(2)}x；全程均值=${head.toStringAsFixed(2)}）；'
      '总灌入=${_steps * _inflateStep} 次构树',
    );

    expect(mdMs.first, greaterThan(0), reason: '耗时必须被真实测量到');
    expect(
      ratios,
      everyElement(greaterThan(1)),
      reason: 'Markdown 构树显著贵于纯文本渲染（对照组有效性检查）',
    );
    // L0 实测结论：末/首 在 1.0~1.5 之间波动，**噪声与效应同量级** →
    // 无法证实该缺陷显著（原先「主因」假设被推翻，见
    // `.agents/chat-ui-perf-plan.md` §0）。此处只保留**数量级级**的哨兵：
    // 若将来该比值超过 2.0，说明它真的开始咬人了。
    expect(
      tail5 / head5,
      lessThan(2.0),
      reason: '哨兵：_kBlockTags 增长的相对影响不应达到 2 倍量级',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// 连续 `count` 次「新建 → 构树 → 布局」，返回去掉前 [warmup] 次后的中位数（ms）。
///
/// 每次用新 key 强制新建 State，等价于真实场景里条目被销毁后重建 /
/// 流式正文每次 `data` 变化，从而每次都真正执行一次完整 Markdown 构树。
Future<double> _measure(
  WidgetTester tester,
  String tag,
  String data, {
  required bool markdown,
  required int count,
  int warmup = 10,
}) async {
  const style = TextStyle(fontSize: 15, height: 1.65);
  final samples = <double>[];
  for (var i = 0; i < count; i++) {
    final sw = Stopwatch()..start();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: KeyedSubtree(
          key: ValueKey('$tag-$i'),
          child: markdown
              // selectable: false → 只保留 Markdown 解析/构树与文本布局，
              // 排除 SelectionArea 与平台调用对计时的干扰。
              ? MarkdownPreview(data: data, selectable: false, base: style)
              : Text(data, style: style),
        ),
      ),
    );
    sw.stop();
    if (i >= warmup) samples.add(sw.elapsedMicroseconds / 1000);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}
