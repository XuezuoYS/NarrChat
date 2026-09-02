import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/general_settings_form.dart';

void main() {
  Widget buildApp(double width) {
    return ChangeNotifierProvider.value(
      value: UiSettingsProvider(),
      child: ChangeNotifierProvider(
        // Agent 模式开关由实验性设置 Provider 驱动（构造注入初值，
        // 不触碰真实配置文件）。
        create: (_) => ExperimentalSettingsProvider(),
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

    // 实验性设置内容：Agent 模式开关（默认关闭）。
    expect(
      find.byKey(const ValueKey('experimental_agent_mode_switch')),
      findsOneWidget,
    );
    expect(find.text('Agent 模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Agent 模式开关默认关闭，切换后界面即时生效', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildApp(1000));
    await tester.pump();

    Switch switchWidget() => tester.widget<Switch>(
          find.byKey(const ValueKey('experimental_agent_mode_switch')),
        );

    // 默认关闭（与实验性功能声明一致）。
    expect(switchWidget().value, isFalse);

    // 点击开关 → 开启（Provider 乐观更新）。
    await tester.tap(find.byKey(const ValueKey('experimental_agent_mode_switch')));
    await tester.pump();
    expect(switchWidget().value, isTrue);

    await tester.tap(find.byKey(const ValueKey('experimental_agent_mode_switch')));
    await tester.pump();
    expect(switchWidget().value, isFalse);
  });

  testWidgets('Agent 模式描述声明自定义工具、所用特性与风险', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildApp(1000));
    await tester.pump();

    // 工具清单（自定义工具）。
    expect(find.textContaining('narrchat_readState'), findsOneWidget);
    expect(find.textContaining('narrchat_editSection'), findsOneWidget);
    expect(find.textContaining('narrchat_webSearch'), findsOneWidget);
    expect(find.textContaining('narrchat_webFetchPage'), findsOneWidget);

    // 特性声明：两阶段生成 / tool_choice / previous_response_id / 状态工作副本。
    expect(find.textContaining('两阶段生成'), findsOneWidget);
    expect(find.textContaining('tool_choice'), findsOneWidget);
    expect(find.textContaining('previous_response_id'), findsOneWidget);
    expect(find.textContaining('状态工作副本'), findsOneWidget);

    // 风险声明：可能错误、服务商支持程度不同 / 不被支持、不保证。
    expect(find.textContaining('可能导致请求失败'), findsOneWidget);
    expect(find.textContaining('不被支持'), findsOneWidget);
    expect(find.textContaining('正确性不保证'), findsOneWidget);
    expect(find.textContaining('默认关闭'), findsOneWidget);
  });
}
