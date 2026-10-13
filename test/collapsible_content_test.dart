import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/widgets/collapsible_content.dart';

/// [CollapsibleContent] 的渲染层行为：按「第 N 行下沿」裁切、裁掉的部分不接受
/// 命中、「是否需要收起」在布局阶段回报。
///
/// 「用户气泡 7 行收起 / 展开」的整体行为见 `chat_bubble_test.dart`。
void main() {
  /// 与用例正文同款的样式（度量真源）。
  const TextStyle textStyle = TextStyle(fontSize: 15, height: 1.65);

  /// 一行的高度（同款样式实测）。
  double lineHeight() {
    final painter = TextPainter(
      text: const TextSpan(text: '行', style: textStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// 宽 200 的正文替身（[lines] 行手打文本，单行短不会自动换行）。
  Widget textBody(int lines) => SizedBox(
        width: 200,
        child: Text(
          List.generate(lines, (i) => '第 ${i + 1} 行').join('\n'),
          style: textStyle,
        ),
      );

  /// 正文替身：高 [height] 的色块（非文本子级：不参与行计算）。
  Widget box(double height) => SizedBox(
        width: 200,
        height: height,
        child: const ColoredBox(color: Color(0xFF123456)),
      );

  /// 正文替身的实际尺寸（区别于 Material / Scaffold 内部的装饰盒）。
  Size boxSize(WidgetTester tester) => tester.getSize(find.byKey(_boxKey));

  /// 可见高度（= 裁切后的高度）。
  double visibleHeight(WidgetTester tester) =>
      tester.getSize(find.byType(CollapsibleContent)).height;

  testWidgets('正文行数超过阈值：裁切到第 N 行下沿；展开后恢复原高', (tester) async {
    Future<void> pump({required bool expanded}) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CollapsibleContent(
                collapsedLines: 2,
                lineHeight: lineHeight(),
                expanded: expanded,
                child: textBody(6),
              ),
            ),
          ),
        );

    /// 行字框（段落局部 = 正文局部：Text 是唯一直系排版子级）。
    List<Rect> lineBoxes() {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(CollapsibleContent),
          matching: find.byType(RichText),
        ),
      );
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: paragraph.text.toPlainText().length,
        ),
      );
      return [for (final b in boxes) b.toRect()];
    }

    await pump(expanded: false);
    // 阈值 = 实测第 2 行下沿：第 2 行字完整露出，第 3 行一个像素都不露。
    final visible = visibleHeight(tester);
    final boxes = lineBoxes();
    expect(visible, greaterThanOrEqualTo(boxes[1].bottom), reason: '第 2 行完整露出');
    expect(visible, lessThanOrEqualTo(boxes[2].top), reason: '第 3 行不露头');
    // 子级仍按自然高度布局（展开无需重新排版）。
    expect(tester.getSize(find.byType(Text)).height,
        closeTo(lineHeight() * 6, 0.5));

    await pump(expanded: true);
    expect(visibleHeight(tester), closeTo(lineHeight() * 6, 0.5));
  });

  testWidgets('正文行数不超过阈值：原样铺开，不裁切', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollapsibleContent(
            collapsedLines: 4,
            lineHeight: lineHeight(),
            expanded: false,
            child: textBody(2),
          ),
        ),
      ),
    );

    expect(visibleHeight(tester), closeTo(lineHeight() * 2, 0.5));
  });

  testWidgets('非文本子级：不计行数（视作未超阈值），不裁切', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollapsibleContent(
            collapsedLines: 3,
            lineHeight: lineHeight(),
            expanded: false,
            child: KeyedSubtree(key: _boxKey, child: box(300)),
          ),
        ),
      ),
    );

    expect(visibleHeight(tester), 300, reason: '没有可数的行 → 不收起');
    expect(boxSize(tester).height, 300);
    expect(tester.getSize(find.byType(CollapsibleContent)).width, 800,
        reason: '铺满可用宽');
  });

  testWidgets('正文按完整可用宽排版：不给省略号 / 控件让位', (tester) async {
    late BoxConstraints bodyConstraints;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollapsibleContent(
            collapsedLines: 2,
            lineHeight: lineHeight(),
            expanded: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                bodyConstraints = constraints;
                return const SizedBox(height: 10);
              },
            ),
          ),
        ),
      ),
    );

    // 收起的正文一行都不变窄：省略号与展开控件由调用方放在正文之外。
    expect(bodyConstraints.maxWidth, 800, reason: '换行宽度 = 完整可用宽');
  });

  testWidgets('绘制裁剪严格等于可见区域（横向留白不得加进裁剪高度）', (tester) async {
    // 回归：裁剪框曾误写成「高度 + 横向留白」——那是给展开控件的横向让位
    // （约两行高），裁剪线因此多放出正好两行，气泡下方漏出两行文字。尺寸断言
    // 看不出来（size 一直是对的），必须盯绘制用的裁剪框本身。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollapsibleContent(
            collapsedLines: 2,
            lineHeight: lineHeight(),
            expanded: false,
            child: textBody(6),
          ),
        ),
      ),
    );

    final render = tester.renderObject<RenderCollapsibleContent>(
      find.byType(CollapsibleContent),
    );
    expect(render.paintClipRect, Offset.zero & render.size);
    expect(render.paintClipRect.height, render.collapsedHeight,
        reason: '裁剪高度 = 第 N 行下沿，不含任何横向留白');
  });

  testWidgets('展开高度可预读：收起态下也能量到正文自然高度', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollapsibleContent(
            collapsedLines: 2,
            lineHeight: lineHeight(),
            expanded: false,
            child: textBody(6),
          ),
        ),
      ),
    );

    // 调用方（气泡）据此算「展开会让上方内容上移多少」——必须收起态就可读，
    // 否则只能等展开帧才知道增量，锁定顶部就晚了。
    final render = tester.renderObject<RenderCollapsibleContent>(
      find.byType(CollapsibleContent),
    );
    expect(render.naturalHeight, closeTo(lineHeight() * 6, 0.5));
    expect(render.naturalHeight, greaterThan(render.collapsedHeight));
  });

  testWidgets('裁掉的部分不接受命中（不可见也不该点得到）', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollapsibleContent(
            collapsedLines: 1,
            lineHeight: lineHeight(),
            expanded: false,
            child: GestureDetector(onTap: () => taps++, child: textBody(8)),
          ),
        ),
      ),
    );

    // 第 1 行可见：命中正文。
    await tester.tapAt(Offset(100, lineHeight() / 2));
    expect(taps, 1);
    // 第 3 行已被裁掉：不可见，也不该被点到。
    await tester.tapAt(Offset(100, lineHeight() * 3));
    expect(taps, 1);
  });

  testWidgets('是否需要收起：布局阶段回报，状态翻转时才再次回调', (tester) async {
    final reports = <bool>[];
    Future<void> pump({
      required int collapsedLines,
      required int contentLines,
    }) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CollapsibleContent(
                collapsedLines: collapsedLines,
                lineHeight: lineHeight(),
                expanded: false,
                onCollapsedChanged: reports.add,
                child: textBody(contentLines),
              ),
            ),
          ),
        );

    // 首帧布局完成 → 帧末回调。
    await pump(collapsedLines: 2, contentLines: 5);
    expect(reports, [true]);

    // 状态没翻转 → 不重复回调（否则调用方会被无谓地反复重建）。
    await tester.pump();
    await tester.pump();
    expect(reports, [true]);

    // 阈值放宽到高于正文行数 → 翻转回「不需要收起」。
    await pump(collapsedLines: 8, contentLines: 5);
    await tester.pump();
    expect(reports, [true, false]);
    expect(visibleHeight(tester), closeTo(lineHeight() * 5, 0.5));
  });
}

/// 正文替身的键：`ColoredBox` / `SizedBox` 在 Material 内部满地都是，
/// 用键定位被测子级，避免命中框架自带的盒子。
const Key _boxKey = Key('collapsible-content-box');
