import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/screens/debug_screen.dart';
import 'package:narrchat/screens/settings_screen.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

void main() {
  /// 直接以「关于」面板为初始页打开设置页。
  ///
  /// 设置页首页已是「通用设置」（依赖 UI / 实验性设置 Provider 与系统字体
  /// 扫描），本用例只测版本号连点，故用 [SettingsScreen.pageIndexAbout]
  /// 直达关于面板，保持脚手架最小（仅需 API / 云同步两个 Provider）。
  Future<void> openAbout(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AiSettingsProvider(),
        child: ChangeNotifierProvider(
          create: (_) => CloudSyncProvider(),
          child: MaterialApp(
            theme: NarrChatTheme.light,
            home: const SettingsScreen(
              initialIndex: SettingsScreen.pageIndexAbout,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('连点版本号三次进入调试页', (tester) async {
    await openAbout(tester);

    final tapTarget = find.byKey(const ValueKey('about_version_tap'));
    expect(tapTarget, findsOneWidget);

    await tester.tap(tapTarget);
    await tester.pump();
    await tester.tap(tapTarget);
    await tester.pump();
    await tester.tap(tapTarget);
    await tester.pumpAndSettle();

    expect(find.byType(DebugScreen), findsOneWidget);
  });

  testWidgets('超过窗口未满三次不进入调试页，第三次才进入', (tester) async {
    await openAbout(tester);

    final tapTarget = find.byKey(const ValueKey('about_version_tap'));
    expect(tapTarget, findsOneWidget);

    await tester.tap(tapTarget);
    await tester.pump();
    await tester.tap(tapTarget);
    await tester.pump();
    // 超过窗口（800ms），计数重置。
    await tester.pump(const Duration(milliseconds: 900));
    await tester.tap(tapTarget);
    await tester.pump();
    await tester.tap(tapTarget);
    await tester.pump();
    expect(find.byType(DebugScreen), findsNothing);

    await tester.tap(tapTarget);
    await tester.pumpAndSettle();
    expect(find.byType(DebugScreen), findsOneWidget);
  });
}
