import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/ui_settings_form.dart';

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
                child: const UiSettingsForm(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('窄屏下主题设置不挤压、不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildApp(400));
    await tester.pump();

    // 窄屏下不应出现布局溢出异常。
    expect(tester.takeException(), isNull);
    // 左侧文字描述完整可见，未被右侧控件挤压。
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('跟随系统（默认）：随系统亮暗自动切换'), findsOneWidget);
    // 三个主题选项均可见。
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('亮色'), findsOneWidget);
    expect(find.text('暗色'), findsOneWidget);
  });

  testWidgets('宽屏下主题设置保持横向布局', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildApp(1000));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('跟随系统（默认）：随系统亮暗自动切换'), findsOneWidget);
  });
}
