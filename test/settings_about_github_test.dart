import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/app_config.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/screens/settings_screen.dart';
import 'package:narrchat/services/app_notice_center.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/github_badge.dart';
import 'package:provider/provider.dart';

import 'helpers/notice_harness.dart';

/// 「关于」页 GitHub 徽章入口：展示、打开浏览器、打开失败兜底复制。
void main() {
  /// 以宽屏视口直达「关于」面板（只挂设置页所需的两个 Provider）。
  Future<void> pumpAbout(
    WidgetTester tester, {
    required Future<bool> Function(Uri url) openLink,
    Widget Function(BuildContext, Widget?)? builder,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AiSettingsProvider(),
        child: ChangeNotifierProvider(
          create: (_) => CloudSyncProvider(),
          child: MaterialApp(
            theme: NarrChatTheme.light,
            builder: builder,
            home: SettingsScreen(
              initialIndex: SettingsScreen.pageIndexAbout,
              externalLinkOpener: openLink,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('关于页展示 GitHub 徽章与仓库链接入口', (tester) async {
    await pumpAbout(tester, openLink: (_) async => true);

    // 徽章：官方 mark 图 + 「GitHub」字标。
    final badge = find.byType(GitHubBadge);
    expect(badge, findsOneWidget);
    final mark = tester.widget<Image>(
      find.descendant(of: badge, matching: find.byType(Image)),
    );
    expect((mark.image as AssetImage).assetName, GitHubBadge.markAsset);
    expect(
      find.descendant(of: badge, matching: find.text('GitHub')),
      findsOneWidget,
    );

    // 链接行：仓库名 + 完整地址 + 尾部「在浏览器中打开」图标。
    expect(find.text('NarrChat 开源仓库'), findsOneWidget);
    expect(find.text(AppConfig.githubRepoUrl), findsOneWidget);
    final row = find.byKey(const ValueKey('about_github'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.open_in_new)),
      findsOneWidget,
    );
  });

  testWidgets('点击 GitHub 入口用系统浏览器打开仓库地址', (tester) async {
    Uri? opened;
    await pumpAbout(
      tester,
      openLink: (url) async {
        opened = url;
        return true;
      },
    );

    await tester.tap(find.byKey(const ValueKey('about_github')));
    await tester.pumpAndSettle();

    expect(opened, Uri.parse(AppConfig.githubRepoUrl));
  });

  testWidgets('浏览器打不开时复制链接并提示', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final center = AppNoticeCenter();
    addTearDown(center.dispose);

    await pumpAbout(
      tester,
      openLink: (_) async => false,
      builder: floatingNoticeBuilder(center: center),
    );

    await tester.tap(find.byKey(const ValueKey('about_github')));
    await tester.pump();
    await settleNoticeEnter(tester);

    expect(copied, AppConfig.githubRepoUrl);
    expect(find.text('无法打开浏览器，GitHub 链接已复制'), findsOneWidget);

    drainNotices(center);
    await tester.pump();
  });
}
