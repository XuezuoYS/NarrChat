import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 探针：把一大块带 `\n` 的文字切成多段 [RichText] 后，**版面与复制能否仍与整块
/// 逐字逐像素一致**。
///
/// 背景：切段只为摊薄排版（`raw_result_frame_probe_2026_10_12_test.dart`：同一块
/// 20 万字符，挪一次「当前定位」整块重排 545 ms，切 10 段只要 86 ms）。
///
/// 难点（本文件逐条实测）：
/// 1. 引擎把「最后一个换行之后」也算一行 → 段尾留 `\n` 就比整块多一个空行；
///    19 段共多 18 行（3942 vs 3618）。
/// 2. 用**样式**压掉这个空行全废：改 `\n` 自己（字号 0.01 / 行高 0 / 两者叠加）
///    压不掉，改段落根 span 的默认样式也压不掉（`a\n` 仍 38.00，`x\ny\n` 仍 57.00
///    = 三行）。空行高度既不取那个字符，也不取段落默认样式。
/// 3. `maxLines` 能精确吃掉段尾空行，但它数的是**视觉行**：一行折行后按硬换行数
///    给的 maxLines 会把折出来的内容直接截没（同一段 198.00 → 18.00）。RAW 里
///    长行遍地，此路不通。
/// 4. 换行干脆不留（丢切点 `\n` 或归下一段开头）→ 版面/复制只能保一头：
///    丢了复制出的 JSON 挤成一行；归下一段开头照样多一行。
/// 5. 现成的「负偏移」容器全被框架断言拦住：`RenderPadding` 要求 inset 非负，
///    `RenderFlex` 要求 `spacing >= 0`，`heightFactor` 只收非负值且乘的是传入约束，
///    `CustomMultiChildLayout` 能把子节点画到负偏移但自己的 size 不许依赖子节点。
///
/// 结论走**几何补偿**（本文件验证可行）：换行照旧留在段尾（复制逐字相同），除末段外
/// 每段外套一层自定义 render object `_TrimLine`，把该段末尾那个空行从**自己的 size
/// 里裁掉**：内容照旧画出（空行本来啥都不画），命中区让给下一段——正好对上整块里
/// 「段尾空行的位置就是下一段首行」这件事。裁掉的行高用 `TextPainter` 量一个字符
/// 实测（debug / dpr 3 下名义 12.5×1.5 = 18.75 会被吸成 19.00，不能拿名义值）。
void main() {
  // 与 _HighlightText 生产样式同形：12.5 号、行高 1.5、只换底色。
  const base = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.5);
  const highlight = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12.5,
    height: 1.5,
    backgroundColor: Color(0x80FFF176),
  );
  const lineHeight = 12.5 * 1.5; // 18.75
  const caret = Rect.fromLTWH(0, 0, 1, 1);

  /// 按硬换行切段，切点取 `\n` **之后**（每段自带结尾换行，拼回逐字相同）。
  List<String> splitAfterNewline(String s, int budget) {
    final out = <String>[];
    var start = 0;
    while (start < s.length) {
      if (start + budget >= s.length) {
        out.add(s.substring(start));
        break;
      }
      final prev = s.lastIndexOf('\n', start + budget);
      int end;
      if (prev >= start) {
        end = prev + 1;
      } else {
        final next = s.indexOf('\n', start + budget);
        end = next < 0 ? s.length : next + 1;
      }
      if (end <= start) end = start + 1; // 兜底：绝不出空段
      out.add(s.substring(start, end));
      start = end;
    }
    return out;
  }

  String jsonLike(int lines) {
    final buf = StringBuffer();
    for (var i = 0; i < lines; i++) {
      buf.writeln('  "line$i": "青云宗是北域大派，弟子三千，编号 $i",');
    }
    return buf.toString();
  }

  /// 造与生产同形 span：普通段与命中段交替，命中只换 backgroundColor。
  List<InlineSpan> spansOf(String piece) {
    final words = piece.split(' ');
    return [
      for (var i = 0; i < words.length; i++)
        TextSpan(
          text: i == words.length - 1 ? words[i] : '${words[i]} ',
          style: i % 5 == 3 ? highlight : base,
        ),
    ];
  }

  TextSpan spanTree(String piece, {required bool outerStyle}) => TextSpan(
        style: outerStyle ? base : null,
        children: spansOf(piece),
      );

  Widget scrollWrap(Widget child) =>
      SingleChildScrollView(child: Align(alignment: Alignment.topLeft, child: child));

  RenderParagraph paraAt(WidgetTester tester, int index) {
    final w = tester.widgetList<RichText>(find.byType(RichText)).elementAt(index);
    return tester.renderObject<RenderParagraph>(find.byWidget(w));
  }

  List<int> samplesOf(String text) => <int>[
        0,
        1,
        17,
        199,
        399,
        400,
        401,
        1200,
        5000,
        text.length - 2,
        text.length - 1,
      ].where((i) => i >= 0 && i < text.length).toList();

  List<int> startsOf(List<String> pieces) {
    final starts = <int>[];
    var consumed = 0;
    for (final piece in pieces) {
      starts.add(consumed);
      consumed += piece.length;
    }
    return starts;
  }

  int pieceIndexOf(List<String> pieces, List<int> starts, int flat) {
    for (var k = 0; k < pieces.length; k++) {
      if (flat < starts[k] + pieces[k].length) return k;
    }
    return pieces.length - 1;
  }

  List<Offset> coordsOf(
    List<RenderParagraph> paras,
    List<String> pieces,
    List<int> starts,
    List<int> samples,
  ) =>
      [
        for (final flat in samples)
          () {
            final i = pieceIndexOf(pieces, starts, flat);
            final p = paras[i];
            return p.localToGlobal(
              p.getOffsetForCaret(TextPosition(offset: flat - starts[i]), caret),
            );
          }(),
      ];

  double maxAbsDelta(List<Offset> a, List<Offset> b, double Function(Offset) pick) {
    var m = 0.0;
    for (var i = 0; i < a.length; i++) {
      final d = (pick(a[i]) - pick(b[i])).abs();
      if (d > m) m = d;
    }
    return m;
  }

  testWidgets('基线：段尾 \\n 必多一行，且改 \\n 自身样式压不掉', (tester) async {
    Future<double> heightOf(TextSpan span) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: scrollWrap(RichText(textDirection: TextDirection.ltr, text: span))),
        ),
      );
      await tester.pump();
      return paraAt(tester, 0).size.height;
    }

    final one = await heightOf(const TextSpan(text: 'a', style: base));
    final tail = await heightOf(const TextSpan(text: 'a\n', style: base));
    final head = await heightOf(const TextSpan(text: '\na', style: base));
    final two = await heightOf(const TextSpan(text: 'a\nb', style: base));
    print('「a」= ${one.toStringAsFixed(2)} · 「a\\n」= ${tail.toStringAsFixed(2)} · '
        '「\\na」= ${head.toStringAsFixed(2)} · 「a\\nb」= ${two.toStringAsFixed(2)}'
        '（一行 = ${lineHeight.toStringAsFixed(2)}）');
    expect(one, closeTo(lineHeight, 0.5));
    expect(tail, closeTo(lineHeight * 2, 0.5), reason: '段尾留 \\n 必多一个空行');
    expect(head, closeTo(lineHeight * 2, 0.5), reason: '段首带 \\n 同样多一行');
    expect(two, closeTo(lineHeight * 2, 0.5));

    // 试过把切点 \\n 自己换成零行高 / 极小字号，指望它不占高度。全部无效：
    // 空行高度取自段落默认字体，与那个字符自己的样式无关。
    const tinyVariants = <String, TextStyle>{
      '字号 0.01 + 行高 0': TextStyle(fontFamily: 'monospace', fontSize: 0.01, height: 0),
      '字号 0.01 + 行高 0.01': TextStyle(fontFamily: 'monospace', fontSize: 0.01, height: 0.01),
      '只行高 0': TextStyle(fontFamily: 'monospace', height: 0),
      '只字号 0.01': TextStyle(fontFamily: 'monospace', fontSize: 0.01),
    };
    for (final v in tinyVariants.entries) {
      final h = await heightOf(
        TextSpan(children: [const TextSpan(text: 'a', style: base), TextSpan(text: '\n', style: v.value)]),
      );
      print('${v.key}：「a\\n」= ${h.toStringAsFixed(3)}'
          '（${h > lineHeight * 1.5 ? '仍多一行 ❌' : '压掉了 ✅'}）');
      expect(h, closeTo(lineHeight * 2, 0.5), reason: '${v.key} 压不掉段尾空行');
    }

    // 换个方向：段尾空行没有字符，它的高度大概来自段落默认样式（根 span），
    // 而不是那个 `\n` 字符。若如此，把根 span 设成零行高、真文字全放子 span，
    // 就能白拿一个不占高度的段尾空行——不需要任何几何补偿。
    const rootTiny = TextStyle(fontFamily: 'monospace', fontSize: 0.01, height: 0);
    final byRoot = await heightOf(
      const TextSpan(
        style: rootTiny,
        children: [TextSpan(text: 'a', style: base), TextSpan(text: '\n', style: base)],
      ),
    );
    final byRootThree = await heightOf(
      const TextSpan(
        style: rootTiny,
        children: [
          TextSpan(text: 'x\ny', style: base),
          TextSpan(text: '\n', style: base),
        ],
      ),
    );
    final byRootPlain = await heightOf(
      const TextSpan(style: rootTiny, children: [TextSpan(text: 'a\n', style: base)]),
    );
    print('默认样式压到 0：「a\\n」两子 span = ${byRoot.toStringAsFixed(3)}'
        '（${byRoot > one + lineHeight * 0.5 ? '仍多一行 ❌' : '压掉了 ✅'}） · '
        '「x\\ny\\n」= ${byRootThree.toStringAsFixed(3)}'
        '（${byRootThree > two + lineHeight * 0.5 ? '仍占三行 ❌' : '只占两行 ✅'}） · '
        '「a\\n」单子 span = ${byRootPlain.toStringAsFixed(3)}'
        '（${byRootPlain > one + lineHeight * 0.5 ? '仍多一行 ❌' : '压掉了 ✅'}）');
    // 记录死路：段尾空行跟段落默认样式也无关，样式这条路彻底走完。
    expect(byRoot, closeTo(tail, 0.5), reason: '段落默认样式同样压不掉段尾空行');
    expect(byRootThree, closeTo(two + (tail - one), 0.5), reason: '三行文字照样占三行高');
    expect(byRootPlain, closeTo(tail, 0.5), reason: '合成一个 span 也一样压不掉');

    // 补偿量必须取「实测行高」而非名义 fontSize×height：debug / dpr 3 下 18.75 会被
    // 吸成 19.00，差 0.25 px × 每个接缝一处。TextPainter 量一个字就能拿到同一口径。
    final byPainter = rowHeightOf(base);
    print('TextPainter 量一行 = ${byPainter.toStringAsFixed(3)}'
        ' · Widget 实测一行 = ${(tail - one).toStringAsFixed(3)}'
        ' · 名义 = ${lineHeight.toStringAsFixed(3)}');
    expect(byPainter, closeTo(tail - one, 0.001), reason: '补偿常量必须与真实行盒等高');
  });

  testWidgets('裁掉段尾空行的补偿容器：总高、逐字坐标、命中归属全与整块一致', (tester) async {
    const budget = 400;
    final text = jsonLike(200);
    final pieces = splitAfterNewline(text, budget);
    final starts = startsOf(pieces);
    final samples = samplesOf(text);
    final rowH = rowHeightOf(base);
    expect(pieces.join(), text, reason: '拼回必须逐字相同');
    expect(pieces.length, greaterThan(1));
    // 每段渲染「段内换行数 + 1」行，整块渲染「总换行数 + 1」行 →
    // 多出来的恰是 (段数 - 1) 个段尾空行，末段那个空行正对应整块自己的末空行。
    expect(pieces.last.endsWith('\n'), isTrue, reason: '夹具以换行结尾，末段也带段尾换行');
    print('段数 = ${pieces.length} · 行高实测 = ${rowH.toStringAsFixed(3)}'
        '（名义 ${lineHeight.toStringAsFixed(3)}）');

    // 整块基准。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: scrollWrap(
            RichText(textDirection: TextDirection.ltr, text: spanTree(text, outerStyle: true)),
          ),
        ),
      ),
    );
    await tester.pump();
    final wholePara = paraAt(tester, 0);
    final wholeHeight = wholePara.size.height;
    final wholeCoords = coordsOf([wholePara], [text], const <int>[0], samples);
    print('整块高 = ${wholeHeight.toStringAsFixed(2)}'
        '（${(wholeHeight / rowH).toStringAsFixed(1)} 行）');

    /// 渲染一种变体，返回**外层容器**量到的总高与逐字坐标。
    Future<({double height, double paraSum, List<Offset> coords})> render({
      required bool outerStyle,
      required bool compensate,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: scrollWrap(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < pieces.length; i++)
                    _TrimLine(
                      // 末段那个空行整块本来就有，只有前面的段需要裁。
                      amount: !compensate || i == pieces.length - 1 ? 0 : rowH,
                      child: RichText(
                        textDirection: TextDirection.ltr,
                        text: spanTree(pieces[i], outerStyle: outerStyle),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final paras = [for (var i = 0; i < pieces.length; i++) paraAt(tester, i)];
      final boxes = [for (var i = 0; i < pieces.length; i++) trimBoxAt(tester, i)];
      return (
        height: boxes.fold<double>(0, (sum, b) => sum + b.size.height),
        paraSum: paras.fold<double>(0, (sum, p) => sum + p.size.height),
        coords: coordsOf(paras, pieces, starts, samples),
      );
    }

    final bare = await render(outerStyle: true, compensate: false);
    final fixed = await render(outerStyle: true, compensate: true);
    final fixedInner = await render(outerStyle: false, compensate: true);

    for (final variant in <String, ({double height, double paraSum, List<Offset> coords})>{
      '不补偿': bare,
      '裁空行（外层带样式）': fixed,
      '裁空行（样式只在子 span，生产形状）': fixedInner,
    }.entries) {
      final v = variant.value;
      print('${variant.key}：总高 ${v.height.toStringAsFixed(2)}'
          '（相对整块 ${((v.height - wholeHeight) / rowH).toStringAsFixed(2)} 行），'
          '段内排版合计 ${v.paraSum.toStringAsFixed(2)}'
          '（多 ${((v.paraSum - wholeHeight) / rowH).toStringAsFixed(2)} 行），'
          '逐字最大偏移 dy ${maxAbsDelta(v.coords, wholeCoords, (o) => o.dy).toStringAsFixed(2)}'
          ' / dx ${maxAbsDelta(v.coords, wholeCoords, (o) => o.dx).toStringAsFixed(2)}');
    }

    // 段内排版合计与样式无关，多出来的恰好是 (段数 - 1) 个空行——补偿只是把它们裁掉。
    for (final v in <({double height, double paraSum, List<Offset> coords})>[bare, fixed, fixedInner]) {
      expect(v.paraSum, closeTo(wholeHeight + rowH * (pieces.length - 1), 0.5),
          reason: '每段各多一个段尾空行，合计必多 (段数 - 1) 行');
    }
    expect(bare.height, closeTo(bare.paraSum, 0.5), reason: '不补偿时外层容器一点也裁不掉');

    for (final v in <({double height, double paraSum, List<Offset> coords})>[fixed, fixedInner]) {
      expect(v.height, closeTo(wholeHeight, 0.5), reason: '补偿后总高必须等于整块');
      expect(maxAbsDelta(v.coords, wholeCoords, (o) => o.dy), lessThan(0.5),
          reason: '逐字行顶必须一致');
      expect(maxAbsDelta(v.coords, wholeCoords, (o) => o.dx), lessThan(0.5),
          reason: '行内 x 必须一致');
    }

    // 命中归属：段 1 首行那条横带必须落在段 1 的容器里、落在段 0 容器之外，
    // 否则点该处会被上一段的空行抢走（`_TrimLine` 只裁 size，不裁绘制）。
    final p1 = paraAt(tester, 1);
    final seamPoint = p1.localToGlobal(
      p1.getOffsetForCaret(const TextPosition(offset: 0), caret) +
          Offset(1, rowH / 2),
    );
    expect(trimBoxAt(tester, 1).size.contains(trimBoxAt(tester, 1).globalToLocal(seamPoint)),
        isTrue, reason: '段 1 首行必须归段 1 命中');
    final inP0 = trimBoxAt(tester, 0).globalToLocal(seamPoint);
    expect(inP0.dy >= trimBoxAt(tester, 0).size.height, isTrue,
        reason: '同一横带在段 0 容器之外（它的空行已裁出 size）');
    // 但段 0 的段落本身照旧画满，含那个空行。
    expect(paraAt(tester, 0).size.height, greaterThan(trimBoxAt(tester, 0).size.height + rowH * 0.5),
        reason: '裁剪只改容器 size，不改段内排版');
  });

  testWidgets('死路记录：负 top padding 与负 Column spacing 都被框架断言拦住', (tester) async {
    final rowH = rowHeightOf(base);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: scrollWrap(
            Padding(
              padding: EdgeInsets.only(top: -rowH),
              child: const SizedBox.square(dimension: 10),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final byPadding = tester.takeException();
    print('负 top Padding → ${_firstLine(byPadding)}');
    expect(byPadding, isNotNull, reason: 'RenderPadding 要求 inset 非负');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: scrollWrap(
            Column(
              spacing: -rowH,
              children: const [SizedBox.square(dimension: 10), SizedBox.square(dimension: 10)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final bySpacing = tester.takeException();
    print('负 Column spacing → ${_firstLine(bySpacing)}');
    expect(bySpacing, isNotNull, reason: 'RenderFlex 断言 spacing >= 0');
  });

  testWidgets('反面教材复核：maxLines 数视觉行，长行折行会被截没', (tester) async {
    final longLine = '青云宗' * 200; // 600 字，800 px 宽必然折行
    final text = '$longLine\nx\n';
    final pieces = splitAfterNewline(text, 400);
    expect(pieces.length, greaterThan(1));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: scrollWrap(
            RichText(textDirection: TextDirection.ltr, text: TextSpan(text: pieces.first, style: base)),
          ),
        ),
      ),
    );
    await tester.pump();
    final uncapped = paraAt(tester, 0).size.height;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: scrollWrap(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final piece in pieces)
                  RichText(
                    textDirection: TextDirection.ltr,
                    maxLines: '\n'.allMatches(piece).length, // 「硬行数」
                    text: TextSpan(text: piece, style: base),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final capped = paraAt(tester, 0).size.height;
    print('首段不限行 = ${uncapped.toStringAsFixed(2)}，按硬行数 1 限行后 = '
        '${capped.toStringAsFixed(2)}');
    expect(capped, lessThan(uncapped - lineHeight),
        reason: 'maxLines 按硬行数会把折行内容截掉，故不可用');
  });

  testWidgets('补偿切段后跨段选中：复制文字与整块逐字相同', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add('${(call.arguments as Map)['text']}');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final text = jsonLike(60);
    final pieces = splitAfterNewline(text, 300);
    final starts = startsOf(pieces);
    final rowH = rowHeightOf(base);
    expect(pieces.join(), text);
    expect(pieces.length, greaterThan(1));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: scrollWrap(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < pieces.length; i++)
                    _TrimLine(
                      amount: i == pieces.length - 1 ? 0 : rowH,
                      child: Builder(
                        builder: (context) => RichText(
                          textDirection: TextDirection.ltr,
                          selectionRegistrar: SelectionContainer.maybeOf(context),
                          selectionColor:
                              Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
                          text: TextSpan(text: pieces[i], style: base),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    print('选中用例：${pieces.length} 段 · 裁掉 ${pieces.length - 1} 个段尾空行'
        '（行高 ${rowH.toStringAsFixed(3)}）');

    Offset globalPos(int flat, {double dy = 8}) {
      final i = pieceIndexOf(pieces, starts, flat);
      final p = paraAt(tester, i);
      return p.localToGlobal(
            p.getOffsetForCaret(TextPosition(offset: flat - starts[i]), caret),
          ) +
          Offset(0.5, dy);
    }

    // 跨三段：起点在段 0 中部，终点落在段 2 内。
    final end = starts[2] + 20;
    final expected = text.substring(5, end);
    expect(newlinesOf(expected) > 1, isTrue, reason: '样本必须真的跨过换行');

    final gesture = await tester.startGesture(globalPos(5), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(globalPos(end));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    Actions.invoke(tester.element(find.byType(RichText).first), CopySelectionTextIntent.copy);
    await tester.pump();

    expect(copied, hasLength(1), reason: '跨段拖动应产生一份可复制的选中内容');
    expect(copied.single, expected, reason: '切段 + 补偿后的复制必须与整块逐字相同');

    // 反向拖动（终段拖回首段）也应得到同一段文字，证明重叠带没把边界判定搞乱。
    copied.clear();
    final back = await tester.startGesture(globalPos(end), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await back.moveTo(globalPos(5));
    await tester.pump();
    await back.up();
    await tester.pump();
    Actions.invoke(tester.element(find.byType(RichText).first), CopySelectionTextIntent.copy);
    await tester.pump();
    expect(copied.single, expected, reason: '反向拖动结果必须一致');
  });
}

int newlinesOf(String s) {
  var n = 0;
  for (final unit in s.codeUnits) {
    if (unit == 0x0A) n++;
  }
  return n;
}

/// 一行的真实高度：量一个字，拿到的是引擎按物理像素吸附后的值
/// （debug / dpr 3 下名义 12.5×1.5 = 18.75 会吸成 19.00）。
double rowHeightOf(TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: 'M', style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final double height = painter.height;
  painter.dispose();
  return height;
}

/// 取第 [index] 个补偿容器的 render box（不是里面那段文字）。
RenderBox trimBoxAt(WidgetTester tester, int index) =>
    tester.renderObject<RenderBox>(find.byType(_TrimLine).at(index));

String _firstLine(Object? error) => '$error'.split('\n').first;

/// 探针用补偿容器：把子节点末尾 `amount` 像素从**自己的 size** 里裁掉，绘制与
/// 命中坐标一律照旧（子节点仍从 (0,0) 画满、不偏移）。
///
/// 于是段尾那个空行照样画得出来（它本来什么都不画），却不再占位；被裁掉的那条
/// 横带归下一段的容器，下一段首行也就正好落回整块里的原始位置。
class _TrimLine extends SingleChildRenderObjectWidget {
  const _TrimLine({required this.amount, super.child});

  final double amount;

  @override
  _RenderTrimLine createRenderObject(BuildContext context) =>
      _RenderTrimLine(amount: amount);

  @override
  void updateRenderObject(BuildContext context, _RenderTrimLine renderObject) {
    if (renderObject.amount == amount) return;
    renderObject.amount = amount;
    renderObject.markNeedsLayout();
  }
}

class _RenderTrimLine extends RenderProxyBox {
  _RenderTrimLine({required this.amount});

  /// 末尾要裁掉的像素数；改动后须由 [updateRenderObject] 标脏（与生产同款写法）。
  double amount;

  double _trimmed(double height) => height <= amount ? 0.0 : height - amount;

  @override
  void performLayout() {
    final RenderBox boxedChild = child!;
    boxedChild.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(Size(boxedChild.size.width, _trimmed(boxedChild.size.height)));
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final Size childSize = child!.getDryLayout(constraints);
    return constraints.constrain(Size(childSize.width, _trimmed(childSize.height)));
  }

  @override
  double computeMinIntrinsicHeight(double width) => _trimmed(child!.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) => _trimmed(child!.getMaxIntrinsicHeight(width));
}
