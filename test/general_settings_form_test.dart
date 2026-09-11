import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/services/system_fonts_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/general_settings_form.dart';

void main() {
  Widget buildApp(double width, {ExperimentalSettingsProvider? experimental}) {
    return ChangeNotifierProvider.value(
      value: UiSettingsProvider(),
      child: ChangeNotifierProvider(
        // Agent 档位由实验性设置 Provider 驱动（构造注入初值，
        // 不触碰真实配置文件）。
        create: (_) => experimental ?? ExperimentalSettingsProvider(),
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: const GeneralSettingsForm(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('三个子模块分区齐全：UI 设置 / 其它设置 / 实验性设置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildApp(1000));
    await tester.pump();

    // 面板标题与三个子模块标题。
    expect(find.text('通用设置'), findsOneWidget);
    expect(find.text('UI 设置'), findsOneWidget);
    expect(find.text('其它设置'), findsOneWidget);
    expect(find.text('实验性设置'), findsOneWidget);

    // UI 设置内容：主题设置可见。
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('跟随系统（默认）：随系统亮暗自动切换'), findsOneWidget);

    // 其它设置内容：检查更新开关可见。
    expect(
      find.byKey(const ValueKey('other_update_check_switch')),
      findsOneWidget,
    );

    // 实验性设置内容：Agent 模式档位卡片（默认「关」）。
    expect(
      find.byKey(const ValueKey('experimental_agent_mode_card')),
      findsOneWidget,
    );
    expect(find.text('Agent 模式'), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('experimental_agent_mode_label')),
          )
          .data,
      '关',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Agent 模式：点击整卡任意位置展开档位菜单，切换后界面即时生效', (tester) async {
    // 预扫描系统字体：字体扫描是真实 IO，在 fake zone 中永不完成，
    // 会让 UiSettingsForm 一直显示转圈动画，导致 pumpAndSettle 超时。
    await tester.runAsync(() => SystemFontsService.instance.scan());
    // 视口取高一些：实验性设置在最下方，卡片需可见才能点击。
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final provider = ExperimentalSettingsProvider();
    await tester.pumpWidget(buildApp(1000, experimental: provider));
    await tester.pump();

    final card = find.byKey(const ValueKey('experimental_agent_mode_card'));
    String label() => tester
        .widget<Text>(
          find.byKey(const ValueKey('experimental_agent_mode_label')),
        )
        .data!;

    // 默认「无」档（传统 Chat）。
    expect(provider.agentModeLevel, AgentModeLevel.off);
    expect(label(), '关');
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();

    // 点击卡片**左侧的标题文字**（不靠近右侧箭头）也能展开菜单。
    await tester.tap(find.text('Agent 模式'));
    await tester.pumpAndSettle();
    // 三个档位齐全，且每个选项自带一行说明。
    expect(find.text('无'), findsWidgets);
    expect(find.text('Agent Lv.1'), findsWidgets);
    expect(find.text('Agent Lv.2'), findsWidgets);
    expect(find.text('使用传统 Chat 方式'), findsOneWidget);
    expect(find.text('记忆总结部分将由 Agent 托管'), findsOneWidget);
    expect(
      find.text('角色状态、世界状态、记忆总结部分将由 Agent 托管'),
      findsOneWidget,
    );

    // 选择 Lv.1 → Provider 乐观更新（界面即时生效）。
    await tester.tap(find.text('Agent Lv.1').last);
    await tester.pumpAndSettle();
    expect(provider.agentModeLevel, AgentModeLevel.lv1);
    expect(label(), 'Lv.1');

    // 再次点击卡片**描述文字区域**同样可展开 → 切到 Lv.2。
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('实验性功能（默认「无」）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agent Lv.2').last);
    await tester.pumpAndSettle();
    expect(provider.agentModeLevel, AgentModeLevel.lv2);
    expect(label(), 'Lv.2');
  });

  testWidgets('精简思考回传开关：默认关，点击后开启并即时生效', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final provider = ExperimentalSettingsProvider();
    await tester.pumpWidget(buildApp(1000, experimental: provider));
    await tester.pump();

    final toggle =
        find.byKey(const ValueKey('experimental_reduce_reasoning_switch'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();

    // 说明文案点明用途与默认状态。
    expect(find.text('精简思考回传'), findsOneWidget);
    expect(find.textContaining('只保留首段与末段'), findsOneWidget);
    expect(find.textContaining('默认关'), findsOneWidget);

    // 默认关。
    expect(provider.reduceReasoningReplay, isFalse);
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(provider.reduceReasoningReplay, isTrue);
    expect(tester.widget<Switch>(toggle).value, isTrue);

    // 再点回关。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(provider.reduceReasoningReplay, isFalse);
  });

  testWidgets('Agent 模式简介简要概括：托管范围、指示器限制与破坏性变更声明', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildApp(1000));
    await tester.pump();

    // 简要介绍：指向下拉选项（细节不在卡片里堆砌）。
    expect(find.textContaining('各档位托管范围见下拉选项说明'), findsOneWidget);
    expect(find.textContaining('narrchat_*'), findsOneWidget);
    expect(find.textContaining('两阶段生成'), findsOneWidget);
    // 指示器限制声明 + 破坏性变更声明 + 正确性声明。
    expect(find.textContaining('无法通过对话页指示器关闭'), findsOneWidget);
    expect(find.textContaining('破坏性变更'), findsOneWidget);
    expect(find.textContaining('正确性不保证'), findsOneWidget);
    // 逐档说明移入下拉选项，不再出现在卡片简介里。
    expect(find.textContaining('previous_response_id'), findsNothing);
    expect(find.textContaining('narrchat_editWorldState'), findsNothing);
  });
}
