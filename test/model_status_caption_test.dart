import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/char_count_indicator.dart';
import 'package:narrchat/widgets/model_status_caption.dart';

/// [ModelStatusCaption] 的显示与挤压规则测试。
///
/// 组件本身只负责一行内容：思考强度 + ` · ` + 字数；宽度不足时强度先省略，
/// 字数宽度随内容自然变化，并与强度保持固定的小间距。
void main() {
  Widget host(Widget child) => MaterialApp(
    theme: NarrChatTheme.light,
    home: Scaffold(body: Center(child: child)),
  );

  /// 字数指示器内的文本。
  Finder countText(String label) => find.descendant(
    of: find.byType(CharCountIndicator),
    matching: find.text(label),
  );

  testWidgets('显示「强度 · 字数」，字数随输入实时更新', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        ModelStatusCaption(
          strengthLabel: 'high',
          controller: controller,
        ),
      ),
    );

    expect(find.text('high · '), findsOneWidget);
    expect(countText('0 字'), findsOneWidget);

    controller.text = '你好，world!';
    await tester.pump();
    expect(countText('9 字'), findsOneWidget);
  });

  testWidgets('强度与字数紧贴，间距不随位数变化', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        ModelStatusCaption(
          strengthLabel: 'high',
          controller: controller,
        ),
      ),
    );

    /// 强度文本右边界到字数文本左边界的距离。
    double gap(String countLabel) {
      final strength = tester.getRect(find.text('high · '));
      final count = tester.getRect(countText(countLabel));
      return count.left - strength.right;
    }

    final initial = gap('0 字');
    expect(initial, lessThanOrEqualTo(1));

    // 千分位长数字出现后，间距保持固定（字数整体向左扩展）。
    controller.text = 'x' * 1234;
    await tester.pump();
    expect(countText('1,234 字'), findsOneWidget);
    expect(gap('1,234 字'), closeTo(initial, 0.01));
  });

  testWidgets('窄宽度：强度被省略，字数完整', (tester) async {
    final controller = TextEditingController(text: 'x' * 1234);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 120,
          child: ModelStatusCaption(
            strengthLabel: 'extremely-long-reasoning-effort',
            controller: controller,
          ),
        ),
      ),
    );

    expect(countText('1,234 字'), findsOneWidget);

    final strength = find.textContaining('extremely-long-reasoning-effort');
    expect(strength, findsOneWidget);
    expect(tester.widget<Text>(strength).overflow, TextOverflow.ellipsis);
    expect(
      tester.renderObject<RenderParagraph>(strength).didExceedMaxLines,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('无思考 / 思考关闭的标注也能正常显示', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        ModelStatusCaption(
          strengthLabel: ModelStatusCaption.noThinkingLabel,
          controller: controller,
        ),
      ),
    );
    expect(find.textContaining('【无思考】'), findsOneWidget);

    await tester.pumpWidget(
      host(
        ModelStatusCaption(
          strengthLabel: ModelStatusCaption.thinkingOffLabel,
          controller: controller,
        ),
      ),
    );
    expect(find.textContaining('【思考off】'), findsOneWidget);
  });
}
