import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:narrchat/models/default_cover_style.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/ui_settings_form.dart';

void main() {
  Widget buildApp(double width, {UiSettingsProvider? ui}) {
    return ChangeNotifierProvider.value(
      value: ui ?? UiSettingsProvider(persist: (_) async {}),
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
    // 字体设置入口行：显示当前字体与缩放档位（默认系统默认 / 0%）。
    expect(find.text('字体设置'), findsOneWidget);
    expect(find.text('系统默认（0%）'), findsOneWidget);
  });

  testWidgets('宽屏下主题设置保持横向布局', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildApp(1000));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('跟随系统（默认）：随系统亮暗自动切换'), findsOneWidget);
    expect(find.text('字体设置'), findsOneWidget);
  });

  testWidgets('默认封面：默认插画1，可展开选择无插画', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ui = UiSettingsProvider(persist: (_) async {});
    await tester.pumpWidget(buildApp(1000, ui: ui));
    await tester.pump();

    expect(find.text('默认封面'), findsOneWidget);
    expect(find.text('当未设置书籍封面时，首页展示的封面内容'), findsOneWidget);
    expect(find.text('插画1'), findsOneWidget);
    expect(ui.defaultCoverStyle, DefaultCoverStyle.illustration1);

    await tester.tap(
      find.byKey(const ValueKey('ui_settings_default_cover_menu')),
    );
    await tester.pumpAndSettle();
    expect(find.text('无插画'), findsOneWidget);

    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<DefaultCoverStyle>, '无插画'),
    );
    await tester.pumpAndSettle();

    expect(ui.defaultCoverStyle, DefaultCoverStyle.noIllustration);
    expect(find.text('无插画'), findsOneWidget);
    expect(find.text('插画1'), findsNothing);
  });
}
