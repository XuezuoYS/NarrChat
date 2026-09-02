import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/general_settings_form.dart';

void main() {
  Widget buildApp(double width) {
    return ChangeNotifierProvider.value(
      value: UiSettingsProvider(),
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

    // 实验性设置内容：占位文案。
    expect(find.text('暂无实验性功能，敬请期待。'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
