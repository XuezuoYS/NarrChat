import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/mod.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/mod_detail_dialog.dart';
import 'package:narrchat/widgets/prompt_input_hint.dart';

/// Mod 编辑 / 查看对话框的**响应式布局**与面板元数据。
///
/// 规格（`docs/mods.md` §七）：
/// - 宽屏（可用宽度 ≥720）：左侧 8 个面板导航 + 右侧编辑区；
/// - 窄屏：整页布局（全屏对话框）+ 顶栏 + 面板下拉选择器 + 撑满的编辑区；
/// - 四个 system 通道统一叫 `System 提示词 - …`；
/// - 三个新列显示「该列在 3.0 不生效」；切换面板不丢草稿。
void main() {
  const sample = Mod(
    uuid: 'm1',
    name: '文笔润色',
    description: '让文风更流畅',
    prePrompt: '前置词内容',
    systemPrompt: '通用约束内容',
    systemMust: '最高优先约束内容',
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

  Future<void> pickPanel(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const ValueKey('mod_panel_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title).last);
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
      find.byKey(const ValueKey('mod_panel_title_basic')),
      findsOneWidget,
      reason: '默认停在基本信息',
    );
    expect(
      find.byKey(const ValueKey('mod_panel_content_basic')),
      findsOneWidget,
    );
    // 基本信息：没有数据库列，灰字只写「仅用于辨识」。
    expect(find.textContaining('仅用于辨识，不发送给 AI'), findsWidgets);
    // 统一的 #/## 输入提示只出现一次。
    expect(find.text(PromptInputHint.text), findsOneWidget);
  });

  testWidgets('四个 system 通道统一用「System 提示词 - …」命名', (tester) async {
    await open(tester, size: const Size(1200, 800));

    for (final title in const [
      kModPanelMiscTitle,
      kModPanelSettingTitle,
      kModPanelWritingTitle,
      kModPanelMustTitle,
    ]) {
      expect(find.text(title), findsOneWidget, reason: '导航缺少：$title');
    }
    expect(kModPanelWritingTitle, 'System 提示词 - 文笔要求与参考段落');
    expect(find.text('通用约束'), findsNothing);
    expect(find.text('最高优先约束'), findsNothing);
  });

  testWidgets('宽屏：切到新列面板显示列名 / 注入位置与 3.0 提醒条', (tester) async {
    await open(tester, size: const Size(1200, 800));

    await tapPanel(tester, ModPanel.must);
    expect(find.byKey(const ValueKey('mod_panel_title_must')), findsOneWidget);
    expect(
      find.text(
        '数据库列 system_must · 注入位置：「必须遵循」段 2~n，末尾会复述一次（token ×2）',
      ),
      findsOneWidget,
    );
    expect(find.text('该列在 3.0 不生效'), findsOneWidget);
    // 导航 + 编辑区标题各一份。
    expect(find.text(kModPanelMustTitle), findsNWidgets(2));

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

  testWidgets('多行编辑区铺满高度、文字顶部对齐（不垂直居中）', (tester) async {
    await open(tester, size: const Size(1200, 800));

    await tapPanel(tester, ModPanel.misc);
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.expands, isTrue, reason: '编辑区应铺满面板剩余高度');
    expect(field.maxLines, isNull);
    expect(
      field.textAlignVertical,
      TextAlignVertical.top,
      reason: 'expands 时默认会垂直居中，必须显式顶对齐',
    );
  });

  testWidgets('窄屏：仍是悬浮窗（不贴屏幕边缘）+ 下拉切换面板，没有左侧导航', (tester) async {
    await open(tester, size: const Size(420, 780));

    expect(find.byKey(const ValueKey('mod_panel_dropdown')), findsOneWidget);
    expect(find.byKey(const ValueKey('mod_panel_nav_basic')), findsNothing);
    // 窄屏不重复面板标题：选择器本身就是标题。
    expect(find.byKey(const ValueKey('mod_panel_title_basic')), findsNothing);
    expect(find.byKey(const ValueKey('mod_panel_content_basic')), findsOneWidget);
    expect(find.text('基本信息'), findsOneWidget, reason: '选择器里显示当前面板');
    // 悬浮窗：不贴屏幕边缘（全屏时下拉框左边距只等于内容内边距 16）。
    final dropdown = find.byKey(const ValueKey('mod_panel_dropdown'));
    expect(tester.getTopLeft(dropdown).dx, greaterThan(24));
    expect(tester.getSize(dropdown).width, lessThan(420 - 48));
    // 底部按钮与宽屏一致。
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    // #/## 提示仍在（窄屏挪到编辑区下方当脚注），全文只出现一次。
    expect(find.text(PromptInputHint.text), findsOneWidget);

    await pickPanel(tester, kModPanelMustTitle);

    expect(find.byKey(const ValueKey('mod_panel_content_must')), findsOneWidget);
    expect(find.text('该列在 3.0 不生效'), findsOneWidget);
    expect(find.text(kModPanelMustTitle), findsOneWidget, reason: '选择器已切到最高优先约束');
  });

  testWidgets('小屏（360×640）：长标题下也不溢出、编辑区可用', (tester) async {
    await open(tester, size: const Size(360, 640));

    await pickPanel(tester, kModPanelWritingTitle);
    expect(find.byKey(const ValueKey('mod_panel_content_writing')), findsOneWidget);
    expect(find.text(kModPanelWritingTitle), findsOneWidget);
    // 长标题被省略号截断而不是撑破布局（不出现 RenderFlex overflow 异常）。
    expect(tester.takeException(), isNull);

    // 编辑区铺满剩余高度：多行输入框可用并可输入。
    await tester.enterText(find.byType(TextField).first, '窄屏也能写');
    await tester.pump();
    expect(find.text('窄屏也能写'), findsOneWidget);
  });

  testWidgets('只读：没有保存按钮，提醒条照常显示', (tester) async {
    await open(tester, size: const Size(1200, 800), readOnly: true);

    expect(find.text('查看 Mod'), findsOneWidget);
    expect(find.text('保存'), findsNothing);
    expect(find.text('关闭'), findsOneWidget);

    await tapPanel(tester, ModPanel.must);
    expect(find.text('该列在 3.0 不生效'), findsOneWidget);
  });

  testWidgets('只读（窄屏）：底部只有「关闭」，没有保存', (tester) async {
    await open(tester, size: const Size(420, 780), readOnly: true);

    expect(find.text('查看 Mod'), findsOneWidget);
    expect(find.text('保存'), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
  });

  testWidgets('保存回传七个通道的内容', (tester) async {
    await open(tester, size: const Size(1200, 800));

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(lastResult, isNotNull);
    expect(lastResult!.name, '文笔润色');
    expect(lastResult!.prePrompt, '前置词内容');
    expect(lastResult!.systemMust, '最高优先约束内容');
    expect(lastResult!.systemPrompt, '通用约束内容');
    expect(lastResult!.systemSetting, '设定内容');
    expect(lastResult!.systemWritingStyle, '文笔内容');
    expect(lastResult!.worldBookEntries, hasLength(1));
  });
}
