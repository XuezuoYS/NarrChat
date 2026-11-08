import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/providers/mod_provider.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/book_mod_panel.dart';
import 'package:narrchat/widgets/prompt_input_hint.dart';
import 'package:provider/provider.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 书籍设置页的 Mod 面板（真库 + ModRepository）。
///
/// 面板是**纯草稿组件**：开关 / 排序只通过 `onChanged` 回传配置，
/// 不直接写 `use_mods`；落库由书籍设置页点「保存」时统一提交。
void main() {
  late TestStack stack;
  late String modPolish;
  late String modDeAi;

  setUp(() async {
    stack = await TestStack.create();
    await stack.seedBook(uuid: 'b1', title: '书');
    modPolish = await stack.seedMod(
      name: '文笔润色',
      description: '让文风更流畅',
      prePrompt: '前置词内容',
    );
    modDeAi = await stack.seedMod(
      name: '去AI味',
      description: '减少 AI 腔',
      postPrompt: '后置词内容',
    );
  });

  tearDown(() async {
    await stack.dispose();
  });

  /// 把「已启用 uuid 列表」拼成面板初始草稿（启用在前、按置入顺序）。
  List<BookModConfig> configsOf(List<String> enabledUuids) => [
    for (var i = 0; i < enabledUuids.length; i++)
      BookModConfig(
        bookUuid: 'b1',
        modUuid: enabledUuids[i],
        isEnabled: true,
        sortOrder: i,
      ),
  ];

  /// Pump 书籍设置页的 Mod 管理面板（编辑模式，书 b1）。
  Future<List<List<BookModConfig>>> pumpPanel(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    List<String> enabledUuids = const [],
  }) async {
    // 先按“上次保存”的状态写库，用来断言面板改动不会即时落库。
    await tester.runAsync(
      () => stack.repos.mod.setUseModUuids('b1', enabledUuids),
    );
    final emitted = <List<BookModConfig>>[];
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ModProvider(repository: stack.repos.mod),
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: Scaffold(
            body: SingleChildScrollView(
              child: BookModPanel(
                bookUuid: 'b1',
                initialConfigs: configsOf(enabledUuids),
                onChanged: (configs) => emitted.add(configs),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return emitted;
  }

  testWidgets('点击已启用条目主体打开只读【预览 mod】对话框', (tester) async {
    await pumpPanel(tester, enabledUuids: [modPolish]);

    await tester.tap(find.text('文笔润色'));
    await settle(tester);

    // 打开的是只读「查看 Mod」对话框：5 个内容标签 + 仅「关闭」按钮。
    expect(find.text('查看 Mod'), findsOneWidget);
    expect(find.text('基本信息'), findsOneWidget);
    expect(find.text('前置词'), findsOneWidget);
    expect(find.text('后置词'), findsOneWidget);
    expect(find.text('系统提示词'), findsOneWidget);
    expect(find.text('世界书'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, '文笔润色'),
      findsOneWidget,
      reason: '预览对话框展示 Mod 名称',
    );
    // 对话框内统一的 #/## 输入提示（与书籍设置各页同一文案）。
    expect(find.text(PromptInputHint.text), findsOneWidget);
    expect(find.text('保存'), findsNothing, reason: '预览为只读，无保存按钮');
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('点击开关只切换启用状态，不打开预览对话框', (tester) async {
    await pumpPanel(tester, enabledUuids: [modPolish]);

    await tester.tap(find.byType(Switch));
    await settle(tester);

    expect(find.text('查看 Mod'), findsNothing, reason: '开关区域不应触发预览');
    expect(
      find.textContaining('暂无启用中的 Mod'),
      findsOneWidget,
      reason: '关闭开关后移入「未启用」标签',
    );
  });

  testWidgets('点击拖动柄不打开预览对话框，也不改变顺序', (tester) async {
    final emitted = await pumpPanel(tester, enabledUuids: [modPolish, modDeAi]);

    await tester.tap(find.byIcon(Icons.drag_handle).first);
    await settle(tester);

    expect(find.text('查看 Mod'), findsNothing, reason: '拖动柄区域不应触发预览');
    final firstY = tester.getTopLeft(find.text('文笔润色')).dy;
    final secondY = tester.getTopLeft(find.text('去AI味')).dy;
    expect(firstY < secondY, isTrue, reason: '未发生拖动，顺序保持自上而下');
    expect(emitted, isEmpty, reason: '轻点拖动柄不产生配置变更');
  });

  testWidgets('窄屏（竖版）布局下点击条目主体同样打开预览对话框', (tester) async {
    await pumpPanel(
      tester,
      size: const Size(400, 800),
      enabledUuids: [modPolish],
    );

    await tester.tap(find.text('文笔润色'));
    await settle(tester);

    expect(find.text('查看 Mod'), findsOneWidget);
    expect(find.widgetWithText(TextField, '文笔润色'), findsOneWidget);
  });

  testWidgets('未改动配置时不回调，也不碰库里的启用清单', (tester) async {
    final emitted = await pumpPanel(tester, enabledUuids: [modPolish]);

    expect(emitted, isEmpty);
    expect(await tester.runAsync(() => stack.repos.mod.useModUuids('b1')), [
      modPolish,
    ], reason: '打开面板只读不写');
  });

  testWidgets('停用唯一启用项：只回调草稿，库里的启用清单不变', (tester) async {
    final emitted = await pumpPanel(tester, enabledUuids: [modPolish]);

    await tester.tap(find.byType(Switch));
    await settle(tester);

    expect(emitted, isNotEmpty);
    expect(
      emitted.last.where((c) => c.isEnabled),
      isEmpty,
      reason: '回调里停用项不再出现在启用清单',
    );
    expect(await tester.runAsync(() => stack.repos.mod.useModUuids('b1')), [
      modPolish,
    ], reason: '面板不写库，保存前库里保持原启用清单');
  });

  testWidgets('启用未启用项：追加到启用末尾并回调完整配置', (tester) async {
    final emitted = await pumpPanel(tester, enabledUuids: [modPolish]);

    // 切到「未启用」标签，启用「去AI味」。
    await tester.tap(find.textContaining('未启用（'));
    await settle(tester);
    final deAiTile = find.byKey(ValueKey('book_mod_disabled_user:$modDeAi'));
    await tester.tap(
      find.descendant(of: deAiTile, matching: find.byType(Switch)),
    );
    await settle(tester);

    expect(emitted, isNotEmpty);
    final enabled = emitted.last
        .where((c) => c.isEnabled)
        .where((c) => c.modUuid != null)
        .map((c) => c.modUuid)
        .toList();
    expect(enabled, [modPolish, modDeAi], reason: '新启用的项追加到启用末尾');
    expect(await tester.runAsync(() => stack.repos.mod.useModUuids('b1')), [
      modPolish,
    ], reason: '保存前不落库');
  });

  testWidgets('启用顺序按面板自上而下的顺序回传', (tester) async {
    final emitted = await pumpPanel(tester, enabledUuids: [modPolish, modDeAi]);

    // 停用第一个后再保存：回调里只剩另一个，顺序不塌陷。
    await tester.tap(find.byType(Switch).first);
    await settle(tester);

    expect(emitted, isNotEmpty);
    final enabled = emitted.last
        .where((c) => c.isEnabled)
        .where((c) => c.modUuid != null)
        .map((c) => c.modUuid)
        .toList();
    expect(enabled, [modDeAi]);
    expect(await tester.runAsync(() => stack.repos.mod.useModUuids('b1')), [
      modPolish,
      modDeAi,
    ], reason: 'sort_order 只在点保存后统一写库');
  });
}
