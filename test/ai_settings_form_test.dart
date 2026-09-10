import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/api_type.dart';
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

/// 「jpg→jpeg」开关测试用替身：仅内存态写回，不触碰
/// LocalConfigService 真实文件 I/O（widget 测试处于 FakeAsync 区域，
/// 真实文件 I/O 不会完成，会让测试挂起）。
class _NoPersistAiSettingsProvider extends AiSettingsProvider {
  bool _flag = false;

  @override
  bool get convertJpgToJpeg => _flag;

  @override
  Future<bool> setConvertJpgToJpeg(bool value) async {
    _flag = value;
    notifyListeners();
    return true;
  }
}

/// 展开第一个平台的第一个模型（deepseek-v4-pro）的编辑器。
Future<void> _expandFirstModel(WidgetTester tester) async {
  await tester.tap(
    find.textContaining('deepseek-v4-pro', findRichText: true).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('默认态：提示当前为内置预置，平台标注「内置默认」且无重置入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('API 设置'), findsOneWidget);
    // 图片设置 与 模型设置 两个节标题。
    expect(find.text('图片设置'), findsOneWidget);
    expect(find.text('模型设置'), findsOneWidget);
    // 预置分层提示：默认态明确告知"当前为软件内置预置配置"。
    expect(find.text('当前为软件内置预置配置（未自定义模型）'), findsOneWidget);
    expect(find.text('已自定义模型配置：内置预置平台可整平台重置为预置'), findsNothing);
    // 预置平台标注「内置默认」，未改动时无重置入口。
    expect(find.text('内置默认'), findsOneWidget);
    expect(find.text('已自定义'), findsNothing);
    expect(find.text('重置为内置预置'), findsNothing);
    // 平台卡片（展开态）：名称可改 + 连接设置。
    expect(find.text('平台名称'), findsOneWidget);
    expect(find.text('API 类型'), findsOneWidget);
    expect(find.text('OpenAI Response API 兼容'), findsWidgets);
    expect(find.text('模型'), findsOneWidget);
    for (final modelId in const [
      'deepseek-v4-pro',
      'deepseek-v4-flash',
      'deepseek-v4-flash-vision-exp',
    ]) {
      expect(
        find.textContaining(modelId, findRichText: true),
        findsWidgets,
        reason: '预置模型 $modelId 应列出',
      );
    }
    // 限制已放开：预置平台同样有「添加模型」；仅一个平台时删除入口禁用。
    expect(find.text('添加模型'), findsOneWidget);
    final deleteButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '删除此平台'),
    );
    expect(deleteButton.onPressed, isNull);
    expect(find.text('至少需要保留一个平台。'), findsOneWidget);
    // 图片设置项仍在。
    expect(find.text('单张图片大小上限（超过将提示文件过大）'), findsOneWidget);
    expect(find.text('自动将 .jpg 转换为 .jpeg'), findsOneWidget);
    expect(find.text('添加自定义平台'), findsOneWidget);
  });

  testWidgets('编辑预置模型参数 → 标注「已自定义」并出现重置入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();
    await _expandFirstModel(tester);

    // 展开后不应出现 Flutter 的 Element 协调断言崩溃；模型编辑器就位。
    expect(tester.takeException(), isNull);
    final labelField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '如 V4F',
    );
    expect(labelField, findsOneWidget);

    // 编辑简写标识：写回工作副本，界面切换为"已自定义"。
    await tester.enterText(labelField, 'V4P');
    await tester.pump();
    expect(form.platforms.first.modelById('deepseek-v4-pro')!.shortLabel, 'V4P');
    expect(find.text('已自定义'), findsOneWidget);
    expect(find.text('内置默认'), findsNothing);
    expect(find.text('重置为内置预置'), findsOneWidget);
    expect(find.text('已自定义模型配置：内置预置平台可整平台重置为预置'), findsOneWidget);
  });

  testWidgets('重置为内置预置：二次确认，取消不变更、确认后还原（含输入框文本）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();
    await _expandFirstModel(tester);
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '如 V4F',
      ),
      'V4P',
    );
    await tester.pump();

    // 取消：不还原。
    await tester.tap(find.text('重置为内置预置'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('API Key 与其它平台不受影响'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(form.platforms.first.modelById('deepseek-v4-pro')!.shortLabel, 'V4P');
    expect(find.text('已自定义'), findsOneWidget);

    // 确认：还原为预置值，输入框文本同步清空，标注回到「内置默认」。
    await tester.tap(find.text('重置为内置预置'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '重置'));
    await tester.pumpAndSettle();

    expect(form.platforms.first.modelById('deepseek-v4-pro')!.shortLabel, '');
    final restoredField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '如 V4F',
      ),
    );
    expect(restoredField.controller!.text, '');
    expect(find.text('内置默认'), findsOneWidget);
    expect(find.text('重置为内置预置'), findsNothing);
    expect(find.text('当前为软件内置预置配置（未自定义模型）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预置模型：可调配功能可自由编辑（限制已放开）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();
    await _expandFirstModel(tester);

    expect(find.text('可调配功能（Chat 页对话框内可选）'), findsOneWidget);
    expect(find.text('预设模型的能力由平台固定，用户不可更改。'), findsNothing);
    // 图片设置「jpg→jpeg」开关 + 4 个能力开关，共 5 个，且全部可编辑。
    expect(find.byType(SwitchListTile), findsNWidgets(5));
    final switches = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    expect(switches.every((s) => s.onChanged != null), isTrue);

    // 关闭「联网搜索」：写回工作副本。
    await tester.tap(find.widgetWithText(SwitchListTile, '联网搜索'));
    await tester.pump();
    expect(
      form.platforms.first.modelById('deepseek-v4-pro')!.supportsSearch,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加自定义平台：标注「自定义」、无重置入口、可增删模型', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    await tester.tap(find.text('添加自定义平台'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    // 对话框内的 API 类型下拉默认选中 Response 兼容（两项协议可切换）。
    expect(
      find.descendant(of: dialog, matching: find.text('OpenAI Response API 兼容')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.byWidgetPredicate((w) => w is DropdownButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('OpenAI Chat API 兼容'), findsWidgets);
    expect(find.text('OpenAI Response API 兼容'), findsWidgets);
    // 收起下拉（点回当前选中项），继续填写平台信息。
    await tester.tap(find.text('OpenAI Response API 兼容').last);
    await tester.pumpAndSettle();

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

    // 新平台 header（折叠）出现，标注「自定义」。
    expect(find.text('我的网关'), findsOneWidget);
    expect(find.text('自定义'), findsOneWidget);
    // 尚未展开时无删除/重置入口（预置平台未改动也没有重置入口）。
    expect(find.text('重置为内置预置'), findsNothing);

    // 展开自定义平台后，显示「添加模型」与「删除此平台」（此时平台多于一个，删除可用）。
    await tester.tap(find.text('我的网关'));
    await tester.pumpAndSettle();
    expect(find.text('添加模型'), findsNWidgets(2));
    final deleteButtons = tester
        .widgetList<TextButton>(find.widgetWithText(TextButton, '删除此平台'))
        .toList();
    expect(deleteButtons.length, 2);
    expect(deleteButtons.every((b) => b.onPressed != null), isTrue);
    // 自定义平台没有重置入口（无预置可回退）。
    expect(find.text('重置为内置预置'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除预置平台后：出现「恢复内置平台」入口，确认后卡片回归', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);
    // 先加一个自定义平台，使预置平台可被删除（至少保留一个平台）。
    form.addPlatform(
      name: 'gw',
      baseUrl: 'https://gw.example.com',
      apiTypeId: ApiType.openAiCompatibleId,
    );

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    // 展开的预置平台卡片上的删除入口此时可用。
    await tester.tap(find.text('删除此平台'));
    await tester.pumpAndSettle();
    expect(find.text('删除平台'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(form.platforms.length, 1);
    expect(form.platforms.single.id, isNot(AiPlatforms.defaultPlatformId));
    expect(find.text('恢复内置平台「默认（DeepSeek 开放平台）」'), findsOneWidget);

    await tester.tap(find.text('恢复内置平台「默认（DeepSeek 开放平台）」'));
    await tester.pumpAndSettle();
    expect(find.text('恢复内置平台'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '恢复'));
    await tester.pumpAndSettle();

    expect(
      form.platforms.any((p) => p.id == AiPlatforms.defaultPlatformId),
      isTrue,
    );
    expect(find.text('恢复内置平台「默认（DeepSeek 开放平台）」'), findsNothing);
    expect(find.text('默认（DeepSeek 开放平台）'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片设置：点击「jpg→jpeg 自动转换」开关可开启并写回表单状态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(
      ai: _NoPersistAiSettingsProvider(),
      sync: CloudSyncProvider(),
    );
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    expect(form.convertJpgToJpeg, isFalse);
    final toggleFinder = find.widgetWithText(SwitchListTile, '自动将 .jpg 转换为 .jpeg');
    expect(tester.widget<SwitchListTile>(toggleFinder).value, isFalse);

    await tester.tap(toggleFinder);
    await tester.pump();

    expect(form.convertJpgToJpeg, isTrue);
    expect(tester.widget<SwitchListTile>(toggleFinder).value, isTrue);
    expect(tester.takeException(), isNull);
  });
}
