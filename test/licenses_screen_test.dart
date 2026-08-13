import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/screens/licenses_screen.dart';
import 'package:narrchat/screens/settings_screen.dart';
import 'package:narrchat/theme/app_theme.dart';

void main() {
  setUp(() {
    // 测试环境无构建期 NOTICES，需自行注册许可证数据。
    LicenseRegistry.reset();
  });

  group('LicensesScreen', () {
    testWidgets('渲染许可证卡片，次级标题取首行，点击弹出详情对话框', (tester) async {
      LicenseRegistry.addLicense(() async* {
        yield const LicenseEntryWithLineBreaks(
          ['provider'],
          'BSD-3-Clause License\n\nCopyright (c) 2024 Remi Rousselet',
        );
        yield const LicenseEntryWithLineBreaks(
          ['sqflite', 'sqflite_common'],
          'MIT License\n\nCopyright (c) 2024 Tekartik',
        );
      });

      await tester.pumpWidget(
        MaterialApp(theme: NarrChatTheme.light, home: const LicensesScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('provider'), findsOneWidget);
      expect(find.text('sqflite'), findsOneWidget);
      expect(find.text('sqflite_common'), findsOneWidget);

      // 次级标题 = 首个非空行（不拼接作者）。
      expect(find.text('BSD-3-Clause License'), findsOneWidget);
      // 同一许可证覆盖多个包（sqflite / sqflite_common）→ 次级标题各出现一次。
      expect(find.text('MIT License'), findsNWidgets(2));

      // 未打开对话框时，许可证正文不在树中。
      expect(
        find.textContaining('Copyright (c) 2024 Remi Rousselet'),
        findsNothing,
      );

      // 点击卡片 → 弹出详情对话框（标题 + 完整可复制的许可证全文）。
      await tester.tap(find.text('provider'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Copyright (c) 2024 Remi Rousselet'),
        findsOneWidget,
      );
      expect(find.text('复制全文'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);
    });

    testWidgets('按包名排序（忽略大小写）', (tester) async {
      LicenseRegistry.addLicense(() async* {
        yield const LicenseEntryWithLineBreaks(['zeta'], 'Z');
        yield const LicenseEntryWithLineBreaks(['Alpha'], 'A');
        yield const LicenseEntryWithLineBreaks(['beta'], 'B');
      });

      await tester.pumpWidget(
        MaterialApp(theme: NarrChatTheme.light, home: const LicensesScreen()),
      );
      await tester.pumpAndSettle();

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(texts.indexOf('Alpha'), lessThan(texts.indexOf('beta')));
      expect(texts.indexOf('beta'), lessThan(texts.indexOf('zeta')));
    });

    testWidgets('无许可证时显示空态', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: NarrChatTheme.light, home: const LicensesScreen()),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂未发现开放源代码许可证'), findsOneWidget);
    });
  });

  group('设置「关于」面板入口', () {
    testWidgets('点击「开放源代码许可」打开许可证页', (tester) async {
      LicenseRegistry.addLicense(() async* {
        yield const LicenseEntryWithLineBreaks(['demo'], 'MIT License');
      });

      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => AiSettingsProvider(),
          child: MaterialApp(
            theme: NarrChatTheme.light,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 切到「关于」标签。
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();

      expect(find.text('开放源代码许可'), findsOneWidget);
      await tester.tap(find.text('开放源代码许可'));
      await tester.pumpAndSettle();

      // 已打开许可证页，且手动注册的条目可见。
      expect(find.byType(LicensesScreen), findsOneWidget);
      expect(find.text('demo'), findsOneWidget);
    });
  });
}
