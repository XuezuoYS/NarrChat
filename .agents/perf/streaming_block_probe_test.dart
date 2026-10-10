/// 探针（非回归测试；属 `.agents/` 度量设施）：P0-①「流式正文按块增量渲染」的收益与边界。
///
/// 两部分：
/// 1. **微基准 A/B（隔离解析成本）**：同一内容序列分别走
///    「现状＝整段 `MarkdownPreview`」与「P0-①＝`StreamingMarkdown`」两条渲染路径，
///    在**同一个宿主**里对比每次增量的耗时曲线——不含对话页的整页帧成本，
///    归因最干净；
/// 2. **端到端结构事实**（对话页真实链路）：已冻结块数 / 尾部残块字符数。
///    这两个量是「每帧真正参与重建的部分」，与机器性能无关，因此是可靠信号；
///    端到端的原始 ms 曲线受整页帧成本影响，只作参考。
///
/// 内容形态：
/// - 「单段无空行」：`'字' × 8` 连续推送，永不出块边界（按块切分的边界情况）；
/// - 「空行分段」：每 6 个 chunk（48 字）追加一个空行，模拟真实剧情正文的自然段。
///
/// 运行：`flutter test .agents/perf/streaming_block_probe_test.dart`
/// ⚠️ 必须**单独运行**（与其他测试并发会污染耗时比值）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_preview.dart';
import 'package:narrchat/widgets/streaming_markdown.dart';

import '../../test/helpers/chat_harness.dart';
import '../../test/helpers/fakes.dart';

const Book _book = Book(uuid: kHarnessBookUuid, title: '测试书');
const int _charsPerChunk = 8;
const int _paragraphEveryChunks = 6;
const int _updatesPerBatch = 100;
const int _batchCount = 10;

/// 造一段流式正文：[chunkIndex] 为 6 的整数倍时追加一个空行（[paragraphs] 为真时）。
String _chunkAt(int chunkIndex, {required bool paragraphs}) =>
    '字' * _charsPerChunk +
    (paragraphs && chunkIndex % _paragraphEveryChunks == 0 ? '\n\n' : '');

/// 同宿主 A/B：返回每个 batch 的 ms/次增量（已扣本宿主的空转底噪）。
Future<List<double>> _measureMicro({
  required WidgetTester tester,
  required bool streaming,
  required bool paragraphs,
  bool selectable = true,
}) async {
  final data = ValueNotifier<String>('');
  addTearDown(data.dispose);
  const base = TextStyle(fontSize: 15, height: 1.65);

  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: ValueListenableBuilder<String>(
            valueListenable: data,
            builder: (context, value, _) => streaming
                ? StreamingMarkdown(
                    data: value,
                    trailing: '▍',
                    selectable: selectable,
                    base: base,
                  )
                : MarkdownPreview(data: '$value▍', base: base),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // 本宿主空转底噪（内容不变、只 pump）。
  const idlePumps = 200;
  final idleSw = Stopwatch()..start();
  for (var i = 0; i < idlePumps; i++) {
    await tester.pump();
  }
  idleSw.stop();
  final idle = idleSw.elapsedMicroseconds / 1000 / idlePumps;

  final perUpdate = <double>[];
  var chunkIndex = 0;
  var text = '';
  for (var b = 0; b < _batchCount; b++) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < _updatesPerBatch; i++) {
      chunkIndex++;
      text += _chunkAt(chunkIndex, paragraphs: paragraphs);
      data.value = text;
      await tester.pump();
    }
    sw.stop();
    perUpdate.add(sw.elapsedMicroseconds / 1000 / _updatesPerBatch - idle);
  }
  return perUpdate;
}

/// 微基准：隔离解析/重建成本，对比两条渲染路径。
Future<void> _runMicroAb(WidgetTester tester, {required bool paragraphs}) async {
  final label = paragraphs ? '空行分段（每 6 chunk 一个空行）' : '单段无空行';
  final legacy = await _measureMicro(
    tester: tester,
    streaming: false,
    paragraphs: paragraphs,
  );
  final incremental = await _measureMicro(
    tester: tester,
    streaming: true,
    paragraphs: paragraphs,
  );
  // 归因用对照：同一路径**关掉选中容器**（不建 SelectionArea）。
  final noSelection = await _measureMicro(
    tester: tester,
    streaming: true,
    paragraphs: paragraphs,
    selectable: false,
  );

  // ignore: avoid_print
  print('=== 微基准 P0-①｜$label ===');
  // ignore: avoid_print
  print('batch（累计字数）        现状整段   P0-①按块   P0-①无选区   倍数');
  for (var i = 0; i < _batchCount; i++) {
    final chars = (i + 1) * _updatesPerBatch * _charsPerChunk;
    // ignore: avoid_print
    print(
      'batch ${i.toString().padLeft(2)}（${chars.toString().padLeft(4)} 字）'
      '  ${legacy[i].toStringAsFixed(3).padLeft(9)}'
      '  ${incremental[i].toStringAsFixed(3).padLeft(9)}'
      '  ${noSelection[i].toStringAsFixed(3).padLeft(11)}'
      '  ${(legacy[i] / incremental[i]).toStringAsFixed(2).padLeft(6)}x',
    );
  }
  // ignore: avoid_print
  print(
    '末批/首批（净工作增长倍数）'
    '  现状 ${(legacy.last / legacy.first).toStringAsFixed(2)}x'
    '  P0-① ${(incremental.last / incremental.first).toStringAsFixed(2)}x'
    '  P0-①无选区 ${(noSelection.last / noSelection.first).toStringAsFixed(2)}x',
  );
  // ignore: avoid_print
  print(
    '合计（1000 次增量，ms）'
    '  现状 ${(legacy.reduce((a, b) => a + b) * _updatesPerBatch).toStringAsFixed(0)}'
    '  P0-① ${(incremental.reduce((a, b) => a + b) * _updatesPerBatch).toStringAsFixed(0)}'
    '  P0-①无选区 ${(noSelection.reduce((a, b) => a + b) * _updatesPerBatch).toStringAsFixed(0)}',
  );

  // 探针断言：只钉住与实现无关的趋势事实（耗时绝对值不设阈值）。
  expect(
    incremental.first,
    greaterThan(0),
    reason: '按块增量路径确实有成本被测量到',
  );
  expect(legacy.last, greaterThan(legacy.first), reason: '整段重建的成本随长度上升');
  if (paragraphs) {
    expect(
      incremental.last,
      lessThan(legacy.last),
      reason: '空行分段下按块增量应显著便宜于整段重建',
    );
  }
}

void main() {
  testWidgets('微基准 A/B：空行分段', (tester) async {
    await _runMicroAb(tester, paragraphs: true);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('微基准 A/B：单段无空行', (tester) async {
    await _runMicroAb(tester, paragraphs: false);
  }, timeout: const Timeout(Duration(minutes: 8)));

  for (final paragraphs in [false, true]) {
    final label = paragraphs ? '空行分段' : '单段无空行';
    testWidgets('端到端结构事实（对话页）：$label', (tester) async {
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

      final sendFuture = provider.sendRound(userInput: '继续剧情', book: _book);
      await tester.pump();

      final perChunkMs = <double>[];
      var emittedChars = 0;
      var chunkIndex = 0;
      for (var b = 0; b < _batchCount; b++) {
        final sw = Stopwatch()..start();
        for (var i = 0; i < _updatesPerBatch; i++) {
          chunkIndex++;
          final chunk = _chunkAt(chunkIndex, paragraphs: paragraphs);
          ai.emit(chunk);
          emittedChars += chunk.length;
          await tester.pump();
        }
        sw.stop();
        perChunkMs.add(sw.elapsedMicroseconds / 1000 / _updatesPerBatch);
      }

      // 结构事实：尾部残块 = 每帧真正参与重建/重排的部分。
      final previews = tester
          .widgetList<MarkdownPreview>(
            find.descendant(
              of: find.byType(StreamingMarkdown),
              matching: find.byType(MarkdownPreview),
            ),
          )
          .toList();
      final frozenBlocks = previews.length - 1;
      final tailChars = previews.isEmpty ? 0 : previews.last.data.length;

      // ignore: avoid_print
      print('=== 端到端（对话页）｜$label ===');
      // ignore: avoid_print
      print(
        '正文 $emittedChars 字 | 已冻结块=$frozenBlocks | 尾部残块=$tailChars 字 | '
        '每 chunk 原始耗时 ${perChunkMs.first.toStringAsFixed(2)} → '
        '${perChunkMs.last.toStringAsFixed(2)} ms（含整页帧成本，仅参考）',
      );

      expect(find.byType(StreamingMarkdown), findsOneWidget);
      expect(find.textContaining('字' * _charsPerChunk), findsWidgets);
      if (paragraphs) {
        expect(
          frozenBlocks,
          greaterThan(
            _batchCount * _updatesPerBatch ~/ _paragraphEveryChunks - 5,
          ),
          reason: '空行分段应几乎全部冻结',
        );
        expect(
          tailChars,
          lessThan(_charsPerChunk * _paragraphEveryChunks + 2),
          reason: '尾部残块应只含最后一个未完成段落（+ 光标）',
        );
      } else {
        expect(frozenBlocks, 0, reason: '没有空行就没有块边界，一块都不该冻结');
        expect(tailChars, greaterThan(6000), reason: '单段正文全部留在尾部');
      }

      ai.complete();
      await waitSendDone(tester, provider);
      expect(await sendFuture, isTrue, reason: '流式轮次应正常收尾');
    }, timeout: const Timeout(Duration(minutes: 8)));
  }
}
