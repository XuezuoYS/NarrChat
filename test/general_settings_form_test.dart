import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/services/system_fonts_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/general_settings_form.dart';

/// 取出标题富文本里「（实验性）」后缀的颜色（断言「全局警告黄」用）。
///
/// 标题是 `Text.rich`（本体 + 后缀同段富文本），`find.text` 需要
/// `findRichText: true` 才能命中；这里顺带把后缀 span 的颜色捞出来。
Color? experimentalTagColor(WidgetTester tester, String title) {
  final rich = tester.widget<RichText>(find.text(title, findRichText: true));
  Color? color;
  void visit(InlineSpan span) {
    if (span is! TextSpan) return;
    if (span.text == '（实验性）') color = span.style?.color;
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child);
    }
  }

  visit(rich.text);
  return color;
}

void main() {
  Widget buildApp(
    double width, {
    ExperimentalSettingsProvider? experimental,
    AiSettingsProvider? ai,
  }) {
    return ChangeNotifierProvider.value(
      value: UiSettingsProvider(),
      child: ChangeNotifierProvider(
        // 子模型行需要读取平台 / 模型列表与当前主模型；构造注入不触碰真实配置。
        create: (_) => ai ?? AiSettingsProvider(),
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
      ),
    );
  }

  testWidgets('窄列（261 宽）：同一设置页列宽下各分区不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // 云同步面板曾在该列宽（卡片内容 229）出现 RenderFlex overflow；
    // 通用设置各分区共用同一列宽，一并纳入回归。
    await tester.pumpWidget(buildApp(261));
    await tester.pump();
    expect(find.text('通用设置'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得出现 RenderFlex overflow');
  });

  testWidgets('三个子模块分区齐全：UI 设置 / 其它设置 / 会话工作模式（实验性）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildApp(1000));
    await tester.pump();

    // 面板标题与三个子模块标题（实验性分区已改名，后缀为黄色标注）。
    expect(find.text('通用设置'), findsOneWidget);
    expect(find.text('UI 设置'), findsOneWidget);
    expect(find.text('其它设置'), findsOneWidget);
    expect(find.text('会话工作模式（实验性）', findRichText: true), findsOneWidget);
    expect(find.text('实验性设置'), findsNothing);
    expect(
      experimentalTagColor(tester, '会话工作模式（实验性）'),
      NarrChatColors.light.warning,
      reason: '「（实验性）」应使用全局警告黄，而不是标题正文色',
    );

    // UI 设置内容：主题设置可见。
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('跟随系统（默认）：随系统亮暗自动切换'), findsOneWidget);
    // UI 设置内容：默认封面设置可见。
    expect(find.text('默认封面'), findsOneWidget);
    expect(find.text('当未设置书籍封面时，首页展示的封面内容'), findsOneWidget);
    // UI 设置内容：字体设置入口行可见（字体样式 + 大小缩放的二级页入口）。
    expect(find.text('字体设置'), findsOneWidget);

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
    // 选项标题也带黄色「（实验性）」标注。
    expect(find.text('Agent 模式（实验性）', findRichText: true), findsOneWidget);
    expect(
      experimentalTagColor(tester, 'Agent 模式（实验性）'),
      NarrChatColors.light.warning,
    );
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
    await tester.tap(find.text('Agent 模式（实验性）', findRichText: true));
    await tester.pumpAndSettle();
    // 菜单只剩两个档位（无 / Agent Lv.1），且每个选项自带一行说明。
    expect(
      find.byKey(const ValueKey('experimental_agent_mode_option_0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('experimental_agent_mode_option_1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('experimental_agent_mode_option_2')),
      findsNothing,
      reason: 'Lv.2 已移除，不再出现在菜单里',
    );
    expect(find.text('无'), findsWidgets);
    expect(find.text('Agent Lv.1'), findsWidgets);
    expect(find.text('Agent Lv.2'), findsNothing);
    expect(find.text('使用传统 Chat 方式'), findsOneWidget);
    expect(find.text('记忆总结部分将由 Agent 托管'), findsOneWidget);

    // 选择 Lv.1 → Provider 乐观更新（界面即时生效）。
    await tester.tap(find.text('Agent Lv.1').last);
    await tester.pumpAndSettle();
    expect(provider.agentModeLevel, AgentModeLevel.lv1);
    expect(label(), 'Lv.1');

    // 再次点击卡片**描述文字区域**同样可展开 → 切回「无」。
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('实验性功能（默认「无」）'));
    await tester.pumpAndSettle();
    expect(find.text('Agent Lv.1'), findsWidgets);
    await tester.tap(find.text('无').last);
    await tester.pumpAndSettle();
    expect(provider.agentModeLevel, AgentModeLevel.off);
    expect(label(), '关');
  });

  testWidgets('思考链压缩：主开关默认开，子开关默认关且仅主开关开启时显示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final provider = ExperimentalSettingsProvider();
    await tester.pumpWidget(buildApp(1000, experimental: provider));
    await tester.pump();

    final parentToggle = find.byKey(
      const ValueKey('experimental_compress_non_body_reasoning_switch'),
    );
    final childToggle = find.byKey(
      const ValueKey('experimental_compress_all_reasoning_switch'),
    );
    await tester.ensureVisible(parentToggle);
    await tester.pumpAndSettle();

    // 标题本体 + 全局黄色「（实验性）」后缀；子开关默认可见但关闭。
    expect(
      find.text('压缩非正文步模型所获取到的思考链（实验性）', findRichText: true),
      findsOneWidget,
    );
    expect(
      experimentalTagColor(tester, '压缩非正文步模型所获取到的思考链（实验性）'),
      NarrChatColors.light.warning,
    );
    expect(find.text('压缩所有回合的思考链（实验性）', findRichText: true), findsOneWidget);
    expect(
      experimentalTagColor(tester, '压缩所有回合的思考链（实验性）'),
      NarrChatColors.light.warning,
    );
    expect(find.textContaining('第一步（调研 + 正文）视为正文步'), findsOneWidget);
    expect(find.textContaining('默认关'), findsWidgets);
    expect(find.textContaining('⚠ 会改写回传给模型的思考原文'), findsOneWidget);
    expect(provider.compressNonBodyReasoning, isTrue);
    expect(provider.compressAllReasoning, isFalse);
    expect(tester.widget<Switch>(parentToggle).value, isTrue);
    expect(tester.widget<Switch>(childToggle).value, isFalse);

    // 关闭主开关：子行消失，子状态强制复位。
    await tester.tap(parentToggle);
    await tester.pumpAndSettle();
    expect(provider.compressNonBodyReasoning, isFalse);
    expect(provider.compressAllReasoning, isFalse);
    expect(childToggle, findsNothing);

    // 重新打开主开关：子行回来且仍为关。
    await tester.tap(parentToggle);
    await tester.pumpAndSettle();
    expect(provider.compressNonBodyReasoning, isTrue);
    expect(provider.compressAllReasoning, isFalse);
    expect(childToggle, findsOneWidget);
    expect(tester.widget<Switch>(childToggle).value, isFalse);

    // 打开子开关。
    await tester.tap(childToggle);
    await tester.pumpAndSettle();
    expect(provider.compressAllReasoning, isTrue);
    expect(tester.widget<Switch>(childToggle).value, isTrue);
  });

  testWidgets('思考链压缩：点副标题整行切换主 / 子开关', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final provider = ExperimentalSettingsProvider();
    await tester.pumpWidget(buildApp(1000, experimental: provider));
    await tester.pump();

    final childToggle = find.byKey(
      const ValueKey('experimental_compress_all_reasoning_switch'),
    );
    await tester.ensureVisible(
      find.text('压缩非正文步模型所获取到的思考链（实验性）', findRichText: true),
    );
    await tester.pumpAndSettle();
    expect(provider.compressNonBodyReasoning, isTrue);

    // 点主开关副标题也能关闭主开关，子行随之消失。
    await tester.tap(find.textContaining('第一步（调研 + 正文）视为正文步'));
    await tester.pumpAndSettle();
    expect(provider.compressNonBodyReasoning, isFalse);
    expect(childToggle, findsNothing);

    // 点主开关副标题重新打开，再点子开关副标题开启所有回合。
    await tester.tap(find.textContaining('第一步（调研 + 正文）视为正文步'));
    await tester.pumpAndSettle();
    expect(provider.compressNonBodyReasoning, isTrue);
    await tester.tap(find.textContaining('开启后第一步的调研 / 正文回合也压缩'));
    await tester.pumpAndSettle();
    expect(provider.compressAllReasoning, isTrue);
  });

  testWidgets('非创作步子模型：跟随主模型 / 选具体模型 / 灰字缓存提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final experimental = ExperimentalSettingsProvider();
    final ai = AiSettingsProvider();
    await tester.pumpWidget(buildApp(1000, experimental: experimental, ai: ai));
    await tester.pump();

    final row = find.byKey(const ValueKey('experimental_subagent_model_card'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();

    // 默认跟随主模型；提示原句必须在灰字里。
    expect(
      find.text('非创作步所使用的模型（子模型）（实验性）', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('跨模型无法使用缓存命中'), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('experimental_subagent_model_label')),
          )
          .data,
      '与当前激活主模型一致',
    );
    expect(experimental.hasSubagentModel, isFalse);

    // 打开选择器 → 选第二个模型（DeepSeek V4 Pro）。
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('subagent_model_dialog')), findsOneWidget);
    final option = find.byKey(
      const ValueKey('subagent_model_option___default___deepseek-v4-pro'),
    );
    expect(option, findsOneWidget);
    await tester.tap(option);
    await tester.pumpAndSettle();

    expect(experimental.hasSubagentModel, isTrue);
    expect(experimental.subagentPlatformId, '__default__');
    expect(experimental.subagentModelId, 'deepseek-v4-pro');
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('experimental_subagent_model_label')),
          )
          .data,
      'deepseek-v4-pro',
    );

    // 再打开 → 选回「与当前激活主模型一致」。
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('subagent_model_follow_main')));
    await tester.pumpAndSettle();
    expect(experimental.hasSubagentModel, isFalse);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('experimental_subagent_model_label')),
          )
          .data,
      '与当前激活主模型一致',
    );
  });

  testWidgets('Agent 模式简介简要概括：托管范围、指示器限制与破坏性变更声明', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildApp(1000));
    await tester.pump();

    // 简要介绍：指向下拉选项（细节不在卡片里堆砌）。
    expect(find.textContaining('托管范围见下拉选项说明'), findsOneWidget);
    expect(find.textContaining('narrchat_*'), findsOneWidget);
    expect(find.textContaining('两步生成'), findsOneWidget);
    // 指示器限制声明 + 破坏性变更声明 + 正确性声明。
    expect(find.textContaining('无法通过对话页指示器关闭'), findsOneWidget);
    expect(find.textContaining('破坏性变更'), findsOneWidget);
    expect(find.textContaining('正确性不保证'), findsOneWidget);
    // 逐档说明移入下拉选项，不再出现在卡片简介里。
    expect(find.textContaining('previous_response_id'), findsNothing);
    expect(find.textContaining('narrchat_editWorldState'), findsNothing);
  });
}
