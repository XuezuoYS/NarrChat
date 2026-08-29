import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/widgets/ai_bubble_actions.dart';

/// AiBubbleActions 的「模型名 + Token 用量」元信息胶囊布局测试：
/// 宽度够 → 单行；宽度不足 → 仅换行成两行；极限 → 两段各自省略号。
///
/// 注意：flutter test 默认 Ahem 字体下每字符 ≈ 11px 宽，故
/// 模型名 `deepseek-v4-flash`（16 字符）≈ 176px，
/// Token 文本（37 字符）≈ 407px，两者 + 间距 ≈ 591px，
/// 下方各用例按该真实度量选择宽度。
const _model = 'deepseek-v4-flash';
const _tokens = '输入 Tokens: 3395  ·  输出 Tokens: 3395';

/// 以 [width] 宽度 pump AiBubbleActions（round 用 [modelName] 预置模型名）。
Future<void> _pump(
  WidgetTester tester, {
  required double width,
  String modelName = _model,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: AiBubbleActions(
              round: Round(
                bookUuid: 'b1',
                roundIndex: 1,
                tokensIn: 3395,
                tokensOut: 3395,
                modelName: modelName,
              ),
              onViewSidebar: () {},
              onDelete: () {},
              onRefresh: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

/// 以指定样式单行排版 [text] 是否超出 [maxWidth]（即会被省略号截断）。
bool _exceeds(String text, TextStyle? style, double maxWidth) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    ellipsis: '…',
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxWidth);
  return painter.didExceedMaxLines;
}

void main() {
  testWidgets('宽度足够：模型名在左、Token 右侧同行显示', (tester) async {
    // 内容宽度 = 700 - 20 = 680 > 591（两者 + 间距），单行放得下。
    await _pump(tester, width: 700);

    final modelFinder = find.text(_model);
    final tokensFinder = find.text(_tokens);
    expect(modelFinder, findsOneWidget);
    expect(tokensFinder, findsOneWidget);

    final modelPos = tester.getCenter(modelFinder);
    final tokensPos = tester.getCenter(tokensFinder);
    // 同一行：y 对齐；模型名在 Token 左侧。
    expect(modelPos.dy, closeTo(tokensPos.dy, 0.5));
    expect(modelPos.dx, lessThan(tokensPos.dx));
  });

  testWidgets('宽度不足：Token 换行到第二行，两段均完整显示', (tester) async {
    // 内容宽度 = 500 - 20 = 480：< 591（放不下同行），且 ≥ 407（Token 可整行显示）。
    await _pump(tester, width: 500);

    final modelFinder = find.text(_model);
    final tokensFinder = find.text(_tokens);
    expect(modelFinder, findsOneWidget);
    expect(tokensFinder, findsOneWidget);

    final modelWidget = tester.widget<Text>(modelFinder);
    final tokensWidget = tester.widget<Text>(tokensFinder);
    const contentMaxWidth = 500.0 - 20.0; // 容器左右 padding 各 10
    expect(
      _exceeds(_model, modelWidget.style, contentMaxWidth),
      isFalse,
      reason: '模型名应整行显示，不省略',
    );
    expect(
      _exceeds(_tokens, tokensWidget.style, contentMaxWidth),
      isFalse,
      reason: 'Token 文本应整行显示，不省略',
    );

    final modelPos = tester.getCenter(modelFinder);
    final tokensPos = tester.getCenter(tokensFinder);
    expect(modelPos.dy, lessThan(tokensPos.dy), reason: 'Token 换行到第二行');
    // 仅两个子项 → 最多两行，不会出现第三行。
    final wrap = tester.widget<Wrap>(find.byType(Wrap).first);
    expect(wrap.children.length, 2);
  });

  testWidgets('极限宽度：模型名与 Token 均省略号截断', (tester) async {
    // 内容宽度 = 110 - 20 = 90 < 176：两段都放不下完整文本 → 各自省略。
    // （110 也足够容纳最宽的操作按钮行，避免无关的按钮溢出告警。）
    await _pump(tester, width: 110);

    final modelFinder = find.text(_model);
    final tokensFinder = find.text(_tokens);
    expect(modelFinder, findsOneWidget);
    expect(tokensFinder, findsOneWidget);

    final modelWidget = tester.widget<Text>(modelFinder);
    final tokensWidget = tester.widget<Text>(tokensFinder);
    expect(modelWidget.maxLines, 1);
    expect(modelWidget.overflow, TextOverflow.ellipsis);
    expect(tokensWidget.maxLines, 1);
    expect(tokensWidget.overflow, TextOverflow.ellipsis);

    const contentMaxWidth = 110.0 - 20.0; // 容器左右 padding 各 10
    expect(
      _exceeds(_model, modelWidget.style!, contentMaxWidth),
      isTrue,
      reason: '模型名在极限宽度下应被省略',
    );
    expect(
      _exceeds(_tokens, tokensWidget.style!, contentMaxWidth),
      isTrue,
      reason: 'Token 文本在极限宽度下应被省略',
    );

    final modelPos = tester.getCenter(modelFinder);
    final tokensPos = tester.getCenter(tokensFinder);
    expect(modelPos.dy, lessThan(tokensPos.dy), reason: '仍保持两行布局');
  });

  testWidgets('模型名为空（历史轮次）：不显示模型名，仅 Token', (tester) async {
    await _pump(tester, width: 700, modelName: '');

    expect(find.text(_model), findsNothing);
    expect(find.text(_tokens), findsOneWidget);
  });
}
