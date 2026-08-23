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
  testWidgets('默认平台自动展开：连接设置 + 模型列表，且无添加/删除模型入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('API设置'), findsOneWidget);
    // 默认平台 header（首个平台，自动展开）。
    expect(find.text('默认（DeepSeek 开放平台）'), findsOneWidget);
    expect(find.text('内置'), findsOneWidget);
    // 展开后可看到连接设置与模型列表。
    expect(find.text('API 类型'), findsOneWidget);
    expect(find.text('OpenAI 兼容 API'), findsWidgets);
    expect(find.text('模型'), findsOneWidget);
    expect(
      find.textContaining('deepseek-v4-pro', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('deepseek-v4-flash', findRichText: true),
      findsWidgets,
    );
    expect(find.text('添加自定义平台'), findsOneWidget);
    // 内置默认平台无「添加模型」入口。
    expect(find.text('添加模型'), findsNothing);
    expect(find.text('删除此平台'), findsNothing);
  });

  testWidgets('添加自定义平台：仅 OpenAI 兼容；展开后可添加模型、可删除平台', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
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

    // 新平台 header（折叠）出现。
    expect(find.text('我的网关'), findsOneWidget);
    // 尚未展开时无删除入口。
    expect(find.text('删除此平台'), findsNothing);

    // 展开自定义平台后，显示「添加模型」与「删除此平台」。
    await tester.tap(find.text('我的网关'));
    await tester.pumpAndSettle();
    expect(find.text('添加模型'), findsOneWidget);
    expect(find.text('删除此平台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开模型不崩溃，且可编辑该模型参数', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    // 展开第一个模型（deepseek-v4-pro，默认平台已自动展开）。
    await tester.tap(
      find.textContaining('deepseek-v4-pro', findRichText: true).first,
    );
    await tester.pumpAndSettle();

    // 展开后不应再出现 Flutter 的 Element 协调断言崩溃。
    expect(tester.takeException(), isNull);
    // 该模型的可编辑设置项出现（简写标识输入框的提示文案）。
    expect(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '如 V4F',
      ),
      findsOneWidget,
    );

    // 编辑简写标识：写回工作副本。
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '如 V4F',
      ),
      'V4P',
    );
    await tester.pump();

    expect(form.platforms.first.modelById('deepseek-v4-pro')!.shortLabel, 'V4P');
    expect(tester.takeException(), isNull);
  });

  testWidgets('预设模型：可调配功能只读，用户不可更改', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    // 展开默认平台第一个模型（deepseek-v4-pro，内置预设）。
    await tester.tap(
      find.textContaining('deepseek-v4-pro', findRichText: true).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('可调配功能（Chat 页对话框内可选）'), findsOneWidget);
    expect(find.text('预设模型的能力由平台固定，用户不可更改。'), findsOneWidget);
    // 三个能力开关存在，且均为禁用只读态。
    expect(find.byType(SwitchListTile), findsNWidgets(3));
    final switches = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    expect(switches.every((s) => s.onChanged == null), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义模型：可自行设置可调配功能', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);
    form.addPlatform(name: 'gw', baseUrl: 'x');
    form.addModel(form.platforms.last.id, id: 'gpt-4o-mini', shortLabel: 'GPT4O');

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    // 展开自定义平台。
    await tester.tap(find.text('gw'));
    await tester.pumpAndSettle();
    // 展开自定义模型。
    await tester.tap(
      find.textContaining('gpt-4o-mini', findRichText: true).first,
    );
    await tester.pumpAndSettle();

    // 三个能力开关存在且可编辑。
    expect(find.byType(SwitchListTile), findsNWidgets(3));
    final switches = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    expect(switches.every((s) => s.onChanged != null), isTrue);

    // 关闭「联网搜索」：写回工作副本。
    await tester.tap(find.widgetWithText(SwitchListTile, '联网搜索'));
    await tester.pump();

    expect(form.platforms.last.modelById('gpt-4o-mini')!.supportsSearch, isFalse);
    expect(tester.takeException(), isNull);
  });
}
