import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/mod_provider.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/json_editing_controller.dart';
import 'package:narrchat/widgets/json_syntax_colors.dart';
import 'package:narrchat/widgets/json_view.dart';
import 'package:narrchat/widgets/mod_management_panel.dart';
import 'package:provider/provider.dart';

import 'helpers/chat_harness.dart' show settle;
import 'helpers/fakes.dart';
import 'helpers/span_helpers.dart';

/// 设置页「Mod 管理」面板的 JSON 接线：导出弹窗走 [JsonView]，
/// 导入弹窗的输入框走 [JsonEditingController]。
void main() {
  late TestStack stack;

  setUp(() async {
    stack = await TestStack.create();
    await stack.seedMod(
      name: '文笔润色',
      description: '让文风更流畅',
      prePrompt: '前置词内容',
    );
  });

  tearDown(() async {
    await stack.dispose();
  });

  /// Pump 面板（真库 + ModProvider）；等用户 Mod 加载完。
  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ModProvider(repository: stack.repos.mod),
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: const Scaffold(
            body: SingleChildScrollView(child: ModManagementPanel()),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('导出弹窗：Mod JSON 用 JsonView 着色展示', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byTooltip('导出'));
    await tester.pumpAndSettle();

    expect(find.text('导出 Mod（JSON）'), findsOneWidget);
    expect(find.byType(JsonView), findsOneWidget);

    final rich = tester.widget<Text>(
      find.descendant(
        of: find.byType(JsonView),
        matching: find.byWidgetPredicate(
          (widget) => widget is Text && widget.textSpan != null,
        ),
      ),
    );
    final root = rich.textSpan!;
    expect(spanWithText(root, '"name"').style?.color, JsonSyntaxColors.light.key);
    expect(
      spanWithText(root, '"文笔润色"').style?.color,
      JsonSyntaxColors.light.string,
    );
  });

  testWidgets('导入弹窗：输入框用 JSON 高亮控制器，粘贴内容即时着色', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.text('导入 Mod'), findsOneWidget);

    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(field).controller, isA<JsonEditingController>());

    await tester.enterText(field, '{"name":"青云宗","n":1}');
    await tester.pump();

    final root = _renderEditableText(tester, field);
    expect(spanWithText(root, '"name"').style?.color, JsonSyntaxColors.light.key);
    expect(
      spanWithText(root, '"青云宗"').style?.color,
      JsonSyntaxColors.light.string,
    );
    expect(spanWithText(root, '1').style?.color, JsonSyntaxColors.light.number);
  });
}

/// 输入框真正排版用的 [RenderEditable] 里的 span 树（即控制器的 `buildTextSpan`）。
///
/// `EditableText` 的表层 render object 是合成回调代理（`_RenderCompositionCallback`），
/// 得顺子节点往下走才能拿到 [RenderEditable]。
InlineSpan _renderEditableText(WidgetTester tester, Finder field) {
  RenderEditable? editable;
  void visit(RenderObject node) {
    if (editable != null) return;
    if (node is RenderEditable) {
      editable = node;
      return;
    }
    node.visitChildren(visit);
  }

  visit(tester.renderObject(field));
  return editable!.text!;
}
