import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/models/api_type.dart';
import 'package:narrchat/models/app_notice.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/app_notice_center.dart';
import 'package:narrchat/services/model_discovery_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/ai_settings_form.dart';
import 'package:narrchat/widgets/settings/settings_kit.dart';
import 'package:narrchat/widgets/settings_form_state.dart';

import 'helpers/notice_harness.dart';

Widget _buildApp(
  SettingsFormState form, {
  AppNoticeCenter? center,
  ModelDiscoveryService? discoveryService,
}) {
  return MaterialApp(
    theme: NarrChatTheme.light,
    builder: floatingNoticeBuilder(center: center),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: AiSettingsForm(form: form, discoveryService: discoveryService),
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

/// 展开第一个平台的第一个模型（deepseek-flash，预置列表首位 / 默认选中）的编辑器。
Future<void> _expandFirstModel(WidgetTester tester) async {
  await tester.tap(
    find.textContaining('deepseek-flash', findRichText: true).first,
  );
  await tester.pumpAndSettle();
}

/// 自定义平台的固定 id（`addPlatform` 默认按时间戳生成，这里固定下来，
/// 便于按「平台 + 模型」精确定位模型编辑器内的控件）。
const String _customPlatformId = 'custom_test_gateway';

/// 构造含一个自定义平台的工作副本（模型 `gw-a` 四项档位、`gw-b` 仅 `['low']`），
/// 用于验证「可选强度值」按模型独立生效。
///
/// `reasoningEffort` 是模型默认值（当前强度已迁到对话页选择），本页不再展示它。
SettingsFormState _formWithCustomPlatform() {
  final form = SettingsFormState(
    ai: AiSettingsProvider(),
    sync: CloudSyncProvider(),
  );
  form.addPlatform(
    id: _customPlatformId,
    name: '自定义网关',
    baseUrl: 'https://gw.example.com',
    apiTypeId: ApiType.openAiCompatibleId,
  );
  form.addModel(_customPlatformId, id: 'gw-a');
  form.addModel(_customPlatformId, id: 'gw-b');
  form.updateModel(
    _customPlatformId,
    'gw-a',
    const AiModel(
      id: 'gw-a',
      reasoningEffort: 'medium',
      reasoningEffortOptions: ['minimal', 'low', 'medium', 'high'],
    ),
  );
  form.updateModel(
    _customPlatformId,
    'gw-b',
    const AiModel(
      id: 'gw-b',
      reasoningEffort: 'high',
      reasoningEffortOptions: ['low'],
    ),
  );
  return form;
}

/// 展开自定义平台并展开其指定模型的编辑器。
Future<void> _expandCustomModel(WidgetTester tester, String modelId) async {
  await tester.tap(find.text('自定义网关'));
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining(modelId, findRichText: true).first);
  await tester.pumpAndSettle();
}

/// 「可选强度值」输入框（按标签文本定位，跨用例复用）。
Finder _optionsField() => find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.labelText == '可选强度值（逗号分隔，留空用默认）',
    );

/// 某个可调配功能标签（如「联网搜索」）对应的芯片。
Finder _capabilityChip(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip));

/// 已启用（选中态）的可调配功能标签数量。
int _enabledCapabilityCount(WidgetTester tester) => tester
    .widgetList<ChoiceChip>(find.byType(ChoiceChip))
    .where((chip) => chip.selected)
    .length;

void main() {
  testWidgets('窄列（261 宽）：平台与模型行展开后不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(261, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(
      ai: AiSettingsProvider(),
      sync: CloudSyncProvider(),
    );
    addTearDown(form.dispose);

    // 与云同步面板同一列宽（曾在该列宽出现 RenderFlex overflow）。
    await tester.pumpWidget(_buildApp(form));
    await tester.pump();
    await _expandFirstModel(tester);
    expect(tester.takeException(), isNull, reason: '不得出现 RenderFlex overflow');
  });

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
      'deepseek-flash',
    ]) {
      expect(
        find.textContaining(modelId, findRichText: true),
        findsWidgets,
        reason: '预置模型 $modelId 应列出',
      );
    }
    // 预置首位（默认选中）的 Flash 在卡片标题显示简写名称。
    expect(
      find.textContaining('DeepSeek V4.1 Flash', findRichText: true),
      findsWidgets,
    );
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
    expect(form.platforms.first.modelById('deepseek-flash')!.shortLabel, 'V4P');
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
    expect(form.platforms.first.modelById('deepseek-flash')!.shortLabel, 'V4P');
    expect(find.text('已自定义'), findsOneWidget);

    // 确认：还原为预置值（简写名称 DeepSeek V4.1 Flash），输入框文本同步回预置值，
    // 标注回到「内置默认」。
    await tester.tap(find.text('重置为内置预置'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '重置'));
    await tester.pumpAndSettle();

    expect(
      form.platforms.first.modelById('deepseek-flash')!.shortLabel,
      'DeepSeek V4.1 Flash',
    );
    final restoredField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '如 V4F',
      ),
    );
    expect(restoredField.controller!.text, 'DeepSeek V4.1 Flash');
    expect(find.text('内置默认'), findsOneWidget);
    expect(find.text('重置为内置预置'), findsNothing);
    expect(find.text('当前为软件内置预置配置（未自定义模型）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('可调配功能：两栏标签（已启用 / 未启用），点击即在两栏间移动', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(ai: AiSettingsProvider(), sync: CloudSyncProvider());
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();
    // 展开 v4 Pro（预置里 识图 关闭的模型）⇒ 已启用 3 个、未启用 1 个。
    await tester.tap(
      find.textContaining('deepseek-v4-pro', findRichText: true).first,
    );
    await tester.pumpAndSettle();

    // 区域标题与两栏栏名就位；不再有四行长开关（能力开关已改为标签）。
    expect(find.text('可调配功能（Chat 页对话框内可选）'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.text('未启用'), findsOneWidget);
    expect(find.text('预设模型的能力由平台固定，用户不可更改。'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(SettingsSwitchRow), findsOneWidget, reason: '仅剩图片设置的 jpg 开关');

    // 默认值不变：v4 Pro 预置为 流式 / 思考 / 联网搜索 开、识图关。
    for (final label in const ['流式', '思考', '联网搜索', '识图']) {
      expect(_capabilityChip(label), findsOneWidget);
    }
    expect(_enabledCapabilityCount(tester), 3);
    expect(tester.widget<ChoiceChip>(_capabilityChip('识图')).selected, isFalse);

    // 已启用栏点击「联网搜索」⇒ 禁用并移入未启用栏。
    await tester.tap(_capabilityChip('联网搜索'));
    await tester.pump();
    expect(form.platforms.first.modelById('deepseek-v4-pro')!.supportsSearch, isFalse);
    expect(tester.widget<ChoiceChip>(_capabilityChip('联网搜索')).selected, isFalse);
    expect(_enabledCapabilityCount(tester), 2);

    // 未启用栏点击「识图」⇒ 启用并移入已启用栏。
    await tester.tap(_capabilityChip('识图'));
    await tester.pump();
    expect(form.platforms.first.modelById('deepseek-v4-pro')!.supportsVision, isTrue);
    expect(tester.widget<ChoiceChip>(_capabilityChip('识图')).selected, isTrue);
    expect(_enabledCapabilityCount(tester), 3);

    // 全部启用后，未启用栏显示「（无）」占位。
    await tester.tap(_capabilityChip('联网搜索'));
    await tester.pump();
    expect(find.text('（无）'), findsOneWidget);
    expect(_enabledCapabilityCount(tester), 4);
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
        matching: find.byType(SettingsDropdownField<String>),
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
    final toggleFinder = find.byKey(
      const ValueKey('ai_settings_convert_jpg_switch'),
    );
    expect(tester.widget<Switch>(toggleFinder).value, isFalse);

    await tester.tap(toggleFinder);
    await tester.pump();

    expect(form.convertJpgToJpeg, isTrue);
    expect(tester.widget<Switch>(toggleFinder).value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('可选强度值：按模型配置显示档位，编辑后规范化写回该模型', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = _formWithCustomPlatform();
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();
    await _expandCustomModel(tester, 'gw-b');

    // 只配了 ['low'] 的模型：输入框显示配置值（不显示内置默认档位）。
    final field = _optionsField();
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'low');
    expect(find.textContaining('当前生效：low'), findsOneWidget);

    // 编辑为 mixed 写法：中文逗号 + 空格 + 重复项 ⇒ 解析为三个档位写回该模型。
    await tester.enterText(field, 'low，high max, low');
    await tester.pump();
    expect(
      form.platforms.last.modelById('gw-b')!.reasoningEffortOptions,
      ['low', 'high', 'max'],
    );
    // 输入框文本保持用户原样，只有中文逗号被即时换成英文逗号（不回写规范化文本）。
    expect(
      tester.widget<TextField>(field).controller!.text,
      'low,high max, low',
    );
    expect(find.textContaining('当前生效：low / high / max'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('可选强度值：中文逗号即时转英文逗号，刚敲的分隔符不会被吞', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = _formWithCustomPlatform();
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();
    await _expandCustomModel(tester, 'gw-b');
    final field = _optionsField();

    // 中文逗号即时转英文逗号：输入框里不残留全角逗号，模型解析出两项。
    await tester.enterText(field, 'low，high');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'low,high');
    expect(
      form.platforms.last.modelById('gw-b')!.reasoningEffortOptions,
      ['low', 'high'],
    );

    // 末尾刚敲下的逗号必须留在输入框里（旧实现会在下一帧回写文本把它吞掉）。
    await tester.enterText(field, 'low,high,');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'low,high,');
    expect(
      form.platforms.last.modelById('gw-b')!.reasoningEffortOptions,
      ['low', 'high'],
    );

    // 空格分隔同样原样保留，并解析为两个独立档位。
    await tester.enterText(field, 'minimal low');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'minimal low');
    expect(
      form.platforms.last.modelById('gw-b')!.reasoningEffortOptions,
      ['minimal', 'low'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('可选强度值：自定义列表生效，内置默认档位不再出现', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = _formWithCustomPlatform();
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();
    await _expandCustomModel(tester, 'gw-a');

    expect(
      tester.widget<TextField>(_optionsField()).controller!.text,
      'minimal,low,medium,high',
    );
    expect(
      find.textContaining('当前生效：minimal / low / medium / high'),
      findsOneWidget,
    );
    // 本页不再提供当前强度下拉（已迁到对话页选择）。
    expect(find.textContaining('推理强度（reasoning_effort）'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('思考强度：本页只配置档位，不提供当前强度值下拉', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = _formWithCustomPlatform();
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();
    await _expandCustomModel(tester, 'gw-a');

    expect(find.textContaining('推理强度（reasoning_effort）'), findsNothing);
    expect(_optionsField(), findsOneWidget);
    expect(
      find.textContaining('当前强度在对话页右下角的模型选择器中按模型选择'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('可选强度值：留空回落内置默认档位（low/high/max）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = _formWithCustomPlatform();
    addTearDown(form.dispose);

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();
    await _expandCustomModel(tester, 'gw-a');

    await tester.enterText(_optionsField(), ' , ， ');
    await tester.pump();

    expect(
      form.platforms.last.modelById('gw-a')!.reasoningEffortOptions,
      isEmpty,
    );
    expect(find.textContaining('当前生效：low / high / max'), findsOneWidget);
    expect(find.textContaining('推理强度（reasoning_effort）'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('可选强度值：内置预置平台不提供该入口，自定义平台才有', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final form = SettingsFormState(
      ai: AiSettingsProvider(),
      sync: CloudSyncProvider(),
    );
    addTearDown(form.dispose);
    // 追加一个自定义平台，保证同页同时存在「预置」与「自定义」两种模型编辑器。
    form.addPlatform(
      id: _customPlatformId,
      name: '自定义网关',
      baseUrl: 'https://gw.example.com',
      apiTypeId: ApiType.openAiCompatibleId,
    );
    form.addModel(_customPlatformId, id: 'gw-a');

    await tester.pumpWidget(_buildApp(form));
    await tester.pump();

    // 内置预置平台（默认展开）：模型编辑器不显示「可选强度值」入口，
    // 只显示固定档位与「去对话页选择当前强度」的说明。
    await _expandFirstModel(tester);
    expect(_optionsField(), findsNothing);
    expect(find.textContaining('思考强度档位：low / high / max'), findsOneWidget);
    expect(
      find.textContaining('当前强度在对话页右下角的模型选择器中按模型选择'),
      findsOneWidget,
    );
    expect(find.textContaining('推理强度（reasoning_effort）'), findsNothing);

    // 自定义平台：入口存在，且初始文本为内置默认档位。
    await _expandCustomModel(tester, 'gw-a');
    expect(_optionsField(), findsOneWidget);
    expect(
      tester.widget<TextField>(_optionsField()).controller!.text,
      'low,high,max',
    );
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // 获取可用模型（GET {baseUrl}/models → 多选导入）
  // ---------------------------------------------------------------------------
  group('获取可用模型', () {
    /// 构造 UTF-8 JSON 响应。
    http.Response jsonResponse(Object body, {int status = 200}) =>
        http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );

    testWidgets('入口：仅自定义平台显示，且并列在「添加模型」右侧', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final form = _formWithCustomPlatform();
      addTearDown(form.dispose);

      await tester.pumpWidget(_buildApp(form));
      await tester.pumpAndSettle();

      // 首个平台（内置预置）默认展开：只有「添加模型」，没有获取入口。
      expect(find.text('添加模型'), findsOneWidget);
      expect(find.text('获取可用模型'), findsNothing);

      await tester.tap(find.text('自定义网关'));
      await tester.pumpAndSettle();

      // 自定义平台：两个按钮并列，获取入口在「添加模型」右侧。
      expect(find.text('添加模型'), findsNWidgets(2));
      expect(find.text('获取可用模型'), findsOneWidget);
      final addButtonX = tester.getTopLeft(find.text('添加模型').last).dx;
      final fetchButtonX = tester.getTopLeft(find.text('获取可用模型')).dx;
      expect(fetchButtonX, greaterThan(addButtonX));
      expect(tester.takeException(), isNull);
    });

    testWidgets('成功：默认只勾新模型，可全选/全不选，同名整体覆盖', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final form = _formWithCustomPlatform();
      // gw-a 先改成用户手调过的值，用来证明导入是「整体覆盖」。
      form.updateModel(
        _customPlatformId,
        'gw-a',
        const AiModel(id: 'gw-a', shortLabel: 'A 简写', temperature: 0.7),
      );
      addTearDown(form.dispose);
      final center = AppNoticeCenter();
      addTearDown(center.dispose);
      final service = ModelDiscoveryService(
        client: MockClient(
          (_) async => jsonResponse({
            'data': [
              {'id': 'gw-a', 'supports_thinking': false},
              {
                'id': 'brand-new',
                'name': 'Brand New',
                'max_output_tokens': 4096,
                'supports_vision': true,
              },
            ],
          }),
        ),
      );

      await tester.pumpWidget(
        _buildApp(form, center: center, discoveryService: service),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义网关'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('获取可用模型'));
      await tester.pumpAndSettle();

      // 多选对话框：按钮 + 标题各一处「获取可用模型」，两行候选。
      expect(find.text('获取可用模型'), findsNWidgets(2));
      expect(find.byType(SettingsCheckboxRow), findsNWidgets(2));
      expect(find.text('将覆盖'), findsOneWidget);
      // 默认只勾「新模型」：冲突的 gw-a 不勾，避免误覆盖。
      expect(
        tester
            .widgetList<SettingsCheckboxRow>(
              find.byType(SettingsCheckboxRow),
            )
            .map((tile) => tile.value),
        [false, true],
      );
      expect(find.text('导入 1 个'), findsOneWidget);

      // 全选 → 全不选（未勾选不可导入）→ 再全选。
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('导入 2 个'), findsOneWidget);
      await tester.tap(find.text('全不选'));
      await tester.pump();
      expect(find.text('导入 0 个'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(
                of: find.text('导入 0 个'),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('全选'));
      await tester.pump();
      await tester.tap(find.text('导入 2 个'));
      await tester.pumpAndSettle();

      final platform = form.platforms.firstWhere(
        (p) => p.id == _customPlatformId,
      );
      // 同名整体覆盖：手调的简写标识 / 温度回到导入默认值。
      final gwA = platform.modelById('gw-a')!;
      expect(gwA.shortLabel, isEmpty);
      expect(gwA.temperature, 1.0);
      expect(gwA.supportsThinking, isFalse);
      // 新模型追加，并按接口导入能力字段。
      final brandNew = platform.modelById('brand-new')!;
      expect(brandNew.maxTokens, 4096);
      expect(brandNew.supportsVision, isTrue);
      expect(platform.models.map((m) => m.id), ['gw-a', 'gw-b', 'brand-new']);

      // 成功通知汇总新增 / 覆盖数。
      expect(center.current?.message, contains('新增 1 个'));
      expect(center.current?.message, contains('覆盖 1 个同名模型'));
      await flushNotices(tester);
    });

    testWidgets('失败：悬浮通知包含失败码与响应体，且不弹导入框', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final form = _formWithCustomPlatform();
      addTearDown(form.dispose);
      final center = AppNoticeCenter();
      addTearDown(center.dispose);
      final service = ModelDiscoveryService(
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode('{"error":{"message":"bad key"}}'),
            401,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      await tester.pumpWidget(
        _buildApp(form, center: center, discoveryService: service),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义网关'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('获取可用模型'));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsCheckboxRow), findsNothing);
      final notice = center.current;
      expect(notice, isNotNull);
      expect(notice!.kind, NoticeKind.error);
      expect(notice.copyable, isTrue);
      expect(notice.message, contains('HTTP 401'));
      expect(notice.message, contains('bad key'));
      await flushNotices(tester);
    });

    testWidgets('未填 Base URL：提示先填写地址，不发请求', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final form = _formWithCustomPlatform();
      form.setPlatformBaseUrl(_customPlatformId, '');
      addTearDown(form.dispose);
      final center = AppNoticeCenter();
      addTearDown(center.dispose);
      var called = false;
      final service = ModelDiscoveryService(
        client: MockClient((_) async {
          called = true;
          return jsonResponse({'data': []});
        }),
      );

      await tester.pumpWidget(
        _buildApp(form, center: center, discoveryService: service),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义网关'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('获取可用模型'));
      await tester.pumpAndSettle();

      expect(called, isFalse);
      expect(center.current?.kind, NoticeKind.warning);
      expect(center.current?.message, contains('Base URL'));
      await flushNotices(tester);
    });

    test('importModels：同名整体覆盖、新名追加，并触发模型编辑器重建', () {
      final form = _formWithCustomPlatform();
      addTearDown(form.dispose);
      form.updateModel(
        _customPlatformId,
        'gw-a',
        const AiModel(id: 'gw-a', shortLabel: 'A', temperature: 0.7),
      );
      final revisionBefore = form.resetRevision;

      final counts = form.importModels(_customPlatformId, [
        const AiModel(id: 'gw-a', supportsThinking: false),
        const AiModel(id: 'gw-new'),
      ]);

      expect(counts, (added: 1, overwritten: 1));
      final platform = form.platforms.firstWhere(
        (p) => p.id == _customPlatformId,
      );
      final gwA = platform.modelById('gw-a')!;
      expect(gwA.shortLabel, isEmpty);
      expect(gwA.temperature, 1.0);
      expect(gwA.supportsThinking, isFalse);
      expect(platform.models.map((m) => m.id), ['gw-a', 'gw-b', 'gw-new']);
      expect(form.resetRevision, revisionBefore + 1);
    });

    test('importModels：无改动时不通知也不重建；未知平台忽略', () {
      final form = _formWithCustomPlatform();
      addTearDown(form.dispose);
      final revisionBefore = form.resetRevision;
      var notified = 0;
      form.addListener(() => notified++);

      expect(
        form.importModels(_customPlatformId, const []),
        (added: 0, overwritten: 0),
      );
      expect(
        form.importModels('missing-platform', [const AiModel(id: 'x')]),
        (added: 0, overwritten: 0),
      );
      expect(notified, 0);
      expect(form.resetRevision, revisionBefore);
    });
  });
}
