import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/brand_logo.dart';
import 'package:narrchat/widgets/chat_bubble.dart';
import 'package:narrchat/widgets/collapsible_content.dart';
import 'package:narrchat/widgets/markdown_preview.dart';
import 'package:narrchat/widgets/recommended_action_view.dart';

/// 足够长的正文：在 320px 宽的正文列上必然换行（用于「填满可用宽度」断言）。
/// 重复次数兼顾默认 600 高的测试视口（12 次 ≈ 13 行，不会垂直溢出）。
final String longText = '这是一段用于验证窄屏气泡填满可用宽度的长剧情正文。' * 12;

void main() {
  /// 核对「可见区里正好 [lines] 行」：第 [lines] 行**完整**在可见区内，
  /// 第 [lines] + 1 行整体在可见区之外。
  ///
  /// 行框坐标是段落局部的，得加上「段落相对正文的偏移」才是可见区里的位置。
  /// 逐段扫（Markdown 一个块一个 [RenderParagraph]），自动换行也算在内。
  void expectVisibleLines(WidgetTester tester, int lines) {
    final body = tester.renderObject<RenderBox>(find.byType(CollapsibleContent));
    final visible = body.size.height;
    var index = 0;
    for (final element in find
        .descendant(
          of: find.byType(MarkdownPreview),
          matching: find.byType(RichText),
        )
        .evaluate()) {
      final paragraph = element.renderObject! as RenderParagraph;
      final top = paragraph.localToGlobal(Offset.zero, ancestor: body).dy;
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: paragraph.text.toPlainText().length,
        ),
      )) {
        index++;
        if (index == lines) {
          expect(top + box.bottom, lessThanOrEqualTo(visible + 0.5),
              reason: '第 $lines 行完整露出');
        } else if (index == lines + 1) {
          expect(top + box.top, greaterThanOrEqualTo(visible - 0.5),
              reason: '第 ${lines + 1} 行不露头');
        }
      }
    }
    expect(index, greaterThan(lines), reason: '正文确实多于 $lines 行');
  }

  /// 以 [width] 可用宽度 pump 单个 [ChatBubble]（外层包 [SizedBox] 模拟窄/宽屏）。
  Widget buildInWidth({required double width, required ChatBubble bubble}) {
    return MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: bubble),
        ),
      ),
    );
  }

  /// 单一 pump 入口：以用户 / AI 气泡渲染 [text]（渲染模式判定用例复用）。
  ///
  /// 第二帧等待「收起判定」回报：是否超长只在布局阶段才知道，展开箭头因此
  /// 在下一帧出现（用户气泡的收起裁切本身首帧已生效）。
  Future<void> pumpBubble(WidgetTester tester,
      {required bool isUser, required String text}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: Center(child: ChatBubble(isUser: isUser, text: text)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Widget buildBubble({required VoidCallback onMenu}) {
    return MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(
        body: Center(
          child: ChatBubble(
            isUser: false,
            text: '测试消息内容',
            onContextMenu: (_) => onMenu(),
          ),
        ),
      ),
    );
  }

  testWidgets('触屏长按（不移动）触发上下文菜单', (tester) async {
    var menuCount = 0;
    await tester.pumpWidget(buildBubble(onMenu: () => menuCount++));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('测试消息内容')),
      kind: PointerDeviceKind.touch,
    );
    // 超过 500ms 长按阈值。
    await tester.pump(const Duration(milliseconds: 600));
    expect(menuCount, 1);
    await gesture.up();
    await tester.pump();
    expect(menuCount, 1);
  });

  testWidgets('触屏上下滑动（手指不抬起）不触发上下文菜单', (tester) async {
    var menuCount = 0;
    await tester.pumpWidget(buildBubble(onMenu: () => menuCount++));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('测试消息内容')),
      kind: PointerDeviceKind.touch,
    );
    // 上下滑动：移动距离超过 18px 阈值，长按应被取消。
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 600));
    expect(menuCount, 0);
    await gesture.up();
    await tester.pump();
    expect(menuCount, 0);
  });

  testWidgets('触屏轻微抖动（小于阈值）仍可触发长按', (tester) async {
    var menuCount = 0;
    await tester.pumpWidget(buildBubble(onMenu: () => menuCount++));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('测试消息内容')),
      kind: PointerDeviceKind.touch,
    );
    // 小于 18px 的轻微移动不应取消长按。
    await gesture.moveBy(const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 600));
    expect(menuCount, 1);
    await gesture.up();
    await tester.pump();
    expect(menuCount, 1);
  });

  testWidgets('带图气泡：正文上方显示图片预览，缺失文件显示占位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: Center(
            child: ChatBubble(
              isUser: false,
              text: '测试消息内容',
              images: ['img/a.png'],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 正文仍在。
    expect(find.text('测试消息内容'), findsOneWidget);
    // 解析失败（无真实文件）→ 灰色占位：损坏图标 + 文件名 + 「图片已丢失」。
    expect(find.text('a.png'), findsOneWidget);
    expect(find.text('图片已丢失'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无图气泡：不渲染图片预览条', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: Center(child: ChatBubble(isUser: false, text: '纯文本')),
        ),
      ),
    );
    expect(find.text('图片已丢失'), findsNothing);
  });

  test('chatBubbleMaxWidth：窄屏填满可用宽度，宽屏受阅读列宽上限约束', () {
    expect(chatBubbleMaxWidth(320), 320);
    expect(chatBubbleMaxWidth(360), 360);
    expect(chatBubbleMaxWidth(800), kChatBubbleMaxWidth);
    expect(chatBubbleMaxWidth(double.infinity), kChatBubbleMaxWidth);
    expect(chatBubbleMaxWidth(0), 0);
  });

  testWidgets('窄屏 AI 气泡：头像在正文上方左对齐，右侧标注「第 n 轮」', (tester) async {
    await tester.pumpWidget(
      buildInWidth(
        width: 360,
        bubble: ChatBubble(isUser: false, text: longText, roundIndex: 3),
      ),
    );
    await tester.pump();

    // 头像移至正文上方并**左对齐**（30×30 原始尺寸，不被 stretch 拉宽）；
    // 头像右侧以「第 n 轮」标注（markdown 标题色 + 小于正文字号）；
    // 正文块左右对齐 = 内容列全宽 360。
    // 注：窄屏分支内部也有一个 SizedBox(width: available)，与外壳同宽同位置，
    // ancestor 匹配到多个时取 .first（两者矩形一致，均可作为内容列基准）。
    expect(find.byType(BrandLogo), findsOneWidget);
    final boxRect = tester.getRect(
      find
          .ancestor(
            of: find.byType(MarkdownPreview),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    final logoRect = tester.getRect(find.byType(BrandLogo));
    final textRect = tester.getRect(find.byType(MarkdownPreview));
    expect(textRect.width, 360);
    expect(logoRect.bottom, lessThanOrEqualTo(textRect.top));
    expect(logoRect.width, 30);
    expect(logoRect.left, closeTo(boxRect.left, 0.01));
    // 「第 3 轮」页眉位于头像右侧同一行：软件二级描述文本色（浅色 #8A8F98）、13px。
    final label = tester.widget<Text>(find.text('第 3 轮'));
    expect(label.style?.color, NarrChatColors.light.textSecondary);
    expect(label.style?.fontSize, 13);
    final labelRect = tester.getRect(find.text('第 3 轮'));
    expect(labelRect.left, greaterThan(logoRect.right));
    expect(labelRect.center.dy, closeTo(logoRect.center.dy, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏 AI 气泡：未提供 roundIndex 时不显示轮次标注', (tester) async {
    await tester.pumpWidget(
      buildInWidth(
        width: 360,
        bubble: const ChatBubble(isUser: false, text: '纯文本'),
      ),
    );
    await tester.pump();

    expect(find.textContaining('第'), findsNothing);
  });

  testWidgets('窄屏 AI 气泡：短消息正文块同样左右对齐（满宽列，与主流一致）', (tester) async {
    await tester.pumpWidget(
      buildInWidth(
        width: 360,
        bubble: ChatBubble(isUser: false, text: '短消息'),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(MarkdownPreview)).width, 360);
  });

  testWidgets('宽屏 AI 气泡：头像居左，「第 n 轮」在正文上方且顶部与头像对齐', (tester) async {
    await tester.pumpWidget(
      buildInWidth(
        width: 800,
        bubble: ChatBubble(isUser: false, text: longText, roundIndex: 5),
      ),
    );
    await tester.pump();

    // 680（上限）− 头像 40 = 640；头像仍内嵌正文左侧（同一行）。
    final logoRect = tester.getRect(find.byType(BrandLogo));
    final textRect = tester.getRect(find.byType(MarkdownPreview));
    expect(textRect.width, 640);
    expect(logoRect.right, lessThanOrEqualTo(textRect.left));
    // 「第 5 轮」页眉位于正文上方：顶部与头像顶部对齐、颜色为次要文本色。
    final label = tester.widget<Text>(find.text('第 5 轮'));
    expect(label.style?.color, NarrChatColors.light.textSecondary);
    expect(label.style?.fontSize, 13);
    final labelRect = tester.getRect(find.text('第 5 轮'));
    expect(labelRect.top, closeTo(logoRect.top, 0.01));
    expect(labelRect.bottom, lessThanOrEqualTo(textRect.top));
  });

  testWidgets('窄屏用户气泡：右侧对齐，左侧留出 10% 空白表达「靠右」', (tester) async {
    await tester.pumpWidget(
      buildInWidth(
        width: 360,
        bubble: ChatBubble(isUser: true, text: longText),
      ),
    );
    await tester.pump();

    // 气泡总宽 = 内容列 90%（324）；正文含水平内边距（14 × 2）= 296 可用。
    // 正文按**完整 296** 换行：省略号与箭头都在正文**之外**的尾行里，一行都不
    // 挤占（绝对坐标受 800 测试视口 Center 影响，只做相对断言）。
    final body = tester.getRect(find.byType(CollapsibleContent));
    final text = tester.getRect(find.byType(MarkdownPreview));
    final arrow =
        tester.getRect(find.byIcon(Icons.keyboard_arrow_down_rounded));
    expect(body.width, closeTo(296, 0.6));
    expect(text.width, closeTo(296, 0.6), reason: '正文满宽，不给控件让位');
    // 箭头在正文**下方**的尾行右端：两者不重叠，也不吃正文宽度。
    // （纵向位置按可见区 [body] 判：未裁切的 MarkdownPreview 比可见区高。）
    expect(arrow.top, greaterThanOrEqualTo(body.bottom));
    expect(arrow.right, lessThanOrEqualTo(text.right + 0.5),
        reason: '箭头在气泡右缘之内');
    expect(arrow.right, greaterThan(text.right - 12), reason: '贴右下角');
    // 「…」独自占尾行左侧（不贴在第 7 行末尾）。
    final ellipsis = tester.getRect(find.text('…'));
    expect(ellipsis.top, greaterThanOrEqualTo(body.bottom));
    expect(ellipsis.left, closeTo(text.left, 0.6));

    // 展开：正文宽度本来就没让位 → 保持不变，气泡只向下变高；省略号消失、箭头朝上。
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
    expect(tester.getRect(find.byType(MarkdownPreview)).width,
        closeTo(text.width, 0.6));
    expect(find.text('…'), findsNothing, reason: '展开后省略号消失');
    // 收起控件仍独占尾行（不与正文同排）。
    final up = tester.getRect(find.byIcon(Icons.keyboard_arrow_up_rounded));
    expect(up.top,
        greaterThanOrEqualTo(
            tester.getRect(find.byType(CollapsibleContent)).bottom));
  });

  testWidgets('用户气泡：无 md 特征的多行手打文本按纯文本渲染（换行生效）',
      (tester) async {
    await pumpBubble(tester, isUser: true, text: '第一行\n第二行');

    // 不进入 Markdown 解析：单换行若被当作软换行会折叠成空格。
    expect(find.byType(MarkdownBody), findsNothing);
    final plain = tester.widget<Text>(find.text('第一行\n第二行'));
    expect(plain.data, '第一行\n第二行');
    // 纯文本沿用用户气泡正文样式（15px / 1.65 行高）。
    expect(plain.style?.fontSize, 15);
    expect(plain.style?.height, 1.65);
    expect(find.text('第一行 第二行'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('用户气泡：无空行的 Markdown 列表按 Markdown 渲染', (tester) async {
    await pumpBubble(tester, isUser: true, text: '- 列出了\n- 一些\n- 项目');

    expect(find.byType(MarkdownBody), findsOneWidget);
    // 每条各自成块：逐行呈现（行首符号渲染为 •，而非字面 `- `）。
    expect(find.text('•'), findsNWidgets(3));
    expect(find.text('- 列出了'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('用户气泡：单行成对粗体按 Markdown 渲染', (tester) async {
    await pumpBubble(tester, isUser: true, text: '**这种**格式的一行式');

    expect(find.byType(MarkdownBody), findsOneWidget);
    // 星号被解析掉，而不是按字面显示（纯文本分支才会原样保留）。
    expect(find.text('**这种**格式的一行式'), findsNothing);
    expect(find.textContaining('**'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('用户气泡：含空行分段按 Markdown 渲染', (tester) async {
    await pumpBubble(tester, isUser: true, text: '# 标题\n\n正文内容');

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text('标题'), findsOneWidget);
    expect(find.text('# 标题\n\n正文内容'), findsNothing);
  });

  testWidgets('用户气泡：语气波浪线 / 裸星号等口语符号不被误判为 Markdown',
      (tester) async {
    const raw = '~~你好呀~~\n10*20*30\n>a<';
    await pumpBubble(tester, isUser: true, text: raw);

    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text(raw), findsOneWidget);
  });

  group('用户气泡：超过 7 行自动收起', () {
    /// 气泡内可见正文区的高度（= 裁切后的高度）。
    double visibleHeight(WidgetTester tester) {
      final context = tester.element(find.byType(CollapsibleContent));
      return (context.findRenderObject()! as RenderBox).size.height;
    }

    /// 实现当前的折叠阈值（px）= 实测第 7 行下沿：断言直接对齐被测真源，
    /// 不再另抄一份「15 × 1.65」（字体度量会与手算差一两个像素）。
    double collapseThreshold(WidgetTester tester) {
      final context = tester.element(find.byType(CollapsibleContent));
      final render = context.findRenderObject()! as RenderCollapsibleContent;
      return render.collapsedHeight;
    }

    /// 正好露出 [lines] 行：第 [lines] 行完整露出，下一行一个像素都不露，
    /// 可见高度等于折叠阈值（实测第 [lines] 行下沿）。
    void expectExactlyLines(WidgetTester tester, int lines) {
      expectVisibleLines(tester, lines);
      expect(visibleHeight(tester), collapseThreshold(tester),
          reason: '可见高度 = 折叠阈值');
    }

    /// 正文自然高度（未被裁切时的全高）。
    double naturalHeight(WidgetTester tester) =>
        tester.getSize(find.byType(MarkdownPreview)).height;

    /// 一行正文的高度：与实现同一算式（[kUserBubbleTextStyle] × 文字缩放）。
    double lineHeight(WidgetTester tester) {
      final style = tester
              .widget<Text>(
                find
                    .descendant(
                      of: find.byType(PlainTextPreview),
                      matching: find.byType(Text),
                    )
                    .first,
              )
              .style ??
          const TextStyle();
      final scaler = MediaQuery.textScalerOf(
        tester.element(find.byType(CollapsibleContent)),
      );
      final painter = TextPainter(
        text: TextSpan(text: '行', style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    /// 收起 / 展开箭头（收起态朝下、展开态朝上）。
    Finder arrow() => find.byIcon(Icons.keyboard_arrow_down_rounded);

    /// 生成 [lines] 行手打正文（单行较短，不会自动换行）。
    String linesText(int lines) =>
        List.generate(lines, (i) => '第 ${i + 1} 行').join('\n');

    testWidgets('长正文默认收起为 7 行，箭头可展开为全文', (tester) async {
      await pumpBubble(tester, isUser: true, text: linesText(20));
      final unit = lineHeight(tester);

      // 收起：正好露出 7 行（首帧即生效，无需额外测量帧；阈值 = 实测第 7 行下沿）。
      expectExactlyLines(tester, 7);
      expect(naturalHeight(tester), closeTo(unit * 20, 0.5));
      expect(arrow(), findsOneWidget);
      // 裁切只影响展示：正文仍完整在渲染树内，展开无需重新排版。
      expect(find.text(linesText(20)), findsOneWidget);

      // 展开：箭头翻转，正文按全文高度铺开。
      await tester.tap(arrow());
      await tester.pump();
      expect(visibleHeight(tester), closeTo(unit * 20, 0.5));
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
      expect(arrow(), findsNothing);

      // 再点收起，回到 7 行。
      await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
      await tester.pump();
      expectExactlyLines(tester, 7);
      expect(arrow(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('正好 7 行：不收起也不显示箭头', (tester) async {
      await pumpBubble(tester, isUser: true, text: linesText(7));
      final unit = lineHeight(tester);

      expect(visibleHeight(tester), closeTo(unit * 7, 0.5));
      expect(arrow(), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
    });

    testWidgets('短消息：正文完整显示，不显示箭头', (tester) async {
      await pumpBubble(tester, isUser: true, text: linesText(3));

      expect(visibleHeight(tester), closeTo(lineHeight(tester) * 3, 0.5));
      expect(arrow(), findsNothing);
      expect(find.text(linesText(3)), findsOneWidget);
    });

    testWidgets('Markdown 正文（列表）同样按 7 行收起并可展开', (tester) async {
      final text = List.generate(12, (i) => '- 第 ${i + 1} 项').join('\n');
      await pumpBubble(tester, isUser: true, text: text);
      expect(find.byType(MarkdownBody), findsOneWidget);

      final collapsed = visibleHeight(tester);
      expect(collapsed, lessThan(naturalHeight(tester)));
      expect(arrow(), findsOneWidget);

      await tester.tap(arrow());
      await tester.pump();
      expect(visibleHeight(tester), closeTo(naturalHeight(tester), 0.5));
      expect(visibleHeight(tester), greaterThan(collapsed + 50));

      await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
      await tester.pump();
      expect(visibleHeight(tester), closeTo(collapsed, 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Markdown 空行分段（段落间有块间距）：同样只露 7 行', (tester) async {
      // 4 段，每段正文都会自动换成 3 行（10 行以上），段落之间还有 12px 块间距：
      // 阈值若只按「整段排版高度」或「纯文本 7 行」算，都会多露出一行。
      final text = List.generate(
        4,
        (i) => '第 ${i + 1} 段正文写得比较长，用来在气泡里自动换成好几行。' * 3,
      ).join('\n\n');
      await pumpBubble(tester, isUser: true, text: text);
      expect(find.byType(MarkdownBody), findsOneWidget, reason: '含空行 → 走 Markdown');

      // 正文样式：15px × 1.65 = 24.75 / 行（Markdown 与纯文本同一份样式）。
      const unit = 15 * 1.65;
      expect(naturalHeight(tester), greaterThan(unit * 8), reason: '自然高度含段落块间距');
      // 可见区里正好 7 行：第 8 行整体在可见区之外。
      expectVisibleLines(tester, 7);
      expect(arrow(), findsOneWidget);
    });

    // 回归：折叠阈值曾按「正文样式 × 7」算，而正文实际换行宽度比它窄一点
    // （右侧要给省略号 + 箭头让位），于是多露出一行。现在正文按**完整可用宽**
    // 排版（控件只在正文之外的尾行里）、行数按实际排版数、阈值取「实测第 7 行
    // 下沿」，各气泡宽度下都只露 7 行。
    for (final width in const [300.0, 360.0, 420.0, 520.0]) {
      testWidgets('气泡可用宽 ${width.toInt()}：收起时正好 7 行（不多不少）',
          (tester) async {
        final text = '“说起来，你们这个搭配挺常见的。”我这样说，苏浅浅有些疑惑问我，'
            '我继续说：“就是运动系不良和乖乖女好学生的搭配，比如你和王浩啊，'
            '王浩校外有一些狐朋狗友你也应该知道，多少算半个不良来看。”\n\n'
            '苏浅浅听到这样说，无奈的笑了笑，说确实，毕竟这种人很擅长主动出击，'
            '而乖乖女又不善于拒绝，当然就会导致这样。\n\n'
            '很快，车就开到我租住的出租屋的楼下，我下了车对苏浅浅说：'
            '“感恩大小姐载我一程，感恩的心感谢有你在我身边。”然后就上楼了。\n\n'
            '回到屋里我把窗户推开透了口气，顺手把今天的事记在了本子上，'
            '想着明天见面的时候该怎样把话跟苏浅浅说明白，免得她又多想。';
        await tester.pumpWidget(
          MaterialApp(
            theme: NarrChatTheme.light,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: ChatBubble(isUser: true, text: text),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(arrow(), findsOneWidget, reason: '这个宽度下正文确实超过 7 行');

        // 可见高度 = 折叠阈值（实测第 7 行下沿）；正文确实比它高。
        final visible = visibleHeight(tester);
        final threshold = collapseThreshold(tester);
        expect(naturalHeight(tester), greaterThan(threshold + 0.5),
            reason: '正文确实超过 7 行');
        expect(visible, threshold);

        // 逐段核对：第 7 行完整露出、第 8 行整体在可见区之外。
        expectVisibleLines(tester, 7);

        // 正文宽度不因控件缩水：铺满裁切容器（= 气泡完整可用宽）。
        expect(tester.getSize(find.byType(MarkdownPreview)).width,
            tester.getSize(find.byType(CollapsibleContent)).width,
            reason: '正文按气泡完整可用宽排版');
      });
    }

    testWidgets('真实长段落（软换行 + 空行分段）：可见高度不超过 7 行', (tester) async {
      // 还原线上样式：长段落靠软换行占满多行，随后空行分段（Markdown 渲染）。
      final text = '“说起来，你们这个搭配挺常见的。”我这样说，苏浅浅有些疑惑问我，'
          '我继续说：“就是运动系不良和乖乖女好学生的搭配，比如你和王浩啊，'
          '王浩校外有一些狐朋狗友你也应该知道，多少算半个不良来看。”\n\n'
          '苏浅浅听到这样说，无奈的笑了笑，说确实，毕竟这种人很擅长主动出击，'
          '而乖乖女又不善于拒绝，当然就会导致这样。\n\n'
          '很快，车就开到我租住的出租屋的楼下，我下了车对苏浅浅说：'
          '“感恩大小姐载我一程，感恩的心感谢有你捏。”然后就上楼了，'
          '苏浅浅被我的话逗笑了两声后让苏若开车回她自己租住的别墅了。';
      await pumpBubble(tester, isUser: true, text: text);
      expect(find.byType(MarkdownBody), findsOneWidget);

      const unit = 15 * 1.65;
      final visible = visibleHeight(tester);
      final natural = naturalHeight(tester);
      expect(natural, greaterThan(unit * 7), reason: '正文确实超过 7 行');
      // 裁切落在第 7 行之后、第 8 行之前：既不多露一行，也不切断第 7 行。
      expect(visible, greaterThan(unit * 6.5));
      expect(visible, lessThan(unit * 7 + unit));
      expect(arrow(), findsOneWidget);
    });

    testWidgets('全局字体放大 1.45 倍：阈值随行高放大（仍为 7 行）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NarrChatTheme.light,
          home: Scaffold(
            body: Center(
              // 与生产 main.dart 一致：MediaQuery 覆盖在页面子树之上，
              // 文字缩放经 textScaler 生效。
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.45)),
                child: ChatBubble(isUser: true, text: linesText(20)),
              ),
            ),
          ),
        ),
      );
      // 首帧布局 + 第二帧收起判定回报。
      await tester.pump();
      await tester.pump();

      // 行高随文字缩放变为 1.45 倍：仍然正好露出 7 行（而不是固定像素数）。
      final unit = lineHeight(tester);
      expect(unit, closeTo(15 * 1.65 * 1.45, 0.5));
      expectExactlyLines(tester, 7);
      expect(arrow(), findsOneWidget);
    });
  });

  testWidgets('AI 气泡：不受纯文本判定影响，始终走 Markdown 渲染', (tester) async {
    await pumpBubble(tester, isUser: false, text: '第一行\n第二行');

    expect(find.byType(MarkdownBody), findsOneWidget);
  });

  group('推荐下一步：双击选项插入输入框', () {
    const action = '1. 上前行礼\n2. 询问掌门\n3. 自定义行动';

    Widget buildAction({
      String data = action,
      ValueChanged<String>? onInsert,
      VoidCallback? onCustom,
    }) {
      return MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: Center(
            child: ChatBubble(
              isUser: false,
              text: '测试正文',
              recommendedAction: data,
              onRecommendedActionInsert: onInsert,
              onRecommendedActionCustomTap: onCustom,
            ),
          ),
        ),
      );
    }

    /// 推荐行动区块内的文本（Markdown 渲染为 RichText，需 `findRichText`）。
    Finder actionText(String text) => find.descendant(
          of: find.byType(RecommendedActionView),
          matching: find.text(text, findRichText: true),
        );

    /// 鼠标双击（同一位置两次点击，间隔在双击窗口内）。
    Future<void> doubleTap(WidgetTester tester, Finder finder) async {
      await tester.tap(finder, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(finder, kind: PointerDeviceKind.mouse);
      // 越过后一个双击判定窗口：让识别器计时器收敛（测试结束不得残留计时器）。
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('标签提示双击用法；列表项按 Markdown 列表外观渲染（符号 + 内容）', (tester) async {
      await tester.pumpWidget(buildAction());

      expect(find.text('推荐下一步（双击选项插入输入框）'), findsOneWidget);
      // 序号由 bullet 渲染（源标记 `1. ` 不按字面显示），条目内容各自成块。
      expect(actionText('上前行礼'), findsOneWidget);
      expect(actionText('询问掌门'), findsOneWidget);
      expect(actionText('自定义行动'), findsOneWidget);
      expect(actionText('1. 上前行礼'), findsNothing);
      expect(find.text('1.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('双击普通选项：回调收到剥掉列表标记的条目内容', (tester) async {
      final inserted = <String>[];
      await tester.pumpWidget(buildAction(onInsert: inserted.add));

      await doubleTap(tester, actionText('询问掌门'));

      expect(inserted, ['询问掌门']);
    });

    testWidgets('双击末条「自定义行动」：只走聚焦回调，不写入文本', (tester) async {
      final inserted = <String>[];
      var customCount = 0;
      await tester.pumpWidget(
        buildAction(onInsert: inserted.add, onCustom: () => customCount++),
      );

      await doubleTap(tester, actionText('自定义行动'));

      expect(customCount, 1);
      expect(inserted, isEmpty, reason: '「自定义行动」不写入任何文本');
    });

    testWidgets('单击不插入（仅双击生效）', (tester) async {
      final inserted = <String>[];
      await tester.pumpWidget(buildAction(onInsert: inserted.add));

      await tester.tap(actionText('上前行礼'), kind: PointerDeviceKind.mouse);
      // 越过双击判定窗口（> 300ms），确认单击不会被当成双击。
      await tester.pump(const Duration(milliseconds: 400));

      expect(inserted, isEmpty);
    });

    testWidgets('非列表文本：双击不触发任何回调', (tester) async {
      final inserted = <String>[];
      var customCount = 0;
      await tester.pumpWidget(
        buildAction(
          data: '继续前进，保持警惕。',
          onInsert: inserted.add,
          onCustom: () => customCount++,
        ),
      );

      await doubleTap(tester, actionText('继续前进，保持警惕。'));

      expect(inserted, isEmpty);
      expect(customCount, 0);
    });

    testWidgets('未接线回调时不绑定双击手势（保持纯 Markdown 文本）', (tester) async {
      await tester.pumpWidget(buildAction());

      expect(
        find.descendant(
          of: find.byType(RecommendedActionView),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
      await doubleTap(tester, actionText('上前行礼'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏（360）：选项同样渲染、双击生效，无布局异常', (tester) async {
      final inserted = <String>[];
      await tester.pumpWidget(
        buildInWidth(
          width: 360,
          bubble: ChatBubble(
            isUser: false,
            text: '测试正文',
            recommendedAction: action,
            onRecommendedActionInsert: inserted.add,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('推荐下一步（双击选项插入输入框）'), findsOneWidget);
      await doubleTap(tester, actionText('上前行礼'));

      expect(inserted, ['上前行礼']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('选项仍可长按拖动选择并复制（触屏，与双击手势共存）', (tester) async {
      // 复制走系统剪贴板：拦截 Clipboard.setData 读取被复制的文本。
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

      await tester.pumpWidget(buildAction(onInsert: (_) {}));

      final region = find.descendant(
        of: find.byType(RecommendedActionView),
        matching: find.byType(SelectableRegion),
      );
      expect(region, findsOneWidget, reason: '整个区块共用一个选中容器');

      // 触屏长按（超过 500ms 阈值）开始选择，随后拖动框选到末条。
      final gesture = await tester.startGesture(
        tester.getCenter(actionText('上前行礼')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(tester.getCenter(actionText('自定义行动')));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      // 复制当前选中内容（选择工具条 / Ctrl+C 的底层动作）；须从
      // SelectableRegion 内部取 context，其 Actions 注册在子树上。
      Actions.invoke(
        tester.element(actionText('上前行礼')),
        CopySelectionTextIntent.copy,
      );
      await tester.pump();

      expect(copied, hasLength(1), reason: '长按拖动产生了可复制的选中内容');
      // 跨选项框选：选中内容覆盖了后续多条选项（长按落点可能落在首条文字内部，
      // 故以被完整包含的条目为锚点）。
      expect(copied.single, contains('询问掌门'));
      expect(copied.single, contains('自定义'));
    });

    testWidgets('触屏双击同样插入（双击与长按选择互不干扰）', (tester) async {
      final inserted = <String>[];
      await tester.pumpWidget(buildAction(onInsert: inserted.add));

      final option = actionText('上前行礼');
      await tester.tap(option, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(option, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 400));

      expect(inserted, ['上前行礼']);
    });
  });
}
