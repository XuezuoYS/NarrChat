import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/brand_logo.dart';
import 'package:narrchat/widgets/chat_bubble.dart';
import 'package:narrchat/widgets/markdown_preview.dart';
import 'package:narrchat/widgets/recommended_action_view.dart';

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

  /// 单一 pump 入口：以用户 / AI 气泡渲染 [text]（渲染模式判定用例复用）。
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
