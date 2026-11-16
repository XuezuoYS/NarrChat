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

  testWidgets('列表摘要：多个 system 通道共用一次「System 提示词 - 」前缀', (tester) async {
    await stack.seedMod(
      name: '多通道 Mod',
      prePrompt: '前置内容',
      systemMust: '强指令内容',
      systemWritingStyle: '文笔内容',
    );
    await pumpPanel(tester);

    // 顺序 = 面板顺序（文笔在强指令之前），前缀只出现一次、通道之间用 ` & `。
    final summary = find.text(
      '含：前置词、System 提示词 - 文笔要求与参考段落 & 强指令',
    );
    expect(summary, findsOneWidget);
    expect(
      'System 提示词'.allMatches(tester.widget<Text>(summary).data!).length,
      1,
      reason: '重复前缀正是这次要修的问题',
    );
    expect(
      find.textContaining('System 提示词 - 文笔要求与参考段落、System 提示词'),
      findsNothing,
    );
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
