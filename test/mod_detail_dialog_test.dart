import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/mod.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/mod_detail_dialog.dart';
import 'package:narrchat/widgets/prompt_input_hint.dart';

/// Mod 编辑对话框的**响应式布局**与面板元数据。
///
/// 规格（`docs/mods.md` §七）：宽屏左右分栏（左导航、右编辑区）、窄屏顶部选择器；
/// 任何宽度都不横向滚动；8 个面板都能到达；三个新列显示「该列在 3.0 不生效」；
/// 切换面板不丢草稿。
void main() {
  const sample = Mod(
    uuid: 'm1',
    name: '文笔润色',
    description: '让文风更流畅',
    prePrompt: '前置词内容',
    systemPrompt: '杂项内容',
    systemMust: '强指令内容',
    systemSetting: '设定内容',
    systemWritingStyle: '文笔内容',
    worldBookEntries: [ModWorldBookEntry(keyword: '宗门', content: '宗门设定')],
  );

  /// 最近一次对话框返回值（取消为 null）。
  ModFormData? lastResult;

  /// Pump 宿主页并点开对话框。
  Future<void> open(
    WidgetTester tester, {
    required Size size,
    Mod? mod = sample,
    bool readOnly = false,
  }) async {
    lastResult = null;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  lastResult = await showModDetailDialog(
                    context,
                    mod: mod,
                    readOnly: readOnly,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> tapPanel(WidgetTester tester, ModPanel panel) async {
    await tester.tap(find.byKey(ValueKey('mod_panel_nav_${panel.name}')));
    await tester.pumpAndSettle();
  }

  testWidgets('宽屏：左侧 8 个面板导航 + 右侧编辑区（无 TabBar）', (tester) async {
    await open(tester, size: const Size(1200, 800));

    for (final panel in ModPanel.values) {
      expect(
        find.byKey(ValueKey('mod_panel_nav_${panel.name}')),
        findsOneWidget,
        reason: '缺少面板导航：${panel.name}',
      );
    }
    expect(find.byType(TabBar), findsNothing);
    expect(
      find.byKey(const ValueKey('mod_panel_editor_basic')),
      findsOneWidget,
      reason: '默认停在基本信息',
    );
    // 基本信息：没有数据库列，灰字只写「仅用于辨识」。
    expect(find.textContaining('仅用于辨识，不发送给 AI'), findsWidgets);
    // 统一的 #/## 输入提示只出现一次。
    expect(find.text(PromptInputHint.text), findsOneWidget);
  });

  testWidgets('宽屏：切到新列面板显示列名 / 注入位置与 3.0 提醒条', (tester) async {
    await open(tester, size: const Size(1200, 800));

    await tapPanel(tester, ModPanel.must);
    expect(find.byKey(const ValueKey('mod_panel_editor_must')), findsOneWidget);
    expect(
      find.text(
        '数据库列 system_must · 注入位置：「必须遵循」段 2~n，末尾会复述一次（token ×2）',
      ),
      findsOneWidget,
    );
    expect(find.text('该列在 3.0 不生效'), findsOneWidget);

    await tapPanel(tester, ModPanel.setting);
    expect(find.textContaining('数据库列 system_setting'), findsOneWidget);
    expect(find.text('该列在 3.0 不生效'), findsOneWidget);

    await tapPanel(tester, ModPanel.writing);
    expect(find.textContaining('数据库列 system_writing_style'), findsOneWidget);

    // 老列不显示提醒条。
    await tapPanel(tester, ModPanel.misc);
    expect(find.textContaining('数据库列 system_prompt'), findsOneWidget);
    expect(find.text('该列在 3.0 不生效'), findsNothing);
  });

  testWidgets('切换面板不丢草稿（控制器常驻 State）', (tester) async {
    await open(tester, size: const Size(1200, 800));

    await tapPanel(tester, ModPanel.pre);
    await tester.enterText(find.byType(TextField).first, '新写的前置词');
    await tester.pump();
    expect(find.text('新写的前置词'), findsOneWidget);

    await tapPanel(tester, ModPanel.must);
    await tapPanel(tester, ModPanel.pre);
    expect(find.text('新写的前置词'), findsOneWidget);
  });

  testWidgets('窄屏：顶部下拉切换面板，没有左侧导航', (tester) async {
    await open(tester, size: const Size(420, 780));

    expect(find.byKey(const ValueKey('mod_panel_dropdown')), findsOneWidget);
    expect(find.byKey(const ValueKey('mod_panel_nav_basic')), findsNothing);
    expect(find.byKey(const ValueKey('mod_panel_editor_basic')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mod_panel_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('强指令').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mod_panel_editor_must')), findsOneWidget);
    expect(find.text('该列在 3.0 不生效'), findsOneWidget);
  });

  testWidgets('只读：没有保存按钮，提醒条照常显示', (tester) async {
    await open(tester, size: const Size(1200, 800), readOnly: true);

    expect(find.text('查看 Mod'), findsOneWidget);
    expect(find.text('保存'), findsNothing);
    expect(find.text('关闭'), findsOneWidget);

    await tapPanel(tester, ModPanel.must);
    expect(find.text('该列在 3.0 不生效'), findsOneWidget);
  });

  testWidgets('保存回传七个通道的内容', (tester) async {
    await open(tester, size: const Size(1200, 800));

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(lastResult, isNotNull);
    expect(lastResult!.name, '文笔润色');
    expect(lastResult!.prePrompt, '前置词内容');
    expect(lastResult!.systemMust, '强指令内容');
    expect(lastResult!.systemPrompt, '杂项内容');
    expect(lastResult!.systemSetting, '设定内容');
    expect(lastResult!.systemWritingStyle, '文笔内容');
    expect(lastResult!.worldBookEntries, hasLength(1));
  });
}
