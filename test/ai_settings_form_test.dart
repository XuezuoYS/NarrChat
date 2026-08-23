import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/ai_settings_form.dart';
import 'package:narrchat/widgets/settings_form_state.dart';

Widget _buildApp(SettingsFormState form) {
  return MaterialApp(
    theme: NarrChatTheme.light,
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: AiSettingsForm(form: form),
      ),
    ),
  );
}

void main() {
  testWidgets('默认平台与模型渲染：连接区 + 模型列表 + 添加按钮', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('默认（DeepSeek 开放平台）', findRichText: true),
      findsWidgets,
    );
    expect(find.text('API 类型'), findsOneWidget);
    expect(find.text('OpenAI 兼容 API'), findsWidgets);
    expect(
      find.textContaining('deepseek-v4-pro', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('deepseek-v4-flash', findRichText: true),
      findsWidgets,
    );
    expect(find.text('添加自定义平台'), findsOneWidget);
    expect(find.text('添加模型'), findsOneWidget);
  });

  testWidgets('添加自定义平台：仅 OpenAI 兼容，添加后选中并可删除', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    await tester.tap(find.text('添加自定义平台'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    // 对话框内的 API 类型下拉只出现一个选项。
    expect(find.descendant(of: dialog, matching: find.text('OpenAI 兼容 API')), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: dialog,
        matching: find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '平台名称',
        ),
      ),
      '我的网关',
    );
    await tester.enterText(
      find.descendant(
        of: dialog,
        matching: find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Base URL',
        ),
      ),
      'https://gw.example.com',
    );
    await tester.tap(
      find.descendant(of: dialog, matching: find.widgetWithText(FilledButton, '添加')),
    );
    await tester.pumpAndSettle();

    // 新平台被选中并渲染，且可删除（非内置）。
    expect(find.textContaining('我的网关', findRichText: true), findsWidgets);
    expect(find.text('删除此平台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
