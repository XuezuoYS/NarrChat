import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/brand_logo.dart';
import 'package:narrchat/widgets/chat_bubble.dart';
import 'package:narrchat/widgets/markdown_preview.dart';

/// 足够长的正文：在 320px 宽的正文列上必然换行（用于「填满可用宽度」断言）。
/// 重复次数兼顾默认 600 高的测试视口（12 次 ≈ 13 行，不会垂直溢出）。
final String longText = '这是一段用于验证窄屏气泡填满可用宽度的长剧情正文。' * 12;

void main() {
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

    // 气泡块宽 = 内容列 90%（324）：块左缘距内容列左缘 36；正文再含水平
    // 内边距（14 × 2）= 296 宽，正文左缘距内容列左缘 50（用相对位置断言，
    // 避免受 800 测试视口 Center 居中的绝对坐标影响）。
    final boxRect = tester.getRect(
      find.ancestor(
        of: find.byType(MarkdownPreview),
        matching: find.byType(SizedBox),
      ),
    );
    final textRect = tester.getRect(find.byType(MarkdownPreview));
    expect(textRect.width, 296);
    expect(textRect.left - boxRect.left, 50);
  });
}
