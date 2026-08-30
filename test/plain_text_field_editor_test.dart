import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/plain_text_field_editor.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 320, child: child),
        ),
      ),
    );
  }

  testWidgets('视图模式展示文本；空内容显示「（空）」占位', (tester) async {
    final controller = TextEditingController(text: '第三天 午时');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      wrap(PlainTextFieldEditor(controller: controller)),
    );
    expect(find.text('第三天 午时'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // 外部内容变化（如切换轮次）后重建组件：空内容显示「（空）」占位。
    controller.text = '';
    await tester.pumpWidget(
      wrap(PlainTextFieldEditor(controller: controller)),
    );
    expect(find.text('（空）'), findsOneWidget);
  });

  testWidgets('进入编辑显示回填当前值的输入框并回调 onEditingChanged', (tester) async {
    final controller = TextEditingController(text: '第三天 午时');
    addTearDown(controller.dispose);
    final editingLog = <bool>[];
    await tester.pumpWidget(
      wrap(
        PlainTextFieldEditor(
          controller: controller,
          onEditingChanged: editingLog.add,
        ),
      ),
    );
    final state = tester.state<PlainTextFieldEditorState>(
      find.byType(PlainTextFieldEditor),
    );
    state.enterEdit();
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '第三天 午时',
    );
    expect(editingLog, [true]);
  });

  testWidgets('save 回写外部控制器并触发 onSave', (tester) async {
    final controller = TextEditingController(text: '第三天 午时');
    addTearDown(controller.dispose);
    String? saved;
    await tester.pumpWidget(
      wrap(
        PlainTextFieldEditor(
          controller: controller,
          onSave: (v) => saved = v,
        ),
      ),
    );
    final state = tester.state<PlainTextFieldEditorState>(
      find.byType(PlainTextFieldEditor),
    );
    state.enterEdit();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '第四天 子时');
    state.save();
    await tester.pump();
    expect(saved, '第四天 子时');
    expect(controller.text, '第四天 子时');
    // 保存后回到视图模式。
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('cancel 还原为进入编辑前的文本且不触发 onSave', (tester) async {
    final controller = TextEditingController(text: '第三天 午时');
    addTearDown(controller.dispose);
    String? saved;
    final editingLog = <bool>[];
    await tester.pumpWidget(
      wrap(
        PlainTextFieldEditor(
          controller: controller,
          onSave: (v) => saved = v,
          onEditingChanged: editingLog.add,
        ),
      ),
    );
    final state = tester.state<PlainTextFieldEditorState>(
      find.byType(PlainTextFieldEditor),
    );
    state.enterEdit();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '第五天 卯时');
    state.cancel();
    await tester.pump();
    expect(saved, isNull);
    expect(controller.text, '第三天 午时');
    expect(find.text('第三天 午时'), findsOneWidget);
    expect(editingLog, [true, false]);
  });

  testWidgets('readOnly 时 enterEdit 不进入编辑模式', (tester) async {
    final controller = TextEditingController(text: '第三天 午时');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      wrap(PlainTextFieldEditor(controller: controller, readOnly: true)),
    );
    final state = tester.state<PlainTextFieldEditorState>(
      find.byType(PlainTextFieldEditor),
    );
    state.enterEdit();
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
  });
}
