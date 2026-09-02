import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/debug_screen.dart';
import 'package:narrchat/services/update_check_service.dart';
import 'package:narrchat/theme/app_theme.dart';

import 'helpers/fakes.dart';

const GitHubRelease _release = GitHubRelease(
  tagVersion: 'v1.4.0',
  displayName: 'NarrChat 1.4.0',
  pageUrl: 'https://github.com/XuezuoYS/NarrChat/releases/tag/v1.4.0',
  notes: '## 更新内容\n- 新功能',
  publishedAt: '2026-01-01T00:00:00Z',
);

const String _probeItemLabel = '触发检查到更新的提示框（即使版本相同或更旧也触发）';

Future<void> _pumpDebugScreen(
  WidgetTester tester,
  FakeUpdateCheckService service,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      home: DebugScreen(updateService: service),
    ),
  );
}

/// 点击「触发检查到更新的提示框」入口。
Future<void> _tapProbeItem(WidgetTester tester) async {
  final target = find.text(_probeItemLabel);
  expect(target, findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('强制触发：以 forceShow 发起检查并弹出「发现新版本」对话框',
      (tester) async {
    final service = FakeUpdateCheckService([UpdateAvailable(_release)]);
    await _pumpDebugScreen(tester, service);

    await _tapProbeItem(tester);

    // 调试入口必须绕过版本比较：无论本地版本比远端新/旧都强制展示。
    expect(service.calls, 1);
    expect(service.forceShowValues, [true]);
    expect(service.checkedVersions, hasLength(1));
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.textContaining('v1.4.0 已发布'), findsOneWidget);
    expect(find.textContaining('当前版本'), findsOneWidget);
  });

  testWidgets('检查失败：SnackBar 提示原因，不弹对话框', (tester) async {
    final service =
        FakeUpdateCheckService([const CheckFailed('网络请求失败：boom')]);
    await _pumpDebugScreen(tester, service);

    await _tapProbeItem(tester);

    expect(service.forceShowValues, [true]);
    expect(find.text('发现新版本'), findsNothing);
    expect(find.text('检查更新失败：网络请求失败：boom'), findsOneWidget);
  });

  testWidgets('仓库无发布：SnackBar 提示未获取到发布信息', (tester) async {
    final service = FakeUpdateCheckService([const NoRelease()]);
    await _pumpDebugScreen(tester, service);

    await _tapProbeItem(tester);

    expect(service.forceShowValues, [true]);
    expect(find.text('发现新版本'), findsNothing);
    expect(find.text('未获取到 GitHub 发布信息'), findsOneWidget);
  });
}
