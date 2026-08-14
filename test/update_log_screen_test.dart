import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/screens/settings_screen.dart';
import 'package:narrchat/screens/update_log_screen.dart';
import 'package:narrchat/theme/app_theme.dart';

void main() {
  group('更新日志功能', () {
    testWidgets('渲染 md 内容；关于页入口可打开更新日志页', (tester) async {
      // 1) 直接打开：解析并渲染 update_log.md。
      await tester.pumpWidget(
        MaterialApp(theme: NarrChatTheme.light, home: const UpdateLogScreen()),
      );
      await tester.pumpAndSettle();

      // AppBar 标题。
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('更新日志')),
        findsOneWidget,
      );
      // md 正文被解析渲染（含已知条目与版本标题）。
      // ⚠️ MarkdownPreview 标题/正文以 TextSpan 渲染，需用 textContaining。
      expect(find.textContaining('支持输入框 md 语法高亮'), findsOneWidget);
      expect(find.textContaining('1.2.1'), findsWidgets);
      expect(tester.takeException(), isNull);

      // 2) 换树为设置页：关于面板入口可打开更新日志页。
      // ⚠️ 同一测试内完成（rootBundle 缓存同一已完成 Future），避免跨测试
      // 加载同一资源键时 Future 挂起导致 pumpAndSettle 超时。
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => AiSettingsProvider(),
          child: ChangeNotifierProvider(
            create: (_) => CloudSyncProvider(),
            child: MaterialApp(
              theme: NarrChatTheme.light,
              home: const SettingsScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 切到「关于」标签。
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();

      expect(find.text('更新日志'), findsOneWidget);
      await tester.tap(find.text('更新日志'));
      await tester.pumpAndSettle();

      // 已打开更新日志页，且 md 内容被解析渲染。
      expect(find.byType(UpdateLogScreen), findsOneWidget);
      expect(find.textContaining('1.2.1'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
