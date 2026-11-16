import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/json_editing_controller.dart';
import 'package:narrchat/widgets/json_syntax_colors.dart';

import 'helpers/span_helpers.dart';

/// [JsonEditingController] 语法高亮测试。
///
/// 只验证「输入文本 → 控制器的 TextSpan」这一层：配色键位、基样式继承、
/// 输入法组合区下划线、以及渲染文本与原文逐字一致。
void main() {
  /// 在指定亮度主题下渲染控制器文本，返回展平后的全部叶子。
  Future<List<TextSpan>> renderSpans(
    WidgetTester tester,
    String text, {
    Brightness brightness = Brightness.light,
    bool withComposing = false,
    TextEditingValue? value,
  }) async {
    final controller = JsonEditingController(text: text);
    if (value != null) controller.value = value;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? NarrChatTheme.dark
            : NarrChatTheme.light,
        home: Scaffold(
          body: TextField(controller: controller, maxLines: null),
        ),
      ),
    );
    final context = tester.element(find.byType(TextField));
    final span = controller.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 13),
      withComposing: withComposing,
    );
    return flattenSpans(span);
  }

  testWidgets('键名与字符串值分色（浅色）', (tester) async {
    final spans = await renderSpans(tester, '{"a": "b"}');
    final root = TextSpan(children: spans);

    expect(spanWithText(root, '"a"').style?.color, JsonSyntaxColors.light.key);
    expect(
      spanWithText(root, '"b"').style?.color,
      JsonSyntaxColors.light.string,
    );
  });

  testWidgets('键名与字符串值分色（深色）', (tester) async {
    final spans = await renderSpans(
      tester,
      '{"a": "b"}',
      brightness: Brightness.dark,
    );
    final root = TextSpan(children: spans);

    expect(spanWithText(root, '"a"').style?.color, JsonSyntaxColors.dark.key);
    expect(
      spanWithText(root, '"b"').style?.color,
      JsonSyntaxColors.dark.string,
    );
  });

  testWidgets('数字 / 字面量 / 标点各用专属颜色', (tester) async {
    const text = '{"n": -1.5e3, "ok": true}';
    final spans = await renderSpans(tester, text);
    final root = TextSpan(children: spans);

    expect(
      spanWithText(root, '-1.5e3').style?.color,
      JsonSyntaxColors.light.number,
    );
    expect(
      spanWithText(root, 'true').style?.color,
      JsonSyntaxColors.light.keyword,
    );
    expect(
      spanWithText(root, '{').style?.color,
      JsonSyntaxColors.light.punctuation,
    );
    expect(
      spanWithText(root, ':').style?.color,
      JsonSyntaxColors.light.punctuation,
    );
  });

  testWidgets('只改颜色，字号等基样式原样继承', (tester) async {
    final spans = await renderSpans(tester, '{"a": 1}');
    final root = TextSpan(children: spans);

    final key = spanWithText(root, '"a"');
    expect(key.style?.fontSize, 13, reason: '字号应继承自控制器 style');
    expect(key.style?.fontWeight, isNot(FontWeight.bold), reason: '不额外加粗');
  });

  testWidgets('组合区（IME 输入中）附加下划线且不丢字', (tester) async {
    // 组合区 = 键名中的「键」字（跨在键名区间内部）。
    const text = '{"键": "值"}';
    final spans = await renderSpans(
      tester,
      '',
      withComposing: true,
      value: const TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 2, end: 3),
      ),
    );
    final root = TextSpan(children: spans);
    final underlined = flattenSpans(root)
        .where((s) => s.style?.decoration == TextDecoration.underline)
        .toList();

    expect(underlined.map((s) => s.text).join(), '键');
    expect(combinedSpansText(root), text);
  });

  testWidgets('半截 JSON 不抛异常，渲染与原文逐字一致', (tester) async {
    const text = '{"a": [1, tru';
    final spans = await renderSpans(tester, text);

    expect(combinedSpansText(TextSpan(children: spans)), text);
  });

  testWidgets('多行混合 JSON 渲染与原文逐字一致', (tester) async {
    const text = '{\n  "键": [1, -2.5, true, null],\n  "s": "文本"\n}';
    final spans = await renderSpans(tester, text);
    final root = TextSpan(children: spans);

    expect(combinedSpansText(root), text);
    expect(spanWithText(root, '"键"').style?.color, JsonSyntaxColors.light.key);
    expect(
      spanWithText(root, '"文本"').style?.color,
      JsonSyntaxColors.light.string,
    );
  });

  testWidgets('空文本渲染为空 span 列表', (tester) async {
    final spans = await renderSpans(tester, '');

    expect(spans, isEmpty);
  });
}
