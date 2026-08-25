import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/screens/debug_screen.dart';
import 'package:narrchat/screens/settings_screen.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

void main() {
  Widget buildSettings() {
    return ChangeNotifierProvider(
      create: (_) => AiSettingsProvider(),
      child: ChangeNotifierProvider(
        create: (_) => CloudSyncProvider(),
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: const SettingsScreen(),
        ),
      ),
    );
  }

  Future<void> openAbout(WidgetTester tester) async {
    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
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
