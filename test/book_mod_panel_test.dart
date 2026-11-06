import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/mod_provider.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/book_mod_panel.dart';
import 'package:narrchat/widgets/prompt_input_hint.dart';
import 'package:provider/provider.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 书籍设置页的 Mod 面板（真库 + ModRepository）。
///
/// 数据形态变化：R3 的 `use_mods` 只存**已启用**项的引用与顺序，
/// 未启用只是面板里的本地状态，不再落库。
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

  /// Pump 书籍设置页的 Mod 管理面板（编辑模式，书 b1）。
  Future<void> pumpPanel(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    List<String> enabledUuids = const [],
  }) async {
    await tester.runAsync(
      () => stack.repos.mod.setUseModUuids('b1', enabledUuids),
    );
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
              child: BookModPanel(bookUuid: 'b1'),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
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
    expect(find.widgetWithText(TextField, '文笔润色'), findsOneWidget,
        reason: '预览对话框展示 Mod 名称');
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
    expect(find.textContaining('暂无启用中的 Mod'), findsOneWidget,
        reason: '关闭开关后移入「未启用」标签');
  });

  testWidgets('点击拖动柄不打开预览对话框，也不改变顺序', (tester) async {
    await pumpPanel(tester, enabledUuids: [modPolish, modDeAi]);

    await tester.tap(find.byIcon(Icons.drag_handle).first);
    await settle(tester);

    expect(find.text('查看 Mod'), findsNothing, reason: '拖动柄区域不应触发预览');
    final firstY = tester.getTopLeft(find.text('文笔润色')).dy;
    final secondY = tester.getTopLeft(find.text('去AI味')).dy;
    expect(firstY < secondY, isTrue, reason: '未发生拖动，顺序保持自上而下');
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

  testWidgets('停用唯一启用项后，库里的启用清单变空（只落启用项）', (tester) async {
    await pumpPanel(tester, enabledUuids: [modPolish]);
    expect(
      await tester.runAsync(() => stack.repos.mod.useModUuids('b1')),
      [modPolish],
    );

    await tester.tap(find.byType(Switch));
    await settle(tester);

    expect(
      await tester.runAsync(() => stack.repos.mod.useModUuids('b1')),
      isEmpty,
        reason: '未启用项不落库，启用清单被整体替换为空');
  });

  testWidgets('启用顺序按面板自上而下的顺序落库', (tester) async {
    await pumpPanel(tester, enabledUuids: [modPolish, modDeAi]);
    expect(
      await stack.repos.mod.useModUuids('b1'),
      [modPolish, modDeAi],
      reason: 'sort_order 决定提示词拼合顺序，必须原样保留',
    );

    // 停用一个后再保存：清单里只剩另一个，顺序不塌陷。
    await tester.tap(find.byType(Switch).first);
    await settle(tester);
    expect(
      await tester.runAsync(() => stack.repos.mod.useModUuids('b1')),
      [modDeAi],
    );
  });
}
