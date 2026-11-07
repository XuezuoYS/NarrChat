import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_editing_controller.dart';
import 'package:narrchat/widgets/settings/settings_kit.dart';

/// 设置页输入组件：圆角继承主题、标签透传、密码切换、搜索清空、下拉字段、只读框。
void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: SizedBox(width: 420, child: child),
        ),
      ),
    );
  }

  testWidgets('输入框不再覆盖主题圆角，标签/提示/辅助文案透传', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      wrap(
        SettingsTextField(
          controller: controller,
          label: '平台名称',
          hint: '如 我的网关',
          helperText: '仅用于本机辨识',
          suffixText: 'MB',
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.decoration!.border,
      isNull,
      reason: '传 border 会把主题的 12 圆角覆盖成默认 4',
    );
    expect(field.decoration!.labelText, '平台名称');
    expect(field.decoration!.hintText, '如 我的网关');
    expect(field.decoration!.helperText, '仅用于本机辨识');
    expect(field.decoration!.suffixText, 'MB');

    final border =
        Theme.of(tester.element(find.byType(SettingsTextField)))
            .inputDecorationTheme
            .border! as OutlineInputBorder;
    expect(
      border.borderRadius,
      BorderRadius.circular(NarrChatTheme.controlRadius),
    );
  });

  testWidgets('多行输入框接受 MarkdownEditingController（不破坏 MD 高亮）', (tester) async {
    final controller = MarkdownEditingController(text: '**粗体**');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      wrap(
        SettingsTextField(
          controller: controller,
          label: '文笔要求描述',
          minLines: 4,
          maxLines: null,
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller, same(controller));
    expect(field.maxLines, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('密码框：默认隐藏，点眼睛切换明文', (tester) async {
    final controller = TextEditingController(text: 'sk-test');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      wrap(SettingsSecretField(controller: controller, label: 'API Key')),
    );

    TextField field() => tester.widget<TextField>(find.byType(TextField));
    expect(field().obscureText, isTrue);
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    expect(field().obscureText, isFalse);
    expect(find.byIcon(Icons.visibility), findsOneWidget);
  });

  testWidgets('搜索框：有内容才显示清空按钮，点击触发回调', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var cleared = 0;
    await tester.pumpWidget(
      wrap(
        SettingsSearchField(
          controller: controller,
          hint: '搜索 Mod',
          onClear: () => cleared++,
        ),
      ),
    );

    expect(find.byIcon(Icons.clear), findsNothing);
    controller.text = '文笔';
    await tester.pump();
    expect(find.byIcon(Icons.clear), findsOneWidget);

    await tester.tap(find.byIcon(Icons.clear));
    expect(cleared, 1);
  });

  testWidgets('下拉字段：点字段展开菜单，菜单右对齐字段箭头', (tester) async {
    var picked = '';
    await tester.pumpWidget(
      wrap(
        SettingsDropdownField<String>(
          label: 'API 类型',
          value: 'responses',
          fieldKey: const ValueKey('dropdown_field'),
          items: const [
            DropdownMenuItem(value: 'responses', child: Text('Response 兼容')),
            DropdownMenuItem(value: 'chat', child: Text('Chat 兼容')),
          ],
          onChanged: (value) => picked = value ?? '',
        ),
      ),
    );

    final fieldRect = tester.getRect(
      find.byKey(const ValueKey('dropdown_field')),
    );
    expect(find.text('API 类型'), findsOneWidget);
    expect(find.text('Response 兼容'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dropdown_field')));
    await tester.pumpAndSettle();
    expect(find.text('Chat 兼容'), findsOneWidget);

    final itemRect = tester.getRect(find.byType(MenuItemButton).first);
    expect(
      itemRect.right,
      closeTo(fieldRect.right - 14, 1),
      reason: '菜单右边缘应贴近字段右侧的下拉箭头',
    );
    expect(itemRect.width, closeTo(NarrChatTheme.dropdownMenuWidth, 1));
    expect(
      itemRect.left,
      greaterThan(fieldRect.left + 60),
      reason: '菜单不再贴字段左缘展开',
    );

    await tester.tap(find.text('Chat 兼容'));
    await tester.pumpAndSettle();
    expect(picked, 'chat');
    expect(find.text('Chat 兼容'), findsNothing, reason: '菜单已关闭');
    expect(tester.takeException(), isNull);
  });

  testWidgets('只读展示框：不是 TextField、点击触发回调、保留编辑图标', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      wrap(
        SettingsReadonlyField(
          label: '保留历史版本',
          value: '—',
          onTap: () => tapped++,
        ),
      ),
    );

    expect(find.byType(TextField), findsNothing);
    expect(find.text('—'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);

    await tester.tap(find.text('—'));
    expect(tapped, 1);
  });
}
